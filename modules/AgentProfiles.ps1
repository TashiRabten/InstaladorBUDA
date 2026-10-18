function Get-CodeCliPreferencePath {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    return (Join-Path $localData 'InstaladorBUDA\code-cli.json')
}

function New-CodeCliAgentProfile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object; changes no system state.')]
    param([string]$Name = 'Agent 1', [string]$Command = '', [string]$Arguments = '', [string]$PromptMode = 'stdin', [string]$Id)
    if (-not $Id) { $Id = [guid]::NewGuid().ToString('N') }
    return [pscustomobject]@{ Id = $Id; Name = $Name; Command = $Command; Arguments = $Arguments; PromptMode = $PromptMode }
}

# List-returning functions here emit their items; callers collect them with @(...). Returning
# ,$list instead makes @(...) hold the whole list as ONE item: the agent dropdown then shows a
# single blank entry and the command becomes every command joined by spaces.
function Get-CodeCliStarterProfiles {
    return @(
        (New-CodeCliAgentProfile -Id 'builtin-claude-code' -Name 'Claude Code' -Command 'claude' `
            -Arguments '-p {prompt}' -PromptMode 'argument'),
        (New-CodeCliAgentProfile -Id 'builtin-codex' -Name 'Codex' -Command 'codex' `
            -Arguments 'exec -' -PromptMode 'stdin'),
        (New-CodeCliAgentProfile -Id 'builtin-kiro' -Name 'Kiro' -Command 'kiro-cli' `
            -Arguments 'chat --no-interactive' -PromptMode 'stdin')
    )
}

function Save-CodeCliProfiles {
    param([object[]]$Profiles)
    $path = Get-CodeCliPreferencePath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    $data = [ordered]@{ version = 3; profilesSeeded = $true; profiles = @($Profiles | ForEach-Object {
        [ordered]@{ id = [string]$_.Id; name = [string]$_.Name; command = [string]$_.Command; arguments = [string]$_.Arguments; promptMode = [string]$_.PromptMode }
    }) }
    [IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}

function Get-CodeCliProfiles {
    $path = Get-CodeCliPreferencePath
    $profiles = @()
    $needsSeed = $true
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            $needsSeed = -not ($saved.version -ge 3 -and $saved.profilesSeeded -eq $true)
            if ($saved.profiles) {
                foreach ($agentProfile in @($saved.profiles)) {
                    # The list-wrapping defect above saved every profile merged into one record with
                    # space-joined fields (id "a b c"). It cannot be split back reliably; drop it and
                    # let the starter profiles be seeded again.
                    if ([string]$agentProfile.id -match '\s') { $needsSeed = $true; continue }
                    $mode = if ([string]$agentProfile.promptMode -eq 'stdin') { 'stdin' } else { 'argument' }
                    $name = [string]$agentProfile.name
                    $command = [string]$agentProfile.command
                    # Discard only the empty placeholder left by older builds; preserve named,
                    # partially configured profiles so the user can finish editing them.
                    if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($command)) { continue }
                    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Agent ' + ($profiles.Count + 1) }
                    $profiles += New-CodeCliAgentProfile -Id ([string]$agentProfile.id) -Name $name `
                        -Command $command -Arguments ([string]$agentProfile.arguments) -PromptMode $mode
                }
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$saved.command)) {
                # Migrate the earlier single-command preference without losing its executable.
                $profiles += New-CodeCliAgentProfile -Name 'Agent 1' -Command ([string]$saved.command) `
                    -Arguments '' -PromptMode 'stdin'
            }
        } catch {
            throw "Could not read the saved agent profiles: $($_.Exception.Message)"
        }
    }
    if ($needsSeed) {
        foreach ($starter in @(Get-CodeCliStarterProfiles)) {
            if (@($profiles | Where-Object { $_.Id -eq $starter.Id -or $_.Name -ieq $starter.Name }).Count -eq 0) { $profiles += $starter }
        }
        Save-CodeCliProfiles $profiles
    }
    if ($profiles.Count -eq 0) { $profiles = @(Get-CodeCliStarterProfiles) }
    return $profiles
}

function Resolve-CodeCliCommand {
    param([Parameter(Mandatory=$true)][string]$Command)
    $value = $Command.Trim().Trim([char]34)
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'No executable or command is configured. Open Configure agents and enter a command or select a file.' }

    $resolvedPath = $null
    if ([IO.Path]::IsPathRooted($value) -or $value.Contains('\') -or $value.Contains('/')) {
        if (Test-Path -LiteralPath $value -PathType Leaf) { $resolvedPath = (Resolve-Path -LiteralPath $value).ProviderPath }
    } else {
        $application = Get-Command -Name $value -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($application) {
            $candidate = if ($application.Source) { [string]$application.Source } else { [string]$application.Path }
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $resolvedPath = $candidate }
        }
        if (-not $resolvedPath) {
            # The registry PATHs cover a CLI installed after this window started; npm's global folder
            # covers CLIs installed with `npm install -g` when npm did not add that folder to PATH.
            $npmFolder = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)) 'npm'
            $pathValues = @($env:PATH, [Environment]::GetEnvironmentVariable('Path', 'User'), [Environment]::GetEnvironmentVariable('Path', 'Machine'), $npmFolder)
            $extensions = @('')
            if ([IO.Path]::GetExtension($value) -eq '') {
                $configuredExtensions = [Environment]::GetEnvironmentVariable('PATHEXT', 'Machine')
                if ([string]::IsNullOrWhiteSpace($configuredExtensions)) { $configuredExtensions = '.COM;.EXE;.BAT;.CMD' }
                $extensions += @($configuredExtensions -split ';' | Where-Object { $_ })
            }
            foreach ($pathValue in $pathValues) {
                foreach ($folder in @(([string]$pathValue) -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                    $folder = $folder.Trim().Trim([char]34)
                    foreach ($extension in $extensions) {
                        $candidate = Join-Path $folder ($value + $extension)
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $resolvedPath = (Resolve-Path -LiteralPath $candidate).ProviderPath; break }
                    }
                    if ($resolvedPath) { break }
                }
                if ($resolvedPath) { break }
            }
        }
    }

    if (-not $resolvedPath) {
        throw "Could not find '$value'. Install the CLI, restart InstaladorBUDA if you just installed it, or use Configure agents > Browse... to select its executable."
    }
    $extension = [IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
    if ($extension -notin @('.exe', '.com', '.cmd', '.bat')) {
        throw "'$resolvedPath' is not a supported Windows command file. Choose an .exe, .com, .cmd, or .bat file."
    }
    return $resolvedPath
}

function Show-CodeCliAgentHelpWindow {
    param([System.Windows.Forms.IWin32Window]$Owner)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Agent setup help'
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false; $dialog.MaximizeBox = $false; $dialog.ShowInTaskbar = $false
    $layout = $UI.AgentHelp
    $dialog.ClientSize = [System.Drawing.Size]::new((Px $layout.Width), (Px $layout.Height))

    $instructions = New-Object System.Windows.Forms.RichTextBox
    $instructions.ReadOnly = $true; $instructions.DetectUrls = $true
    $instructions.BorderStyle = 'FixedSingle'; $instructions.HideSelection = $false
    $instructions.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $instructions.Text = @'
Profiles for Claude Code, Codex and Kiro are created for you with the values below. Change one only if its command is not found or you restored it by hand; use Add agent for another CLI.

Prompt delivery
  Standard input: the conversation is sent through the process input. Required when the command is a .cmd or .bat file, such as npm's codex.cmd.
  As an argument: the conversation replaces {prompt} in Arguments (or is appended when {prompt} is absent). It is visible in the process command line.

Claude Code
  Display name: Claude Code
  Executable or command: claude
  Arguments: -p {prompt}
  Prompt delivery: As an argument
  Sign in to the CLI before using it. The -p option sends one prompt and exits.
  https://code.claude.com/docs/en/cli-reference

Codex
  Display name: Codex
  Executable or command: codex
  Arguments: exec -
  Prompt delivery: Standard input
  Sign in to the CLI before using it. exec runs without the interactive terminal UI; "-" makes it read the prompt from standard input. A Codex installed with npm is found in the npm folder even when that folder is not on PATH.

Kiro
  Display name: Kiro
  Executable or command: kiro-cli
  Arguments: chat --no-interactive
  Prompt delivery: Standard input
  Headless mode requires KIRO_API_KEY authentication. Without a prompt argument, Kiro reads the instruction from standard input.
  https://kiro.dev/docs/cli/headless/

If a command is not found, use Browse... to select its .exe, .cmd or .bat file, or enter its full path.
'@
    Set-Box $instructions $layout.TextX $layout.TextY $layout.TextWidth $layout.TextHeight
    $instructions.Anchor = 'Top,Left,Right,Bottom'
    $instructions.Add_LinkClicked({
        try {
            $link = [Uri]$_.LinkText
            $allowedHosts = @('code.claude.com', 'kiro.dev')
            if (-not $link.IsAbsoluteUri -or $link.Scheme -ne 'https' -or $allowedHosts -notcontains $link.Host) { return }
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $link.AbsoluteUri; $startInfo.UseShellExecute = $true
            [void][System.Diagnostics.Process]::Start($startInfo)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Could not open the documentation link:`r`n$($_.Exception.Message)", 'Agent setup help', 'OK', 'Error')
        }
    }.GetNewClosure())

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'; $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-Box $btnClose $layout.CloseX $layout.CloseY $layout.CloseWidth $layout.CloseHeight
    $dialog.Controls.AddRange(@($instructions, $btnClose))
    $dialog.CancelButton = $btnClose
    if ($Owner) { $dialog.Show($Owner) } else { $dialog.Show() }
    return $dialog
}

function Show-CodeCliAgentDialog {
    param([object[]]$Profiles, [System.Windows.Forms.IWin32Window]$Owner)

    $rows = New-Object System.Collections.ArrayList
    foreach ($agentProfile in $Profiles) {
        [void]$rows.Add((New-CodeCliAgentProfile -Id $agentProfile.Id -Name $agentProfile.Name -Command $agentProfile.Command -Arguments $agentProfile.Arguments -PromptMode $agentProfile.PromptMode))
    }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Configure agents'
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false; $dialog.MaximizeBox = $false; $dialog.ShowInTaskbar = $false
    $layout = $UI.AgentConfig
    $dialog.ClientSize = [System.Drawing.Size]::new((Px $layout.Width), (Px $layout.Height))

    $list = New-Object System.Windows.Forms.ListBox
    $list.DisplayMember = 'Name'; $list.IntegralHeight = $false
    Set-Box $list $layout.List.X $layout.List.Y $layout.List.Width $layout.List.Height
    $fields = @{}
    $labels = @(
        @{ Name = 'Display name:'; Key = 'Name'; Y = $layout.NameLabelY; FieldY = $layout.NameFieldY; Width = $layout.FieldWidth },
        @{ Name = 'Executable or command:'; Key = 'Command'; Y = $layout.CommandLabelY; FieldY = $layout.CommandFieldY; Width = $layout.CommandFieldWidth },
        @{ Name = 'Arguments (use {prompt} where the prompt goes):'; Key = 'Arguments'; Y = $layout.ArgumentsLabelY; FieldY = $layout.ArgumentsFieldY; Width = $layout.FieldWidth }
    )
    foreach ($field in $labels) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $field.Name; $label.TextAlign = 'MiddleLeft'
        Set-Box $label $layout.LabelX $field.Y $layout.LabelWidth $layout.LabelHeight
        $text = New-Object System.Windows.Forms.TextBox
        Set-Field $text $dialog.Font $layout.LabelX $field.FieldY $field.Width
        $text.Anchor = 'Top,Left,Right'
        $fields[$field.Key] = $text
        $dialog.Controls.AddRange(@($label, $text))
    }
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'; Set-Box $btnBrowse $layout.BrowseX $layout.BrowseY $layout.BrowseWidth $layout.BrowseHeight; $btnBrowse.Anchor = 'Top,Right'
    $fields.Command.Width = (Px $layout.CommandFieldWidth)
    $fields.Command.Anchor = 'Top,Left,Right'
    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.Text = 'Prompt delivery:'; $lblMode.TextAlign = 'MiddleLeft'
    Set-Box $lblMode $layout.ModeLabelX $layout.ModeY $layout.ModeLabelWidth $layout.ModeLabelHeight
    $cmbMode = New-Object System.Windows.Forms.ComboBox
    $cmbMode.DropDownStyle = 'DropDownList'; Set-Field $cmbMode $dialog.Font $layout.ModeX $layout.ModeY $layout.ModeWidth; $cmbMode.Anchor = 'Top,Left,Right'
    [void]$cmbMode.Items.Add('As an argument')
    [void]$cmbMode.Items.Add('Standard input')
    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.Text = 'The command runs inside the selected project folder and uses its existing local sign-in. Standard input is preselected; argument mode exposes the prompt in the process command line.'
    $lblHelp.AutoEllipsis = $true; $lblHelp.ForeColor = [System.Drawing.Color]::DimGray
    Set-Box $lblHelp $layout.HelpX $layout.HelpY $layout.HelpWidth $layout.HelpHeight

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Add agent'; Set-Box $btnAdd $layout.AddX $layout.ButtonsY $layout.AddWidth $layout.ButtonHeight
    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = 'Delete'; Set-Box $btnDelete $layout.DeleteX $layout.ButtonsY $layout.DeleteWidth $layout.ButtonHeight
    $btnHelp = New-Object System.Windows.Forms.Button
    $btnHelp.Text = 'Help...'; Set-Box $btnHelp $layout.HelpButtonX $layout.ButtonsY $layout.HelpButtonWidth $layout.ButtonHeight
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Save'; Set-Box $btnSave $layout.SaveX $layout.ButtonsY $layout.SaveWidth $layout.ButtonHeight
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-Box $btnCancel $layout.CancelX $layout.ButtonsY $layout.CancelWidth $layout.ButtonHeight
    $dialog.Controls.AddRange(@($list, $btnBrowse, $lblMode, $cmbMode, $lblHelp, $btnAdd, $btnDelete, $btnHelp, $btnSave, $btnCancel))
    foreach ($row in $rows) { [void]$list.Items.Add($row) }

    $helpState = [hashtable]::Synchronized(@{ Dialog = $null })
    $editState = [hashtable]::Synchronized(@{ Loading = $false; CurrentRow = $null })
    $storeFields = {
        if ($editState.Loading -or -not $editState.CurrentRow) { return }
        $row = $editState.CurrentRow
        $row.Name = $fields.Name.Text.Trim()
        $row.Command = $fields.Command.Text.Trim()
        $row.Arguments = $fields.Arguments.Text
        $row.PromptMode = if ($cmbMode.SelectedIndex -eq 1) { 'stdin' } else { 'argument' }
        $list.Refresh()
    }.GetNewClosure()
    $loadFields = {
        $editState.Loading = $true
        try {
            if ($list.SelectedIndex -lt 0) { return }
            $row = $list.SelectedItem
            $editState.CurrentRow = $row
            $fields.Name.Text = [string]$row.Name
            $fields.Command.Text = [string]$row.Command
            $fields.Arguments.Text = [string]$row.Arguments
            $cmbMode.SelectedIndex = if ($row.PromptMode -eq 'stdin') { 1 } else { 0 }
        } finally { $editState.Loading = $false }
    }.GetNewClosure()
    $list.Add_SelectedIndexChanged({ & $storeFields; & $loadFields }.GetNewClosure())
    $btnAdd.Add_Click({
        & $storeFields
        $number = $rows.Count + 1
        $agentProfile = New-CodeCliAgentProfile -Name "Agent $number"
        [void]$rows.Add($agentProfile)
        [void]$list.Items.Add($agentProfile)
        $editState.CurrentRow = $null
        $list.SelectedItem = $agentProfile
    }.GetNewClosure())
    $btnDelete.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        if ($rows.Count -le 1) {
            [void][System.Windows.Forms.MessageBox]::Show('Keep at least one agent profile.', 'Configure agents', 'OK', 'Information')
            return
        }
        $index = $list.SelectedIndex
        $rows.Remove($list.SelectedItem)
        $list.Items.RemoveAt($index)
        if ($list.Items.Count -gt 0) { $list.SelectedIndex = [Math]::Min($index, $list.Items.Count - 1) }
    }.GetNewClosure())
    $btnBrowse.Add_Click({
        try {
            $current = $fields.Command.Text.Trim().Trim('"')
            $picked = Invoke-BudaFilePicker -Key 'agent-executable' -Purpose File -Title 'Choose an agent command' `
                -Owner $dialog -CurrentFile $current -DefaultFolder ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) `
                -Filters @(@{ Name = 'Programs (*.exe, *.cmd, *.bat)'; Pattern = '*.exe;*.cmd;*.bat' })
            if ($picked.Count -gt 0) { $fields.Command.Text = [string]$picked[0] }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Executable selection failed:`r`n$($_.Exception.Message)", 'Configure agents', 'OK', 'Error')
        }
    }.GetNewClosure())
    $btnHelp.Add_Click({
        if ($helpState.Dialog -and -not $helpState.Dialog.IsDisposed) {
            $helpState.Dialog.Activate()
            return
        }
        $helpState.Dialog = Show-CodeCliAgentHelpWindow -Owner $dialog
    }.GetNewClosure())
    $btnSave.Add_Click({
        & $storeFields
        $names = @{}
        foreach ($row in $rows) {
            if ([string]::IsNullOrWhiteSpace($row.Name) -or [string]::IsNullOrWhiteSpace($row.Command)) {
                [void][System.Windows.Forms.MessageBox]::Show('Each agent needs a display name and executable or command.', 'Configure agents', 'OK', 'Warning')
                return
            }
            if ($row.Name -match '[\r\n\x00]' -or $row.Command -match '[\r\n\x00]' -or $row.Arguments -match '[\r\n\x00]') {
                [void][System.Windows.Forms.MessageBox]::Show('Agent fields must fit on one line.', 'Configure agents', 'OK', 'Warning')
                return
            }
            $key = $row.Name.Trim().ToLowerInvariant()
            if ($names.ContainsKey($key)) {
                [void][System.Windows.Forms.MessageBox]::Show('Agent names must be unique.', 'Configure agents', 'OK', 'Warning')
                return
            }
            $names[$key] = $true
        }
        try {
            Save-CodeCliProfiles @($rows.ToArray())
            $dialog.Tag = [pscustomobject]@{ Saved = $true; Profiles = @($rows.ToArray()) }
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Could not save agent profiles:`r`n$($_.Exception.Message)", 'Configure agents', 'OK', 'Error')
        }
    }.GetNewClosure())
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    $dialog.CancelButton = $btnCancel
    try {
        if ($Owner) { [void]$dialog.ShowDialog($Owner) } else { [void]$dialog.ShowDialog() }
        return $dialog.Tag
    } finally { $dialog.Dispose() }
}
