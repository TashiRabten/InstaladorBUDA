function Resolve-CliTab {
    param($GuiState, $Request)
    $tabs = @($GuiState.Tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.Id })
    $selector = if (Test-CliProperty $Request 'session') { 'session' } elseif (Test-CliProperty $Request 'tab') { 'tab' } else { $null }
    if ($selector) {
        $value = [string]$Request.$selector
        $match = $tabs | Where-Object { $_.Tag.Id -eq $value -or $_.Text -eq $value } | Select-Object -First 1
        if (-not $match) { throw "No cockpit session matches '$value'. Use status to list session IDs." }
        return $match
    }
    if ($GuiState.Tabs.SelectedTab -and $GuiState.Tabs.SelectedTab.Tag) { return $GuiState.Tabs.SelectedTab }
    if ($tabs.Count -gt 0) { return $tabs[0] }
    throw 'The cockpit has no job tab.'
}

function Select-CockpitSession {
    param($GuiState, $Page)
    if ($GuiState.SessionPicker) {
        for ($i = 0; $i -lt $GuiState.SessionPicker.Items.Count; $i++) {
            if ($GuiState.SessionPicker.Items[$i].Page -eq $Page) {
                $GuiState.SessionPicker.SelectedIndex = $i
                return
            }
        }
    }
    $GuiState.Tabs.SelectedTab = $Page
}

function Get-CockpitStatus {
    param($GuiState, $Request)
    # logLines: how much of each session's log comes back (default 20, at most 2000), so an agent reads a whole job.
    $lineCount = 20
    if (Test-CliProperty $Request 'logLines') { $lineCount = [Math]::Max(1, [Math]::Min(2000, [int]$Request.logLines)) }
    $all = @()
    foreach ($page in @($GuiState.Tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.Controls })) {
        $state = $page.Tag; $c = $state.Controls
        $tail = @($c.Log.Text -split "`r?`n" | Where-Object { $_ } | Select-Object -Last $lineCount)
        $all += [pscustomobject]@{
            id = $state.Id; sessionId = $state.Id; target = "$($c.Target.SelectedItem)"; version = $c.Version.Text
            publish = [bool]$c.Publish.Checked; dryRun = [bool]$c.DryRun.Checked
            running = [bool]$state.IsRunning; title = $page.Text
            workflow = $c.Workflow.Text; task = "$($c.Task.SelectedItem)"
            bootstrapRoot = $c.BootstrapRoot.Text; githubRepo = $c.BootstrapRepo.Text
            bootstrapMessage = $c.BootstrapMessage.Text; gitleaksPath = $c.BootstrapScanner.Text
            visibility = $c.Visibility.Text; visibilityRepo = [string]$state.VisibilityRepo; visibilityToggle = [bool]($c.Buttons.MakePublic.Enabled -and $c.Buttons.MakePrivate.Enabled); gitRepoRoot = $c.GitRepoRoot.Text; repoRoot = (Get-SessionApp (Get-App ([string]$c.Target.SelectedItem)) $c.GitRepoRoot.Text).repoRoot
            lastCommands = @($state.LastCommands); merge = Get-MergeCliStatus $state; logTail = $tail
        }
    }
    $selector = if (Test-CliProperty $Request 'session') { 'session' } elseif (Test-CliProperty $Request 'tab') { 'tab' } else { $null }
    if ($selector) {
        $filter = [string]$Request.$selector
        if ($filter -match '^\d+$') { $all = @($all | Where-Object { $_.id -eq [int]$filter }) }
        else { $all = @($all | Where-Object { $_.target -eq $filter -or $_.title -eq $filter }) }
    }
    $selectedId = if ($GuiState.Tabs.SelectedTab -and $GuiState.Tabs.SelectedTab.Tag) { [int]$GuiState.Tabs.SelectedTab.Tag.Id } else { $null }
    return [pscustomobject]@{ ok = $true; command = 'status'; data = @{ pipe = $script:ControlPipeName; selectedSession = $selectedId; sessions = $all; tabs = $all } }
}

function Resolve-CliBundles {
    param($App, $Value)
    if (-not $App.bundles -or @($App.bundles).Count -eq 0) { return 'all' }
    $tokens = @(Convert-CliList $Value)
    if ($tokens.Count -eq 0) { $tokens = @($App.bundles | Where-Object { $_.default } | ForEach-Object { $_.id }) }
    if ($tokens.Count -eq 1 -and $tokens[0] -eq 'all') { return 'all' }
    $ids = @()
    foreach ($token in $tokens) {
        $bundle = $App.bundles | Where-Object { $_.id -eq $token -or $_.name -eq $token } | Select-Object -First 1
        if (-not $bundle) { throw "Unknown bundle '$token' for $($App.name). Use list to see bundle IDs and names." }
        $ids += $bundle.id
    }
    return (Resolve-BundleSelection $App ($ids -join ','))
}

function Resolve-CliModels {
    param($App, $Value)
    $definitions = @($App.uploadModels)
    if ($definitions.Count -eq 0) { throw "$($App.name) has no model-upload list." }
    $tokens = @(Convert-CliList $Value)
    if ($tokens.Count -eq 1 -and $tokens[0] -eq 'all') { $tokens = @($definitions | ForEach-Object { $_.name }) }
    if ($tokens.Count -eq 0) {
        $tokens = @($definitions | Where-Object { $_.default -and (Test-Path (Join-Path $App.repoRoot $_.path)) } | ForEach-Object { $_.name })
    }
    foreach ($token in $tokens) {
        if (-not ($definitions | Where-Object { $_.name -eq $token })) { throw "Unknown model '$token' for $($App.name). Use list to see model IDs." }
    }
    return ,$tokens
}

function Assert-ActionsSecretsRequest {
    param($Request, $Controls)

    foreach ($field in @('secret','secretValue','value','token','apiKey','password')) {
        if (Test-CliProperty $Request $field) { throw 'Do not include a credential in CLI request JSON. The visible masked prompt collects it locally.' }
    }
    if (-not $Request.confirm) { throw 'actions-secrets requires confirm:true.' }
    if ($Controls.DryRun.Checked) { throw 'Disable Dry run before managing GitHub Actions secrets.' }
}

# A CLI request clicks the same button as the mouse. Button.PerformClick does nothing unless the
# button can take focus, and a collapsed section hides its buttons, so a request against a collapsed
# group answered ok without running anything. Open the button's sections, then require it clickable.
function Assert-CockpitButtonReady {
    param($Button, [string]$UnavailableMessage)
    if (-not $Button -or -not $Button.Enabled) { throw $UnavailableMessage }
    Expand-CollapsibleSectionsFor $Button
    if (-not $Button.CanSelect) { throw "$UnavailableMessage It is hidden in the cockpit window; select its session and try again." }
}

# Opens a modal manager after the CLI reply has gone out: the click runs from a short UI timer, so the
# request does not wait on a window the user may keep open. $Reply goes back to the CLI at once.
function Invoke-CockpitButtonAfterReply {
    param($Button, $Reply)
    $dialogTimer = New-Object System.Windows.Forms.Timer
    $dialogTimer.Interval = 250
    $dialogTimer.Add_Tick({
        $dialogTimer.Stop()
        try { $Button.PerformClick() } finally { $dialogTimer.Dispose() }
    }.GetNewClosure())
    $dialogTimer.Start()
    return $Reply
}

function Select-CockpitCliTarget {
    param($Request, $Controls)

    if (-not (Test-CliProperty $Request 'target')) { return }
    $app = Get-App ([string]$Request.target)
    if (-not $app -or -not $Controls.Target.Items.Contains($app.name)) { throw "Unknown target '$($Request.target)'." }
    $Controls.Target.SelectedItem = $app.name
}

function Select-CockpitCliTask {
    param($Request, $Controls)

    if (-not (Test-CliProperty $Request 'taskName')) { return }
    $taskIndex = -1
    for ($i = 0; $i -lt $Controls.Task.Items.Count; $i++) {
        if ($Controls.Task.Items[$i] -eq $Request.taskName) { $taskIndex = $i; break }
    }
    if ($taskIndex -lt 0) { throw "Unknown task '$($Request.taskName)'." }
    $Controls.Task.SelectedIndex = $taskIndex
}

function Invoke-CockpitCliConfiguration {
    param($Command, $Request, $State, $Controls)

    Select-CockpitCliTarget $Request $Controls
    $textFields = [ordered]@{
        prBase = 'PrBase'; prHead = 'PrHead'; prTitle = 'PrTitle'; prBody = 'PrBody'; prNumber = 'PrNumber'
        version = 'Version'; notes = 'Notes'; workflow = 'Workflow'; gitPaths = 'GitAdd'
        commitMessage = 'GitMessage'; bootstrapRoot = 'BootstrapRoot'; githubRepo = 'BootstrapRepo'
        bootstrapMessage = 'BootstrapMessage'; gitleaksPath = 'BootstrapScanner'
    }
    foreach ($field in $textFields.Keys) {
        if (Test-CliProperty $Request $field) {
            $control = $Controls[$textFields[$field]]
            $value = [string]$Request.$field
            if ($field -eq 'prBody') { $value = $value.Replace("`r`n", "`n").Replace("`n", "`r`n") }
            $control.Text = $value
        }
    }
    if (Test-CliProperty $Request 'gitRepoRoot') { $Controls.GitRepoRoot.Text = ConvertTo-SessionRepoRoot ([string]$Request.gitRepoRoot) }; if (Test-CliProperty $Request 'publish') { $Controls.Publish.Checked = [bool]$Request.publish }
    if (Test-CliProperty $Request 'dryRun') { $Controls.DryRun.Checked = [bool]$Request.dryRun }
    Select-CockpitCliTask $Request $Controls
    & $State.AppendLog ("CLI configured target=$($Controls.Target.SelectedItem), version=$($Controls.Version.Text).")

    if ($Command -ne 'configure') { return $null }
    return [pscustomobject]@{ ok = $true; command = $Command; data = @{
        tabId = $State.Id; target = "$($Controls.Target.SelectedItem)"; version = $Controls.Version.Text; gitRepoRoot = $Controls.GitRepoRoot.Text; repoRoot = (Get-SessionApp (Get-App ([string]$Controls.Target.SelectedItem)) $Controls.GitRepoRoot.Text).repoRoot
        bootstrapRoot = $Controls.BootstrapRoot.Text; githubRepo = $Controls.BootstrapRepo.Text
        bootstrapMessage = $Controls.BootstrapMessage.Text; gitleaksPath = $Controls.BootstrapScanner.Text
    } }
}

function Invoke-CockpitCliRepository {
    param($Request, $Controls)

    if (-not (Test-CliProperty $Request 'githubRepo')) { return }
    $requestedRepo = ([string]$Request.githubRepo).Trim().TrimEnd('/')
    if ($requestedRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'create-repo githubRepo must be owner/name.' }
    $Controls.BootstrapRepo.Text = $requestedRepo
}

# The help reply, with the agent shell (which lives in this module) added to it.
function Get-CockpitHelpWithShell {
    $help = Get-CockpitHelp
    $help.data.actions = @($help.data.actions) + 'shell'
    $help.data.parameters.shell = @{ required = @('commands (a list of PowerShell lines) or script (one block)', 'confirm:true'); optional = @('session','tab','target','gitRepoRoot','workdir','label','waitMs') }
    $help.data.parameters.status = @{ required = @(); optional = @('session','tab','logLines') }
    $help.data.safety.shell = 'shell (confirm:true) runs PowerShell as a job of the session, the same way every other step runs: the lines are written to the session log, run from a script file in workdir (default: the session''s Git folder or the target''s project folder), each native failure ends the job with its exit code, and the output streams into the log. With waitMs the reply comes when the job ends; read the whole output with status and logLines (up to 2000). Dry run only logs the lines. Never put a password, token or key in the lines: they are logged.'
    $help.data.safety.publishApproval = 'Publishing asks the developer in the cockpit window: deploy, retag-deploy, dispatch, publish-run, undraft, upload, rerun, rerun-failed, retry-last-job, bootstrap-publish, and shell lines that create or push a tag, change a release, or run or re-run a workflow, wait for a Yes clicked in a question over the window (No is the default; closing it refuses). confirm:true is not that Yes. Ask the developer in the chat before asking to publish. Dry runs do not ask.'
    $help.data.examples = @($help.data.examples) + @(
        '{"command":"action","session":2,"action":"shell","commands":["git status --short","gh pr list --repo TashiRabten/SuiteBUDA"],"confirm":true,"waitMs":120000}',
        '{"command":"status","session":2,"logLines":300}'
    )
    return $help
}

# -- Publishing waits for the developer ---------------------------------------------------------
# The developer's rule (2026-11-14, after a release tag nobody had asked for): an agent never publishes on its own.
# A CLI request that would publish - a release or tag, a workflow run, a re-run of a build, a model upload, a draft
# made public, the first push of a new repository, or shell lines that do the same - waits for the developer's own
# Yes in a question the cockpit window shows. confirm:true in the JSON is not that answer. The question opens over
# the window with No as the default button; No, or closing it, refuses the request. Dry runs do not ask.
$script:PublishActions = @('deploy','retag-deploy','dispatch','publish-run','undraft','upload','rerun','rerun-failed','retry-last-job')

function Test-PublishingShellLine {
    param([string]$Line)
    $patterns = @(
        '\bgh\s+release\s+(create|edit|upload|delete)\b',
        '\bgh\s+workflow\s+run\b',
        '\bgh\s+run\s+rerun\b',
        '\bgh\s+api\b.*\b(releases|tags|dispatches)\b.*(-X|--method)\s*(POST|PATCH|PUT|DELETE)\b',
        '\bgh\s+api\b.*(-X|--method)\s*(POST|PATCH|PUT|DELETE)\b.*\b(releases|tags|dispatches)\b',
        '\bgit\s+push\b.*(--tags|--follow-tags|--mirror|refs/tags/|\bv?\d+\.\d+\.\d+\b)',
        '\bgit\s+tag\s+(?!-l\b|--list\b|-n\d*\b|--contains\b|--points-at\b|--merged\b|--no-merged\b|--sort\b)\S'
    )
    foreach ($p in $patterns) { if ($Line -match "(?i)$p") { return $true } }
    return $false
}

# The permission question: Yes / No (No is the default and the Esc key), a countdown, and No by itself after
# $Seconds, so it never outlives the CLI request that asked (the pipe waits 120 s).
function Show-PublishQuestion {
    param($Owner, [string]$Text, [int]$Seconds)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'InstaladorBUDA - permission to publish'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'; $f.TopMost = $true; $f.ShowInTaskbar = $false
    $f.ClientSize = New-Object System.Drawing.Size(540, 230)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text; $label.Location = New-Object System.Drawing.Point(14, 14); $label.Size = New-Object System.Drawing.Size(512, 160)
    $count = New-Object System.Windows.Forms.Label
    $count.Location = New-Object System.Drawing.Point(14, 192); $count.Size = New-Object System.Drawing.Size(320, 24)
    $yes = New-Object System.Windows.Forms.Button
    $yes.Text = 'Yes'; $yes.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $yes.Location = New-Object System.Drawing.Point(350, 186); $yes.Size = New-Object System.Drawing.Size(80, 30)
    $no = New-Object System.Windows.Forms.Button
    $no.Text = 'No'; $no.DialogResult = [System.Windows.Forms.DialogResult]::No
    $no.Location = New-Object System.Drawing.Point(440, 186); $no.Size = New-Object System.Drawing.Size(80, 30)
    $f.AcceptButton = $no; $f.CancelButton = $no
    $f.Controls.AddRange(@($label, $count, $yes, $no))
    $state = @{ Left = $Seconds }
    $count.Text = "Closes as No in $($state.Left) s"
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $state.Left--
        $count.Text = "Closes as No in $($state.Left) s"
        if ($state.Left -le 0) { $timer.Stop(); $f.DialogResult = [System.Windows.Forms.DialogResult]::No }
    }.GetNewClosure())
    $f.Add_Shown({ $no.Focus(); $timer.Start() }.GetNewClosure())
    try { return $f.ShowDialog($Owner) }
    finally { $timer.Stop(); $timer.Dispose(); $f.Dispose() }
}

function Assert-PublishApproval {
    param($GuiState, $State, [string]$What)
    if ($State -and $State.AppendLog) { & $State.AppendLog "Waiting for your answer in this window: an agent asks to $What" }
    $form = if ($GuiState) { $GuiState.Form } else { $null }
    $answer = [System.Windows.Forms.DialogResult]::No
    if ($form) {
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
        $form.Activate()
        $text = "An agent asks to publish:`n`n$What`n`nThis is not a dry run. Allow it?`n`nNo, closing this question, or no answer in 100 s refuses it, and the agent is told to ask you in the chat first."
        $answer = Show-PublishQuestion $form $text 100
    }
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        if ($State -and $State.AppendLog) { & $State.AppendLog "Refused in this window: $What" }
        throw "Not published: the developer did not allow '$What' in the cockpit window. Ask them in the chat before trying again."
    }
    if ($State -and $State.AppendLog) { & $State.AppendLog "Allowed in this window: $What" }
}

# shell: PowerShell lines from the agent, run as this session's job (logged, like every step the cockpit runs).
function Invoke-AgentShellRequest {
    param($Request, $State, $Controls, $GuiState)
    if (-not $Request.confirm -and -not $Controls.DryRun.Checked) { throw 'shell requires confirm:true (or set dryRun:true to only log the lines).' }
    $lines = @()
    if (Test-CliProperty $Request 'commands') { $lines = @(@($Request.commands) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) }
    elseif (Test-CliProperty $Request 'script') { $lines = @([string]$Request.script) | Where-Object { $_.Trim() } }
    if (@($lines).Count -eq 0) { throw 'shell requires commands (a list of PowerShell lines) or script (one block).' }
    $app = Get-SessionApp (Get-App ([string]$Controls.Target.SelectedItem)) $Controls.GitRepoRoot.Text
    if (Test-CliProperty $Request 'workdir') { $dir = [string]$Request.workdir }
    elseif ($app -and $app.repoRoot) { $dir = [string]$app.repoRoot }
    else { $dir = [string]$AppDir }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "workdir does not exist: $dir" }
    $dir = (Resolve-Path -LiteralPath $dir).Path
    $label = if (Test-CliProperty $Request 'label') { 'Shell: ' + (([string]$Request.label) -replace '[\r\n]', ' ') } else { 'Shell (agent)' }
    & $State.AppendLog ("To run - $label ($(@($lines).Count) line(s), in $dir):")
    foreach ($line in $lines) { foreach ($part in ($line -split "`r?`n")) { & $State.AppendLog "    $part" } }
    if (-not $Controls.DryRun.Checked) {
        $publishing = @($lines | ForEach-Object { $_ -split "`r?`n" } | Where-Object { Test-PublishingShellLine $_ })
        if ($publishing.Count -gt 0) { Assert-PublishApproval $GuiState $State ('run shell lines that publish: ' + (($publishing | Select-Object -First 3) -join ' | ')) }
    }
    $State.CliConfirmed = $true
    try { & $State.StartJob ([string[]]$lines) $label $false $dir $null $null $true }
    finally { $State.CliConfirmed = $false }
    return [pscustomobject]@{ ok = $true; command = 'action'; data = @{ tabId = $State.Id; action = 'shell'; workdir = $dir; lines = @($lines).Count; running = [bool]$State.IsRunning; dryRun = [bool]$Controls.DryRun.Checked } }
}

function Invoke-CockpitRequest {
    param($GuiState, $Request)
    $command = [string]$Request.command
    if ($command -eq 'help') { return (Get-CockpitHelpWithShell) }
    if ($command -eq 'list') {
        $targets = Get-CockpitTargetList
        return [pscustomobject]@{ ok = $true; command = 'list'; data = @{ targets = $targets; tasks = @($script:Tasks | ForEach-Object { [pscustomobject]@{ name = $_.name; runOn = $_.runOn } }) } }
    }
    if ($command -eq 'status') { return (Get-CockpitStatus $GuiState $Request) }
    if ($command -eq 'start') { return (Get-CockpitStatus $GuiState $Request) }
    if ($command -eq 'release-plan') {
        $page = Resolve-CliTab $GuiState $Request
        $targetName = if (Test-CliProperty $Request 'target') { [string]$Request.target } else { [string]$page.Tag.Controls.Target.SelectedItem }
        $app = Get-App $targetName
        if (-not $app) { throw "Unknown target '$targetName'. Use list to see configured targets." }
        Select-CockpitSession $GuiState $page
        $controls = $page.Tag.Controls
        $controls.Target.SelectedItem = $app.name
        if (Test-CliProperty $Request 'version') { $controls.Version.Text = [string]$Request.version }
        $requestedVersion = [string]$controls.Version.Text
        $showPlan = $page.Tag.ShowReleasePlan
        return (& $showPlan (Get-SessionApp $app $controls.GitRepoRoot.Text) $requestedVersion)   # the session Git folder, as Deploy reads it
    }
    if ($command -eq 'add-app') {
        foreach ($field in @('name','repoRoot','githubRepo')) {
            if (-not (Test-CliProperty $Request $field)) { throw "add-app requires $field." }
        }
        $page = Resolve-CliTab $GuiState $Request
        Select-CockpitSession $GuiState $page
        $state = $page.Tag
        $c = $state.Controls
        $c.BootstrapName.Text = [string]$Request.name
        $c.BootstrapRoot.Text = [string]$Request.repoRoot
        $c.BootstrapRepo.Text = [string]$Request.githubRepo
        $state.LastAddedApp = $null; $state.LastAddedWiring = $null; $state.LastAddAppError = $null
        $button = $c.Buttons.AddApp
        Assert-CockpitButtonReady $button 'The Add app control is unavailable.'
        $button.PerformClick()
        if ($state.LastAddAppError) { throw [string]$state.LastAddAppError }
        if (-not $state.LastAddedApp) { throw 'The app was not registered. Check the selected tab log for details.' }
        $wiring = @($state.LastAddedWiring)
        return [pscustomobject]@{ ok = $true; command = $command; data = @{ app = $state.LastAddedApp; tabId = $state.Id; configPath = $cfgFile; bootstrapReady = $true
            entry = (Get-App $state.LastAddedApp); wiring = $wiring; fullyWired = (@($wiring | Where-Object { -not $_.ok }).Count -eq 0) } }
    }
    if ($command -eq 'gitignore') {
        $page = Resolve-CliTab $GuiState $Request
        Select-CockpitSession $GuiState $page
        $state = $page.Tag
        $c = $state.Controls
        if ($state.IsRunning) { throw 'Wait until this tab running job finishes before editing .gitignore.' }
        Select-CockpitCliTarget $Request $c
        $selectedApp = Get-App ([string]$c.Target.SelectedItem)
        if (Test-CliProperty $Request 'repoRoot') { $rawRoot = [string]$Request.repoRoot }
        elseif (Test-CliProperty $Request 'target') { $rawRoot = [string]$selectedApp.repoRoot }
        else { $rawRoot = [string]$c.BootstrapRoot.Text }
        if ([string]::IsNullOrWhiteSpace($rawRoot)) {
            if ($selectedApp) { $rawRoot = [string]$selectedApp.repoRoot }
        }
        if ([string]::IsNullOrWhiteSpace($rawRoot)) { throw 'Set repoRoot or choose a project folder first.' }
        if (-not (Test-Path -LiteralPath $rawRoot -PathType Container)) { throw "Project folder does not exist: $rawRoot" }
        $repoRoot = (Resolve-Path -LiteralPath $rawRoot).Path
        $c.BootstrapRoot.Text = $repoRoot
        $button = $c.Buttons.GitIgnore
        Assert-CockpitButtonReady $button 'The Git ignore manager control is unavailable.'
        return (Invoke-CockpitButtonAfterReply $button ([pscustomobject]@{ ok = $true; command = 'gitignore'; data = @{ tabId = $state.Id; repoRoot = $repoRoot; scheduled = $true; modal = 'gitignore' } }))
    }
    if ($command -in @('bootstrap-plan', 'bootstrap-prepare', 'bootstrap-publish')) {
        $page = Resolve-CliTab $GuiState $Request
        Select-CockpitSession $GuiState $page
        $state = $page.Tag
        $c = $state.Controls
        if (Test-CliProperty $Request 'repoRoot') { $c.BootstrapRoot.Text = [string]$Request.repoRoot }
        if (Test-CliProperty $Request 'githubRepo') { $c.BootstrapRepo.Text = [string]$Request.githubRepo }
        if (Test-CliProperty $Request 'commitMessage') { $c.BootstrapMessage.Text = [string]$Request.commitMessage }
        if (Test-CliProperty $Request 'gitleaksPath') { $c.BootstrapScanner.Text = [string]$Request.gitleaksPath }
        $rawRoot = [string]$c.BootstrapRoot.Text
        if ([string]::IsNullOrWhiteSpace($rawRoot)) { throw 'repoRoot is required.' }
        if (-not (Test-Path -LiteralPath $rawRoot -PathType Container)) { throw "Repository folder does not exist: $rawRoot" }
        $repoRoot = (Resolve-Path -LiteralPath $rawRoot).Path
        $githubRepo = ([string]$c.BootstrapRepo.Text).Trim().TrimEnd('/')
        if ($githubRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'githubRepo must be an owner/name pair, for example TashiRabten/ScanBUDA.' }
        $phase = switch ($command) {
            'bootstrap-plan' { 'plan' }
            'bootstrap-prepare' { 'prepare' }
            'bootstrap-publish' { 'publish' }
        }
        if ($phase -ne 'plan' -and -not $Request.confirm) { throw "$command changes the local Git repository or publishes it; pass confirm:true." }
        $commitMessage = [string]$c.BootstrapMessage.Text
        if ($phase -eq 'publish' -and [string]::IsNullOrWhiteSpace($commitMessage)) { throw 'bootstrap-publish requires commitMessage.' }
        if ($state.IsRunning) { throw 'This cockpit tab already has a running job; choose an idle tab for bootstrap.' }
        if (-not $HasGit -or -not $HasGh) { throw 'Git bootstrap requires both git and the GitHub CLI (gh).' }
        [void](Resolve-GitBootstrapScanner $c.BootstrapScanner.Text.Trim() $AppDir)
        $c.BootstrapRepo.Text = $githubRepo
        $button = switch ($phase) {
            'plan' { $c.Buttons.BootstrapPlan }
            'prepare' { $c.Buttons.BootstrapPrepare }
            'publish' { $c.Buttons.BootstrapPublish }
        }
        Assert-CockpitButtonReady $button "The bootstrap $phase control is unavailable."
        if ($phase -eq 'publish') { Assert-PublishApproval $GuiState $state "bootstrap-publish $githubRepo (first push of the repository)" }
        $state.CliConfirmed = $phase -ne 'plan'
        try { $button.PerformClick() } finally { $state.CliConfirmed = $false }
        return [pscustomobject]@{ ok = $true; command = $command; data = @{ tabId = $state.Id; phase = $phase; repoRoot = $repoRoot; githubRepo = $githubRepo; running = [bool]$state.IsRunning } }
    }
    if ($command -eq 'close') {
        if (-not $Request.confirm) { throw 'close requires confirm:true.' }
        $runningTabs = @($GuiState.Tabs.TabPages | Where-Object { Test-CockpitTabBusy $_.Tag })
        if ($runningTabs.Count -gt 0 -and -not $Request.stopRunning) {
            $names = ($runningTabs | ForEach-Object { $_.Text }) -join ', '
            throw "Closing the cockpit will stop running jobs ($names). Pass stopRunning:true to confirm."
        }
        $closeTimer = New-Object System.Windows.Forms.Timer
        $closeTimer.Interval = 750
        $closeTimer.Add_Tick({
            $closeTimer.Stop()
            $GuiState.CloseConfirmed = $true
            try { $GuiState.Form.Close() } finally { $closeTimer.Dispose() }
        }.GetNewClosure())
        $closeTimer.Start()
        return [pscustomobject]@{ ok = $true; command = 'close'; data = @{ scheduled = $true; stoppedJobs = $runningTabs.Count } }
    }
    if ($command -in @('new-session','new-tab')) {
        if (-not $GuiState.NewSessionButton) { throw 'The New session control is unavailable.' }
        $GuiState.NewSessionButton.PerformClick()
        $page = $GuiState.Tabs.SelectedTab
        return [pscustomobject]@{ ok = $true; command = $command; data = @{ sessionId = $page.Tag.Id; tabId = $page.Tag.Id; target = "$($page.Tag.Controls.Target.SelectedItem)" } }
    }
    if ($command -in @('select-session','select-tab')) {
        $page = Resolve-CliTab $GuiState $Request
        Select-CockpitSession $GuiState $page
        return [pscustomobject]@{ ok = $true; command = $command; data = @{ sessionId = $page.Tag.Id; tabId = $page.Tag.Id; target = "$($page.Tag.Controls.Target.SelectedItem)" } }
    }
    if ($command -eq 'close-session') {
        if (-not $Request.confirm) { throw 'close-session requires confirm:true.' }
        $page = Resolve-CliTab $GuiState $Request
        Select-CockpitSession $GuiState $page
        $before = $GuiState.Tabs.TabPages.Count
        $GuiState.CloseSessionButton.PerformClick()
        $closed = $GuiState.Tabs.TabPages.Count -lt $before
        return [pscustomobject]@{ ok = $closed; command = $command; data = @{ sessionId = $page.Tag.Id; closed = $closed } }
    }

    $page = Resolve-CliTab $GuiState $Request
    $state = $page.Tag; $c = $state.Controls
    Select-CockpitSession $GuiState $page

    if ($command -eq 'configure' -or $command -eq 'action') {
        $configuration = Invoke-CockpitCliConfiguration $command $Request $state $c
        if ($null -ne $configuration) { return $configuration }
    }

    if ($command -ne 'action') { throw "Unknown command '$command'. Use help for the command list." }
    $actionName = ([string]$Request.action).ToLowerInvariant()
    if ($actionName.StartsWith('fix-')) { return (Invoke-FixInboxCliRequest $GuiState $Request $state $actionName) }
    if ($state.IsRunning -and $actionName -ne 'update') { throw "Tab $($state.Id) already has a job running. Use another tab or wait for it to finish." }
    if ($actionName -eq 'shell') { return (Invoke-AgentShellRequest $Request $state $c $GuiState) }
    if ($actionName -eq 'actions-secrets') { Assert-ActionsSecretsRequest $Request $c }
    if ($actionName -in @('code-cli', 'code-cli-terminal') -and -not $Request.confirm) { throw "$actionName requires confirm:true." }
    if ($actionName -eq 'update') {
        if (-not $Request.confirm) { throw 'update requires confirm:true.' }
        $runningTabs = @($GuiState.Tabs.TabPages | Where-Object { Test-CockpitTabBusy $_.Tag })
        if ($runningTabs.Count -gt 0 -and -not $Request.stopRunning) {
            $names = ($runningTabs | ForEach-Object { $_.Text }) -join ', '
            throw "Updating will stop running jobs ($names). Pass stopRunning:true to confirm."
        }
    }
    $app = Get-SessionApp (Get-App ([string]$c.Target.SelectedItem)) $c.GitRepoRoot.Text
    $confirmationActions = @('git-pull','git-switch','git-fetch','git-merge','git-fast-forward','merge-save','merge-continue','merge-quit','retry-last-job','rerun','rerun-failed','pr-create','pr-merge','pr-close','upload','deploy','retag-deploy','dispatch','publish-run','undraft','make-public','make-private','git-add','git-unstage','git-commit','git-push','create-repo','actions-secrets','code-cli','code-cli-terminal','task')
    if ($actionName -eq 'retag-deploy') {
        if (-not $Request.replaceExistingTag) { throw 'retag-deploy requires replaceExistingTag:true.' }
        if (-not $Request.confirm) { throw 'retag-deploy requires confirm:true.' }
        if ($app.outputKind -eq 'container-image') { throw 'Container image tags are immutable; use workflow dispatch to retry a build.' }
    }
    if ($actionName -in $confirmationActions -and -not $c.DryRun.Checked -and -not $Request.confirm) {
        throw "$actionName requires confirm:true (or set dryRun:true to preview only)."
    }
    if ($actionName -in $script:PublishActions -and -not $c.DryRun.Checked) {
        $what = ("$actionName - $($app.name) $($c.Version.Text)").Trim()
        if (Test-CliProperty $Request 'runId') { $what += " (run $($Request.runId))" }
        # The question is modal, but the window keeps serving CLI requests while it is open: one of them can change
        # this session's target or version, and the Yes would then publish something else. Same session or nothing.
        $asked = "$($c.Target.SelectedItem)|$($c.Version.Text)|$($c.GitRepoRoot.Text)|$([bool]$c.DryRun.Checked)"
        Assert-PublishApproval $GuiState $state $what
        $now = "$($c.Target.SelectedItem)|$($c.Version.Text)|$($c.GitRepoRoot.Text)|$([bool]$c.DryRun.Checked)"
        if ($now -ne $asked) {
            & $state.AppendLog "Not published: the session changed while the question was open ($asked -> $now). Ask again."
            throw "Not published: the session changed while the question was open ($asked -> $now). Ask again."
        }
    }
    $gitActionButtons = @{ 'git-status' = 'GitStatus'; 'git-add' = 'GitAdd'; 'git-unstage' = 'GitUnstage'; 'git-commit' = 'GitCommit'; 'git-push' = 'GitPush'; 'merge-quit' = 'GitMergeQuit' }
    if ($actionName -eq 'actions-secrets') {
        $state.LastActionsSecretsResult = $null
        $button = $c.Buttons.ActionsSecrets
    } else { switch ($actionName) {
        'upload' {
            $state.CliModels = @(Resolve-CliModels $app $Request.models)
            $button = $c.Buttons.Upload
        }
        { $_ -in @('deploy','retag-deploy','dispatch') } {
            if (-not $c.Version.Text.Trim()) { throw 'Set version before deploy or dispatch.' }
            if ($app.bundles -and @($app.bundles).Count -gt 0) { $state.CliBundles = Resolve-CliBundles $app $Request.bundles }
            if ($actionName -eq 'retag-deploy') { $button = $c.Buttons.RetagDeploy }
            elseif ($actionName -eq 'deploy') { $button = $c.Buttons.Deploy }
            else { $button = $c.Buttons.Dispatch }
        }
        'load-runs' { $button = $c.Buttons.LoadRuns }
        { $_ -in @('publish-run','rerun','rerun-failed') } {
            if (-not $Request.runId) { throw 'publish-run requires runId.' }
            if (-not $state.LoadedRuns -or $state.LoadedRuns.Count -eq 0) {
                Assert-CockpitButtonReady $c.Buttons.LoadRuns 'The Load runs control is unavailable.'
                $c.Buttons.LoadRuns.PerformClick()
            }
            $idx = -1
            for ($i = 0; $i -lt $state.LoadedRuns.Count; $i++) { if ("$($state.LoadedRuns[$i].databaseId)" -eq "$($Request.runId)") { $idx = $i; break } }
            if ($idx -lt 0) { throw "Run $($Request.runId) is not available in the selected workflow." }
            $c.Run.SelectedIndex = $idx
            if ($actionName -eq 'merge-file') { return [pscustomobject]@{ok=$true;command='action';data=@{file=[string]$merge.Files.SelectedItem;status=$merge.Status.Text}} }
            $button = switch ($actionName) { 'rerun' { $c.Buttons.Rerun } 'rerun-failed' { $c.Buttons.RerunFailed } default { $c.Buttons.PublishRun } }
        }
        'undraft' { $button = $c.Buttons.Undraft }
        'make-public' {
            $state.CliConfirmed = $true; $button = $c.Buttons.MakePublic
        }
        'make-private' { $button = $c.Buttons.MakePrivate }
        'open-actions' { $button = $c.Buttons.Actions }
        'open-release' { $button = $c.Buttons.ReleasePage }
        'copy-command' { $button = $c.Buttons.Copy }
        'task' {
            if (-not $Request.taskName) { throw 'task requires taskName.' }
            $idx = -1
            for ($i = 0; $i -lt $c.Task.Items.Count; $i++) { if ($c.Task.Items[$i] -eq $Request.taskName) { $idx = $i; break } }
            if ($idx -lt 0) { throw "Unknown task '$($Request.taskName)'." }
            $c.Task.SelectedIndex = $idx; $button = $c.Buttons.Task
        }
        'git-pull' { $button = $c.Buttons.GitPull }
        'git-fetch' { $button = $c.Buttons.GitFetch }
        { $_ -in @('git-switch','git-merge','git-fast-forward') } { $button = Resolve-GitReferenceCliButton $Request $state $c $actionName }
        'merge-tool' { $button = $c.Buttons.MergeTool }
        { $_ -in @('merge-refresh','merge-file','merge-use-local','merge-use-incoming','merge-save','merge-continue') } {
            $button = Resolve-MergeCliButton $Request $state $c $app $actionName
        }
        'retry-last-job' { $button = $c.Buttons.RetryLast }
        'pr-list' { $button = $c.Buttons.PrList }
        'pr-create' { $button = $c.Buttons.PrCreate }
        'pr-merge' { $button = $c.Buttons.PrMerge }
        'pr-close' { $button = Get-PullRequestButton $c 'PrClose' }
        { $gitActionButtons.ContainsKey($_) } { $button = $c.Buttons[$gitActionButtons[$_]] }
        'create-repo' {
            Invoke-CockpitCliRepository $Request $c
            $button = $c.Buttons.CreateRepo
        }
        { $_ -in @('code-cli', 'code-cli-terminal') } {
            if (-not $app -or -not $app.repoRoot -or -not (Test-Path -LiteralPath $app.repoRoot -PathType Container)) {
                throw 'The selected target has no available project folder.'
            }
            $button = $c.Buttons.CodeCli
        }
        'update' { $button = $GuiState.UpdateButton }
        default { throw "Unknown action '$actionName'. Use help for available actions." }
    } }
    Assert-CockpitButtonReady $button "The '$actionName' control is unavailable for target $($app.name)."
    if ($actionName -eq 'actions-secrets') {
        return (Invoke-CockpitButtonAfterReply $button ([pscustomobject]@{ ok = $true; command = 'action'; data = @{ tabId = $state.Id; action = 'actions-secrets'; target = "$($c.Target.SelectedItem)"; scheduled = $true; modal = 'actions-secrets'; dryRun = [bool]$c.DryRun.Checked } }))
    }
    if ($actionName -eq 'code-cli-terminal') { return (Invoke-CodeCliTerminalRequest $GuiState $Request $state $app $button) }
    if ($actionName -eq 'code-cli') {
        return (Invoke-CockpitButtonAfterReply $button ([pscustomobject]@{ ok = $true; command = 'action'; data = @{ tabId = $state.Id; action = 'code-cli'; target = [string]$app.name; repoRoot = [string]$app.repoRoot; scheduled = $true; modal = 'code-cli' } }))
    }
    if ($actionName -eq 'update') {
        # Reply over the pipe before closing the form; otherwise the CLI client sees a
        # broken connection instead of the acknowledgement for its update request.
        $GuiState.CliConfirmed = $true
        $updateTimer = New-Object System.Windows.Forms.Timer
        $updateTimer.Interval = 750
        $updateTimer.Add_Tick({
            $updateTimer.Stop()
            try { $button.PerformClick() }
            finally { $GuiState.CliConfirmed = $false; $updateTimer.Dispose() }
        }.GetNewClosure())
        $updateTimer.Start()
        return [pscustomobject]@{ ok = $true; command = 'action'; data = @{ tabId = $state.Id; action = $actionName; scheduled = $true; target = "$($c.Target.SelectedItem)"; version = $c.Version.Text; running = [bool]$state.IsRunning; dryRun = [bool]$c.DryRun.Checked } }
    }
    $state.CliConfirmed = $true
    try { $button.PerformClick() }
    finally {
        $GuiState.CliConfirmed = $false
        $state.CliConfirmed = $false
        $state.CliModels = $null
        $state.CliBundles = $null
    }
    return [pscustomobject]@{ ok = $true; command = 'action'; data = @{ tabId = $state.Id; action = $actionName; target = "$($c.Target.SelectedItem)"; version = $c.Version.Text; running = [bool]$state.IsRunning; dryRun = [bool]$c.DryRun.Checked } }
}

function Start-CockpitPipeServer {
    param($GuiState, $Queue)
    $pipeName = $script:ControlPipeName
    $serverLoop = {
        param($GuiState, $Queue, $PipeName)
        while (-not $GuiState.Stopping) {
            $pipe = $null
            try {
                $options = [System.IO.Pipes.PipeOptions]::Asynchronous -bor [System.IO.Pipes.PipeOptions]::CurrentUserOnly
                $pipe = [System.IO.Pipes.NamedPipeServerStream]::new($PipeName,
                    [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte,
                    $options, 4096, 4096)
                $GuiState.Pipe = $pipe
                $pipe.WaitForConnection()
                if ($GuiState.Stopping) { break }
                $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
                $writer.AutoFlush = $true
                $request = $reader.ReadLine() | ConvertFrom-Json -ErrorAction Stop
                $item = [hashtable]::Synchronized(@{ Request = $request; Response = $null; Done = (New-Object System.Threading.ManualResetEvent($false)) })
                $Queue.Enqueue($item)
                if ($item.Done.WaitOne(120000)) { $reply = $item.Response }
                else { $item.Abandoned = $true; $reply = [pscustomobject]@{ ok = $false; error = 'The UI did not process the command within 120 seconds; it will not run later.' } }
                $writer.WriteLine(($reply | ConvertTo-Json -Compress -Depth 12))
                $reader.Dispose(); $writer.Dispose(); if (-not $item.Abandoned) { $item.Done.Dispose() }
            } catch {
                if ($pipe -and $pipe.IsConnected) {
                    try {
                        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
                        $writer.AutoFlush = $true
                        $writer.WriteLine(([pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress))
                    } catch { }
                }
                if (-not $GuiState.Stopping) { Start-Sleep -Milliseconds 250 }
            } finally {
                $GuiState.Pipe = $null
                if ($pipe) { $pipe.Dispose() }
            }
        }
    }
    # A PowerShell script block cannot run as a raw .NET ThreadStart without a
    # PowerShell runspace; that raises an unhandled PSInvalidOperationException and
    # terminates the compiled GUI. Give the pipe loop its own runspace instead.
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $worker = [System.Management.Automation.PowerShell]::Create()
    $worker.Runspace = $runspace
    $null = $worker.AddScript($serverLoop.ToString())
    $null = $worker.AddArgument($GuiState)
    $null = $worker.AddArgument($Queue)
    $null = $worker.AddArgument($pipeName)
    $GuiState.ServerRunspace = $runspace
    $GuiState.ServerWorker = $worker
    $GuiState.ServerAsync = $worker.BeginInvoke()
}
