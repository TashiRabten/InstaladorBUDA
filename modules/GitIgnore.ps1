function Show-GitIgnoreDialog {
    param(
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [System.Windows.Forms.IWin32Window]$Owner
    )

    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
        throw "Project folder does not exist: $RepositoryRoot"
    }

    $path = Join-Path $RepositoryRoot '.gitignore'
    $originalLines = @()
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $originalLines = @([IO.File]::ReadAllLines($path))
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Git ignore rules'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = [System.Drawing.Size]::new((Px 640), (Px 410))

    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = ".gitignore in $RepositoryRoot"
    $lblPath.AutoEllipsis = $true
    $lblPath.TextAlign = 'MiddleLeft'
    Set-Box $lblPath 18 12 604 25

    $list = New-Object System.Windows.Forms.ListBox
    $list.HorizontalScrollbar = $true
    $list.IntegralHeight = $false
    Set-Box $list 18 45 390 285
    foreach ($line in $originalLines) { [void]$list.Items.Add([string]$line) }

    $lblPattern = New-Object System.Windows.Forms.Label
    $lblPattern.Text = 'Pattern or comment:'
    $lblPattern.TextAlign = 'MiddleLeft'
    Set-Box $lblPattern 420 48 202 24

    $txtPattern = New-Object System.Windows.Forms.TextBox
    Set-Field $txtPattern $dialog.Font 420 74 202

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Add entry'
    Set-Box $btnAdd 420 110 202 32

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = 'Remove selected'
    Set-Box $btnRemove 420 150 202 32

    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.Text = "Examples:`r`nbuild/`r`n*.log`r`n.env"
    $lblHelp.TextAlign = 'TopLeft'
    Set-Box $lblHelp 420 194 202 92

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "$($list.Items.Count) entr$(if ($list.Items.Count -eq 1) { 'y' } else { 'ies' })"
    $lblStatus.TextAlign = 'MiddleLeft'
    Set-Box $lblStatus 18 337 390 24

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Save'
    $btnSave.DialogResult = [System.Windows.Forms.DialogResult]::None
    Set-Box $btnSave 420 358 96 34

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-Box $btnCancel 526 358 96 34

    $dialog.Controls.AddRange(@($lblPath, $list, $lblPattern, $txtPattern, $btnAdd, $btnRemove, $lblHelp, $lblStatus, $btnSave, $btnCancel))
    $dialog.AcceptButton = $btnAdd
    $dialog.CancelButton = $btnCancel

    $btnAdd.Add_Click({
        $entry = [string]$txtPattern.Text
        if ([string]::IsNullOrWhiteSpace($entry)) {
            [System.Windows.Forms.MessageBox]::Show('Enter a pattern or comment first.', 'Git ignore rules', 'OK', 'Information') | Out-Null
            return
        }
        if ($entry -match '[\r\n\x00]') {
            [System.Windows.Forms.MessageBox]::Show('Each entry must fit on one line.', 'Git ignore rules', 'OK', 'Warning') | Out-Null
            return
        }
        if ($list.Items.Contains($entry)) {
            [System.Windows.Forms.MessageBox]::Show('That exact entry is already in the list.', 'Git ignore rules', 'OK', 'Information') | Out-Null
            return
        }
        [void]$list.Items.Add($entry)
        $txtPattern.Clear()
        $list.SelectedIndex = $list.Items.Count - 1
        $lblStatus.Text = "$($list.Items.Count) entr$(if ($list.Items.Count -eq 1) { 'y' } else { 'ies' })"
    }.GetNewClosure())

    $btnRemove.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        $index = $list.SelectedIndex
        $list.Items.RemoveAt($index)
        if ($list.Items.Count -gt 0) { $list.SelectedIndex = [Math]::Min($index, $list.Items.Count - 1) }
        $lblStatus.Text = "$($list.Items.Count) entr$(if ($list.Items.Count -eq 1) { 'y' } else { 'ies' })"
    }.GetNewClosure())

    $btnSave.Add_Click({
        try {
            $currentLines = @($list.Items | ForEach-Object { [string]$_ })
            $changed = $currentLines.Count -ne $originalLines.Count
            if (-not $changed) {
                for ($i = 0; $i -lt $currentLines.Count; $i++) {
                    if (-not [string]::Equals($currentLines[$i], $originalLines[$i], [StringComparison]::Ordinal)) { $changed = $true; break }
                }
            }
            if ($changed -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                [IO.File]::WriteAllLines($path, [string[]]$currentLines, [Text.UTF8Encoding]::new($false))
            }
            $dialog.Tag = [pscustomobject]@{ Saved = $true; Changed = $changed; Path = $path; EntryCount = $currentLines.Count }
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not save .gitignore:`r`n$($_.Exception.Message)", 'Git ignore rules', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())

    try {
        if ($Owner) { [void]$dialog.ShowDialog($Owner) } else { [void]$dialog.ShowDialog() }
        return $dialog.Tag
    } finally {
        $dialog.Dispose()
    }
}
