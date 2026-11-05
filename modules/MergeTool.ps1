# Visual text-conflict editor. Writes and staging use the same confirmed job runner as Git buttons.
function Get-MergeFile {
    param([string]$Root, [string]$File)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $Root $File))
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Conflict path is outside the repository.' }
    for ($part = $path; $part -and $part.Length -ge $prefix.Length; $part = Split-Path $part) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked paths must be resolved outside the text editor.' }
    }
    if (-not (Test-Path -LiteralPath $path)) { throw 'Deleted conflict: resolve the deletion with Git before continuing.' }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt 1MB -or $bytes -contains 0) { throw 'This editor supports UTF-8 text files up to 1 MB.' }
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
    return @{ Path = $path; Text = $text; Bom = $bom; Hash = $hash }
}

function Build-MergeResolutionCommands {
    param([string]$Root, [string]$File, [string]$Text, [string]$ExpectedHash)
    $current = Get-MergeFile $Root $File
    if ($current.Hash -ne $ExpectedHash) { throw 'The file changed. Reload it before saving.' }
    if ($Text -match '(?m)^(<<<<<<< |=======$|>>>>>>> )') { throw 'Remove the conflict markers before saving.' }
    $normalized=$Text.Replace("`r`n","`n")
    if ($current.Text.Contains("`r`n")) { $normalized=$normalized.Replace("`n","`r`n") }
    $data = [Text.UTF8Encoding]::new([bool]$current.Bom).GetBytes($normalized)
    if ($current.Bom) { $data = [byte[]](@(239,187,191) + @($data)) }
    $b64 = [Convert]::ToBase64String($data)
    $p = Quote-PS $current.Path
    return @(
        "if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne '$ExpectedHash') { throw 'File changed after review; reload it.' }",
        "[IO.File]::WriteAllBytes($p, [Convert]::FromBase64String('$b64'))",
        "& git -C $(Quote-PS $Root) add -- $(Quote-PS $File)"
    )
}

function Read-MergeFiles {
    param($State)
    $selected=[string]$State.Files.SelectedItem
    $files = @(& git -C $State.App.repoRoot diff --name-only --diff-filter=U)
    if ($LASTEXITCODE) { throw 'Could not read conflicts.' }
    $State.Files.Items.Clear()
    foreach ($file in $files) { if ($file) { [void]$State.Files.Items.Add($file) } }
    if ($State.Files.Items.Count) { if ($selected -and $State.Files.Items.Contains($selected)) { $State.Files.SelectedItem=$selected } else { $State.Files.SelectedIndex = 0 } }
    else { $State.Status.Text = 'No unresolved files. Complete merge if a pull stopped for conflicts.' }
}

function Read-MergeSelection {
    param($State)
    if ($State.Files.SelectedIndex -lt 0) { return }
    $file = [string]$State.Files.SelectedItem
    $State.Snapshot = $null
    try {
        $snapshot = Get-MergeFile $State.App.repoRoot $file
        $State.Ours.Text = (Read-GitConflictSide $State.App.repoRoot $file 2).Replace("`r`n","`n").Replace("`n","`r`n")
        $State.Theirs.Text = (Read-GitConflictSide $State.App.repoRoot $file 3).Replace("`r`n","`n").Replace("`n","`r`n")
        $State.Base.Text = (Read-GitConflictSide $State.App.repoRoot $file 1).Replace("`r`n","`n").Replace("`n","`r`n")
        $State.Result.Text = $snapshot.Text.Replace("`r`n","`n").Replace("`n","`r`n"); $State.Snapshot = $snapshot
        $State.Status.Text = 'Edit the result, remove markers, then Save resolution. Refresh after the job finishes.'
    } catch { $State.Status.Text = $_.Exception.Message }
}

function Connect-MergeButtons {
    param($State)
    $State.Files.Add_SelectedIndexChanged({ Read-MergeSelection $State }.GetNewClosure())
    $State.Buttons.Refresh.Add_Click({ try { Read-MergeFiles $State } catch { $State.Status.Text = $_.Exception.Message } }.GetNewClosure())
    $State.Buttons.Ours.Add_Click({ $State.Result.Text = $State.Ours.Text }.GetNewClosure())
    $State.Buttons.Theirs.Add_Click({ $State.Result.Text = $State.Theirs.Text }.GetNewClosure())
    $State.Buttons.Save.Add_Click({
        try {
            if (-not $State.Snapshot) { throw 'Select a supported conflict file first.' }
            $commands = Build-MergeResolutionCommands $State.App.repoRoot ([string]$State.Files.SelectedItem) $State.Result.Text $State.Snapshot.Hash
            & $State.Run $commands "Save and stage resolution: $($State.Files.SelectedItem)" $false $State.App.repoRoot
        } catch { $State.Status.Text = $_.Exception.Message }
    }.GetNewClosure())
    $State.Buttons.Continue.Add_Click({
        try {
            $root = $State.App.repoRoot
            $conflicts = @(& git -C $root diff --name-only --diff-filter=U)
            if ($LASTEXITCODE -or $conflicts.Count) { throw 'Resolve and stage all conflicts first.' }
            & git -C $root rev-parse -q --verify MERGE_HEAD 2>$null | Out-Null
            if ($LASTEXITCODE) { throw 'No merge is in progress.' }
            $scanner = & $State.Scanner 'the merge cannot be committed'
            if (-not $scanner) { return }
            $commands = @(Build-GitSecretScanCommand $State.App $scanner 'commit') + @(Build-GitCommitCommands $State.App 'Merge remote updates')
            & $State.Run $commands 'Complete merge (Gitleaks first)' $false $root
        } catch { $State.Status.Text = $_.Exception.Message }
    }.GetNewClosure())
    $State.Buttons.Quit.Add_Click({
        try {
            $root = $State.App.repoRoot
            & $State.Run (Build-GitMergeQuitCommands $root) 'Forget the merge in progress (git merge --quit): the index and every file stay as they are' $false $root
        } catch { $State.Status.Text = $_.Exception.Message }
    }.GetNewClosure())
}

function Show-GitMergeTool {
    param($App, $Run, $Scanner, $Owner, $TabState)
    if ($TabState.MergeState -and -not $TabState.MergeState.Form.IsDisposed) { $TabState.MergeState.Form.Activate(); return }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Resolve conflicts - $($App.name)"
    $form.Size = New-Object System.Drawing.Size((Px $UI.Merge.Width), (Px $UI.Merge.Height))
    $form.MinimumSize = New-Object System.Drawing.Size((Px $UI.Merge.MinWidth), (Px $UI.Merge.MinHeight))
    $area=[System.Windows.Forms.Screen]::FromControl($Owner).WorkingArea
    $form.Size=New-Object System.Drawing.Size([Math]::Min($form.Width,$area.Width),[Math]::Min($form.Height,$area.Height))
    $form.StartPosition = 'CenterParent'; $form.Font = $Owner.Font
    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.ColumnCount = 3; $layout.RowCount = 4
    foreach ($i in 1..3) { [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',33.333))) }
    foreach ($height in @($UI.Merge.TopH, 0, $UI.Merge.ButtonH, $UI.Merge.StatusH)) {
        $style = if ($height) { New-Object System.Windows.Forms.RowStyle('Absolute',(Px $height)) } else { New-Object System.Windows.Forms.RowStyle('Percent',100) }
        [void]$layout.RowStyles.Add($style)
    }
    $files = New-Object System.Windows.Forms.ComboBox; $files.DropDownStyle='DropDownList'; $files.Dock='Fill'
    $layout.Controls.Add($files,0,0); $layout.SetColumnSpan($files,3)
    $state = @{App=$App; Run=$Run; Scanner=$Scanner; Form=$form; Files=$files; Buttons=@{}; Snapshot=$null}
    Add-MergeEditors $layout $state
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel; $bar.Dock='Fill'; $bar.AutoScroll=$true
    foreach ($entry in @(@('Refresh','Refresh conflicts'),@('Ours','Use local'),@('Theirs','Use incoming'),@('Save','Save resolution'),@('Continue','Complete merge'),@('Quit','Forget merge'))) {
        $button=New-Object System.Windows.Forms.Button; $button.Text=$entry[1]; $button.AutoSize=$true; $button.Height=Px $UI.BtnH
        $state.Buttons[$entry[0]]=$button; $bar.Controls.Add($button)
    }
    $layout.Controls.Add($bar,0,2); $layout.SetColumnSpan($bar,3)
    $status=New-Object System.Windows.Forms.Label; $status.Dock='Fill'; $state.Status=$status
    $layout.Controls.Add($status,0,3); $layout.SetColumnSpan($status,3)
    $form.Controls.Add($layout); Connect-MergeButtons $state
    $TabState.MergeState=$state
    Read-MergeFiles $state
    $form.Show($Owner)
}

function Add-MergeEditors {
    param($Layout, $State)
    $column=0
    foreach ($item in @(@('Ours','Local version'),@('Theirs','Incoming version'),@('Result','Resolved result (editable)'))) {
        $group=New-Object System.Windows.Forms.GroupBox; $group.Text=$item[1]; $group.Dock='Fill'
        $text=New-Object System.Windows.Forms.TextBox; $text.Multiline=$true; $text.AcceptsReturn=$true; $text.AcceptsTab=$true
        $text.WordWrap=$false; $text.ScrollBars='Both'; $text.Dock='Fill'; $text.MaxLength=0
        $text.ReadOnly=$item[0] -ne 'Result'; $text.Font=New-Object System.Drawing.Font('Consolas',$UI.Merge.FontSize)
        $State[$item[0]]=$text
        if ($item[0] -eq 'Ours') {
            $tabs=New-Object System.Windows.Forms.TabControl; $tabs.Dock='Fill'
            $local=New-Object System.Windows.Forms.TabPage; $local.Text='Local'
            $basePage=New-Object System.Windows.Forms.TabPage; $basePage.Text='Common ancestor'
            $base=New-Object System.Windows.Forms.TextBox; $base.Multiline=$true; $base.ReadOnly=$true; $base.Dock='Fill'
            $base.WordWrap=$false; $base.ScrollBars='Both'; $base.MaxLength=0; $base.Font=$text.Font
            $State.Base=$base; $local.Controls.Add($text); $basePage.Controls.Add($base)
            $tabs.TabPages.AddRange(@($local,$basePage)); $group.Controls.Add($tabs)
        } else { $group.Controls.Add($text) }
        $Layout.Controls.Add($group,$column,1); $column++
    }
}

function Resolve-GitReferenceCliButton {
    param($Request, $State, $Controls, [string]$Action)
    $field = if ($Action -eq 'git-switch') { 'gitBranch' } else { 'gitRef' }
    if (-not (Test-CliProperty $Request $field)) { throw "$Action requires $field." }
    if ($Action -eq 'git-switch') { $State.CliGitBranch = [string]$Request.gitBranch; return $Controls.Buttons.GitSwitch }
    $State.CliGitRef = [string]$Request.gitRef
    if ($Action -eq 'git-fast-forward') { return $Controls.Buttons.GitFastForward }
    return $Controls.Buttons.GitMerge
}

function Build-GitFetchCommands {
    param([string]$Root)
    return @("& git -C $(Quote-PS $Root) fetch origin; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }")
}

function Build-GitMergeCommands {
    param([string]$Root, [string]$Ref, [switch]$FastForwardOnly)
    $refName = ([string]$Ref).Trim()
    if ($refName -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $refName -match '\.\.|//|@\{|\.lock$|/$|\.$') {
        throw "Not a commit or reference name: '$Ref'."
    }
    $r = Quote-PS $Root; $q = Quote-PS $refName
    $guard = if ($FastForwardOnly) { "# Fast-forward only: Git refuses local changes that would be overwritten." } else {
        "`$dirty = & git -C $r status --porcelain; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; if (`$dirty) { throw 'Commit or preserve local changes before merging.' }"
    }
    $mergeFlags = if ($FastForwardOnly) { '--ff-only' } else { '--no-edit --no-commit' }
    return @(
        "& git -C $r rev-parse -q --verify MERGE_HEAD *> `$null; if (`$LASTEXITCODE -eq 0) { throw 'A merge is in progress: finish it with Resolve conflicts first.' }; `$global:LASTEXITCODE = 0",
        $guard,
        "& git -C $r rev-parse --verify $(Quote-PS ($refName + '^{commit}')); if (`$LASTEXITCODE) { throw 'The selected commit or reference is unavailable. Fetch first.' }",
        "& git -C $r merge $mergeFlags $q; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }",
        "& git -C $r -c core.quotepath=false status --short --branch"
    )
}

function Build-GitPullCommands {
    param([string]$Root)
    $r = Quote-PS $Root
    return @(
        "`$dirty = & git -C $r status --porcelain; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; if (`$dirty) { throw 'Commit or stash local changes before pulling.' }",
        "& git -C $r pull --no-rebase --no-commit"
    )
}

# Switch branch: the target first brought up to date from GitHub when that loses nothing (a fast-forward of a branch
# that is not the current one; one with commits GitHub lacks stops everything), then git switch --merge, which takes
# the local changes along with a three-way merge and changes nothing when an untracked file would be overwritten. A
# merge in progress stops it before anything runs. git switch --merge exits 0 even when it leaves conflict markers,
# so the files it could not merge are named and the step fails, for Resolve conflicts.
# Forget a merge that will not be completed (one a pull stopped long ago, whose changes another way already brought):
# git merge --quit drops MERGE_HEAD and keeps the index and every file as they are, so nothing is undone or lost, as
# --abort would. Refused while a file is still in conflict.
function Build-GitMergeQuitCommands {
    param([string]$Root)
    $r = Quote-PS $Root
    return @(
        "& git -C $r rev-parse -q --verify MERGE_HEAD | Out-Null; if (`$LASTEXITCODE) { throw 'No merge is in progress.' }",
        "`$conflicts = @(& git -C $r -c core.quotepath=false diff --name-only --diff-filter=U); if (`$conflicts.Count) { throw ('Files still in conflict: ' + (`$conflicts -join ', ')) }",
        "& git -C $r merge --quit; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }",
        "& git -C $r -c core.quotepath=false status --short --branch"
    )
}

function Build-GitSwitchCommands {
    param([string]$Root, [string]$Branch)
    $b = ([string]$Branch).Trim()
    if ($b -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $b -match '\.\.|//|@\{|\.lock$|/$|\.$') {
        throw "Not a branch name: '$Branch'."
    }
    $r = Quote-PS $Root; $q = Quote-PS $b
    $refspec = Quote-PS ($b + ':' + $b)
    return @(
        "& git -C $r rev-parse -q --verify MERGE_HEAD *> `$null; if (`$LASTEXITCODE -eq 0) { throw 'A merge is in progress: finish it with Resolve conflicts first.' }; `$global:LASTEXITCODE = 0",
        "& git -C $r fetch origin; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }",
        "`$current = & git -C $r branch --show-current",
        "if (`$current -ne $q -and (& git -C $r rev-parse -q --verify $(Quote-PS "refs/heads/$b")) -and (& git -C $r rev-parse -q --verify $(Quote-PS "refs/remotes/origin/$b"))) { & git -C $r fetch origin $refspec; if (`$LASTEXITCODE) { throw 'The local $b has commits GitHub lacks (not a fast-forward): nothing was switched.' } }",
        "& git -C $r switch --merge $q; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }",
        "`$conflicts = @(& git -C $r -c core.quotepath=false diff --name-only --diff-filter=U); if (`$conflicts.Count) { Write-Output ('Switched, but these files have conflicts to settle with Resolve conflicts: ' + (`$conflicts -join ', ')); exit 1 }",
        "& git -C $r -c core.quotepath=false status --short --branch"
    )
}

function Read-GitConflictSide {
    param([string]$Root, [string]$File, [int]$Stage)
    if ($File -match '["\r\n]' -or $Stage -notin @(1,2,3)) { throw 'Unsupported conflict path.' }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName='git'; $info.WorkingDirectory=$Root
    $info.Arguments='show ":' + $Stage + ':' + $File + '"'
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true)
    $proc=New-Object System.Diagnostics.Process; $proc.StartInfo=$info
    try {
        [void]$proc.Start(); $text=$proc.StandardOutput.ReadToEnd(); $null=$proc.StandardError.ReadToEnd(); $proc.WaitForExit()
        if ($proc.ExitCode) { return [string]::Empty }
        return [string]$text
    } finally { $proc.Dispose() }
}

function Resolve-MergeCliButton {
    param($Request, $State, $Controls, $App, [string]$Action)
    if (-not $State.MergeState -or $State.MergeState.Form.IsDisposed) {
        Assert-CockpitButtonReady $Controls.Buttons.MergeTool 'Merge tool unavailable.'
        $Controls.Buttons.MergeTool.PerformClick()
    }
    $merge=$State.MergeState
    if (-not $merge -or $merge.Form.IsDisposed) { throw 'Merge tool did not open.' }
    if ($merge.App.repoRoot -ne $App.repoRoot) { throw 'Close the merge window for the other target first.' }
    Read-MergeFiles $merge
    if ($Request.mergeFile) {
        $merge.Files.SelectedItem=[string]$Request.mergeFile
        if ($merge.Files.SelectedItem -ne $Request.mergeFile) { throw 'Conflict file not found. Refresh conflicts.' }
    }
    if ($Action -ne 'merge-refresh') {
        Read-MergeSelection $merge
        if ($Action -in @('merge-file','merge-use-local','merge-use-incoming','merge-save') -and -not $merge.Snapshot) { throw [string]$merge.Status.Text }
    }
    if ((Test-CliProperty $Request 'mergeResult') -and (Test-CliProperty $Request 'mergeResultFile')) {
        throw 'Use mergeResult or mergeResultFile, not both.'
    }
    if (Test-CliProperty $Request 'mergeResult') { $merge.Result.Text=[string]$Request.mergeResult }
    if (Test-CliProperty $Request 'mergeResultFile') {
        $resultPath=[IO.Path]::GetFullPath([string]$Request.mergeResultFile)
        if (-not [IO.File]::Exists($resultPath)) { throw 'mergeResultFile must name an existing UTF-8 text file.' }
        if ((Get-Item -LiteralPath $resultPath).Length -gt 1MB) { throw 'mergeResultFile exceeds the 1 MiB limit.' }
        try { $merge.Result.Text=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($resultPath)).TrimStart([char]0xFEFF) }
        catch [Text.DecoderFallbackException] { throw 'mergeResultFile must contain valid UTF-8.' }
    }
    switch ($Action) {
        'merge-refresh' { return $merge.Buttons.Refresh }
        'merge-file' { if (-not $Request.mergeFile) { throw 'merge-file requires mergeFile.' }; return $merge.Buttons.Refresh }
        'merge-use-local' { return $merge.Buttons.Ours }
        'merge-use-incoming' { return $merge.Buttons.Theirs }
        'merge-save' { return $merge.Buttons.Save }
        'merge-continue' { return $merge.Buttons.Continue }
    }
}

function Get-MergeCliStatus {
    param($State)
    $merge=$State.MergeState
    if (-not $merge -or $merge.Form.IsDisposed) { return $null }
    return @{ file = [string]$merge.Files.SelectedItem; status = [string]$merge.Status.Text; selectedIndex = [int]$merge.Files.SelectedIndex; conflictCount = [int]$merge.Files.Items.Count; hasSnapshot = [bool]$merge.Snapshot }
}
