function Initialize-BudaNativeFilePicker {
    if ('InstaladorBuda.NativeFilePicker' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace InstaladorBuda {
    [Flags]
    internal enum FileOpenOptions : uint {
        OverwritePrompt = 0x00000002,
        StrictFileTypes = 0x00000004,
        NoChangeDirectory = 0x00000008,
        PathMustExist = 0x00000800,
        FileMustExist = 0x00001000,
        ForceFileSystem = 0x00000040,
        AllowMultiSelect = 0x00000200,
        PickFolders = 0x00000020
    }

    internal enum DisplayNameType : uint { FileSystemPath = 0x80058000 }
    internal enum AddPlaceLocation { Bottom = 0, Top = 1 }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DialogFilter {
        [MarshalAs(UnmanagedType.LPWStr)] public string Name;
        [MarshalAs(UnmanagedType.LPWStr)] public string Spec;
        public DialogFilter(string name, string spec) { Name = name; Spec = spec; }
    }

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogCom { }

    [ComImport, Guid("D57C7288-D4AD-4768-BE02-9D969532D960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog {
        [PreserveSig] int Show(IntPtr owner);
        void SetFileTypes(uint count, [In, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.Struct, SizeParamIndex = 0)] DialogFilter[] filters);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(FileOpenOptions options);
        void GetOptions(out FileOpenOptions options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetResult(out IShellItem item);
        void AddPlace(IShellItem item, AddPlaceLocation where);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr filter);
        void GetResults(out IShellItemArray results);
        void GetSelectedItems(out IShellItemArray results);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        [PreserveSig] int GetDisplayName(DisplayNameType kind, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [ComImport, Guid("B63EA76D-1F85-456F-A19C-48159EFA858B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItemArray {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetPropertyStore(int flags, ref Guid iid, out IntPtr result);
        void GetPropertyDescriptionList(IntPtr key, ref Guid iid, out IntPtr result);
        void GetAttributes(uint flags, uint mask, out uint attributes);
        void GetCount(out uint count);
        void GetItemAt(uint index, out IShellItem item);
        void EnumItems(out IntPtr items);
    }

    public static class NativeFilePicker {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, out IShellItem item);

        [DllImport("ole32.dll")]
        private static extern void CoTaskMemFree(IntPtr memory);

        public static Task<string[]> ShowAsync(bool pickFolder, string title, string initialFolder, string currentFile,
            string[] filterNames, string[] filterSpecs, string[] recentFolders, Guid clientGuid,
            IntPtr owner, bool allowMultiSelect) {
            var completion = new TaskCompletionSource<string[]>();
            var worker = new Thread(() => {
                try { completion.SetResult(ShowOnSta(pickFolder, title, initialFolder, currentFile, filterNames, filterSpecs, recentFolders, clientGuid, owner, allowMultiSelect)); }
                catch (Exception error) { completion.SetException(error); }
            });
            worker.IsBackground = true;
            worker.SetApartmentState(ApartmentState.STA);
            worker.Start();
            return completion.Task;
        }

        private static string[] ShowOnSta(bool pickFolder, string title, string initialFolder, string currentFile,
            string[] filterNames, string[] filterSpecs, string[] recentFolders, Guid clientGuid,
            IntPtr owner, bool allowMultiSelect) {
            IFileOpenDialog dialog = null;
            var shellItems = new List<object>();
            try {
                dialog = (IFileOpenDialog)new FileOpenDialogCom();
                dialog.SetTitle(title ?? String.Empty);
                dialog.SetClientGuid(ref clientGuid);
                var options = FileOpenOptions.PathMustExist | FileOpenOptions.ForceFileSystem | FileOpenOptions.NoChangeDirectory;
                if (pickFolder) options |= FileOpenOptions.PickFolders;
                else {
                    options |= FileOpenOptions.FileMustExist;
                    if (allowMultiSelect) options |= FileOpenOptions.AllowMultiSelect;
                }
                dialog.SetOptions(options);

                if (!pickFolder && filterNames != null && filterSpecs != null && filterNames.Length > 0 && filterNames.Length == filterSpecs.Length) {
                    var filters = new DialogFilter[filterNames.Length];
                    for (int i = 0; i < filters.Length; i++) filters[i] = new DialogFilter(filterNames[i], filterSpecs[i]);
                    dialog.SetFileTypes((uint)filters.Length, filters);
                }

                if (!String.IsNullOrWhiteSpace(initialFolder) && DirectoryExists(initialFolder)) {
                    var folder = CreateShellItem(initialFolder);
                    shellItems.Add(folder);
                    dialog.SetFolder(folder);
                }
                if (!pickFolder && !String.IsNullOrWhiteSpace(currentFile) && FileExists(currentFile)) {
                    dialog.SetFileName(System.IO.Path.GetFileName(currentFile));
                }

                if (recentFolders != null) {
                    foreach (var path in recentFolders) {
                        if (String.IsNullOrWhiteSpace(path) || !DirectoryExists(path)) continue;
                        try {
                            var place = CreateShellItem(path);
                            shellItems.Add(place);
                            dialog.AddPlace(place, AddPlaceLocation.Top);
                        } catch { }
                    }
                }

                int result = dialog.Show(owner);
                if (result == unchecked((int)0x800704C7)) return new string[0];
                Marshal.ThrowExceptionForHR(result);

                IShellItemArray results;
                dialog.GetResults(out results);
                if (results == null) return new string[0];
                shellItems.Add(results);
                uint count;
                results.GetCount(out count);
                var selected = new List<string>();
                for (uint i = 0; i < count; i++) {
                    IShellItem item;
                    results.GetItemAt(i, out item);
                    if (item == null) continue;
                    shellItems.Add(item);
                    IntPtr displayName = IntPtr.Zero;
                    try {
                        int hr = item.GetDisplayName(DisplayNameType.FileSystemPath, out displayName);
                        Marshal.ThrowExceptionForHR(hr);
                        if (displayName != IntPtr.Zero) selected.Add(Marshal.PtrToStringUni(displayName));
                    } finally { if (displayName != IntPtr.Zero) CoTaskMemFree(displayName); }
                }
                return selected.ToArray();
            } finally {
                foreach (var item in shellItems) if (item != null && Marshal.IsComObject(item)) { try { Marshal.FinalReleaseComObject(item); } catch { } }
                if (dialog != null && Marshal.IsComObject(dialog)) { try { Marshal.FinalReleaseComObject(dialog); } catch { } }
            }
        }

        private static IShellItem CreateShellItem(string path) {
            Guid iid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
            IShellItem item;
            int result = SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item);
            Marshal.ThrowExceptionForHR(result);
            return item;
        }

        private static bool DirectoryExists(string path) { try { return System.IO.Directory.Exists(path); } catch { return false; } }
        private static bool FileExists(string path) { try { return System.IO.File.Exists(path); } catch { return false; } }
    }
}
'@
}

function Get-BudaFileDialogMemoryPath {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    return (Join-Path $localData 'InstaladorBUDA\file-dialog-memory.json')
}

function Get-BudaFileDialogMemory {
    $memory = @{ Folders = @{}; Guids = @{}; Recent = @() }
    $path = Get-BudaFileDialogMemoryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $memory }
    try {
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($saved.folders) { foreach ($property in $saved.folders.PSObject.Properties) { $memory.Folders[[string]$property.Name] = [string]$property.Value } }
        if ($saved.guids) { foreach ($property in $saved.guids.PSObject.Properties) { $memory.Guids[[string]$property.Name] = [string]$property.Value } }
        if ($saved.recent) { $memory.Recent = @($saved.recent | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    } catch { }
    return $memory
}

function Save-BudaFileDialogMemory {
    param([hashtable]$Memory)
    $path = Get-BudaFileDialogMemoryPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    $saved = [ordered]@{ folders = $Memory.Folders; guids = $Memory.Guids; recent = @($Memory.Recent | Select-Object -First 5) }
    [IO.File]::WriteAllText($path, ($saved | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}

function Resolve-BudaExistingFolder {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { $candidate = [IO.Path]::GetFullPath($Path) } catch { return '' }
    while ($candidate -and -not (Test-Path -LiteralPath $candidate -PathType Container)) {
        $parent = [IO.Directory]::GetParent($candidate)
        if (-not $parent) { return '' }
        $candidate = $parent.FullName
    }
    return $candidate
}

function Invoke-BudaFilePicker {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][ValidateSet('File','Folder')][string]$Purpose,
        [Parameter(Mandatory=$true)][string]$Title,
        [System.Windows.Forms.IWin32Window]$Owner,
        [string]$CurrentFile,
        [string]$CurrentFolder,
        [string]$DefaultFolder,
        [object[]]$Filters = @()
    )

    $memory = Get-BudaFileDialogMemory
    if (-not $memory.Guids.ContainsKey($Key)) { $memory.Guids[$Key] = [guid]::NewGuid().ToString('D') }
    $currentFileFolder = ''
    if ($CurrentFile -and (Test-Path -LiteralPath $CurrentFile -PathType Leaf)) { $currentFileFolder = Split-Path -Parent (Resolve-Path -LiteralPath $CurrentFile).Path }
    $remembered = if ($memory.Folders.ContainsKey($Key)) { [string]$memory.Folders[$Key] } else { '' }
    $currentFolder = if ($Purpose -eq 'Folder') { $CurrentFolder } else { $currentFileFolder }
    $initial = Resolve-BudaExistingFolder $currentFolder
    if (-not $initial) { $initial = Resolve-BudaExistingFolder $remembered }
    if (-not $initial) { $initial = Resolve-BudaExistingFolder $DefaultFolder }
    if (-not $initial -and $memory.Recent.Count -gt 0) { $initial = Resolve-BudaExistingFolder ([string]$memory.Recent[0]) }
    if (-not $initial) { $initial = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) }

    $filterNames = @(); $filterSpecs = @()
    if ($Purpose -eq 'File') {
        foreach ($filter in $Filters) {
            if ($filter -and $filter.Name -and $filter.Pattern) { $filterNames += [string]$filter.Name; $filterSpecs += [string]$filter.Pattern }
        }
        $allIndex = [Array]::IndexOf([string[]]$filterNames, 'All files (*.*)')
        if ($allIndex -ge 0) { $filterNames = @($filterNames | Where-Object { $_ -ne 'All files (*.*)' }); $filterSpecs = @($filterSpecs | Where-Object { $_ -ne '*.*' }) }
        $filterNames += 'All files (*.*)'; $filterSpecs += '*.*'
    }
    $recentPlaces = @($memory.Recent | ForEach-Object { Resolve-BudaExistingFolder $_ } | Where-Object { $_ } | Select-Object -Unique -First 5)
    $ownerHandle = if ($Owner) { $Owner.Handle } else { [IntPtr]::Zero }
    $paths = @()
    try {
        Initialize-BudaNativeFilePicker
        $dialogTask = [InstaladorBuda.NativeFilePicker]::ShowAsync(
            ($Purpose -eq 'Folder'), $Title, $initial, $CurrentFile,
            [string[]]$filterNames, [string[]]$filterSpecs, [string[]]$recentPlaces,
            [guid]$memory.Guids[$Key], $ownerHandle, $true)
        while (-not $dialogTask.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 15
        }
        $paths = @($dialogTask.GetAwaiter().GetResult())
    } catch {
        # The platform dialogs remain a fallback if COM is unavailable on this Windows build.
        if ($Purpose -eq 'Folder') {
            $fallback = New-Object System.Windows.Forms.FolderBrowserDialog
            try {
                $fallback.Description = $Title
                $fallback.ShowNewFolderButton = $false
                $fallback.SelectedPath = $initial
                $result = if ($Owner) { $fallback.ShowDialog($Owner) } else { $fallback.ShowDialog() }
                if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $paths = @($fallback.SelectedPath) }
            } finally { $fallback.Dispose() }
        } else {
            $fallback = New-Object System.Windows.Forms.OpenFileDialog
            try {
                $fallback.Title = $Title
                $fallback.InitialDirectory = $initial
                $fallback.Filter = (($filterNames | ForEach-Object -Begin { $i = 0 } -Process { $n = $_; $spec = $filterSpecs[$i]; $i++; "$n|$spec" }) -join '|')
                $fallback.CheckFileExists = $true
                $fallback.Multiselect = $true
                if ($CurrentFile -and (Test-Path -LiteralPath $CurrentFile -PathType Leaf)) { $fallback.FileName = $CurrentFile }
                $result = if ($Owner) { $fallback.ShowDialog($Owner) } else { $fallback.ShowDialog() }
                if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $paths = @($fallback.FileNames) }
            } finally { $fallback.Dispose() }
        }
    }
    if (-not $paths -or $paths.Count -eq 0) { Save-BudaFileDialogMemory $memory; return ,@() }
    $chosenFolder = if ($Purpose -eq 'Folder') { [string]$paths[0] } else { Split-Path -Parent ([string]$paths[0]) }
    $chosenFolder = Resolve-BudaExistingFolder $chosenFolder
    if ($chosenFolder) {
        $memory.Folders[$Key] = $chosenFolder
        $memory.Recent = @($chosenFolder) + @($memory.Recent | Where-Object { $_ -ine $chosenFolder })
    }
    Save-BudaFileDialogMemory $memory
    return ,@($paths | ForEach-Object { [string]$_ })
}
