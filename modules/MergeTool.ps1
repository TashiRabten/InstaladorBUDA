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
    return @{ Path = $path; Text = $text; Bom = $bom; Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
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
    foreach ($entry in @(@('Refresh','Refresh conflicts'),@('Ours','Use local'),@('Theirs','Use incoming'),@('Save','Save resolution'),@('Continue','Complete merge'))) {
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

function Build-GitPullCommands {
    param([string]$Root)
    $r = Quote-PS $Root
    return @(
        "`$dirty = & git -C $r status --porcelain; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; if (`$dirty) { throw 'Commit or stash local changes before pulling.' }",
        "& git -C $r pull --no-rebase --no-commit"
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
    if ($Request.mergeFile) {
        $merge.Files.SelectedItem=[string]$Request.mergeFile
        if ($merge.Files.SelectedItem -ne $Request.mergeFile) { throw 'Conflict file not found. Refresh conflicts.' }
    }
    if (Test-CliProperty $Request 'mergeResult') { $merge.Result.Text=[string]$Request.mergeResult }
    switch ($Action) {
        'merge-refresh' { return $merge.Buttons.Refresh }
        'merge-file' { if (-not $Request.mergeFile) { throw 'merge-file requires mergeFile.' }; Read-MergeSelection $merge; return $merge.Buttons.Refresh }
        'merge-use-local' { return $merge.Buttons.Ours }
        'merge-use-incoming' { return $merge.Buttons.Theirs }
        'merge-save' { return $merge.Buttons.Save }
        'merge-continue' { return $merge.Buttons.Continue }
    }
}
