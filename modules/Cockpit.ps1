function Resolve-CliTab {
    param($GuiState, $Request)
    $tabs = @($GuiState.Tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.Id })
    if (Test-CliProperty $Request 'tab') {
        $value = "$($Request.tab)"
        $match = $tabs | Where-Object { $_.Tag.Id -eq $value -or $_.Text -eq $value } | Select-Object -First 1
        if (-not $match) { throw "No cockpit tab matches '$value'. Use status to list tab IDs." }
        return $match
    }
    if ($GuiState.Tabs.SelectedTab -and $GuiState.Tabs.SelectedTab.Tag) { return $GuiState.Tabs.SelectedTab }
    if ($tabs.Count -gt 0) { return $tabs[0] }
    throw 'The cockpit has no job tab.'
}

function Get-CockpitStatus {
    param($GuiState, $Request)
    $all = @()
    foreach ($page in @($GuiState.Tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.Controls })) {
        $state = $page.Tag; $c = $state.Controls
        $tail = @($c.Log.Text -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 20)
        $all += [pscustomobject]@{
            id = $state.Id; target = "$($c.Target.SelectedItem)"; version = $c.Version.Text
            publish = [bool]$c.Publish.Checked; dryRun = [bool]$c.DryRun.Checked
            running = [bool]$state.IsRunning; title = $page.Text
            workflow = $c.Workflow.Text; task = "$($c.Task.SelectedItem)"
            bootstrapRoot = $c.BootstrapRoot.Text; githubRepo = $c.BootstrapRepo.Text
            bootstrapMessage = $c.BootstrapMessage.Text; gitleaksPath = $c.BootstrapScanner.Text
            lastCommands = @($state.LastCommands); logTail = $tail
        }
    }
    if (Test-CliProperty $Request 'tab') {
        $filter = "$($Request.tab)"
        if ($filter -match '^\d+$') { $all = @($all | Where-Object { $_.id -eq [int]$filter }) }
        else { $all = @($all | Where-Object { $_.target -eq $filter }) }
    }
    return [pscustomobject]@{ ok = $true; command = 'status'; data = @{ pipe = $script:ControlPipeName; tabs = $all } }
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

function Invoke-CockpitRequest {
    param($GuiState, $Request)
    $command = [string]$Request.command
    if ($command -eq 'help') {
        return [pscustomobject]@{
            ok = $true
            command = 'help'
            data = @{
                commands = @('start','close','list','status','new-tab','select-tab','configure','release-plan','add-app','bootstrap-plan','bootstrap-prepare','bootstrap-publish','action')
                actions = @('upload','deploy','retag-deploy','dispatch','load-runs','publish-run','undraft','make-public','make-private','open-actions','open-release','copy-command','task','git-status','git-add','git-commit','git-push','update')
                parameters = @{
                    configure = @{ required = @(); optional = @('tab','target','version','publish','dryRun','notes','workflow','gitPaths','commitMessage','taskName','bootstrapRoot','githubRepo','bootstrapMessage','gitleaksPath') }
                    releasePlan = @{ required = @(); optional = @('tab','target','version') }
                    addApp = @{ required = @('name','repoRoot','githubRepo'); optional = @('tab') }
                    bootstrapPlan = @{ required = @(); optional = @('tab','repoRoot','githubRepo','gitleaksPath','waitMs') }
                    bootstrapPrepare = @{ required = @('confirm:true'); optional = @('tab','repoRoot','githubRepo','gitleaksPath','waitMs') }
                    bootstrapPublish = @{ required = @('confirm:true'); optional = @('tab','repoRoot','githubRepo','commitMessage','gitleaksPath','waitMs') }
                    action = @{ required = @('action'); optional = @('tab','target','version','publish','dryRun','notes','bundles','models','runId','taskName','gitPaths','commitMessage','confirm','replaceExistingTag','waitMs') }
                }
                examples = @(
                    '{"command":"add-app","name":"MyApp","repoRoot":"C:\\work\\MyApp","githubRepo":"owner/MyApp"}',
                    '{"command":"release-plan","target":"TradutorBUDA"}',
                    '{"command":"action","tab":1,"action":"deploy","target":"TradutorBUDA","version":"1.8.2","notes":"Release notes","confirm":true,"waitMs":900000}',
                    '{"command":"action","tab":1,"action":"retag-deploy","target":"TradutorBUDA","version":"1.8.1","replaceExistingTag":true,"confirm":true,"waitMs":900000}'
                )
                safety = @{
                    deploy = 'Rejects an existing local tag, remote tag, or GitHub release.'
                    retagDeploy = 'Moves an existing remote tag only with replaceExistingTag:true and confirm:true; uses a remote-object lease.'
                }
                parity = 'Every operational capability is available in the visible GUI and CLI; command requests drive the same visible controls.'
                pipe = $script:ControlPipeName
            }
        }
    }
    if ($command -eq 'list') {
        $targets = @($script:AppRegistry.Apps | ForEach-Object { [pscustomobject]@{ name = $_.name; repoRoot = $_.repoRoot; workflow = $_.workflow; tagPrefix = $_.tagPrefix; bundles = @($_.bundles); models = @($_.uploadModels | ForEach-Object { $_.name }) } })
        return [pscustomobject]@{ ok = $true; command = 'list'; data = @{ targets = $targets; tasks = @($script:Tasks | ForEach-Object { [pscustomobject]@{ name = $_.name; runOn = $_.runOn } }) } }
    }
    if ($command -eq 'status') { return (Get-CockpitStatus $GuiState $Request) }
    if ($command -eq 'start') { return (Get-CockpitStatus $GuiState $Request) }
    if ($command -eq 'release-plan') {
        $page = Resolve-CliTab $GuiState $Request
        $targetName = if (Test-CliProperty $Request 'target') { [string]$Request.target } else { [string]$page.Tag.Controls.Target.SelectedItem }
        $app = Get-App $targetName
        if (-not $app) { throw "Unknown target '$targetName'. Use list to see configured targets." }
        $GuiState.Tabs.SelectedTab = $page
        $controls = $page.Tag.Controls
        $controls.Target.SelectedItem = $app.name
        if (Test-CliProperty $Request 'version') { $controls.Version.Text = [string]$Request.version }
        $requestedVersion = [string]$controls.Version.Text
        $showPlan = $page.Tag.ShowReleasePlan
        return (& $showPlan $app $requestedVersion)
    }
    if ($command -eq 'add-app') {
        foreach ($field in @('name','repoRoot','githubRepo')) {
            if (-not (Test-CliProperty $Request $field)) { throw "add-app requires $field." }
        }
        $page = Resolve-CliTab $GuiState $Request
        $GuiState.Tabs.SelectedTab = $page
        $state = $page.Tag
        $c = $state.Controls
        $c.BootstrapName.Text = [string]$Request.name
        $c.BootstrapRoot.Text = [string]$Request.repoRoot
        $c.BootstrapRepo.Text = [string]$Request.githubRepo
        $state.LastAddedApp = $null
        $state.LastAddAppError = $null
        $button = $c.Buttons.AddApp
        if (-not $button -or -not $button.Enabled) { throw 'The Add app control is unavailable.' }
        $button.PerformClick()
        if ($state.LastAddAppError) { throw [string]$state.LastAddAppError }
        if (-not $state.LastAddedApp) { throw 'The app was not registered. Check the selected tab log for details.' }
        return [pscustomobject]@{ ok = $true; command = $command; data = @{ app = $state.LastAddedApp; tabId = $state.Id; configPath = $cfgFile; bootstrapReady = $true } }
    }
    if ($command -in @('bootstrap-plan', 'bootstrap-prepare', 'bootstrap-publish')) {
        $page = Resolve-CliTab $GuiState $Request
        $GuiState.Tabs.SelectedTab = $page
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
        if (-not $button -or -not $button.Enabled) { throw "The bootstrap $phase control is unavailable." }
        $state.CliConfirmed = $phase -ne 'plan'
        try { $button.PerformClick() } finally { $state.CliConfirmed = $false }
        return [pscustomobject]@{ ok = $true; command = $command; data = @{ tabId = $state.Id; phase = $phase; repoRoot = $repoRoot; githubRepo = $githubRepo; running = [bool]$state.IsRunning } }
    }
    if ($command -eq 'close') {
        if (-not $Request.confirm) { throw 'close requires confirm:true.' }
        $runningTabs = @($GuiState.Tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.IsRunning })
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
    if ($command -eq 'new-tab') {
        $page = & $GuiState.NewJobTab
        return [pscustomobject]@{ ok = $true; command = $command; data = @{ tabId = $page.Tag.Id; target = "$($page.Tag.Controls.Target.SelectedItem)" } }
    }
    if ($command -eq 'select-tab') {
        $page = Resolve-CliTab $GuiState $Request
        $GuiState.Tabs.SelectedTab = $page
        return [pscustomobject]@{ ok = $true; command = $command; data = @{ tabId = $page.Tag.Id; target = "$($page.Tag.Controls.Target.SelectedItem)" } }
    }

    $page = Resolve-CliTab $GuiState $Request
    $state = $page.Tag; $c = $state.Controls
    $GuiState.Tabs.SelectedTab = $page

    if ($command -eq 'configure' -or $command -eq 'action') {
        if (Test-CliProperty $Request 'target') {
            $app = Get-App ([string]$Request.target)
            if (-not $app -or -not ($c.Target.Items.Contains($app.name))) { throw "Unknown target '$($Request.target)'." }
            $c.Target.SelectedItem = $app.name
            $app = Get-App ([string]$c.Target.SelectedItem)
        }
        if (Test-CliProperty $Request 'version') { $c.Version.Text = [string]$Request.version }
        if (Test-CliProperty $Request 'publish') { $c.Publish.Checked = [bool]$Request.publish }
        if (Test-CliProperty $Request 'dryRun') { $c.DryRun.Checked = [bool]$Request.dryRun }
        if (Test-CliProperty $Request 'notes') { $c.Notes.Text = [string]$Request.notes }
        if (Test-CliProperty $Request 'workflow') { $c.Workflow.Text = [string]$Request.workflow }
        if (Test-CliProperty $Request 'gitPaths') { $c.GitAdd.Text = [string]$Request.gitPaths }
        if (Test-CliProperty $Request 'commitMessage') { $c.GitMessage.Text = [string]$Request.commitMessage }
        if (Test-CliProperty $Request 'bootstrapRoot') { $c.BootstrapRoot.Text = [string]$Request.bootstrapRoot }
        if (Test-CliProperty $Request 'githubRepo') { $c.BootstrapRepo.Text = [string]$Request.githubRepo }
        if (Test-CliProperty $Request 'bootstrapMessage') { $c.BootstrapMessage.Text = [string]$Request.bootstrapMessage }
        if (Test-CliProperty $Request 'gitleaksPath') { $c.BootstrapScanner.Text = [string]$Request.gitleaksPath }
        if (Test-CliProperty $Request 'taskName') {
            $idx = -1
            for ($i = 0; $i -lt $c.Task.Items.Count; $i++) { if ($c.Task.Items[$i] -eq $Request.taskName) { $idx = $i; break } }
            if ($idx -lt 0) { throw "Unknown task '$($Request.taskName)'." }
            $c.Task.SelectedIndex = $idx
        }
        & $state.AppendLog ("CLI configured target=$($c.Target.SelectedItem), version=$($c.Version.Text).")
        if ($command -eq 'configure') {
            return [pscustomobject]@{ ok = $true; command = $command; data = @{
                tabId = $state.Id; target = "$($c.Target.SelectedItem)"; version = $c.Version.Text
                bootstrapRoot = $c.BootstrapRoot.Text; githubRepo = $c.BootstrapRepo.Text
                bootstrapMessage = $c.BootstrapMessage.Text; gitleaksPath = $c.BootstrapScanner.Text
            } }
        }
    }

    if ($command -ne 'action') { throw "Unknown command '$command'. Use help for the command list." }
    $actionName = ([string]$Request.action).ToLowerInvariant()
    if ($state.IsRunning -and $actionName -ne 'update') { throw "Tab $($state.Id) already has a job running. Use another tab or wait for it to finish." }
    if ($actionName -eq 'update') {
        if (-not $Request.confirm) { throw 'update requires confirm:true.' }
        $runningTabs = @($GuiState.Tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.IsRunning })
        if ($runningTabs.Count -gt 0 -and -not $Request.stopRunning) {
            $names = ($runningTabs | ForEach-Object { $_.Text }) -join ', '
            throw "Updating will stop running jobs ($names). Pass stopRunning:true to confirm."
        }
    }
    $app = Get-App ([string]$c.Target.SelectedItem)
    $confirmationActions = @('upload','deploy','retag-deploy','dispatch','publish-run','undraft','make-public','make-private','git-add','git-commit','git-push','task')
    if ($actionName -eq 'retag-deploy') {
        if (-not $Request.replaceExistingTag) { throw 'retag-deploy requires replaceExistingTag:true.' }
        if (-not $Request.confirm) { throw 'retag-deploy requires confirm:true.' }
        if ($app.outputKind -eq 'container-image') { throw 'Container image tags are immutable; use workflow dispatch to retry a build.' }
    }
    if ($actionName -in $confirmationActions -and -not $c.DryRun.Checked -and -not $Request.confirm) {
        throw "$actionName requires confirm:true (or set dryRun:true to preview only)."
    }
    switch ($actionName) {
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
        'publish-run' {
            if (-not $Request.runId) { throw 'publish-run requires runId.' }
            if (-not $state.LoadedRuns -or $state.LoadedRuns.Count -eq 0) { $c.Buttons.LoadRuns.PerformClick() }
            $idx = -1
            for ($i = 0; $i -lt $state.LoadedRuns.Count; $i++) { if ("$($state.LoadedRuns[$i].databaseId)" -eq "$($Request.runId)") { $idx = $i; break } }
            if ($idx -lt 0) { throw "Run $($Request.runId) is not available in the selected workflow." }
            $c.Run.SelectedIndex = $idx; $button = $c.Buttons.PublishRun
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
        'git-status' { $button = $c.Buttons.GitStatus }
        'git-add' { $button = $c.Buttons.GitAdd }
        'git-commit' { $button = $c.Buttons.GitCommit }
        'git-push' { $button = $c.Buttons.GitPush }
        'update' { $button = $GuiState.UpdateButton }
        default { throw "Unknown action '$actionName'. Use help for available actions." }
    }
    if (-not $button -or -not $button.Enabled) { throw "The '$actionName' control is unavailable for target $($app.name)." }
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
                else { $reply = [pscustomobject]@{ ok = $false; error = 'The UI did not process the command within 120 seconds.' } }
                $writer.WriteLine(($reply | ConvertTo-Json -Compress -Depth 12))
                $reader.Dispose(); $writer.Dispose(); $item.Done.Dispose()
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
