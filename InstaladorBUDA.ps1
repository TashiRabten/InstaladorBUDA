<#
.SYNOPSIS
    InstaladorBUDA — a small standalone deployment cockpit for the BUDA apps.
    Pick a target app + version and Upload models / push a release tag / trigger a
    workflow, without memorizing the commands. Every action has a command fallback:
    tick "Dry run" to print the exact command, or run it in a real console window.

.DESCRIPTION
    Fully config-driven: the app list comes from apps.json next to this script (or the
    compiled .exe). Register Git-only projects in the bootstrap panel or add release
    targets to apps.json. See README.md.

    Runs as a .ps1 or as InstaladorBUDA.exe (built with build-exe.ps1 via ps2exe).
    The .exe is self-contained except for apps.json, which must sit beside it.

.PARAMETER Console
    Skip the GUI and use the interactive text menu (also the automatic fallback when
    Windows Forms cannot load).

.PARAMETER ConfigPath
    Path to apps.json. Defaults to the file next to this script / the .exe.

.PARAMETER Cli
    Send one JSON command to the visible cockpit, for example:
    -Cli '{"command":"status"}' or -Cli '{"command":"action","action":"dispatch","tab":1}'.

.EXAMPLE
    .\InstaladorBUDA.ps1
.EXAMPLE
    .\InstaladorBUDA.ps1 -Console
#>
using module .\modules\AppRegistry.psm1
[CmdletBinding()]
param(
    [switch]$Console,
    [string]$ConfigPath,
    [string]$Cli
)

$ErrorActionPreference = 'Stop'
$script:SelfPath = $PSCommandPath   # set when running as .ps1; $null inside a ps2exe .exe

#__APP_REGISTRY_CLASS__

# ── Resolve the directory holding this script / exe (so apps.json is found either way) ──
function Get-AppDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    try { return Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
    return (Get-Location).Path
}
$AppDir  = Get-AppDir
$cfgFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $AppDir 'apps.json' }

if ($script:SelfPath) {
    . (Join-Path $AppDir 'modules\GitBootstrap.ps1')
    . (Join-Path $AppDir 'modules\ReleaseOperations.ps1')
    . (Join-Path $AppDir 'modules\AppSelection.ps1')
    . (Join-Path $AppDir 'modules\GuiLayout.ps1')
    . (Join-Path $AppDir 'modules\FilePicker.ps1')
    . (Join-Path $AppDir 'modules\GitIgnore.ps1')
    . (Join-Path $AppDir 'modules\AgentProfiles.ps1')
    . (Join-Path $AppDir 'modules\CodeCli.ps1')
    . (Join-Path $AppDir 'modules\CockpitHelp.ps1')
    . (Join-Path $AppDir 'modules\Cockpit.ps1')
    . (Join-Path $AppDir 'modules\Gui.ps1')
} else {
    #__GIT_BOOTSTRAP_MODULE__
    #__RELEASE_OPERATIONS_MODULE__
    #__APP_SELECTION_MODULE__
    #__GUI_LAYOUT_MODULE__
    #__FILE_PICKER_MODULE__
    #__GIT_IGNORE_MODULE__
    #__AGENT_PROFILES_MODULE__
    #__CODE_CLI_MODULE__
    #__COCKPIT_HELP_MODULE__
    #__COCKPIT_MODULE__
    #__GUI_MODULE__
}

if (-not (Test-Path $cfgFile)) {
    $m = "apps.json not found at: $cfgFile`nKeep apps.json next to InstaladorBUDA."
    try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($m, 'InstaladorBUDA', 'OK', 'Error') | Out-Null } catch { Write-Error $m }
    return
}
$script:AppRegistry = [BudaAppRegistry]::new($cfgFile)
$script:Config = $script:AppRegistry.Config
$script:Tasks = @($script:Config.tasks)
$ReleaseRepo = if ($script:Config.releaseRepoDefault) { $script:Config.releaseRepoDefault } else { 'TashiRabten/GlossarioBUDA' }
$ActionsUrl  = if ($script:Config.actionsUrl) { $script:Config.actionsUrl } else { 'https://github.com/TashiRabten/TradutorBUDA/actions' }
$script:ReleaseVersionCache = @{}

$script:ControlPipeName = 'InstaladorBUDA.Control.v1'

function Initialize-ConsoleNative {
    if (-not ('InstaladorBudaConsoleNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class InstaladorBudaConsoleNative {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AllocConsole();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int standardHandle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetStdHandle(int standardHandle, IntPtr handle);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool ShowWindow(IntPtr window, int command);
}
'@
    }
}

function Initialize-CliConsole {
    if ($script:SelfPath) { return }
    try {
        Initialize-ConsoleNative
        $stdout = [InstaladorBudaConsoleNative]::GetStdHandle(-11)
        $stderr = [InstaladorBudaConsoleNative]::GetStdHandle(-12)
        if ([InstaladorBudaConsoleNative]::GetConsoleWindow() -eq [IntPtr]::Zero) {
            if (-not [InstaladorBudaConsoleNative]::AttachConsole([uint32]::MaxValue)) { [void][InstaladorBudaConsoleNative]::AllocConsole() }
        }
        if ($stdout -and $stdout -ne [IntPtr]::Zero -and $stdout.ToInt64() -ne -1) { [void][InstaladorBudaConsoleNative]::SetStdHandle(-11, $stdout) }
        if ($stderr -and $stderr -ne [IntPtr]::Zero -and $stderr.ToInt64() -ne -1) { [void][InstaladorBudaConsoleNative]::SetStdHandle(-12, $stderr) }
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $outWriter = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), $utf8NoBom)
        $outWriter.AutoFlush = $true
        [Console]::SetOut($outWriter)
        $errorWriter = [System.IO.StreamWriter]::new([Console]::OpenStandardError(), $utf8NoBom)
        $errorWriter.AutoFlush = $true
        [Console]::SetError($errorWriter)
    } catch { }
}

function Hide-GeneratedConsole {
    if ($script:SelfPath) { return }
    try {
        Initialize-ConsoleNative
        $window = [InstaladorBudaConsoleNative]::GetConsoleWindow()
        if ($window -ne [IntPtr]::Zero) { [void][InstaladorBudaConsoleNative]::ShowWindow($window, 0) }
    } catch { }
}

function Send-CockpitPipeRequest {
    param([string]$Json, [int]$ConnectTimeoutMs = 2500)
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $script:ControlPipeName,
        [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
    try {
        $pipe.Connect($ConnectTimeoutMs)
        $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine($Json)
        $line = $reader.ReadLine()
        if (-not $line) { throw 'The cockpit closed the command connection without a response.' }
        return ($line | ConvertFrom-Json)
    } finally {
        $pipe.Dispose()
    }
}

function Invoke-CockpitCli {
    param([string]$Json)
    try { $request = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $request = [pscustomobject]@{ command = $Json.Trim() }
    }
    if (-not $request.command) {
        throw 'CLI input must be JSON with a command property. Run with -Cli ''{"command":"help"}''.'
    }

    $requestJson = $request | ConvertTo-Json -Compress -Depth 12
    try { $response = Send-CockpitPipeRequest $requestJson }
    catch {
        if ($request.command -eq 'start') {
            $guiExe = Join-Path $AppDir 'InstaladorBUDA.exe'
            if (Test-Path $guiExe) {
                Start-Process -FilePath $guiExe -WorkingDirectory $AppDir | Out-Null
            } elseif ($PSCommandPath) {
                $engine = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' }
                          else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
                Start-Process -FilePath $engine -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") `
                    -WorkingDirectory $AppDir -WindowStyle Hidden | Out-Null
            } else { throw 'Cannot locate InstaladorBUDA.exe or its source script to start the cockpit.' }

            $deadline = [datetime]::UtcNow.AddSeconds(20)
            do {
                Start-Sleep -Milliseconds 300
                try { $response = Send-CockpitPipeRequest $requestJson 500; break } catch { }
            } while ([datetime]::UtcNow -lt $deadline)
            if (-not $response) { throw 'The cockpit did not start its command endpoint within 20 seconds.' }
        } else {
            throw "The visible cockpit is not running. Start it with -Cli '{`"command`":`"start`"}' or open InstaladorBUDA.exe. Details: $($_.Exception.Message)"
        }
    }

    $bootstrapCommands = @('bootstrap-plan', 'bootstrap-prepare', 'bootstrap-publish')
    $waitForJob = ($request.command -eq 'action' -and $request.action -notin @('update','actions-secrets')) -or ($request.command -in $bootstrapCommands)
    if ($request.waitMs -gt 0 -and $waitForJob -and $response.ok -and $response.data.tabId) {
        $tabId = $response.data.tabId
        $deadline = [datetime]::UtcNow.AddMilliseconds([Math]::Min([int]$request.waitMs, 3600000))
        do {
            Start-Sleep -Milliseconds 1000
            $statusJson = [pscustomobject]@{ command = 'status'; tab = $tabId } | ConvertTo-Json -Compress
            $response = Send-CockpitPipeRequest $statusJson
            $tabStatus = $response.data.tabs | Where-Object { $_.id -eq $tabId } | Select-Object -First 1
        } while ($tabStatus -and $tabStatus.running -and [datetime]::UtcNow -lt $deadline)
        if ($tabStatus -and $tabStatus.running) { $response | Add-Member -NotePropertyName timedOut -NotePropertyValue $true -Force }
    }

    [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress -Depth 12))
    if (-not $response.ok) { exit 1 }
}

function Get-App { param([string]$Name) $script:AppRegistry.Get($Name) }

# ── Version helpers ──────────────────────────────────────────────────────────
function Test-Tool { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
$HasGit = Test-Tool git
$HasGh  = Test-Tool gh

# ── Console fallback menu ────────────────────────────────────────────────────
# ── GUI ──────────────────────────────────────────────────────────────────────
# Structure: one TabControl fills the form. Each real tab is a fully independent job
# runner built by New-JobTab — its own Target/Version/Notes/Steps/log, so several
# deploys can run side by side without their output or fields interfering with each
# other. A trailing "+" tab spawns a new job tab when selected (the standard WinForms
# idiom for an add-tab button, since TabControl has no built-in one).

# ── Entry point ──────────────────────────────────────────────────────────────
if ($Cli) { Initialize-CliConsole; Invoke-CockpitCli -Json $Cli; return }
if ($Console) { Show-ConsoleMenu; return }
Hide-GeneratedConsole
try {
    Show-Gui
} catch {
    Write-Warning "GUI unavailable ($($_.Exception.Message)). Falling back to console menu."
    Show-ConsoleMenu
}
