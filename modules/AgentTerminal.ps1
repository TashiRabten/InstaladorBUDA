# Open in terminal: the agent chat runs each CLI non-interactively, so the CLI's own sign-in and slash
# commands (/login, /mcp, /model) cannot run there. This starts the selected agent's CLI interactively
# in a terminal window of its own, in the project folder, and the CLI's code-cli-terminal action clicks
# the same visible button.

# The interactive session takes the profile's permission and model flags only: Arguments are written for
# the chat's non-interactive runs (-p and stream-json, exec -, --no-interactive) and are left out.
function Get-CodeCliTerminalArguments {
    param($AgentProfile)
    $flags = @(Get-CodeCliProfileFlags $AgentProfile)
    # Kiro's interactive chat is its chat subcommand, and --trust-all-tools is an option of that subcommand.
    if ((Get-CodeCliAgentKind ([string]$AgentProfile.Command)) -eq 'kiro') { $flags = @('chat') + $flags }
    return ($flags -join ' ')
}

function Get-CodeCliTerminalStartInfo {
    param($AgentProfile, [string]$RepositoryRoot)
    if (-not $AgentProfile -or [string]::IsNullOrWhiteSpace([string]$AgentProfile.Command)) {
        throw 'Configure an executable or command for this agent first.'
    }
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw "Project folder does not exist: $RepositoryRoot" }
    $command = Resolve-CodeCliCommand ([string]$AgentProfile.Command)
    # The line runs through cmd.exe, which expands %NAME% even inside quotes and ends a quoted part at
    # the next quote. Neither may come from a path or a model name.
    if ($command -match '[%"]') { throw "The command path '$command' contains % or a quote, which a terminal command line cannot carry safely." }
    $model = ([string]$AgentProfile.Model).Trim()
    if ($model -and $model -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/@\[\]-]*$') {
        throw "The model '$model' contains characters a terminal command line cannot carry safely. Clear Model in Configure agents and choose it with the CLI's /model command instead."
    }
    $line = '"' + $command + '"'
    $arguments = Get-CodeCliTerminalArguments $AgentProfile
    if ($arguments) { $line += ' ' + $arguments }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'cmd.exe'
    # /k keeps the window open after the CLI exits, so its errors stay readable and a command such as
    # "kiro-cli login" can follow. /s removes only the outer quotes; /d skips AutoRun commands, which
    # could change the folder; /v:off keeps ! in a path literal.
    $startInfo.Arguments = '/d /v:off /s /k "' + $line + '"'
    $startInfo.WorkingDirectory = $RepositoryRoot
    # ShellExecute gives cmd.exe a new console with its own window. The cockpit itself runs with a
    # console that has no window (CreateNoWindow); a child created without ShellExecute would share it.
    $startInfo.UseShellExecute = $true
    return [pscustomobject]@{ StartInfo = $startInfo; CommandLine = $line }
}

function Open-CodeCliTerminal {
    param($AgentProfile, [string]$RepositoryRoot)
    $launch = Get-CodeCliTerminalStartInfo $AgentProfile $RepositoryRoot
    $process = [System.Diagnostics.Process]::Start($launch.StartInfo)
    if (-not $process) { throw 'Windows did not start the terminal.' }
    try { $processId = $process.Id } finally { $process.Dispose() }
    return [pscustomobject]@{ agent = [string]$AgentProfile.Name; commandLine = $launch.CommandLine; repoRoot = $RepositoryRoot; processId = $processId }
}

function Find-CodeCliProfile {
    param([object[]]$Profiles, [string]$Agent)
    if ([string]::IsNullOrWhiteSpace($Agent)) { return ($Profiles | Select-Object -First 1) }
    $match = $Profiles | Where-Object { [string]$_.Id -eq $Agent -or [string]$_.Name -ieq $Agent.Trim() } | Select-Object -First 1
    if (-not $match) {
        $names = ($Profiles | ForEach-Object { [string]$_.Name }) -join ', '
        throw "No agent profile named '$Agent'. Profiles: $names."
    }
    return $match
}

# Selects $Agent in the open chat window and clicks its Open in terminal button, as a CLI request.
# $Chat is the table Show-CodeCliDialog publishes while it is open.
function Invoke-CodeCliTerminalButton {
    param($Chat, [string]$Agent)
    $picker = $Chat.AgentPicker
    if ($Agent) {
        $wantedId = [string](Find-CodeCliProfile @($picker.Items) $Agent).Id
        if ([string]$picker.SelectedItem.Id -ne $wantedId) {
            if (-not $picker.Enabled) { throw 'The agent chat is running a prompt; wait for it or press Stop before changing the agent.' }
            for ($i = 0; $i -lt $picker.Items.Count; $i++) { if ([string]$picker.Items[$i].Id -eq $wantedId) { $picker.SelectedIndex = $i; break } }
        }
    }
    $state = $Chat.State
    $state.LastTerminal = $null; $state.LastTerminalError = $null
    Assert-CockpitButtonReady $Chat.TerminalButton 'The Open in terminal control is unavailable while the agent chat is running a prompt.'
    $state.CliClick = $true
    try { $Chat.TerminalButton.PerformClick() } finally { $state.CliClick = $false }
    if ($state.LastTerminalError) { throw [string]$state.LastTerminalError }
    if (-not $state.LastTerminal) { throw 'The terminal was not opened.' }
    return $state.LastTerminal
}

# The CLI's code-cli-terminal action. With the chat already open for this project it clicks Open in
# terminal there; otherwise it opens the chat with the Agent chat... button, and the chat clicks Open in
# terminal as soon as it is shown. $ChatButton has already passed Assert-CockpitButtonReady.
function Invoke-CodeCliTerminalRequest {
    param($GuiState, $Request, $TabState, $App, $ChatButton)
    $repoRoot = (Resolve-Path -LiteralPath $App.repoRoot).Path
    $agent = if (Test-CliProperty $Request 'agent') { ([string]$Request.agent).Trim() } else { '' }
    $openChats = @($GuiState.Tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.AgentChat -and -not $_.Tag.AgentChat.Dialog.IsDisposed })
    $data = @{ tabId = $TabState.Id; action = 'code-cli-terminal'; target = [string]$App.name; repoRoot = $repoRoot }
    if ($openChats.Count -gt 0) {
        $chat = $openChats[0].Tag.AgentChat
        if ($openChats[0].Tag -ne $TabState -or $chat.RepositoryRoot -ine $repoRoot) {
            throw "The agent chat is open for $($chat.RepositoryRoot) in session $($openChats[0].Tag.Id); close it first or send the request to that session and target."
        }
        $data.terminal = Invoke-CodeCliTerminalButton $chat $agent
        $data.agent = $data.terminal.agent
        return [pscustomobject]@{ ok = $true; command = 'action'; data = $data }
    }
    # Check now, so the request fails here rather than in a window that opens and does nothing.
    $agentProfile = Find-CodeCliProfile @(Get-CodeCliProfiles) $agent
    [void](Get-CodeCliTerminalStartInfo $agentProfile $repoRoot)
    $TabState.PendingAgentTerminal = @{ Agent = [string]$agentProfile.Id }
    $data.agent = [string]$agentProfile.Name; $data.scheduled = $true; $data.modal = 'code-cli'
    return (Invoke-CockpitButtonAfterReply $ChatButton ([pscustomobject]@{ ok = $true; command = 'action'; data = $data }))
}

# The agent chat is modeless, so a session tab is busy while its job runs or while its open chat runs an agent.
function Test-CockpitTabBusy {
    param($TabState)
    if (-not $TabState) { return $false }
    if ($TabState.IsRunning) { return $true }
    $chat = $TabState.AgentChat
    if (-not $chat -or -not $chat.State.Process) { return $false }
    try { return -not $chat.State.Process.HasExited } catch { return $false }
}

# Closes a tab's open agent chat without asking again (the caller already warned) and stops its agent.
function Close-CockpitTabChat {
    param($TabState)
    $chat = if ($TabState) { $TabState.AgentChat }
    if (-not $chat -or $chat.Dialog.IsDisposed) { return }
    $chat.State.OwnerClosed = $true
    $chat.Dialog.Close()
}

# The cockpit is itself a modal form: closing it only hides its owned windows and raises no close event
# on them (measured), so the chat's agent would outlive the cockpit. Close the chat when the owner closes.
function Connect-CodeCliChatToOwner {
    param([hashtable]$Chat, [System.Windows.Forms.Form]$Owner)
    if (-not $Owner) { return }
    $closeWithOwner = [System.Windows.Forms.FormClosedEventHandler]{
        $Chat.State.OwnerClosed = $true
        if (-not $Chat.Dialog.IsDisposed) { $Chat.Dialog.Close() }
    }.GetNewClosure()
    $Owner.add_FormClosed($closeWithOwner)
    $Chat.Dialog.Add_FormClosed({ $Owner.remove_FormClosed($closeWithOwner) }.GetNewClosure())
}
