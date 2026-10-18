function Get-CodeCliSessionPath {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    return (Join-Path $localData 'InstaladorBUDA\code-cli-sessions.bin')
}

function Get-CodeCliSessionEntropy {
    return [Text.Encoding]::UTF8.GetBytes('InstaladorBUDA local conversation history v1')
}

function Add-CodeCliSavedSessions {
    param($Entries, [System.Collections.Specialized.OrderedDictionary]$Into)
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        # Earlier builds returned the session list as ,$list, so @(...) wrapped it: their files hold
        # the list nested inside itself and sessions merged into one record with space-joined ids
        # (matching no agent). Walk the nesting, keep the real sessions, leave the merged records.
        if ($entry -is [System.Array]) { Add-CodeCliSavedSessions $entry $Into; continue }
        $id = [string]$entry.id
        if ([string]::IsNullOrWhiteSpace($id) -or $id -match '\s') { continue }
        $messages = New-Object System.Collections.ArrayList
        foreach ($message in @($entry.messages)) {
            if ($null -eq $message -or [string]::IsNullOrWhiteSpace([string]$message.role)) { continue }
            [void]$messages.Add([pscustomobject]@{ Role = [string]$message.role; Content = [string]$message.content; CreatedUtc = [string]$message.createdUtc })
        }
        $session = [pscustomobject]@{
            Id = $id; ProjectRoot = [string]$entry.projectRoot; AppName = [string]$entry.appName
            AgentId = [string]$entry.agentId; AgentName = [string]$entry.agentName; Title = [string]$entry.title
            CreatedUtc = [string]$entry.createdUtc; UpdatedUtc = [string]$entry.updatedUtc
            Confirmed = [bool]$entry.confirmed; Messages = $messages
        }
        # The same session can appear at several nesting levels; keep its latest copy.
        if (-not $Into.Contains($id) -or [string]::CompareOrdinal($session.UpdatedUtc, $Into[$id].UpdatedUtc) -gt 0) { $Into[$id] = $session }
    }
}

function Get-CodeCliSessions {
    $path = Get-CodeCliSessionPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try {
        Add-Type -AssemblyName System.Security
        $encrypted = [Convert]::FromBase64String([IO.File]::ReadAllText($path))
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted, (Get-CodeCliSessionEntropy), [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $saved = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
    } catch {
        throw "Could not decrypt the local conversation history for this Windows user: $($_.Exception.Message)"
    }
    $byId = New-Object System.Collections.Specialized.OrderedDictionary
    Add-CodeCliSavedSessions $saved.sessions $byId
    return @($byId.Values)
}

function Save-CodeCliSessions {
    param([object[]]$Sessions)
    Add-Type -AssemblyName System.Security
    $path = Get-CodeCliSessionPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    $data = [ordered]@{ version = 1; sessions = @($Sessions | Select-Object -Last 100) }
    $plain = [Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 8 -Compress))
    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
        $plain, (Get-CodeCliSessionEntropy), [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllText($path, [Convert]::ToBase64String($encrypted), [Text.UTF8Encoding]::new($false))
}

function ConvertTo-CodeCliArgument {
    param([string]$Value)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ([int]$character -eq 92) { $backslashes++; continue }
        if ([int]$character -eq 34) {
            for ($i = 0; $i -lt (2 * $backslashes + 1); $i++) { [void]$builder.Append([char]92) }
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        for ($i = 0; $i -lt $backslashes; $i++) { [void]$builder.Append([char]92) }
        $backslashes = 0
        [void]$builder.Append($character)
    }
    for ($i = 0; $i -lt (2 * $backslashes); $i++) { [void]$builder.Append([char]92) }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}
function Format-CodeCliConversationPrompt {
    param($Session)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("Project: $($Session.AppName)")
    [void]$builder.AppendLine("Project folder: $($Session.ProjectRoot)")
    [void]$builder.AppendLine('Continue the conversation below. The latest user message is the current request.')
    [void]$builder.AppendLine()
    foreach ($message in @($Session.Messages)) {
        $speaker = if ($message.Role -eq 'user') { 'User' } else { 'Agent' }
        [void]$builder.AppendLine("$speaker`:`r`n$($message.Content)`r`n")
    }
    $text = $builder.ToString()
    if ($text.Length -gt 20000) { $text = "[Earlier conversation omitted.]`r`n" + $text.Substring($text.Length - 19500) }
    return $text
}

function Format-CodeCliTranscript {
    param($Session)
    $builder = New-Object System.Text.StringBuilder
    foreach ($message in @($Session.Messages)) {
        $speaker = if ($message.Role -eq 'user') { 'You' } else { 'Agent' }
        [void]$builder.AppendLine("$speaker`r`n$($message.Content)`r`n")
    }
    return $builder.ToString()
}

function New-CodeCliSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object; changes no system state.')]
    param([string]$AppName, [string]$RepositoryRoot, $AgentProfile)
    $now = [datetime]::UtcNow.ToString('o')
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N'); ProjectRoot = $RepositoryRoot; AppName = $AppName
        AgentId = [string]$AgentProfile.Id; AgentName = [string]$AgentProfile.Name; Title = 'New conversation'
        CreatedUtc = $now; UpdatedUtc = $now; Confirmed = $false
        Messages = (New-Object System.Collections.ArrayList)
    }
}

function Invoke-CodeCliProcessTreeKill {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return }
    try { if ($Process.HasExited) { return } } catch { return }
    # A batch-file shim, such as the .cmd npm installs, starts the real CLI as a child process. Kill()
    # stops only cmd.exe; the child keeps running and keeps the output pipe open, so the chat
    # would stay busy. taskkill /T stops the whole tree.
    $taskkill = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'taskkill.exe'
    try {
        Start-Process -FilePath $taskkill -ArgumentList @('/PID', [string]$Process.Id, '/T', '/F') -WindowStyle Hidden -Wait
    } catch { Write-Debug "taskkill could not stop the agent process tree: $($_.Exception.Message)" }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { Write-Debug 'The agent process had already exited.' }
}

function Show-CodeCliDialog {
    param(
        [Parameter(Mandatory=$true)][string]$AppName,
        [Parameter(Mandatory=$true)][string]$RepositoryRoot,
        [System.Windows.Forms.IWin32Window]$Owner
    )

    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw "Project folder does not exist: $RepositoryRoot" }
    $profiles = @(Get-CodeCliProfiles)
    $sessions = New-Object System.Collections.ArrayList
    foreach ($session in @(Get-CodeCliSessions)) { [void]$sessions.Add($session) }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Code CLI conversation'
    $dialog.StartPosition = 'CenterParent'; $dialog.MinimizeBox = $false; $dialog.ShowInTaskbar = $false
    $layout = $UI.AgentChat
    $dialog.ClientSize = [System.Drawing.Size]::new((Px $layout.Width), (Px $layout.Height))
    $dialog.MinimumSize = [System.Drawing.Size]::new((Px $layout.MinWidth), (Px $layout.MinHeight))

    $lblProject = New-Object System.Windows.Forms.Label
    $lblProject.Text = "$AppName — $RepositoryRoot"; $lblProject.AutoEllipsis = $true; $lblProject.TextAlign = 'MiddleLeft'
    Set-Box $lblProject $layout.ProjectX $layout.ProjectY $layout.ProjectWidth $layout.ProjectHeight; $lblProject.Anchor = 'Top,Left,Right'
    $lblAgent = New-Object System.Windows.Forms.Label
    $lblAgent.Text = 'Agent:'; $lblAgent.TextAlign = 'MiddleLeft'; Set-Box $lblAgent $layout.AgentLabelX $layout.AgentLabelY $layout.AgentLabelWidth $UI.RowH
    $cmbAgent = New-Object System.Windows.Forms.ComboBox
    $cmbAgent.DropDownStyle = 'DropDownList'; $cmbAgent.DisplayMember = 'Name'
    Set-Field $cmbAgent $dialog.Font $layout.AgentX $layout.AgentLabelY $layout.AgentWidth; $cmbAgent.Anchor = 'Top,Left,Right'
    $btnConfigure = New-Object System.Windows.Forms.Button
    $btnConfigure.Text = 'Configure agents...'; Set-Box $btnConfigure $layout.ConfigureX $layout.ConfigureY $layout.ConfigureWidth $layout.ConfigureHeight; $btnConfigure.Anchor = 'Top,Right'
    $lblConversation = New-Object System.Windows.Forms.Label
    $lblConversation.Text = 'Conversation:'; $lblConversation.TextAlign = 'MiddleLeft'; Set-Box $lblConversation $layout.ConversationLabelX $layout.ConversationLabelY $layout.ConversationLabelWidth $UI.RowH
    $cmbConversation = New-Object System.Windows.Forms.ComboBox
    $cmbConversation.DropDownStyle = 'DropDownList'; $cmbConversation.DisplayMember = 'Label'
    Set-Field $cmbConversation $dialog.Font $layout.ConversationX $layout.ConversationLabelY $layout.ConversationWidth; $cmbConversation.Anchor = 'Top,Left,Right'
    $btnNewConversation = New-Object System.Windows.Forms.Button
    $btnNewConversation.Text = 'New conversation'; Set-Box $btnNewConversation $layout.NewConversationX $layout.RowY $layout.NewConversationWidth $layout.RowHeight; $btnNewConversation.Anchor = 'Top,Right'
    $transcript = New-Object System.Windows.Forms.TextBox
    $transcript.Multiline = $true; $transcript.ReadOnly = $true; $transcript.ScrollBars = 'Vertical'; $transcript.WordWrap = $true
    $transcript.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    Set-Box $transcript $layout.TranscriptX $layout.TranscriptY $layout.TranscriptWidth $layout.TranscriptHeight; $transcript.Anchor = 'Top,Bottom,Left,Right'
    $lblPrompt = New-Object System.Windows.Forms.Label
    $lblPrompt.Text = 'Prompt:'; $lblPrompt.TextAlign = 'MiddleLeft'; Set-Box $lblPrompt $layout.PromptLabelX $layout.PromptLabelY $layout.PromptLabelWidth $layout.PromptLabelHeight; $lblPrompt.Anchor = 'Bottom,Left,Right'
    $txtPrompt = New-Object System.Windows.Forms.TextBox
    $txtPrompt.Multiline = $true; $txtPrompt.ScrollBars = 'Vertical'; $txtPrompt.AcceptsReturn = $true
    $txtPrompt.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    Set-Box $txtPrompt $layout.PromptX $layout.PromptY $layout.PromptWidth $layout.PromptHeight; $txtPrompt.Anchor = 'Bottom,Left,Right'
    $btnSend = New-Object System.Windows.Forms.Button
    $btnSend.Text = 'Send prompt'; Set-Box $btnSend $layout.SendX $layout.ActionY $layout.SendWidth $layout.ActionHeight; $btnSend.Anchor = 'Bottom,Left'
    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = 'Stop'; $btnStop.Enabled = $false; Set-Box $btnStop $layout.StopX $layout.ActionY $layout.StopWidth $layout.ActionHeight; $btnStop.Anchor = 'Bottom,Left'
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'; $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    Set-Box $btnClose $layout.CloseX $layout.ActionY $layout.CloseWidth $layout.ActionHeight; $btnClose.Anchor = 'Bottom,Right'
    $dialog.Controls.AddRange(@($lblProject, $lblAgent, $cmbAgent, $btnConfigure, $lblConversation, $cmbConversation, $btnNewConversation, $transcript, $lblPrompt, $txtPrompt, $btnSend, $btnStop, $btnClose))
    foreach ($agentProfile in $profiles) { [void]$cmbAgent.Items.Add($agentProfile) }

    $chatState = [hashtable]::Synchronized(@{
        Profiles = $profiles; Session = $null; RunSession = $null; Loading = $false
        Process = $null; Timer = $null; OutputTask = $null; ErrorTask = $null; StopRequested = $false
    })
    $saveSessions = {
        param($Session)
        if (-not $Session) { $Session = $chatState.Session }
        if ($Session) { $Session.UpdatedUtc = [datetime]::UtcNow.ToString('o') }
        Save-CodeCliSessions @($sessions.ToArray())
    }.GetNewClosure()
    $renderSession = {
        if (-not $chatState.Session) { $transcript.Clear(); return }
        $transcript.Text = Format-CodeCliTranscript $chatState.Session
        $transcript.SelectionStart = $transcript.TextLength
        $transcript.ScrollToCaret()
        $idx = $cmbConversation.SelectedIndex
        if ($idx -ge 0) {
            $item = $cmbConversation.Items[$idx]
            if ($item -and $item.Session -eq $chatState.Session) { $item.Label = "$(try { ([datetime]::Parse($chatState.Session.UpdatedUtc)).ToLocalTime().ToString('MM-dd HH:mm') } catch { '' })  $($chatState.Session.Title)" }
        }
    }.GetNewClosure()
    $refreshConversations = {
        if ($chatState.Loading) { return }
        $chatState.Loading = $true
        try {
            $agentProfile = $cmbAgent.SelectedItem
            # Items.Clear() while the agent list is rebuilt fires this with no selection.
            if (-not $agentProfile) { return }
            $cmbConversation.BeginUpdate()
            try {
                $cmbConversation.Items.Clear()
                $matching = @($sessions | Where-Object { $_.AgentId -eq [string]$agentProfile.Id -and $_.ProjectRoot -ieq $RepositoryRoot } | Sort-Object UpdatedUtc -Descending)
                foreach ($session in $matching) {
                    $date = try { ([datetime]::Parse($session.UpdatedUtc)).ToLocalTime().ToString('MM-dd HH:mm') } catch { '' }
                    [void]$cmbConversation.Items.Add([pscustomobject]@{ Label = "$date  $($session.Title)"; Session = $session })
                }
                if ($matching.Count -gt 0) { $cmbConversation.SelectedIndex = 0; $chatState.Session = $matching[0] }
                else {
                    $newSession = New-CodeCliSession $AppName $RepositoryRoot $agentProfile
                    [void]$sessions.Add($newSession)
                    $chatState.Session = $newSession
                    [void]$cmbConversation.Items.Add([pscustomobject]@{ Label = 'New conversation'; Session = $newSession })
                    $cmbConversation.SelectedIndex = 0
                    & $saveSessions
                }
            } finally { $cmbConversation.EndUpdate() }
            & $renderSession
        } finally { $chatState.Loading = $false }
    }.GetNewClosure()
    $newConversation = {
        if ($chatState.Loading -or -not $cmbAgent.SelectedItem) { return }
        $agentProfile = $cmbAgent.SelectedItem
        $session = New-CodeCliSession $AppName $RepositoryRoot $agentProfile
        [void]$sessions.Add($session)
        & $saveSessions
        & $refreshConversations
        foreach ($i in 0..($cmbConversation.Items.Count - 1)) {
            if ($cmbConversation.Items[$i].Session.Id -eq $session.Id) { $cmbConversation.SelectedIndex = $i; break }
        }
        $txtPrompt.Focus()
    }.GetNewClosure()
    $cmbAgent.Add_SelectedIndexChanged({ & $refreshConversations }.GetNewClosure())
    $cmbConversation.Add_SelectedIndexChanged({
        if ($chatState.Loading -or $cmbConversation.SelectedIndex -lt 0) { return }
        $chatState.Session = $cmbConversation.SelectedItem.Session
        & $renderSession
    }.GetNewClosure())
    $btnNewConversation.Add_Click({ & $newConversation }.GetNewClosure())
    $btnConfigure.Add_Click({
        try {
            $edited = Show-CodeCliAgentDialog -Profiles @($chatState.Profiles) -Owner $dialog
            if (-not $edited -or -not $edited.Saved) { return }
            $priorId = if ($cmbAgent.SelectedItem) { [string]$cmbAgent.SelectedItem.Id } else { '' }
            # Kept in $chatState: a variable assigned inside this handler would be gone on the next click.
            $chatState.Profiles = @($edited.Profiles)
            $cmbAgent.Items.Clear()
            foreach ($agentProfile in $chatState.Profiles) { [void]$cmbAgent.Items.Add($agentProfile) }
            $newIndex = -1
            for ($i = 0; $i -lt $cmbAgent.Items.Count; $i++) { if ($cmbAgent.Items[$i].Id -eq $priorId) { $newIndex = $i; break } }
            $cmbAgent.SelectedIndex = if ($newIndex -ge 0) { $newIndex } else { 0 }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Could not open agent settings:`r`n$($_.Exception.Message)", 'Configure agents', 'OK', 'Error')
        }
    }.GetNewClosure())

    $setBusy = {
        param([bool]$Busy)
        $btnSend.Enabled = -not $Busy; $btnStop.Enabled = $Busy; $btnConfigure.Enabled = -not $Busy
        $btnNewConversation.Enabled = -not $Busy; $cmbAgent.Enabled = -not $Busy; $cmbConversation.Enabled = -not $Busy
    }.GetNewClosure()
    $addAgentMessage = {
        param($Session, [string]$Text)
        [void]$Session.Messages.Add([pscustomobject]@{ Role = 'agent'; Content = $Text.Trim(); CreatedUtc = [datetime]::UtcNow.ToString('o') })
        & $saveSessions $Session
        & $renderSession
    }.GetNewClosure()

    # One timer for the dialog, made here so its handler captures $chatState and the controls. A
    # .GetNewClosure() made inside the Send handler captures only that handler's locals: there
    # $chatState was $null and every tick raised "You cannot call a method on a null-valued expression".
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 100
    $chatState.Timer = $pollTimer
    $pollTimer.Add_Tick({
        $process = $chatState.Process
        if (-not $process) { $pollTimer.Stop(); return }
        if (-not $process.HasExited -or -not $chatState.OutputTask.IsCompleted -or -not $chatState.ErrorTask.IsCompleted) { return }
        $pollTimer.Stop()
        try {
            $exitCode = $process.ExitCode
            $response = [string]$chatState.OutputTask.Result
            $errorText = [string]$chatState.ErrorTask.Result
            if ($response.Length -gt 20000) { $response = $response.Substring($response.Length - 20000) }
            if ($chatState.StopRequested) {
                $response = if ([string]::IsNullOrWhiteSpace($response)) { 'Stopped.' } else { "$response`r`n`r`nStopped." }
            } elseif ([string]::IsNullOrWhiteSpace($response)) {
                if ($errorText) { $response = "Command failed (exit $exitCode).`r`n$errorText" }
                else { $response = "Command finished with exit code $exitCode and no response." }
            } elseif ($exitCode -ne 0 -and $errorText) {
                $response += "`r`n`r`nCommand error (exit $exitCode):`r`n$errorText"
            }
            & $addAgentMessage $chatState.RunSession $response
        } catch {
            $transcript.AppendText("`r`nCould not record the agent response: $($_.Exception.Message)`r`n")
        } finally {
            $process.Dispose()
            $chatState.Process = $null; $chatState.OutputTask = $null; $chatState.ErrorTask = $null; $chatState.RunSession = $null
            & $setBusy $false
            [void]$txtPrompt.Focus()
        }
    }.GetNewClosure())

    $btnSend.Add_Click({
        if ($chatState.Process -or -not $chatState.Session) { return }
        $agentProfile = $cmbAgent.SelectedItem
        if (-not $agentProfile -or [string]::IsNullOrWhiteSpace([string]$agentProfile.Command)) {
            [void][System.Windows.Forms.MessageBox]::Show('Configure an executable or command for this agent first.', 'Code CLI conversation', 'OK', 'Information')
            return
        }
        $requestText = $txtPrompt.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($requestText)) { return }
        $session = $chatState.Session
        if (-not $session.Confirmed) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "The selected local agent can read and change files in this project folder. Continue?`r`n`r`n$RepositoryRoot",
                'Allow this conversation', 'YesNo', 'Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $session.Confirmed = $true
        }
        [void]$session.Messages.Add([pscustomobject]@{ Role = 'user'; Content = $requestText; CreatedUtc = [datetime]::UtcNow.ToString('o') })
        if ($session.Title -eq 'New conversation') {
            $firstLine = ($requestText -split "`r?`n", 2)[0].Trim()
            $session.Title = if ($firstLine.Length -gt 72) { $firstLine.Substring(0, 69) + '...' } else { $firstLine }
        }
        $txtPrompt.Clear()
        & $saveSessions $session
        & $renderSession
        $prompt = Format-CodeCliConversationPrompt $session
        $process = $null
        try {
            $command = Resolve-CodeCliCommand ([string]$agentProfile.Command)
            $isBatchFile = [IO.Path]::GetExtension($command).ToLowerInvariant() -in @('.cmd', '.bat')
            if ($agentProfile.PromptMode -eq 'argument' -and $isBatchFile) {
                throw "'$command' is a batch file. Windows re-reads a batch file's command line, so a prompt passed as an argument is cut at its first line break and its symbols can run as commands. Open Configure agents and set Prompt delivery to Standard input for this agent."
            }
            $arguments = [string]$agentProfile.Arguments
            if ($agentProfile.PromptMode -eq 'argument') {
                $token = ConvertTo-CodeCliArgument $prompt
                if ($arguments.Contains('{prompt}')) { $arguments = $arguments.Replace('{prompt}', $token) }
                else { $arguments = ($arguments + ' ' + $token).Trim() }
            } else {
                # A placeholder kept after switching a profile to standard input would otherwise reach
                # the CLI as the literal prompt "{prompt}".
                $arguments = $arguments.Replace('{prompt}', '').Trim()
            }
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = $command
            $processInfo.Arguments = $arguments
            $processInfo.WorkingDirectory = $RepositoryRoot
            $processInfo.UseShellExecute = $false; $processInfo.CreateNoWindow = $true
            # Standard input is always redirected and then closed, so a CLI that checks for piped
            # input sees end-of-input instead of waiting on the installer's own handle.
            $processInfo.RedirectStandardInput = $true
            $processInfo.RedirectStandardOutput = $true; $processInfo.RedirectStandardError = $true
            $processInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
            $processInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            [void](Invoke-ProcessStartWithoutInputBom $process)
            $chatState.Process = $process
            $chatState.RunSession = $session
            $chatState.StopRequested = $false
            $chatState.OutputTask = $process.StandardOutput.ReadToEndAsync()
            $chatState.ErrorTask = $process.StandardError.ReadToEndAsync()
            try {
                if ($agentProfile.PromptMode -eq 'stdin') {
                    # ProcessStartInfo.StandardInputEncoding does not exist on .NET Framework (the
                    # packaged exe's runtime); write UTF-8 bytes without a byte-order mark instead.
                    $promptBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($prompt)
                    $process.StandardInput.BaseStream.Write($promptBytes, 0, $promptBytes.Length)
                    $process.StandardInput.BaseStream.Flush()
                }
                $process.StandardInput.Close()
            } catch [System.IO.IOException] {
                # The CLI exited before reading its input; its exit code and error text are reported by the poll.
                Write-Debug "The agent closed standard input early: $($_.Exception.Message)"
            }
            & $setBusy $true
            $pollTimer.Start()
        } catch {
            if ($process) { Invoke-CodeCliProcessTreeKill $process; $process.Dispose() }
            $chatState.Process = $null; $chatState.RunSession = $null
            & $addAgentMessage $session "Could not run the selected command: $($_.Exception.Message)"
            & $setBusy $false
        }
    }.GetNewClosure())
    $btnStop.Add_Click({
        if ($chatState.Process -and -not $chatState.Process.HasExited) {
            $chatState.StopRequested = $true
            Invoke-CodeCliProcessTreeKill $chatState.Process
        }
    }.GetNewClosure())
    $dialog.Add_FormClosing({
        param($closingForm, $closingArgs)
        if ($chatState.Process -and -not $chatState.Process.HasExited) {
            $answer = [System.Windows.Forms.MessageBox]::Show('Stop the running agent and close this conversation?', 'Close conversation', 'YesNo', 'Warning')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $closingArgs.Cancel = $true; return }
            Invoke-CodeCliProcessTreeKill $chatState.Process
        }
    }.GetNewClosure())

    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.CancelButton = $btnClose
    if ($cmbAgent.Items.Count -gt 0) { $cmbAgent.SelectedIndex = 0 }
    try {
        if ($Owner) { [void]$dialog.ShowDialog($Owner) } else { [void]$dialog.ShowDialog() }
        return [pscustomobject]@{ Used = $true; AppName = $AppName; RepositoryRoot = $RepositoryRoot }
    } finally {
        if ($chatState.Timer) { try { $chatState.Timer.Stop(); $chatState.Timer.Dispose() } catch { Write-Debug 'The poll timer was already disposed.' } }
        if ($chatState.Process) { Invoke-CodeCliProcessTreeKill $chatState.Process; try { $chatState.Process.Dispose() } catch { Write-Debug 'The agent process was already disposed.' } }
        $dialog.Dispose()
    }
}
