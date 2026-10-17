function Show-ConsoleMenu {
    Write-Host ""
    Write-Host "=== InstaladorBUDA (console mode) ===" -ForegroundColor Cyan
    Write-Host "git: $(if($HasGit){'OK'}else{'MISSING'})   gh: $(if($HasGh){'OK'}else{'MISSING'})   release repo: $ReleaseRepo"
    while ($true) {
        Write-Host ""
        for ($i = 0; $i -lt $script:AppRegistry.Apps.Count; $i++) { Write-Host "  $($i+1)) $($script:AppRegistry.Apps[$i].name)" }
        if ($script:Tasks.Count -gt 0) { Write-Host "  t) tasks" }
        Write-Host "  q) quit"
        $sel = Read-Host "Target"
        if ($sel -eq 'q') { return }
        if ($sel -eq 't' -and $script:Tasks.Count -gt 0) {
            for ($j = 0; $j -lt $script:Tasks.Count; $j++) { Write-Host "  $($j+1)) $($script:Tasks[$j].name)" }
            $ts = Read-Host "Task"; $tj = 0
            if ([int]::TryParse($ts, [ref]$tj) -and $tj -ge 1 -and $tj -le $script:Tasks.Count) {
                $task = $script:Tasks[$tj - 1]; $rr = Resolve-TaskRepoRoot $task
                Write-Host ""; Write-Host "Command:" -ForegroundColor Cyan; Write-Host "  $($task.command)"
                if ($task.runOn -eq 'mac') {
                    Write-Host "Run this on your Mac VM (cwd $rr). Not executed here." -ForegroundColor Yellow
                } else {
                    $go = Read-Host "Run now? (y = run / anything else = just print)"
                    if ($go -eq 'y') { Push-Location $rr; try { Invoke-Expression $task.command } finally { Pop-Location } }
                }
            }
            continue
        }
        $idx = 0; if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $script:AppRegistry.Apps.Count) { continue }
        $app = $script:AppRegistry.Apps[$idx - 1]
        $isImageOnly = $app.outputKind -eq 'container-image'

        $cur  = Get-CurrentVersion $app
        $next = Get-NextVersion $cur
        $ver  = Read-Host "Version (current $cur) [$next]"
        if ([string]::IsNullOrWhiteSpace($ver)) { $ver = $next }
        if ($isImageOnly -and $ver -notmatch '^\d+\.\d+\.\d+$') {
            Write-Host 'Container image versions must use semantic version format x.y.z.' -ForegroundColor Yellow
            continue
        }

        Write-Host ""
        $canUpload = [bool]$app.uploadScript -or (@($app.models).Count -gt 0)
        Write-Host "  a) Upload models$(if($canUpload){''}else{'  (n/a)'})"
        if ($isImageOnly) {
            Write-Host "  b) Publish container image — push tag $($app.tagPrefix)$ver"
            Write-Host "  c) Publish container image — trigger workflow"
        } else {
            Write-Host "  b) Deploy — push tag $($app.tagPrefix)$ver"
            Write-Host "  c) Trigger workflow (publishes a real tag/release, same as Deploy)"
            Write-Host "  d) Publish from existing run (no rebuild)"
            Write-Host "  u) Un-draft release $($app.tagPrefix)$ver"
        }
        $repoSlug = Resolve-AppRepo $app
        $canManageVisibility = $null -eq $app.manageVisibility -or [bool]$app.manageVisibility
        $vis = if ($HasGh) { Get-RepoVisibility $repoSlug } else { $null }
        $visLabel = if ($vis) { " (currently $vis)" } else { '' }
        if ($canManageVisibility) {
            Write-Host "  v) Make repo public$visLabel  [$repoSlug]"
            Write-Host "  p) Make repo private$visLabel  [$repoSlug]"
        }
        $act = Read-Host "Action"

        $notes = ''
        # Deploy (b), Trigger (c) and Publish-from-run (d) use the note as the release body.
        if (-not $isImageOnly -and ($act -eq 'c' -or $act -eq 'b' -or $act -eq 'd')) {
            $notes = Read-Host "Release notes (optional, single line)"
        }
        $cmds = switch ($act) {
            'a' {
                $sel = Select-UploadModelsConsole $app
                if ($null -ne $sel -and @($sel).Count -eq 0) { Write-Host "No models selected." -ForegroundColor Yellow; @() }
                else { Build-UploadCommands $app $sel }
            }
            'b' {
                $bundleSel = Select-BundlesConsole $app
                if ($null -ne $bundleSel -and [string]::IsNullOrWhiteSpace($bundleSel)) {
                    Write-Host "No bundles selected." -ForegroundColor Yellow; @()
                } else {
                    Build-TagCommands $app $ver $notes (Resolve-BundleSelection $app $bundleSel)
                }
            }
            'c' {
                $bundleSel = Select-BundlesConsole $app
                if ($null -ne $bundleSel -and [string]::IsNullOrWhiteSpace($bundleSel)) {
                    Write-Host "No bundles selected." -ForegroundColor Yellow; @()
                } else {
                    $bundleArg = 'all'
                    if ($bundleSel) { $bundleArg = $bundleSel }
                    Build-DispatchCommands $app $ver (-not $isImageOnly) $notes $bundleArg
                }
            }
            'u' { if ($isImageOnly) { @() } else { Build-UndraftCommands $app $ver } }
            'v' {
                if (-not $canManageVisibility) { Write-Host "Visibility changes are disabled for $($app.name)." -ForegroundColor Yellow; @() }
                elseif (-not $repoSlug) { Write-Host "Could not resolve the GitHub repo for $($app.name) (no git remote?)." -ForegroundColor Yellow; @() }
                else { Build-VisibilityCommands $repoSlug 'public' }
            }
            'p' {
                if (-not $canManageVisibility) { Write-Host "Visibility changes are disabled for $($app.name)." -ForegroundColor Yellow; @() }
                elseif (-not $repoSlug) { Write-Host "Could not resolve the GitHub repo for $($app.name) (no git remote?)." -ForegroundColor Yellow; @() }
                else { Build-VisibilityCommands $repoSlug 'private' }
            }
            'd' {
                if ($isImageOnly) { @() }
                else {
                    $repo = Resolve-AppRepo $app
                    $runs = Get-WorkflowRuns $repo $app.workflow
                    if (-not $runs -or $runs.Count -eq 0) { Write-Host "No runs found for $($app.workflow)." -ForegroundColor Yellow; @() }
                    else {
                        for ($i = 0; $i -lt [Math]::Min($runs.Count, 15); $i++) {
                            $rr = $runs[$i]
                            $when = try { ([datetime]$rr.createdAt).ToLocalTime().ToString('MM-dd HH:mm') } catch { "$($rr.createdAt)" }
                            Write-Host ("  $($i + 1)) $when  [$($rr.conclusion)]  $($rr.displayTitle)  ($($rr.headBranch))")
                        }
                        $rs = Read-Host "Run # to publish"; $ri = 0
                        if ([int]::TryParse($rs, [ref]$ri) -and $ri -ge 1 -and $ri -le $runs.Count) {
                            Build-PublishFromRunCommands $app $repo "$($runs[$ri - 1].databaseId)" $ver $notes
                        } else { @() }
                    }
                }
            }
            default { @() }
        }
        if (-not $cmds) { Write-Host "Nothing to do." -ForegroundColor Yellow; continue }

        Write-Host ""
        Write-Host "Commands:" -ForegroundColor Cyan
        $cmds | ForEach-Object { Write-Host "  $_" }
        $go = Read-Host "Run now? (y = run / anything else = just print)"
        if ($go -eq 'y') {
            Push-Location $app.repoRoot
            $since = [datetime]::UtcNow
            try {
                foreach ($c in $cmds) { Write-Host "> $c" -ForegroundColor DarkGray; Invoke-Expression $c }
                # Deploy / Trigger: follow the build it started, then report the release;
                # Publish from run / Un-draft: report the release.
                $kind = switch ($act) { 'b' { 'push' } 'c' { 'dispatch' } 'd' { 'release' } 'u' { 'release' } default { $null } }
                if ($kind -and $HasGh) {
                    [void](Invoke-FollowUp -Kind $kind -Publish (-not $isImageOnly) -Since $since -LastExit ([int]$LASTEXITCODE) `
                        -AppRepo (Resolve-AppRepo $app) -Workflow $app.workflow -ReleaseRepo (Resolve-ReleaseRepo $app) `
                        -Tag "$($app.tagPrefix)$ver" -ImageOnly:$isImageOnly)
                }
            }
            finally { Pop-Location }
        }
    }
}

# GUI model picker for apps that declare uploadModels. Opens a small dialog with a
# checklist (pre-checked = this model's "default" flag AND its source folder exists on
# THIS machine — several SegBUDA model folders only live on whichever machine last built
# them, so blindly running the script's own built-in default set fails here). Returns
# $null on Cancel; an array (possibly empty) of selected model names on OK.
function Show-ModelPicker {
    param($app)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Upload models — $($app.name)"
    $dlg.Size = New-Object System.Drawing.Size(420, 430)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Select models to package + upload:'
    $lbl.Location = '15,12'; $lbl.Size = '380,20'

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = '15,36'; $clb.Size = '380,270'
    $clb.CheckOnClick = $true

    foreach ($m in $app.uploadModels) {
        $exists = Test-Path (Join-Path $app.repoRoot $m.path)
        $label  = if ($exists) { $m.name } else { "$($m.name)  (not found locally)" }
        $idx    = $clb.Items.Add($label)
        $clb.SetItemChecked($idx, ([bool]$m.default -and $exists))
    }

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = 'All'; $btnAll.Location = '15,314'; $btnAll.Size = '70,26'
    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = 'None'; $btnNone.Location = '90,314'; $btnNone.Size = '70,26'
    $btnAll.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } }.GetNewClosure())
    $btnNone.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } }.GetNewClosure())

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = 'Upload selected'; $btnOK.Location = '210,354'; $btnOK.Size = '185,30'
    $btnOK.DialogResult = 'OK'
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Location = '15,354'; $btnCancel.Size = '90,30'
    $btnCancel.DialogResult = 'Cancel'

    $dlg.Controls.AddRange(@($lbl, $clb, $btnAll, $btnNone, $btnOK, $btnCancel))
    $dlg.AcceptButton = $btnOK; $dlg.CancelButton = $btnCancel

    if ($dlg.ShowDialog() -ne 'OK') { return $null }
    $selected = @()
    for ($i = 0; $i -lt $clb.Items.Count; $i++) { if ($clb.GetItemChecked($i)) { $selected += $app.uploadModels[$i].name } }
    return , $selected
}

# GUI bundle picker for apps that declare "bundles" (SegBUDA's tiered installers).
# Lets a single tier be rebuilt + tagged/published on its own — e.g. an essential-only
# fix (photilines) doesn't force a rebuild+republish of segmentation/audio, so users on
# those tiers aren't prompted to redownload assets that didn't change. Returns $null on
# Cancel; a comma-joined bundle-id string (possibly empty) on OK.
function Show-BundlePicker {
    param($app)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Bundles to build — $($app.name)"
    $dlg.Size = New-Object System.Drawing.Size(380, 330)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Select bundles to rebuild + tag/publish:'
    $lbl.Location = '15,12'; $lbl.Size = '340,20'

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = '15,36'; $clb.Size = '340,170'
    $clb.CheckOnClick = $true

    foreach ($b in $app.bundles) {
        $idx = $clb.Items.Add("$($b.name)  ($($b.id))")
        $clb.SetItemChecked($idx, [bool]$b.default)
    }

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = 'All'; $btnAll.Location = '15,214'; $btnAll.Size = '70,26'
    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = 'None'; $btnNone.Location = '90,214'; $btnNone.Size = '70,26'
    $btnAll.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } }.GetNewClosure())
    $btnNone.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } }.GetNewClosure())

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = 'Use selection'; $btnOK.Location = '170,254'; $btnOK.Size = '185,30'
    $btnOK.DialogResult = 'OK'
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Location = '15,254'; $btnCancel.Size = '90,30'
    $btnCancel.DialogResult = 'Cancel'

    $dlg.Controls.AddRange(@($lbl, $clb, $btnAll, $btnNone, $btnOK, $btnCancel))
    $dlg.AcceptButton = $btnOK; $dlg.CancelButton = $btnCancel

    if ($dlg.ShowDialog() -ne 'OK') { return $null }
    $selected = @()
    for ($i = 0; $i -lt $clb.Items.Count; $i++) { if ($clb.GetItemChecked($i)) { $selected += $app.bundles[$i].id } }
    return ($selected -join ',')
}
