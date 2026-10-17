function Show-Gui {
    # WinForms needs an STA thread; pwsh (PS7) defaults to MTA. Relaunch self STA when run as .ps1.
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and $script:SelfPath) {
        Start-Process pwsh -ArgumentList @('-STA', '-ExecutionPolicy', 'Bypass', '-File', $script:SelfPath) | Out-Null
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $pipeName = $script:ControlPipeName

    $form = New-Object System.Windows.Forms.Form
    # Px does the DPI scaling (see the layout table); WinForms must not scale a second time.
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.Text = 'InstaladorBUDA'
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    # Each tab scrolls its own content, so the window is capped to the screen (leaving
    # room for the taskbar) instead of growing to fit a whole tab.
    $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size(
        ([Math]::Min((Px $UI.WindowWidth), $work.Width - 40)),
        ([Math]::Min((Px $UI.WindowHeight), $work.Height - 20)))

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $form.Controls.Add($tabs)

    # ── Top bar: Update (rebuild this exe from the .ps1, restart) ─────────────────
    # Added after the Fill tab control: WinForms docks the last-added control first, so the bar takes the top
    # edge and the tabs fill what is left. Sized before its right-anchored button is added (see the layout rules).
    $guiState = [hashtable]::Synchronized(@{ CloseConfirmed = $false; CliConfirmed = $false; Stopping = $false; Form = $form })
    $appDir = $AppDir
    $topBar = New-Object System.Windows.Forms.Panel
    $topBar.Dock = 'Top'
    $topBar.SetBounds(0, 0, $form.ClientSize.Width, (Px $UI.TopBarH))
    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Text = 'Update (rebuild + restart)'; $btnUpdate.Font = $form.Font
    $updW = Get-ButtonWidth $btnUpdate 160
    $barW = $form.ClientSize.Width / (Get-UiScale)
    Set-Box $btnUpdate ($barW - $UI.Pad - $updW) (($UI.TopBarH - $UI.BtnH) / 2) $updW $UI.BtnH
    $btnUpdate.Anchor = 'Top,Right'
    $lblBuild = New-Object System.Windows.Forms.Label
    $lblBuild.ForeColor = [System.Drawing.Color]::Gray; $lblBuild.TextAlign = 'MiddleLeft'
    Set-Box $lblBuild $UI.Pad (($UI.TopBarH - $UI.RowH) / 2) ($barW - 2 * $UI.Pad - $updW - $UI.BtnGap) $UI.RowH
    $lblBuild.Anchor = 'Top,Left,Right'
    # Which build is running, so an update can be seen to have taken effect.
    $exePath = Join-Path $appDir 'InstaladorBUDA.exe'
    $lblBuild.Text = if ($script:SelfPath) { "Running from InstaladorBUDA.ps1" }
                     elseif (Test-Path $exePath) { "InstaladorBUDA.exe built $((Get-Item $exePath).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" }
                     else { 'InstaladorBUDA' }
    $buildScript = Join-Path $appDir 'build-exe.ps1'
    if (-not (Test-Path $buildScript)) {
        $btnUpdate.Enabled = $false
        $lblBuild.Text += '   (build-exe.ps1 not found next to it: Update is off)'
    }
    $topBar.Controls.AddRange(@($lblBuild, $btnUpdate))
    $form.Controls.Add($topBar)
    $updateTips = New-Object System.Windows.Forms.ToolTip
    $updateTips.SetToolTip($btnUpdate, 'Closes this window, rebuilds InstaladorBUDA.exe from InstaladorBUDA.ps1 (build-exe.ps1) in a console, and opens the new exe.')
    $btnUpdate.Add_Click({
        $running = @($tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.IsRunning })
        $question = "Rebuild InstaladorBUDA.exe from InstaladorBUDA.ps1 and restart?`n`n" +
                    "This window closes; a console window shows the build and opens the new InstaladorBUDA when it is done."
        if ($running.Count -gt 0) {
            $question = "Still running: $(($running | ForEach-Object { $_.Text }) -join ', ') — those commands will be stopped.`n`n$question"
        }
        if (-not $guiState.CliConfirmed) {
            $ans = [System.Windows.Forms.MessageBox]::Show($question, 'Update InstaladorBUDA', 'YesNo', 'Question')
            if ($ans -ne 'Yes') { return }
        }
        try {
            Start-UpdateHelper $appDir $PID
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Could not start the update: $($_.Exception.Message)", 'Update InstaladorBUDA', 'OK', 'Error')
            return
        }
        $guiState.CloseConfirmed = $true
        $form.Close()
    }.GetNewClosure())

    # Create the tab strip's window handle before the first TabPages.Insert. On .NET
    # Framework — the runtime the compiled exe runs on — Insert into a TabControl that has
    # no handle yet adds the page as a child control but never as a tab: TabPages.Count
    # stays 1, and the window opened blank on the lone "+" tab. .NET (pwsh 7) does not
    # have this defect, which is why the .ps1 always looked fine. Reading .Handle creates
    # the handle without showing the form, and it lives for the whole run, so every later
    # "+" click inserts correctly too.
    [void]$tabs.Handle

    $addTab = New-Object System.Windows.Forms.TabPage
    $addTab.Text = '+'
    $tabs.TabPages.Add($addTab)

    # Adds a new job tab (titled after its target app once New-JobTab has picked one),
    # inserts it before the "+" tab, selects it, and returns it. Used both at startup and
    # by the "+" tab handler below.
    $jobCounter = 0
    $newJobTab = {
        $script:jobCounter++
        $page = New-JobTab -Tabs $tabs -Number $script:jobCounter
        $insertAt = $tabs.TabPages.IndexOf($addTab)
        $tabs.TabPages.Insert($insertAt, $page)
        $tabs.SelectedTab = $page
        return $page
    }.GetNewClosure()
    $guiState.Tabs = $tabs
    $guiState.NewJobTab = $newJobTab
    $guiState.UpdateButton = $btnUpdate
    $script:jobCounter = 0

    $suppressAddTabReentry = $false
    $tabs.Add_Selected({
        param($s, $e)
        if ($e.TabPage -eq $addTab -and -not $suppressAddTabReentry) {
            $script:suppressAddTabReentry = $true
            try { & $newJobTab | Out-Null } finally { $script:suppressAddTabReentry = $false }
        }
    }.GetNewClosure())

    # Start with one job tab so the window isn't empty on first launch.
    & $newJobTab | Out-Null

    $controlQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $guiState.RequestQueue = $controlQueue
    $controlTimer = New-Object System.Windows.Forms.Timer
    $controlTimer.Interval = 100
    $controlTimer.Add_Tick({
        while ($controlQueue.Count -gt 0) {
            $item = $controlQueue.Dequeue()
            try { $item.Response = Invoke-CockpitRequest $guiState $item.Request }
            catch { $item.Response = [pscustomobject]@{ ok = $false; error = $_.Exception.Message } }
            finally { $item.Done.Set() | Out-Null }
        }
    }.GetNewClosure())
    $form.Add_Shown({
        $controlTimer.Start()
        Start-CockpitPipeServer $guiState $controlQueue
        foreach ($page in @($tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.AppendLog })) {
            & $page.Tag.AppendLog "CLI control ready on \\.\pipe\$pipeName."
        }
    }.GetNewClosure())
    $form.Add_FormClosed({
        $guiState.Stopping = $true
        $controlTimer.Stop()
        if ($guiState.Pipe) { try { $guiState.Pipe.Dispose() } catch { } }
        if ($guiState.ServerWorker) {
            try { $guiState.ServerWorker.Stop() } catch { }
            try { $guiState.ServerWorker.Dispose() } catch { }
        }
        if ($guiState.ServerRunspace) { try { $guiState.ServerRunspace.Dispose() } catch { } }
    }.GetNewClosure())

    # Warn (once) if any tab has a job still running when the window is closed, and make
    # sure no background process / event subscription is left orphaned either way.
    $form.Add_FormClosing({
        param($s, $e)
        $running = @($tabs.TabPages | Where-Object { $_ -ne $addTab -and $_.Tag -and $_.Tag.IsRunning })
        # Update asked already (and said which jobs it stops).
        if ($running.Count -gt 0 -and -not $script:closeConfirmed -and -not $guiState.CloseConfirmed) {
            $names = ($running | ForEach-Object { $_.Text }) -join ', '
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Still running: $names`n`nClose anyway? Running commands will be left to finish or be killed.",
                'Jobs still running', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { $e.Cancel = $true; return }
            $script:closeConfirmed = $true
        }
        foreach ($t in $tabs.TabPages) {
            if ($t.Tag -and $t.Tag.Cleanup) { & $t.Tag.Cleanup }
        }
    }.GetNewClosure())

    [void]$form.ShowDialog()
}

# Builds one fully independent job tab: its own Target/Version/Notes/Steps controls and
# its own log box, so it can run a command concurrently with any other open tab without
# sharing state. This is almost exactly the control panel the single-tab GUI used to
# build directly inside Show-Gui — now it's a function so each tab gets its own copy of
# every control and closure. $Tabs is the parent TabControl (needed so this tab's
# handlers can update ITS OWN page — e.g. the title — via the TabPage returned below,
# not any other tab's). $Number seeds the default tab title before a target is picked.
function New-JobTab {
    param($Tabs, [int]$Number)

    # Every button gets this font explicitly, so Get-ButtonWidth measures its caption in
    # the same font it is drawn in.
    $uiFont   = New-Object System.Drawing.Font('Segoe UI', 9)
    $boxWidth = $UI.ContentWidth - 2 * $UI.Pad
    # Rows inside a group box are button-high; a text input sits centred in its row.
    $inset    = ($UI.BtnH - $UI.RowH) / 2

    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = "Job $Number"

    # AutoScroll panel filling the tab, so a tab's content scrolls independently of the
    # window height and of any other tab. It gets its full design width BEFORE any child
    # is added, and every group box gets its size before its own children are: a control
    # anchored to the right keeps the distance to that edge it had when it was added, so
    # a parent still at its default 200 px width pushes those controls out of view.
    $panel = New-Object System.Windows.Forms.Panel
    $panel.AutoScroll = $true
    Set-Box $panel 0 0 $UI.ContentWidth 600

    # ── Target / version / options ─────────────────────────────────────────────
    $y = $UI.Pad
    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.Text = 'Target app:'; $lblTarget.TextAlign = 'MiddleLeft'
    Set-Box $lblTarget $UI.Pad $y $UI.LabelWidth $UI.RowH
    $cmbTarget = New-Object System.Windows.Forms.ComboBox
    $cmbTarget.DropDownStyle = 'DropDownList'
    $cmbTarget.Sorted = $true
    Set-Field $cmbTarget $uiFont $UI.FieldX $y 240
    $defaultTarget = if ($script:AppRegistry.Apps.Count -gt 0) { [string]$script:AppRegistry.Apps[0].name } else { $null }
    $script:AppRegistry.Apps | ForEach-Object { [void]$cmbTarget.Items.Add($_.name) }
    if ($cmbTarget.Items.Count -gt 0) { $cmbTarget.SelectedItem = $defaultTarget }

    $y += $UI.RowPitch
    $lblVer = New-Object System.Windows.Forms.Label
    $lblVer.Text = 'Version:'; $lblVer.TextAlign = 'MiddleLeft'
    Set-Box $lblVer $UI.Pad $y $UI.LabelWidth $UI.RowH
    $txtVer = New-Object System.Windows.Forms.TextBox
    Set-Field $txtVer $uiFont $UI.FieldX $y 120
    $curX = $UI.FieldX + 120 + 12
    $lblCur = New-Object System.Windows.Forms.Label
    $lblCur.ForeColor = [System.Drawing.Color]::Gray; $lblCur.TextAlign = 'MiddleLeft'
    Set-Box $lblCur $curX $y ($UI.ContentWidth - $UI.Pad - $curX) $UI.RowH
    $lblCur.Anchor = 'Top,Left,Right'

    $y += $UI.RowPitch
    $chkPublish = New-Object System.Windows.Forms.CheckBox
    $chkPublish.Text = 'Publish to website (attach installers to the release)'; $chkPublish.Checked = $true
    Set-Box $chkPublish $UI.FieldX $y ($UI.ContentWidth - $UI.Pad - $UI.FieldX) $UI.RowH

    $y += $UI.CheckPitch
    $chkDry = New-Object System.Windows.Forms.CheckBox
    $chkDry.Text = 'Dry run — show the command, do not execute'
    Set-Box $chkDry $UI.FieldX $y ($UI.ContentWidth - $UI.Pad - $UI.FieldX) $UI.RowH
    $y += $UI.RowH + $UI.BoxGap

    # ── Steps ──────────────────────────────────────────────────────────────────
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Steps'

    $btnUpload = New-Object System.Windows.Forms.Button
    $btnUpload.Text = '1. Upload models'; $btnUpload.Font = $uiFont
    $btnDeploy = New-Object System.Windows.Forms.Button
    $btnDeploy.Text = '2. Deploy (push tag)'; $btnDeploy.Font = $uiFont
    $btnRetagDeploy = New-Object System.Windows.Forms.Button
    $btnRetagDeploy.Text = 'Retag existing release'; $btnRetagDeploy.Font = $uiFont
    $btnDispatch = New-Object System.Windows.Forms.Button
    $btnDispatch.Text = 'or: Trigger workflow'; $btnDispatch.Font = $uiFont
    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = 'Copy last command'; $btnCopy.Font = $uiFont
    $btnReleasePlan = New-Object System.Windows.Forms.Button
    $btnReleasePlan.Text = 'Release plan'; $btnReleasePlan.Font = $uiFont
    $btnActions = New-Object System.Windows.Forms.Button
    $btnActions.Text = 'Open Actions page'; $btnActions.Font = $uiFont

    # Row 2 lines up under row 1 (Copy under Upload, Actions under Trigger). $refresh
    # (below) renames Upload to '1. Upload models (n/a)' for an app with nothing to
    # upload, so that button is sized for the longer caption and never clips.
    $rowY  = $UI.BoxTop
    $col1X = $UI.BoxPad
    $uploadW = Get-ButtonWidth $btnUpload 160 '1. Upload models (n/a)'
    Set-Box $btnUpload $col1X $rowY $uploadW $UI.BtnH
    $col3X = Set-ButtonRow @($btnDeploy) ($col1X + $uploadW + $UI.BtnGap) $rowY 160
    [void](Set-ButtonRow @($btnDispatch) $col3X $rowY 160)
    $rowY += $UI.BoxRowPitch
    [void](Set-ButtonRow @($btnCopy, $btnReleasePlan, $btnRetagDeploy, $btnActions) $col1X $rowY 110)
    $boxH = $rowY + $UI.BtnH + $UI.BoxPad
    Set-Box $grp $UI.Pad $y $boxWidth $boxH
    $grp.Anchor = 'Top,Left,Right'
    $grp.Controls.AddRange(@($btnUpload, $btnDeploy, $btnDispatch, $btnCopy, $btnReleasePlan, $btnRetagDeploy, $btnActions))
    $y += $boxH + $UI.BoxGap

    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($btnDispatch, "With 'Publish to website' checked, this DOES create a real tag + release (same gh release create/finalize path as Deploy) — it just doesn't push a local git tag, so InstaladorBUDA's 'current version' won't see it until you 'git fetch --tags'.")
    $tips.SetToolTip($btnDeploy, 'Pushes a real git tag locally, which always rebuilds every bundle.')
    $tips.SetToolTip($btnRetagDeploy, 'Moves an existing remote release tag only after a lease-protected preflight and an explicit confirmation.')
    $tips.SetToolTip($btnReleasePlan, 'Shows the version source, selected tag, repository state, blockers and warnings without changing the repository.')

    # ── Publish from an existing run (no rebuild) ──────────────────────────────
    $grpPub = New-Object System.Windows.Forms.GroupBox
    $grpPub.Text = 'Publish from existing run (no rebuild)'
    $inputX = $UI.BoxPad + $UI.BoxLabelW + 8

    $rowY = $UI.BoxTop
    $lblWf = New-Object System.Windows.Forms.Label
    $lblWf.Text = 'Workflow:'; $lblWf.TextAlign = 'MiddleLeft'
    Set-Box $lblWf $UI.BoxPad ($rowY + $inset) $UI.BoxLabelW $UI.RowH
    # Load runs stays glued to the box's right edge; the workflow combo stretches into
    # whatever room opens up beside it.
    $btnLoadRuns = New-Object System.Windows.Forms.Button
    $btnLoadRuns.Text = 'Load runs'; $btnLoadRuns.Font = $uiFont
    $loadW = Get-ButtonWidth $btnLoadRuns 120
    $loadX = $boxWidth - $UI.BoxPad - $loadW
    Set-Box $btnLoadRuns $loadX $rowY $loadW $UI.BtnH
    $btnLoadRuns.Anchor = 'Top,Right'
    $cmbWf = New-Object System.Windows.Forms.ComboBox
    $cmbWf.DropDownStyle = 'DropDown'
    Set-Field $cmbWf $uiFont $inputX ($rowY + $inset) ($loadX - $UI.BtnGap - $inputX)
    $cmbWf.Anchor = 'Top,Left,Right'

    $rowY += $UI.BoxRowPitch
    $lblRun = New-Object System.Windows.Forms.Label
    $lblRun.Text = 'Run:'; $lblRun.TextAlign = 'MiddleLeft'
    Set-Box $lblRun $UI.BoxPad ($rowY + $inset) $UI.BoxLabelW $UI.RowH
    $cmbRun = New-Object System.Windows.Forms.ComboBox
    $cmbRun.DropDownStyle = 'DropDownList'
    Set-Field $cmbRun $uiFont $inputX ($rowY + $inset) ($boxWidth - $UI.BoxPad - $inputX)
    $cmbRun.Anchor = 'Top,Left,Right'

    $rowY += $UI.BoxRowPitch
    $btnPubRun = New-Object System.Windows.Forms.Button
    $btnPubRun.Text = 'Publish selected run'; $btnPubRun.Font = $uiFont
    $btnUndraft = New-Object System.Windows.Forms.Button
    $btnUndraft.Text = 'Un-draft release'; $btnUndraft.Font = $uiFont
    $btnRelPage = New-Object System.Windows.Forms.Button
    $btnRelPage.Text = 'Open release'; $btnRelPage.Font = $uiFont
    [void](Set-ButtonRow @($btnPubRun, $btnUndraft, $btnRelPage) $UI.BoxPad $rowY 150)

    $boxH = $rowY + $UI.BtnH + $UI.BoxPad
    Set-Box $grpPub $UI.Pad $y $boxWidth $boxH
    $grpPub.Anchor = 'Top,Left,Right'
    $grpPub.Controls.AddRange(@($lblWf, $cmbWf, $btnLoadRuns, $lblRun, $cmbRun, $btnPubRun, $btnUndraft, $btnRelPage))
    $y += $boxH + $UI.BoxGap
    # Per-tab (not $script:) — concurrent tabs must not share which runs were loaded.
    $tabState = @{ Id = $Number; LoadedRuns = @(); LastCommands = @(); IsRunning = $false; Cleanup = $null; CliModels = $null; CliBundles = $null; CliConfirmed = $false }

    # ── Repo visibility (public/private toggle, e.g. to work around Actions minutes
    # running out on a private repo — flip public just to let a workflow run, then
    # flip back private once it's done) ────────────────────────────────────────
    $grpVis = New-Object System.Windows.Forms.GroupBox
    $grpVis.Text = 'Repo visibility'

    # The two buttons sit together at the box's right edge; the status label takes the rest.
    $rowY = $UI.BoxTop
    $btnMakePublic = New-Object System.Windows.Forms.Button
    $btnMakePublic.Text = 'Make public'; $btnMakePublic.Font = $uiFont
    $btnMakePrivate = New-Object System.Windows.Forms.Button
    $btnMakePrivate.Text = 'Make private'; $btnMakePrivate.Font = $uiFont
    $privW = Get-ButtonWidth $btnMakePrivate 110
    $privX = $boxWidth - $UI.BoxPad - $privW
    $pubW  = Get-ButtonWidth $btnMakePublic 110
    $pubX  = $privX - $UI.BtnGap - $pubW
    Set-Box $btnMakePrivate $privX $rowY $privW $UI.BtnH
    Set-Box $btnMakePublic $pubX $rowY $pubW $UI.BtnH
    $btnMakePublic.Anchor = 'Top,Right'; $btnMakePrivate.Anchor = 'Top,Right'

    $lblVis = New-Object System.Windows.Forms.Label
    $lblVis.ForeColor = [System.Drawing.Color]::Gray; $lblVis.TextAlign = 'MiddleLeft'
    Set-Box $lblVis $UI.BoxPad ($rowY + $inset) ($pubX - $UI.BtnGap - $UI.BoxPad) $UI.RowH
    $lblVis.Anchor = 'Top,Left,Right'

    $boxH = $rowY + $UI.BtnH + $UI.BoxPad
    Set-Box $grpVis $UI.Pad $y $boxWidth $boxH
    $grpVis.Anchor = 'Top,Left,Right'
    $grpVis.Controls.AddRange(@($lblVis, $btnMakePublic, $btnMakePrivate))
    $y += $boxH + $UI.BoxGap

    # ── Tasks (non-release utilities, e.g. rebuild the Tesseract bundle) ────────
    $grpTask = New-Object System.Windows.Forms.GroupBox
    $grpTask.Text = 'Tasks'

    $rowY = $UI.BoxTop
    $btnTask = New-Object System.Windows.Forms.Button
    $btnTask.Text = 'Run / copy'; $btnTask.Font = $uiFont
    $btnTask.Enabled = ($script:Tasks.Count -gt 0)
    $taskW = Get-ButtonWidth $btnTask 115
    $taskX = $boxWidth - $UI.BoxPad - $taskW
    Set-Box $btnTask $taskX $rowY $taskW $UI.BtnH
    $btnTask.Anchor = 'Top,Right'
    $cmbTask = New-Object System.Windows.Forms.ComboBox
    $cmbTask.DropDownStyle = 'DropDownList'
    Set-Field $cmbTask $uiFont $UI.BoxPad ($rowY + $inset) ($taskX - $UI.BtnGap - $UI.BoxPad)
    $cmbTask.Anchor = 'Top,Left,Right'
    $script:Tasks | ForEach-Object { [void]$cmbTask.Items.Add($_.name) }
    if ($cmbTask.Items.Count -gt 0) { $cmbTask.SelectedIndex = 0 }

    $boxH = $rowY + $UI.BtnH + $UI.BoxPad
    Set-Box $grpTask $UI.Pad $y $boxWidth $boxH
    $grpTask.Anchor = 'Top,Left,Right'
    $grpTask.Controls.AddRange(@($cmbTask, $btnTask))
    $y += $boxH + $UI.BoxGap

    # ── Git (status / add / commit / push in the target app's repo) ─────────────
    $grpGit = New-Object System.Windows.Forms.GroupBox
    $grpGit.Text = 'Git'

    # Add and Commit share one width at the box's right edge; their inputs stretch beside them.
    $btnGitAdd = New-Object System.Windows.Forms.Button
    $btnGitAdd.Text = 'Add'; $btnGitAdd.Font = $uiFont
    $btnGitCommit = New-Object System.Windows.Forms.Button
    $btnGitCommit.Text = 'Commit'; $btnGitCommit.Font = $uiFont
    $btnGitStatus = New-Object System.Windows.Forms.Button
    $btnGitStatus.Text = 'Status'; $btnGitStatus.Font = $uiFont
    $btnGitPush = New-Object System.Windows.Forms.Button
    $btnGitPush.Text = 'Push'; $btnGitPush.Font = $uiFont
    $gitBtnW = [Math]::Max((Get-ButtonWidth $btnGitAdd 110), (Get-ButtonWidth $btnGitCommit 110))
    $gitBtnX = $boxWidth - $UI.BoxPad - $gitBtnW
    $gitInputW = $gitBtnX - $UI.BtnGap - $inputX

    $rowY = $UI.BoxTop
    $lblGitAdd = New-Object System.Windows.Forms.Label
    $lblGitAdd.Text = 'Add:'; $lblGitAdd.TextAlign = 'MiddleLeft'
    Set-Box $lblGitAdd $UI.BoxPad ($rowY + $inset) $UI.BoxLabelW $UI.RowH
    $txtGitAdd = New-Object System.Windows.Forms.TextBox
    Set-Field $txtGitAdd $uiFont $inputX ($rowY + $inset) $gitInputW
    $txtGitAdd.Anchor = 'Top,Left,Right'
    Set-Box $btnGitAdd $gitBtnX $rowY $gitBtnW $UI.BtnH
    $btnGitAdd.Anchor = 'Top,Right'

    $rowY += $UI.BoxRowPitch
    $lblGitMsg = New-Object System.Windows.Forms.Label
    $lblGitMsg.Text = 'Message:'; $lblGitMsg.TextAlign = 'MiddleLeft'
    Set-Box $lblGitMsg $UI.BoxPad ($rowY + $inset) $UI.BoxLabelW $UI.RowH
    $txtGitMsg = New-Object System.Windows.Forms.TextBox
    $txtGitMsg.Multiline = $true; $txtGitMsg.ScrollBars = 'Vertical'; $txtGitMsg.AcceptsReturn = $true
    $txtGitMsg.Font = $uiFont
    Set-Box $txtGitMsg $inputX $rowY $gitInputW $UI.MessageH
    $txtGitMsg.Anchor = 'Top,Left,Right'
    Set-Box $btnGitCommit $gitBtnX $rowY $gitBtnW $UI.BtnH
    $btnGitCommit.Anchor = 'Top,Right'

    $rowY += $UI.MessageH + ($UI.BoxRowPitch - $UI.BtnH)
    [void](Set-ButtonRow @($btnGitStatus, $btnGitPush) $UI.BoxPad $rowY 110)

    $boxH = $rowY + $UI.BtnH + $UI.BoxPad
    Set-Box $grpGit $UI.Pad $y $boxWidth $boxH
    $grpGit.Anchor = 'Top,Left,Right'
    $grpGit.Controls.AddRange(@($lblGitAdd, $txtGitAdd, $btnGitAdd, $lblGitMsg, $txtGitMsg, $btnGitCommit, $btnGitStatus, $btnGitPush))
    $y += $boxH + $UI.BoxGap
    $tips.SetToolTip($txtGitAdd, 'Paths separated by spaces; put a path with spaces in "double quotes"; . adds every change.')
    $tips.SetToolTip($btnGitStatus, 'git status of the target app''s repo (read-only, no confirmation).')
    $tips.SetToolTip($btnGitCommit, 'git commit with the message above (several lines are fine).')
    $tips.SetToolTip($btnGitPush, 'git push of the current branch to its upstream — never --force.')

    # ── Bootstrap a project into an empty GitHub repository ─────────────────────
    $grpBootstrap = New-Object System.Windows.Forms.GroupBox
    $grpBootstrap.Text = 'GitHub repository bootstrap (empty remote: prepare → inspect → publish)'
    $bootstrapInputX = $UI.BoxPad + $UI.BootstrapLabelW + ($UI.BtnGap / 2)
    $bootstrapInputW = $boxWidth - $UI.BoxPad - $bootstrapInputX
    $rowY = $UI.BoxTop

    $lblBootstrapName = New-Object System.Windows.Forms.Label
    $lblBootstrapName.Text = 'App name:'; $lblBootstrapName.TextAlign = 'MiddleLeft'
    Set-Box $lblBootstrapName $UI.BoxPad ($rowY + $inset) $UI.BootstrapLabelW $UI.RowH
    $txtBootstrapName = New-Object System.Windows.Forms.TextBox
    Set-Field $txtBootstrapName $uiFont $bootstrapInputX ($rowY + $inset) $bootstrapInputW
    $txtBootstrapName.Anchor = 'Top,Left,Right'

    $rowY += $UI.BoxRowPitch
    $lblBootstrapRoot = New-Object System.Windows.Forms.Label
    $lblBootstrapRoot.Text = 'Project folder:'; $lblBootstrapRoot.TextAlign = 'MiddleLeft'
    Set-Box $lblBootstrapRoot $UI.BoxPad ($rowY + $inset) $UI.BootstrapLabelW $UI.RowH
    $txtBootstrapRoot = New-Object System.Windows.Forms.TextBox
    $bootstrapRootBrowseW = 90
    $bootstrapRootBrowseGap = 8
    $bootstrapRootFieldW = [Math]::Max(160, $bootstrapInputW - $bootstrapRootBrowseW - $bootstrapRootBrowseGap)
    Set-Field $txtBootstrapRoot $uiFont $bootstrapInputX ($rowY + $inset) $bootstrapRootFieldW
    $txtBootstrapRoot.Anchor = 'Top,Left,Right'
    $btnBootstrapBrowse = New-Object System.Windows.Forms.Button
    $btnBootstrapBrowse.Text = 'Browse...'; $btnBootstrapBrowse.Font = $uiFont
    Set-Box $btnBootstrapBrowse ($bootstrapInputX + $bootstrapRootFieldW + $bootstrapRootBrowseGap) ($rowY + $inset) $bootstrapRootBrowseW $UI.RowH
    $btnBootstrapBrowse.Anchor = 'Top,Right'

    $rowY += $UI.BoxRowPitch
    $lblBootstrapRepo = New-Object System.Windows.Forms.Label
    $lblBootstrapRepo.Text = 'GitHub repo:'; $lblBootstrapRepo.TextAlign = 'MiddleLeft'
    Set-Box $lblBootstrapRepo $UI.BoxPad ($rowY + $inset) $UI.BootstrapLabelW $UI.RowH
    $txtBootstrapRepo = New-Object System.Windows.Forms.TextBox
    Set-Field $txtBootstrapRepo $uiFont $bootstrapInputX ($rowY + $inset) $bootstrapInputW
    $txtBootstrapRepo.Anchor = 'Top,Left,Right'

    $rowY += $UI.BoxRowPitch
    $lblBootstrapMessage = New-Object System.Windows.Forms.Label
    $lblBootstrapMessage.Text = 'Commit message:'; $lblBootstrapMessage.TextAlign = 'MiddleLeft'
    Set-Box $lblBootstrapMessage $UI.BoxPad ($rowY + $inset) $UI.BootstrapLabelW $UI.RowH
    $txtBootstrapMessage = New-Object System.Windows.Forms.TextBox
    $txtBootstrapMessage.Multiline = $true; $txtBootstrapMessage.ScrollBars = 'Vertical'; $txtBootstrapMessage.AcceptsReturn = $true
    $txtBootstrapMessage.Font = $uiFont
    Set-Box $txtBootstrapMessage $bootstrapInputX $rowY $bootstrapInputW $UI.MessageH
    $txtBootstrapMessage.Anchor = 'Top,Left,Right'
    $txtBootstrapMessage.Text = 'Initial project commit'

    $rowY += $UI.MessageH + ($UI.BoxRowPitch - $UI.BtnH)
    $lblBootstrapScanner = New-Object System.Windows.Forms.Label
    $lblBootstrapScanner.Text = 'Gitleaks path:'; $lblBootstrapScanner.TextAlign = 'MiddleLeft'
    Set-Box $lblBootstrapScanner $UI.BoxPad ($rowY + $inset) $UI.BootstrapLabelW $UI.RowH
    $txtBootstrapScanner = New-Object System.Windows.Forms.TextBox
    Set-Field $txtBootstrapScanner $uiFont $bootstrapInputX ($rowY + $inset) $bootstrapInputW
    $txtBootstrapScanner.Anchor = 'Top,Left,Right'

    $rowY += $UI.BoxRowPitch
    $btnBootstrapCreateRepo = New-Object System.Windows.Forms.Button
    $btnBootstrapCreateRepo.Text = 'Create private repo'; $btnBootstrapCreateRepo.Font = $uiFont
    $btnBootstrapActionsSecrets = New-Object System.Windows.Forms.Button
    $btnBootstrapActionsSecrets.Text = 'Actions secrets...'; $btnBootstrapActionsSecrets.Font = $uiFont
    $btnBootstrapAddApp = New-Object System.Windows.Forms.Button
    $btnBootstrapAddApp.Text = 'Add app'; $btnBootstrapAddApp.Font = $uiFont
    [void](Set-ButtonRow @($btnBootstrapAddApp, $btnBootstrapCreateRepo, $btnBootstrapActionsSecrets) $UI.BoxPad $rowY $UI.BootstrapButtonMinW)

    $rowY += $UI.BoxRowPitch
    $btnBootstrapPlan = New-Object System.Windows.Forms.Button
    $btnBootstrapPlan.Text = 'Preflight'; $btnBootstrapPlan.Font = $uiFont
    $btnBootstrapPrepare = New-Object System.Windows.Forms.Button
    $btnBootstrapPrepare.Text = 'Prepare and stage'; $btnBootstrapPrepare.Font = $uiFont
    $btnBootstrapPublish = New-Object System.Windows.Forms.Button
    $btnBootstrapPublish.Text = 'Commit and push'; $btnBootstrapPublish.Font = $uiFont
    [void](Set-ButtonRow @($btnBootstrapPlan, $btnBootstrapPrepare, $btnBootstrapPublish) $UI.BoxPad $rowY $UI.BootstrapButtonMinW)

    $boxH = $rowY + $UI.BtnH + $UI.BoxPad
    Set-Box $grpBootstrap $UI.Pad $y $boxWidth $boxH
    $grpBootstrap.Anchor = 'Top,Left,Right'
    $grpBootstrap.Controls.AddRange(@(
        $lblBootstrapName, $txtBootstrapName, $lblBootstrapRoot, $txtBootstrapRoot, $btnBootstrapBrowse, $lblBootstrapRepo, $txtBootstrapRepo,
        $lblBootstrapMessage, $txtBootstrapMessage, $lblBootstrapScanner, $txtBootstrapScanner,
        $btnBootstrapAddApp, $btnBootstrapCreateRepo, $btnBootstrapActionsSecrets, $btnBootstrapPlan, $btnBootstrapPrepare, $btnBootstrapPublish))
    $y += $boxH + $UI.BoxGap
    $tips.SetToolTip($txtBootstrapScanner, 'Optional. Leave blank to find Gitleaks on PATH or in a sibling gitleaks_* folder.')
    $tips.SetToolTip($btnBootstrapPrepare, 'Sets main and origin, scans for secrets, then stages files. Review the staged paths before publishing.')
    $tips.SetToolTip($btnBootstrapPublish, 'Commits the reviewed prepared tree and pushes main to origin; stops if files changed after preparation.')
    $tips.SetToolTip($btnBootstrapAddApp, 'Registers a Git-only target in apps.json and selects it, so these bootstrap controls can continue with this project.')
    $tips.SetToolTip($btnBootstrapCreateRepo, 'Creates a new empty private GitHub repository from the owner/name field. It does not stage or push project files.')
    $tips.SetToolTip($btnBootstrapActionsSecrets, 'Lists repository-level GitHub Actions secret names and lets you add, replace, or delete a secret for the selected app.')
    $tips.SetToolTip($btnBootstrapBrowse, 'Choose an existing local project folder. Its folder name is suggested as the app name when that field is blank.')

    $initialBootstrapApp = Get-App $cmbTarget.SelectedItem
    if ($initialBootstrapApp) {
        $txtBootstrapRoot.Text = [string]$initialBootstrapApp.repoRoot
        try { $txtBootstrapRepo.Text = [string](Resolve-AppRepo $initialBootstrapApp) } catch { $txtBootstrapRepo.Text = '' }
    }
    $tabState.BootstrapDefaults = @{ Root = $txtBootstrapRoot.Text; Repo = $txtBootstrapRepo.Text }

    # ── Release notes — becomes the GitHub Release body (apps whose dispatchInputs use {notes})
    $grpNotes = New-Object System.Windows.Forms.GroupBox
    $grpNotes.Text = 'Release notes (Deploy / Trigger / Publish use this as the release message)'
    $boxH = $UI.BoxTop + $UI.NotesH + $UI.BoxPad
    Set-Box $grpNotes $UI.Pad $y $boxWidth $boxH
    $grpNotes.Anchor = 'Top,Left,Right'
    $txtNotes = New-Object System.Windows.Forms.TextBox
    $txtNotes.Multiline = $true; $txtNotes.ScrollBars = 'Vertical'
    $txtNotes.AcceptsReturn = $true
    $txtNotes.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    Set-Box $txtNotes $UI.BoxPad $UI.BoxTop ($boxWidth - 2 * $UI.BoxPad) $UI.NotesH
    $txtNotes.Anchor = 'Top,Left,Right'
    $grpNotes.Controls.Add($txtNotes)
    $y += $boxH + $UI.BoxGap

    # ── Log + status ───────────────────────────────────────────────────────────
    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
    $logBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $logBox.ForeColor = [System.Drawing.Color]::Gainsboro
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    Set-Box $logBox $UI.Pad $y $boxWidth $UI.LogH
    $logBox.Anchor = 'Top,Left,Right'
    $y += $UI.LogH + 10

    $status = New-Object System.Windows.Forms.Label
    $status.TextAlign = 'MiddleLeft'
    Set-Box $status $UI.Pad $y $boxWidth $UI.StatusH
    $status.Anchor = 'Top,Left,Right'
    $gitOk = if ($HasGit) { 'git OK' } else { 'git MISSING' }
    $ghOk  = if ($HasGh)  { 'gh OK' }  else { 'gh MISSING' }
    $status.Text = "$gitOk   |   $ghOk   |   release repo: $ReleaseRepo"
    $status.ForeColor = if ($HasGit -and $HasGh) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::Firebrick }
    $y += $UI.StatusH + $UI.Pad

    $panel.AutoScrollMinSize = New-Object System.Drawing.Size((Px $UI.ContentWidth), (Px $y))
    $panel.Controls.AddRange(@($lblTarget, $cmbTarget, $lblVer, $txtVer, $lblCur, $chkPublish, $chkDry, $grp, $grpPub, $grpVis, $grpTask, $grpGit, $grpBootstrap, $grpNotes, $logBox, $status))
    $panel.Dock = 'Fill'
    $page.Controls.Add($panel)

    # ── This tab's helpers ─────────────────────────────────────────────────────
    # Each helper is a closure (.GetNewClosure()), made in dependency order so it captures
    # this tab's controls and the helpers defined above it. A plain { } block would not
    # work here: the handlers run after New-JobTab has returned, and a plain block called
    # from a handler looks its variables up in the scope running at that moment
    # (Show-Gui's), where $cmbTarget, $logBox and the rest do not exist. That made picking
    # another target app a silent no-op — the tab kept its old title, version and info —
    # and made every button that writes to the log throw.

    # Appends one timestamped line to THIS tab's own log, so concurrent tabs' output never
    # crosses. Every caller — click handlers and a job's output timer (see $run) — runs
    # on the UI thread.
    $appendLog = {
        param($text)
        $logBox.AppendText(("{0}  {1}{2}" -f (Get-Date -Format 'HH:mm:ss'), $text, [Environment]::NewLine))
    }.GetNewClosure()

    $tabState.ShowReleasePlan = {
        param($app, [string]$requestedVersion)
        $plan = Get-ReleasePlan $app $requestedVersion
        $data = $plan.data
        & $appendLog "Release plan: $($data.target) | latest published=$($data.latestPublishedVersion) | suggested=$($data.suggestedVersion) | source=$($data.versionSource)"
        & $appendLog "  repo=$($data.repoRoot) releaseRepo=$($data.releaseRepo) workflow=$($data.workflow)"
        & $appendLog "  requested=$($data.requestedVersion) tag=$($data.tag) deployWithoutMovingTag=$($data.canDeployWithoutMovingTag)"
        & $appendLog "  branch=$($data.branch) head=$($data.head) workingTreeClean=$($data.workingTreeClean) localTag=$($data.localTagExists) remoteTag=$($data.remoteTagExists) release=$($data.releaseExists)"
        foreach ($line in @($data.workingTree)) { if ($line) { & $appendLog "  status: $line" } }
        foreach ($blocker in @($data.blockers)) { if ($blocker) { & $appendLog "  BLOCKED: $blocker" } }
        foreach ($warning in @($data.warnings)) { if ($warning) { & $appendLog "  WARNING: $warning" } }
        if ($data.release) { & $appendLog "  release: draft=$($data.release.isDraft) prerelease=$($data.release.isPrerelease) publishedAt=$($data.release.publishedAt)" }
        return $plan
    }.GetNewClosure()

    # Titles this tab after its target app, plus its job state ('running...', 'done',
    # 'failed (n)'), so several tabs running at once stay distinguishable at a glance
    # without opening each one.
    $setTabStatus = {
        param($text)
        $appName = if ($cmbTarget.SelectedItem) { $cmbTarget.SelectedItem } else { "Job $Number" }
        $page.Text = if ($text) { "$appName — $text" } else { "$appName" }
    }.GetNewClosure()

    # The Git group follows the selected app's repo: its name, branch and folder in the title; the buttons off
    # when the folder is not a git repo. Also re-read after a commit or push (the job's $onDone).
    $refreshGit = {
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app -or -not $grpGit) { return }
        $branch = Get-GitBranch $app
        $gitMarker = if (Test-Path -LiteralPath ([string]$app.repoRoot) -PathType Container) { Test-Path -LiteralPath (Join-Path ([string]$app.repoRoot) '.git') } else { $false }
        $grpGit.Text = if ($branch) { "Git  ->  $($app.name)  [$branch]   $($app.repoRoot)" }
                       elseif (-not $gitMarker) { "Git  ->  $($app.repoRoot)  (not initialized; use bootstrap)" }
                       else { "Git  ->  $($app.repoRoot)  (branch unavailable)" }
        foreach ($b in @($btnGitStatus, $btnGitAdd, $btnGitCommit, $btnGitPush)) { $b.Enabled = [bool]$branch }
    }.GetNewClosure()

    $refresh = {
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        # An app with no build workflow (InstaladorBUDA itself) is here for its Git group: no release steps.
        $hasWorkflow = -not [string]::IsNullOrWhiteSpace($app.workflow)
        $isImageOnly = $app.outputKind -eq 'container-image'
        $hasGithubRelease = $hasWorkflow -and -not $isImageOnly
        $btnDeploy.Enabled = $hasWorkflow
        $btnRetagDeploy.Enabled = $hasGithubRelease
        $btnReleasePlan.Enabled = [bool]$app.tagPrefix
        $btnDispatch.Enabled = $hasWorkflow
        foreach ($b in @($btnLoadRuns, $btnPubRun, $btnUndraft, $btnRelPage)) { $b.Enabled = $hasGithubRelease }
        $btnActions.Enabled = $hasWorkflow
        $chkPublish.Enabled = $hasGithubRelease
        $chkPublish.Checked = $hasGithubRelease
        $chkPublish.Text = if ($isImageOnly) { 'Container image publishes to GHCR; Flux follows the new semantic version' }
                           elseif ($hasWorkflow) { 'Publish to website (attach installers to the release)' }
                           else { 'No release workflow is configured for this target' }
        $grp.Text = if ($isImageOnly) { 'Build and publish image' } else { 'Steps' }
        $btnDeploy.Text = if ($isImageOnly) { '2. Publish image' } else { '2. Deploy (push tag)' }
        $btnDispatch.Text = if ($isImageOnly) { 'or: Publish image' } else { 'or: Trigger workflow' }
        $grpNotes.Enabled = $hasGithubRelease
        $grpNotes.Text = if ($isImageOnly) { 'Release notes (not used for container image builds)' }
                         elseif ($hasWorkflow) { 'Release notes (Deploy / Trigger / Publish use this as the release message)' }
                         else { 'Release notes (no release workflow configured)' }
        $grpPub.Enabled = $hasGithubRelease
        $txtNotes.Enabled = $hasGithubRelease
        if ($isImageOnly) {
            $tips.SetToolTip($btnDeploy, 'Pushes the version tag; GitHub builds the Namsel daemon image and Flux watches for the new semver tag.')
            $tips.SetToolTip($btnDispatch, 'Builds and publishes the Namsel daemon image for the entered version; Flux watches for the new semver tag.')
        } else {
            $tips.SetToolTip($btnDeploy, 'Pushes a real git tag locally, which always rebuilds every bundle.')
            $tips.SetToolTip($btnDispatch, "With 'Publish to website' checked, this DOES create a real tag + release (same gh release create/finalize path as Deploy) — it just doesn't push a local git tag, so InstaladorBUDA's 'current version' won't see it until you 'git fetch --tags'.")
        }
        & $refreshGit
        $bootstrapRepo = ''
        try { $bootstrapRepo = [string](Resolve-AppRepo $app) } catch { }
        if ([string]::IsNullOrWhiteSpace($bootstrapRepo) -and [string]::IsNullOrWhiteSpace([string]$app.workflow) -and [string]::IsNullOrWhiteSpace([string]$app.tagPrefix) -and $app.releaseRepo) {
            $bootstrapRepo = [string]$app.releaseRepo
        }
        if ($txtBootstrapRoot.Text -eq $tabState.BootstrapDefaults.Root) { $txtBootstrapRoot.Text = [string]$app.repoRoot }
        if ($txtBootstrapRepo.Text -eq $tabState.BootstrapDefaults.Repo) { $txtBootstrapRepo.Text = $bootstrapRepo }
        $tabState.BootstrapDefaults = @{ Root = [string]$app.repoRoot; Repo = $bootstrapRepo }
        $cur = Get-CurrentVersion $app
        $lblCur.Text = "current: $cur   ->   tag: $($app.tagPrefix)"
        if ([string]::IsNullOrWhiteSpace($txtVer.Text) -or $txtVer.Tag -ne $app.name) {
            $txtVer.Text = Get-NextVersion $cur
            $txtVer.Tag  = $app.name
        }
        $canUpload = [bool]$app.uploadScript -or (@($app.models).Count -gt 0)
        $btnUpload.Enabled = $canUpload
        $btnUpload.Text = if ($canUpload) { '1. Upload models' } else { '1. Upload models (n/a)' }
        # Publish-from-run pickers follow the selected app.
        if ($cmbWf) {
            $cmbWf.Items.Clear(); $cmbWf.Text = $app.workflow
            $cmbRun.Items.Clear(); $tabState.LoadedRuns = @()
            $relRepo = Resolve-ReleaseRepo $app
            if ($hasGithubRelease) { $grpPub.Text = "Publish from existing run (no rebuild)  ->  $relRepo" }
            elseif ($isImageOnly) { $grpPub.Text = 'GitHub release controls (not used for container image builds)' }
            else { $grpPub.Text = 'GitHub release controls (no release workflow configured)' }
        }
        # Repo visibility follows the selected app's OWN repo (where Actions minutes
        # are spent), not the release repo.
        if ($lblVis) {
            $repoSlug = Resolve-AppRepo $app
            $grpVis.Text = "Repo visibility  ->  $(if ($repoSlug) { $repoSlug } else { '(no git remote found)' })"
            $lblVis.Text = 'checking...'
            $lblVis.ForeColor = [System.Drawing.Color]::Gray
            $canManageVisibility = [bool]$repoSlug
            if ($null -ne $app.manageVisibility) { $canManageVisibility = $canManageVisibility -and [bool]$app.manageVisibility }
            $btnMakePublic.Enabled = $canManageVisibility
            $btnMakePrivate.Enabled = $canManageVisibility
        }
        if (-not $tabState.IsRunning) { & $setTabStatus $null }
    }.GetNewClosure()

    $run = {
        # $followUp: optional lines run after $commands in the same job (Build-FollowUpLines)
        # — they follow the build the commands started and report the release.
        # $onDone: optional script block called on the UI thread once the job has finished
        # (whatever its exit code) — e.g. to re-read something the commands changed.
        # $noConfirm: a read-only command (git status) runs without the Yes/No dialog.
        param($commands, $label, $needsGh, $repoRoot, $followUp, $onDone, $noConfirm)
        if (-not $commands -or $commands.Count -eq 0) { & $appendLog "Nothing to do for this target."; return }
        $tabState.LastCommands = $commands

        if ($chkDry.Checked) {
            & $appendLog "[dry run] $label :"
            & $appendLog "    cd `"$repoRoot`""
            $commands | ForEach-Object { & $appendLog "    $_" }
            if ($followUp) { & $appendLog "    (for real, it would then follow the build here and report the release)" }
            & $appendLog "Use 'Copy last command' to grab it."
            return
        }
        if (($needsGh -and -not $HasGh) -or (-not $needsGh -and -not $HasGit)) {
            $tool = if ($needsGh) { 'gh' } else { 'git' }
            & $appendLog "$tool not found — showing the command instead (install it, or run elsewhere):"
            $commands | ForEach-Object { & $appendLog "    $_" }
            return
        }
        if (-not $noConfirm -and -not $tabState.CliConfirmed) {
            $msg = "This will run, in`n$repoRoot :`n`n" + ($commands -join "`n") + "`n`nContinue?"
            $ans = [System.Windows.Forms.MessageBox]::Show($msg, "Confirm — $label", 'YesNo', 'Question')
            if ($ans -ne 'Yes') { & $appendLog "Cancelled: $label"; return }
        }

        # Guard against a second real run stacking on top of this tab's current one —
        # intended concurrency is ACROSS tabs (open another "+" tab for that), not two
        # overlapping processes sharing this one tab's $tabState.Proc/IsRunning slot,
        # which would silently orphan the first process's reference (breaking Cleanup /
        # kill-on-close for it) and race the two jobs' output timers' writes to IsRunning.
        if ($tabState.IsRunning) {
            & $appendLog "This tab already has a job running — open a new tab (the '+' tab) to run another one alongside it."
            return
        }

        # Write the commands to a temp .ps1 and run THAT. Passing them inline via -Command
        # double-parses the string, so any command that contains its OWN quotes (e.g. a
        # WriteAllText("...") + FromBase64String('...') release note) collides and fails to
        # parse. In a script file every command is written verbatim — no escaping needed.
        $rr  = $repoRoot.Replace("'", "''")
        $lbl = ($label -replace '[\r\n]', ' ').Replace("'", "''")
        $lines = @(
            # $__since: when this step started, so a follow-up can tell the run it caused
            # from older ones. $__code: the job's exit code, which a follow-up may set.
            "`$__since = [datetime]::UtcNow; `$__code = 0"
            # The log reads the job's output as UTF-8 (accents in notes, paths, git output).
            "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8"
            "Set-Location -LiteralPath '$rr'"
            "Write-Host '=== InstaladorBUDA: $lbl ===' -ForegroundColor Cyan"
        ) + @(
            # After each command, the first native failure becomes the job's exit code. Without
            # this a failing command printed its error, the job went on to "Done." and exited 0,
            # and the log said "finished (OK)" (2026-10-07: the upload script threw, the run was OK).
            # An if statement does not touch $LASTEXITCODE, so a follow-up still reads the last one.
            foreach ($c in $commands) { $c; 'if ($LASTEXITCODE -and -not $__code) { $__code = $LASTEXITCODE }' }
        ) + @($followUp | Where-Object { $_ }) + @(
            "Write-Host ''"
            "Write-Host 'Done.' -ForegroundColor Green"
            "exit `$__code"
        )
        $tmp = Join-Path $env:TEMP ("instaladorbuda-run-" + [guid]::NewGuid().ToString('N') + ".ps1")
        Set-Content -LiteralPath $tmp -Value $lines -Encoding UTF8

        # Run with stdout/stderr redirected into THIS TAB's log box, so several tabs can
        # run at once without their output interleaving in one shared box. CreateNoWindow
        # hides the console; the output streams into $logBox instead.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        # One Arguments string, not ArgumentList: ProcessStartInfo.ArgumentList does not
        # exist on .NET Framework, which is what the compiled exe runs on. $tmp is a GUID
        # file name under %TEMP%, so quoting it is all the escaping it needs.
        $psi.FileName = 'pwsh'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $tabState.IsRunning = $true
        $tabState.Proc = $proc
        & $setTabStatus 'running...'
        & $appendLog "=== $label ==="
        [void]$proc.Start()

        # The output is read on the UI thread by a timer, not by Register-ObjectEvent or
        # the process's DataReceived events. PowerShell runs an event -Action only when
        # the engine gets control back, and while the window is up it is inside
        # ShowDialog: every line of a job, and its Exited handler, arrived together only
        # once the window was closed — so the tab showed no output and said "running..."
        # forever. Each tick takes the lines already read (ReadLineAsync never blocks the
        # UI) and, once both streams have ended and the process has exited, closes the job.
        # A closure made in here captures only this scope's variables, so everything the
        # tick needs travels in $job; its entries are also the only state that outlives
        # one tick (assigning to a captured variable would not).
        $job = @{
            Proc      = $proc
            Streams   = @(
                @{ Reader = $proc.StandardOutput; Pending = $null; Done = $false },
                @{ Reader = $proc.StandardError;  Pending = $null; Done = $false })
            Timer     = New-Object System.Windows.Forms.Timer
            Log       = $appendLog
            SetStatus = $setTabStatus
            TabState  = $tabState
            TmpFile   = $tmp
            OnDone    = $onDone
        }
        $job.Timer.Interval = 100
        $job.Timer.Add_Tick({
            foreach ($s in $job.Streams) {
                while (-not $s.Done) {
                    if (-not $s.Pending) { $s.Pending = $s.Reader.ReadLineAsync() }
                    if (-not $s.Pending.IsCompleted) { break }
                    $line = $s.Pending.Result
                    $s.Pending = $null
                    if ($null -eq $line) { $s.Done = $true }
                    elseif ($line.StartsWith('::status::')) { & $job.SetStatus $line.Substring(10) }
                    else { & $job.Log $line }
                }
            }
            if ($job.Streams[0].Done -and $job.Streams[1].Done -and $job.Proc.HasExited) {
                $job.Timer.Stop(); $job.Timer.Dispose()
                $code = $job.Proc.ExitCode
                & $job.Log $(if ($code -eq 0) { '--- finished (OK) ---' } else { "--- finished (exit code $code) ---" })
                $job.TabState.IsRunning = $false
                & $job.SetStatus $(if ($code -eq 0) { 'done' } else { "failed ($code)" })
                Remove-Item -LiteralPath $job.TmpFile -ErrorAction SilentlyContinue
                if ($job.OnDone) { & $job.OnDone }
            }
        }.GetNewClosure())
        $job.Timer.Start()
    }.GetNewClosure()
    $tabState.StartJob = $run

    $startBootstrap = {
        param([string]$phase)
        $rawRoot = $txtBootstrapRoot.Text.Trim()
        $githubRepo = $txtBootstrapRepo.Text.Trim().TrimEnd('/')
        if (-not $rawRoot) { & $appendLog 'Type the project folder first.'; return }
        if (-not (Test-Path -LiteralPath $rawRoot -PathType Container)) { & $appendLog "Project folder does not exist: $rawRoot"; return }
        if ($githubRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            & $appendLog 'GitHub repository must be owner/name, for example TashiRabten/ScanBUDA.'; return
        }
        $commitMessage = $txtBootstrapMessage.Text
        if ($phase -eq 'publish' -and [string]::IsNullOrWhiteSpace($commitMessage)) { & $appendLog 'Type the initial commit message first.'; return }
        if ($tabState.IsRunning) { & $appendLog 'This tab already has a running job; choose an idle tab for bootstrap.'; return }
        if (-not $HasGit -or -not $HasGh) {
            & $appendLog 'Git bootstrap requires both git and the GitHub CLI (gh). Install the missing tool, then retry.'
            return
        }
        try {
            $repoRoot = (Resolve-Path -LiteralPath $rawRoot).Path
            $scanner = Resolve-GitBootstrapScanner $txtBootstrapScanner.Text.Trim() $AppDir
            $commands = Build-GitBootstrapCommands $repoRoot $githubRepo $phase $commitMessage $scanner
            & $run $commands "GitHub repository $phase ($githubRepo)" $true $repoRoot $null $null ($phase -eq 'plan')
        } catch {
            & $appendLog "Bootstrap preflight stopped: $($_.Exception.Message)"
        }
    }.GetNewClosure()

    $appRegistry = $script:AppRegistry
    $registerApp = {
        $name = $txtBootstrapName.Text.Trim()
        $rawRoot = $txtBootstrapRoot.Text.Trim()
        $githubRepo = $txtBootstrapRepo.Text.Trim().TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Type an app name first.' }
        if ($name.Length -gt 100 -or $name -match '[\x00-\x1f]') { throw 'App name must be 100 characters or fewer and cannot contain control characters.' }
        if ([string]::IsNullOrWhiteSpace($rawRoot)) { throw 'Type the project folder first.' }
        if (-not (Test-Path -LiteralPath $rawRoot -PathType Container)) { throw "Project folder does not exist: $rawRoot" }
        if ($githubRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            throw 'GitHub repository must be owner/name, for example TashiRabten/ScanBUDA.'
        }
        $repoRoot = (Resolve-Path -LiteralPath $rawRoot).Path
        $newApp = [pscustomobject][ordered]@{
            name = $name
            _comment = 'Git controls and GitHub repository bootstrap; no release workflow configured yet.'
            repoRoot = $repoRoot
            releaseRepo = $githubRepo
            manageVisibility = $false
            tagPrefix = ''
            workflow = ''
            releaseBranch = ''
            versionFromGitTag = ''
            uploadScript = $null
            models = @()
            dispatchInputs = @()
        }
        $added = $appRegistry.Add($newApp)
        foreach ($targetPage in @($Tabs.TabPages | Where-Object { $_.Tag -and $_.Tag.Controls -and $_.Tag.Controls.Target })) {
            $targetControl = $targetPage.Tag.Controls.Target
            if (-not $targetControl.Items.Contains($added.name)) { [void]$targetControl.Items.Add($added.name) }
        }
        $cmbTarget.SelectedItem = $added.name
        $tabState.LastAddedApp = $added.name
        & $appendLog "Registered '$($added.name)' for $githubRepo. It is selected; run Preflight in this group to continue the existing bootstrap."
        return $added
    }.GetNewClosure()

    $createBootstrapRepo = {
        $githubRepo = $txtBootstrapRepo.Text.Trim().TrimEnd('/')
        $rawRoot = $txtBootstrapRoot.Text.Trim()
        if ($githubRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            & $appendLog 'GitHub repository must be owner/name, for example TashiRabten/AI-config.'; return
        }
        if (-not $rawRoot -or -not (Test-Path -LiteralPath $rawRoot -PathType Container)) {
            & $appendLog 'Choose an existing project folder first.'; return
        }
        if ($tabState.IsRunning) { & $appendLog 'This tab already has a running job; choose an idle tab to create the repository.'; return }
        if (-not $HasGh) { & $appendLog 'Creating a GitHub repository requires the GitHub CLI (gh) and an authenticated session.'; return }
        try {
            $repoRoot = (Resolve-Path -LiteralPath $rawRoot).Path
            $commands = Build-GitHubRepoCreateCommands $githubRepo
            $txtBootstrapRepo.Text = $githubRepo
            & $run $commands "Create private GitHub repository ($githubRepo)" $true $repoRoot $null $null
        } catch {
            & $appendLog "Repository creation stopped: $($_.Exception.Message)"
        }
    }.GetNewClosure()
    $manageActionsSecrets = {
        $tabState.LastActionsSecretsResult = 'cancelled'
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { & $appendLog 'Select an app before managing its Actions secrets.'; $tabState.LastActionsSecretsResult = 'failed'; return }
        if ($tabState.IsRunning) { & $appendLog 'This tab already has a running job; choose an idle tab before managing Actions secrets.'; $tabState.LastActionsSecretsResult = 'failed'; return }
        if (-not $HasGh) { & $appendLog 'Managing Actions secrets requires the GitHub CLI (gh).'; $tabState.LastActionsSecretsResult = 'failed'; return }
        $repo = ''
        try { $repo = [string](Resolve-AppRepo $app) }
        catch {
            $repo = ''
            Write-Debug "Could not resolve the Actions-secrets repository: $($_.Exception.Message)"
        }
        if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and -not $app.workflow -and -not $app.tagPrefix) {
            $repo = [string]$app.releaseRepo
        }
        if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            & $appendLog "The selected app '$($app.name)' has no GitHub owner/name repository."; $tabState.LastActionsSecretsResult = 'failed'; return
        }
        try {
            $owner = $page.FindForm()
            $result = Show-GitHubActionsSecretDialog -RepositorySlug $repo -Owner $owner
            if (-not $result -or @($result.Operations).Count -eq 0) {
                $tabState.LastActionsSecretsResult = 'closed'
                & $appendLog "Actions secrets window closed without changes for $repo."
                return
            }
            $tabState.LastActionsSecretsResult = 'configured'
            foreach ($operation in @($result.Operations)) {
                if ($operation.Action -eq 'set') { & $appendLog "Saved Actions secret '$($operation.Name)' in $repo. The value was not logged." }
                elseif ($operation.Action -eq 'delete') { & $appendLog "Deleted Actions secret '$($operation.Name)' from $repo." }
            }
        } catch {
            $tabState.LastActionsSecretsResult = 'failed'
            & $appendLog 'Could not manage Actions secrets. Check gh authentication, repository access, and Actions-secrets permission. Secret values are not logged.'
        }
    }.GetNewClosure()
    $tabState.RegisterApp = $registerApp

    # Best-effort: if the whole app is closed while this tab's job is still running,
    # kill the child process rather than leaving it orphaned in the background.
    $tabState.Cleanup = {
        if ($tabState.Proc -and -not $tabState.Proc.HasExited) {
            try { $tabState.Proc.Kill() } catch { }
        }
    }.GetNewClosure()

    # Queries gh for the selected app's current repo visibility and updates the label.
    # Separate from $refresh (which must stay fast) since this shells out to gh.
    $refreshVisibility = {
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app -or -not $lblVis) { return }
        $repoSlug = Resolve-AppRepo $app
        if (-not $repoSlug) { $lblVis.Text = 'no git remote found'; $lblVis.ForeColor = [System.Drawing.Color]::Firebrick; return }
        if (-not $HasGh) { $lblVis.Text = 'gh not found - cannot check'; $lblVis.ForeColor = [System.Drawing.Color]::Firebrick; return }
        $vis = Get-RepoVisibility $repoSlug
        if (-not $vis) { $lblVis.Text = 'could not read visibility (auth?)'; $lblVis.ForeColor = [System.Drawing.Color]::Firebrick; return }
        $lblVis.Text = "currently: $vis"
        $lblVis.ForeColor = if ($vis -eq 'public') { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::ForestGreen }
    }.GetNewClosure()

    $cmbTarget.Add_SelectedIndexChanged({ & $refresh; & $refreshVisibility }.GetNewClosure())
    $btnUpload.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if ($app.uploadModels -and @($app.uploadModels).Count -gt 0) {
            if ($null -ne $tabState.CliModels) { $sel = @($tabState.CliModels) }
            else { $sel = Show-ModelPicker $app }
            $tabState.CliModels = $null
            if ($null -eq $sel) { & $appendLog "Upload cancelled."; return }
            if (@($sel).Count -eq 0) { & $appendLog "No models selected — nothing to upload."; return }
            & $run (Build-UploadCommands $app $sel) "Upload models ($($app.name)): $($sel -join ', ')" $true $app.repoRoot
        } else {
            & $run (Build-UploadCommands $app) "Upload models ($($app.name))" $true $app.repoRoot
        }
    }.GetNewClosure())
    $startTag = {
        param([bool]$replaceTag)
        $app = Get-App $cmbTarget.SelectedItem
        $isImageOnly = $app.outputKind -eq 'container-image'
        $v = $txtVer.Text.Trim()
        if (-not $v) { & $appendLog "Enter a version first."; return }
        if ($isImageOnly -and $v -notmatch '^\d+\.\d+\.\d+$') {
            & $appendLog 'Container image versions must use semantic version format x.y.z.'; return
        }
        # Apps with tiered bundles (SegBUDA) pick which ones this release rebuilds. The
        # selection rides in the tag message (Build-TagCommands); ticking all of them is a
        # plain tag push, exactly as before.
        $bundles = 'all'
        if ($app.bundles -and @($app.bundles).Count -gt 0) {
            if ($null -ne $tabState.CliBundles) { $picked = [string]$tabState.CliBundles }
            else { $picked = Show-BundlePicker $app }
            $tabState.CliBundles = $null
            if ($null -eq $picked) { & $appendLog "Deploy cancelled."; return }
            if ([string]::IsNullOrWhiteSpace($picked)) { & $appendLog "No bundles selected — nothing to deploy."; return }
            $bundles = Resolve-BundleSelection $app $picked
        }
        # GitHub release notes ride along as the annotated tag message. Container-image
        # workflows do not create GitHub releases, so their tags stay lightweight.
        $notes = if ($isImageOnly) { '' } else { $txtNotes.Text }
        $verb = if ($replaceTag) { 'Retag' } else { 'Deploy' }
        $label = if ($isImageOnly) { "Publish $($app.name) image v$v (push tag)" }
                 elseif ($bundles -eq 'all') { "$verb $($app.name) v$v (push tag)" }
                 else { "$verb $($app.name) v$v (push tag, bundles: $bundles)" }
        try {
            $commands = Build-TagCommands $app $v $notes $bundles $replaceTag
            & $run $commands $label $false $app.repoRoot (Build-FollowUpLines $app 'push' $v $true)
        } catch {
            & $appendLog "$verb preflight stopped: $($_.Exception.Message)"
        }
    }.GetNewClosure()
    $btnDeploy.Add_Click({ & $startTag $false }.GetNewClosure())
    $btnRetagDeploy.Add_Click({ & $startTag $true }.GetNewClosure())
    $btnReleasePlan.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        try { $showPlan = $tabState.ShowReleasePlan; & $showPlan $app $txtVer.Text.Trim() | Out-Null }
        catch { & $appendLog "Release plan failed: $($_.Exception.Message)" }
    }.GetNewClosure())
    $btnBootstrapPlan.Add_Click({ & $startBootstrap 'plan' }.GetNewClosure())
    $btnBootstrapPrepare.Add_Click({ & $startBootstrap 'prepare' }.GetNewClosure())
    $btnBootstrapPublish.Add_Click({ & $startBootstrap 'publish' }.GetNewClosure())
    $btnBootstrapCreateRepo.Add_Click({ & $createBootstrapRepo }.GetNewClosure())
    $btnBootstrapActionsSecrets.Add_Click({ & $manageActionsSecrets }.GetNewClosure())
    $btnBootstrapBrowse.Add_Click({
        $folderDialog = $null
        try {
            $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $folderDialog.Description = 'Choose the local project folder to register.'
            $folderDialog.ShowNewFolderButton = $false
            $currentRoot = $txtBootstrapRoot.Text.Trim()
            if ($currentRoot -and (Test-Path -LiteralPath $currentRoot -PathType Container)) {
                $folderDialog.SelectedPath = (Resolve-Path -LiteralPath $currentRoot).Path
            }
            $owner = $page.FindForm()
            $dialogResult = if ($owner) { $folderDialog.ShowDialog($owner) } else { $folderDialog.ShowDialog() }
            if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
                $selectedRoot = (Resolve-Path -LiteralPath $folderDialog.SelectedPath).Path
                $selectedDirectory = Get-Item -LiteralPath $selectedRoot
                $txtBootstrapRoot.Text = $selectedRoot
                $suggestedName = $selectedDirectory.Name
                if ([string]::IsNullOrWhiteSpace($txtBootstrapName.Text)) {
                    if ($suggestedName) { $txtBootstrapName.Text = $suggestedName }
                }
                $defaultRepo = [string]$tabState.BootstrapDefaults.Repo
                $defaultRoot = [string]$tabState.BootstrapDefaults.Root
                $currentRepo = $txtBootstrapRepo.Text.Trim().TrimEnd('/')
                if ($suggestedName -and $defaultRepo -and $currentRepo -eq $defaultRepo -and $defaultRoot -and
                    (Test-Path -LiteralPath $defaultRoot -PathType Container)) {
                    $resolvedDefaultRoot = (Resolve-Path -LiteralPath $defaultRoot).Path
                    if ($selectedRoot -ine $resolvedDefaultRoot) {
                        $ownerMatch = [regex]::Match($defaultRepo, '^([^/]+)/[^/]+$')
                        $repoName = [regex]::Replace($suggestedName, '^[.]+', '')
                        $repoName = [regex]::Replace($repoName, '[^A-Za-z0-9_.-]+', '-').Trim([char[]]@('-', '.'))
                        if ($ownerMatch.Success -and $repoName) {
                            $txtBootstrapRepo.Text = $ownerMatch.Groups[1].Value + '/' + $repoName
                        }
                    }
                }
            }
        } catch {
            & $appendLog "Folder selection failed: $($_.Exception.Message)"
        } finally {
            if ($folderDialog) { $folderDialog.Dispose() }
        }
    }.GetNewClosure())
    $btnBootstrapAddApp.Add_Click({
        $tabState.LastAddedApp = $null
        $tabState.LastAddAppError = $null
        try { [void](& $registerApp) }
        catch {
            $tabState.LastAddAppError = $_.Exception.Message
            & $appendLog "Add app stopped: $($_.Exception.Message)"
        }
    }.GetNewClosure())
    $btnDispatch.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        $isImageOnly = $app.outputKind -eq 'container-image'
        $v = $txtVer.Text.Trim()
        if (-not $v) { & $appendLog "Enter a version first."; return }
        if ($isImageOnly -and $v -notmatch '^\d+\.\d+\.\d+$') {
            & $appendLog 'Container image versions must use semantic version format x.y.z.'; return
        }
        $notes = if ($isImageOnly) { '' } else { $txtNotes.Text }
        $publish = $chkPublish.Checked -and -not $isImageOnly
        $usesNotes = @($app.dispatchInputs | Where-Object { "$($_.value)".Contains('{notes}') }).Count -gt 0
        if ($usesNotes -and [string]::IsNullOrWhiteSpace($notes)) {
            & $appendLog "Tip: Release notes are empty — the release will use a default message."
        }
        $bundles = 'all'
        if ($app.bundles -and @($app.bundles).Count -gt 0) {
            if ($null -ne $tabState.CliBundles) { $picked = [string]$tabState.CliBundles }
            else { $picked = Show-BundlePicker $app }
            $tabState.CliBundles = $null
            if ($null -eq $picked) { & $appendLog "Trigger cancelled."; return }
            if ([string]::IsNullOrWhiteSpace($picked)) { & $appendLog "No bundles selected — nothing to build."; return }
            $bundles = $picked
        }
        $label = if ($isImageOnly) { "Publish $($app.name) image v$v" } else { "Trigger $($app.name) workflow v$v ($bundles)" }
        & $run (Build-DispatchCommands $app $v $publish $notes $bundles) $label $true $app.repoRoot (Build-FollowUpLines $app 'dispatch' $v $publish)
    }.GetNewClosure())
    $btnCopy.Add_Click({
        if ($tabState.LastCommands) {
            Set-Clipboard -Value ($tabState.LastCommands -join [Environment]::NewLine)
            & $appendLog "Copied last command to clipboard."
        } else { & $appendLog "No command yet — click a step first." }
    }.GetNewClosure())
    $btnActions.Add_Click({ Start-Process $ActionsUrl | Out-Null }.GetNewClosure())

    # ── Repo visibility handlers ─────────────────────────────────────────────
    $btnMakePublic.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        if ($null -ne $app.manageVisibility -and -not [bool]$app.manageVisibility) { & $appendLog "Visibility changes are disabled for $($app.name)."; return }
        $repoSlug = Resolve-AppRepo $app
        if (-not $repoSlug) { & $appendLog "Could not resolve the GitHub repo for $($app.name) (no git remote?)."; return }
        if (-not $chkDry.Checked -and -not $tabState.CliConfirmed) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Make $repoSlug PUBLIC?`n`nAnyone will be able to view (not push to) this repo until you switch it back to private.",
                'Confirm — Make public', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { & $appendLog "Cancelled: make $repoSlug public."; return }
        }
        # Re-read the visibility when the change has finished — the job runs in the
        # background, so reading it right after starting it still got the old value.
        & $run (Build-VisibilityCommands $repoSlug 'public') "Make $($app.name) repo public" $true $app.repoRoot $null $refreshVisibility
    }.GetNewClosure())
    $btnMakePrivate.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        if ($null -ne $app.manageVisibility -and -not [bool]$app.manageVisibility) { & $appendLog "Visibility changes are disabled for $($app.name)."; return }
        $repoSlug = Resolve-AppRepo $app
        if (-not $repoSlug) { & $appendLog "Could not resolve the GitHub repo for $($app.name) (no git remote?)."; return }
        & $run (Build-VisibilityCommands $repoSlug 'private') "Make $($app.name) repo private" $true $app.repoRoot $null $refreshVisibility
    }.GetNewClosure())

    # ── Publish-from-run handlers ──────────────────────────────────────────────
    # Populate the workflow picker lazily from the repo when its dropdown opens.
    $cmbWf.Add_DropDown({
        if ($cmbWf.Items.Count -le 1 -and $HasGh) {
            $app = Get-App $cmbTarget.SelectedItem
            if ($app) {
                $cur = $cmbWf.Text
                $wfs = Get-RepoWorkflows (Resolve-AppRepo $app)
                $cmbWf.Items.Clear()
                $wfs | ForEach-Object { [void]$cmbWf.Items.Add($_) }
                if ($cur) { $cmbWf.Text = $cur }
            }
        }
    }.GetNewClosure())
    $btnLoadRuns.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        if (-not $HasGh) { & $appendLog 'gh not found - cannot list runs.'; return }
        $repo = Resolve-AppRepo $app
        if (-not $repo) { & $appendLog "Could not resolve the GitHub repo for $($app.name) (no git remote?)."; return }
        $wf = $cmbWf.Text.Trim(); if (-not $wf) { $wf = $app.workflow; $cmbWf.Text = $wf }
        & $appendLog "Loading runs: $wf @ $repo ..."
        $tabState.LoadedRuns = Get-WorkflowRuns $repo $wf
        $cmbRun.Items.Clear()
        if ($tabState.LoadedRuns.Count -eq 0) { & $appendLog 'No runs found (or gh error / not authenticated).'; return }
        foreach ($r in $tabState.LoadedRuns) {
            $when  = try { ([datetime]$r.createdAt).ToLocalTime().ToString('MM-dd HH:mm') } catch { "$($r.createdAt)" }
            $state = if ($r.conclusion) { $r.conclusion } else { $r.status }
            [void]$cmbRun.Items.Add(("{0}  [{1}]  {2}  ({3})" -f $when, $state, $r.displayTitle, $r.headBranch))
        }
        $okIdx = -1
        for ($i = 0; $i -lt $tabState.LoadedRuns.Count; $i++) {
            if ($tabState.LoadedRuns[$i].conclusion -eq 'success') { $okIdx = $i; break }
        }
        $cmbRun.SelectedIndex = if ($okIdx -ge 0) { $okIdx } else { 0 }
        & $appendLog "Loaded $($cmbRun.Items.Count) run(s); newest successful preselected."
    }.GetNewClosure())
    $btnPubRun.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        $v = $txtVer.Text.Trim()
        if (-not $v) { & $appendLog 'Enter the version to publish AS (the release tag) first.'; return }
        if ($cmbRun.SelectedIndex -lt 0 -or $cmbRun.SelectedIndex -ge $tabState.LoadedRuns.Count) {
            & $appendLog 'Pick a run first - click "Load runs".'; return
        }
        $r = $tabState.LoadedRuns[$cmbRun.SelectedIndex]
        if ($r.conclusion -and $r.conclusion -ne 'success') {
            & $appendLog "Note: selected run conclusion is '$($r.conclusion)' (not success) - its installers may be missing."
        }
        $cmds = Build-PublishFromRunCommands $app (Resolve-AppRepo $app) "$($r.databaseId)" $v $txtNotes.Text
        & $run $cmds "Publish $($app.name) v$v from run $($r.databaseId) (no rebuild)" $true $app.repoRoot (Build-FollowUpLines $app 'release' $v $true)
    }.GetNewClosure())
    $btnUndraft.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        $v = $txtVer.Text.Trim()
        if (-not $v) { & $appendLog 'Enter the version (release tag) to un-draft first.'; return }
        & $run (Build-UndraftCommands $app $v) "Un-draft $($app.name) v$v" $true $app.repoRoot (Build-FollowUpLines $app 'release' $v $true)
    }.GetNewClosure())
    $btnRelPage.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        $v = $txtVer.Text.Trim(); if (-not $v) { $v = (Get-CurrentVersion $app) }
        $relRepo = Resolve-ReleaseRepo $app
        Start-Process ("https://github.com/{0}/releases/tag/{1}{2}" -f $relRepo, $app.tagPrefix, $v) | Out-Null
        & $appendLog "Opened release page: $relRepo $($app.tagPrefix)$v"
    }.GetNewClosure())
    $btnTask.Add_Click({
        if ($cmbTask.SelectedIndex -lt 0) { return }
        $task = $script:Tasks[$cmbTask.SelectedIndex]
        $repoRoot = Resolve-TaskRepoRoot $task
        $tabState.LastCommands = @($task.command)
        if ($task.runOn -eq 'mac') {
            # Can't run mac bash on Windows — show + copy it for the Mac VM terminal.
            & $appendLog "Run this on your Mac VM (in $repoRoot):"
            & $appendLog "    $($task.command)"
            Set-Clipboard -Value $task.command
            & $appendLog "Copied to clipboard."
            return
        }
        $needsGh = ($task.command -match '\bgh\b')
        & $run @($task.command) "Task: $($task.name)" $needsGh $repoRoot
    }.GetNewClosure())

    # ── Git handlers ─────────────────────────────────────────────────────────────
    $btnGitStatus.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        & $run (Build-GitStatusCommands $app) "git status ($($app.name))" $false $app.repoRoot $null $refreshGit $true
    }.GetNewClosure())
    $btnGitAdd.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        $cmds = Build-GitAddCommands $app $txtGitAdd.Text
        if (@($cmds).Count -eq 0) {
            & $appendLog 'Type what to add first: paths separated by spaces, "quoted" when they have spaces, or . for every change.'
            return
        }
        & $run $cmds "git add ($($app.name))" $false $app.repoRoot (Build-GitAfterLines $app 'add')
    }.GetNewClosure())
    $btnGitCommit.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        $cmds = Build-GitCommitCommands $app $txtGitMsg.Text
        if (@($cmds).Count -eq 0) { & $appendLog 'Type the commit message first.'; return }
        $first = ($txtGitMsg.Text.Trim() -split "`r?`n")[0]
        & $run $cmds "git commit ($($app.name)): $first" $false $app.repoRoot (Build-GitAfterLines $app 'commit') $refreshGit
    }.GetNewClosure())
    $btnGitPush.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        $branch = Get-GitBranch $app
        & $run (Build-GitPushCommands $app) "git push ($($app.name), $branch)" $false $app.repoRoot (Build-GitAfterLines $app 'push') $refreshGit
    }.GetNewClosure())

    $tabState.AppendLog = $appendLog
    $tabState.Controls = @{
        Target = $cmbTarget; Version = $txtVer; Publish = $chkPublish; DryRun = $chkDry; Notes = $txtNotes
        Workflow = $cmbWf; Run = $cmbRun; Task = $cmbTask; GitAdd = $txtGitAdd; GitMessage = $txtGitMsg
        BootstrapName = $txtBootstrapName; BootstrapRoot = $txtBootstrapRoot; BootstrapRepo = $txtBootstrapRepo; BootstrapMessage = $txtBootstrapMessage; BootstrapScanner = $txtBootstrapScanner
        Log = $logBox; Visibility = $lblVis
        Buttons = @{
            Upload = $btnUpload; Deploy = $btnDeploy; RetagDeploy = $btnRetagDeploy; ReleasePlan = $btnReleasePlan
            Dispatch = $btnDispatch; Copy = $btnCopy; Actions = $btnActions
            LoadRuns = $btnLoadRuns; PublishRun = $btnPubRun; Undraft = $btnUndraft; ReleasePage = $btnRelPage
            MakePublic = $btnMakePublic; MakePrivate = $btnMakePrivate; Task = $btnTask
            GitAdd = $btnGitAdd; GitCommit = $btnGitCommit; GitStatus = $btnGitStatus; GitPush = $btnGitPush
            AddApp = $btnBootstrapAddApp; CreateRepo = $btnBootstrapCreateRepo; ActionsSecrets = $btnBootstrapActionsSecrets; BootstrapPlan = $btnBootstrapPlan; BootstrapPrepare = $btnBootstrapPrepare; BootstrapPublish = $btnBootstrapPublish
        }
    }
    $page.Tag = $tabState
    & $refresh
    & $refreshVisibility
    & $appendLog "Ready. Pick a target, set the version, then Upload / Deploy."
    if (-not ($HasGit -and $HasGh)) {
        & $appendLog "Note: git/gh not both present — actions fall back to printing the command."
        $chkDry.Checked = $true
    }

    return $page
}
