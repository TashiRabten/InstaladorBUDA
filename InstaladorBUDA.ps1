<#
.SYNOPSIS
    InstaladorBUDA — a small standalone deployment cockpit for the BUDA apps.
    Pick a target app + version and Upload models / push a release tag / trigger a
    workflow, without memorizing the commands. Every action has a command fallback:
    tick "Dry run" to print the exact command, or run it in a real console window.

.DESCRIPTION
    Fully config-driven: the app list comes from apps.json next to this script (or the
    compiled .exe). ADD A NEW APP = add a JSON block — no code changes. See README.md.

    Runs as a .ps1 or as InstaladorBUDA.exe (built with build-exe.ps1 via ps2exe).
    The .exe is self-contained except for apps.json, which must sit beside it.

.PARAMETER Console
    Skip the GUI and use the interactive text menu (also the automatic fallback when
    Windows Forms cannot load).

.PARAMETER ConfigPath
    Path to apps.json. Defaults to the file next to this script / the .exe.

.EXAMPLE
    .\InstaladorBUDA.ps1
.EXAMPLE
    .\InstaladorBUDA.ps1 -Console
#>
[CmdletBinding()]
param(
    [switch]$Console,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$script:SelfPath = $PSCommandPath   # set when running as .ps1; $null inside a ps2exe .exe

# ── Resolve the directory holding this script / exe (so apps.json is found either way) ──
function Get-AppDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    try { return Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
    return (Get-Location).Path
}
$AppDir  = Get-AppDir
$cfgFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $AppDir 'apps.json' }

if (-not (Test-Path $cfgFile)) {
    $m = "apps.json not found at: $cfgFile`nKeep apps.json next to InstaladorBUDA."
    try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($m, 'InstaladorBUDA', 'OK', 'Error') | Out-Null } catch { Write-Error $m }
    return
}
$Config = Get-Content $cfgFile -Raw | ConvertFrom-Json
$Apps   = @($Config.apps)
$Tasks  = @($Config.tasks)
$ReleaseRepo = if ($Config.releaseRepoDefault) { $Config.releaseRepoDefault } else { 'TashiRabten/GlossarioBUDA' }
$ActionsUrl  = if ($Config.actionsUrl) { $Config.actionsUrl } else { 'https://github.com/TashiRabten/TradutorBUDA/actions' }

function Get-App { param([string]$Name) $Apps | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }

# ── Version helpers ──────────────────────────────────────────────────────────
function Get-CurrentVersion {
    param($app)
    try {
        if ($app.versionFile) {
            $f = Join-Path $app.repoRoot $app.versionFile
            if (Test-Path $f) {
                $txt = Get-Content $f -Raw
                if ($app.versionRegex -and $txt -match $app.versionRegex) { return $Matches[1] }
            }
        }
        if ($app.versionFromGitTag) {
            $tags = & git -C $app.repoRoot tag --list $app.versionFromGitTag 2>$null
            if ($LASTEXITCODE -eq 0 -and $tags) {
                $prefix = $app.tagPrefix
                $latest = $tags | ForEach-Object { $_ -replace "^$([regex]::Escape($prefix))", '' } |
                    Sort-Object { try { [version]($_ -replace '[^0-9.].*$', '') } catch { [version]'0.0' } } |
                    Select-Object -Last 1
                if ($latest) { return $latest }
            }
        }
    } catch { }
    return '1.0.0'
}

function Get-NextVersion {
    param([string]$Version)
    $parts = @($Version -split '\.')
    if ($parts.Count -lt 1) { return $Version }
    try { $parts[-1] = [string]([int]$parts[-1] + 1) } catch { }
    return ($parts -join '.')
}

# ── Command builders (each returns an array of plain commands) ────────────────
function Build-UploadCommands {
    param($app)
    if ($app.uploadScript) {
        $p = Join-Path $app.repoRoot $app.uploadScript
        return @("pwsh -ExecutionPolicy Bypass -File `"$p`"")
    }
    if (-not $app.models -or @($app.models).Count -eq 0) { return @() }
    $cmds = @()
    foreach ($grp in $app.models) {
        $repo = if ($grp.repo) { $grp.repo } else { $ReleaseRepo }
        $tag  = $grp.tag
        $cmds += "if (-not (gh release view $tag --repo $repo 2>`$null)) { gh release create $tag --repo $repo --title `"$tag`" --notes `"Model assets for InstaladorBUDA.`" }"
        foreach ($item in $grp.items) {
            $full   = Join-Path $app.repoRoot $item.path
            $parent = Split-Path -Parent $full
            $leaf   = Split-Path -Leaf  $full
            $zip    = "`$env:TEMP\$($item.name).zip"
            $cmds += "tar -a -c -f `"$zip`" -C `"$parent`" `"$leaf`""
            $cmds += "gh release upload $tag `"$zip`" --repo $repo --clobber"
            $cmds += "Remove-Item `"$zip`" -ErrorAction SilentlyContinue"
        }
    }
    return $cmds
}

function Build-TagCommands {
    param($app, [string]$Version, [string]$ReleaseNotes = '')
    $repo = $app.repoRoot
    $tag  = "$($app.tagPrefix)$Version"
    # Use -f / --force so re-deploying an existing version MOVES the tag to the new
    # commit instead of failing ("tag already exists"). Re-pushing a moved tag also
    # re-triggers the build workflow — the intended behaviour when a prior release
    # build failed (e.g. on the Actions storage quota) and you want to rebuild it.
    if ([string]::IsNullOrWhiteSpace($ReleaseNotes)) {
        # No note → lightweight tag; the build workflow uses its default release message.
        return @("git -C `"$repo`" tag -f $tag", "git -C `"$repo`" push --force origin $tag")
    }
    # Note provided → ANNOTATED tag carrying the note as its message. The build
    # workflow reads the tag message on a tag push and uses it as the GitHub Release
    # body, so the same note appears whether you Deploy (push tag) or Trigger (dispatch).
    # Base64 keeps the (possibly multi-line) note a single safe token in the command list.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ReleaseNotes))
    $tmp = '$env:TEMP\instaladorbuda-relnote.txt'
    return @(
        "[IO.File]::WriteAllText(`"$tmp`", [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))",
        "git -C `"$repo`" tag -f -a $tag -F `"$tmp`"",
        "git -C `"$repo`" push --force origin $tag",
        "Remove-Item `"$tmp`" -ErrorAction SilentlyContinue"
    )
}

# Wrap a value as a single PowerShell single-quoted token (doubling embedded quotes),
# so values containing spaces or punctuation survive Invoke-Expression / pwsh -Command.
function Quote-PS { param([string]$s) "'" + ($s -replace "'", "''") + "'" }

function Build-DispatchCommands {
    param($app, [string]$Version, [bool]$Publish, [string]$ReleaseNotes = '')
    $argList = @()
    foreach ($inp in $app.dispatchInputs) {
        if ($inp.onlyIfPublish -and -not $Publish) { continue }
        $val = [string]$inp.value
        $val = $val.Replace('{version}', $Version).Replace('{publish}', $Publish.ToString().ToLower())
        # {notes} expands to the release message. gh -f passes one line, so newlines are
        # encoded as literal \n here and the workflow turns them back into real breaks.
        if ($val.Contains('{notes}')) {
            $encoded = ($ReleaseNotes -replace "`r?`n", '\n')
            $val = $val.Replace('{notes}', $encoded)
        }
        $argList += "-f"; $argList += (Quote-PS "$($inp.name)=$val")
    }
    # Run from the app's repoRoot so gh infers the GitHub repo from the git remote.
    return @("gh workflow run $($app.workflow) $($argList -join ' ')")
}

function Resolve-TaskRepoRoot {
    param($task)
    if ($task.repoRoot) { return $task.repoRoot }
    if ($task.cwdRepo) { $a = Get-App $task.cwdRepo; if ($a) { return $a.repoRoot } }
    if ($Apps.Count -gt 0) { return $Apps[0].repoRoot }
    return (Get-Location).Path
}

# ── Environment probe ────────────────────────────────────────────────────────
function Test-Tool { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
$HasGit = Test-Tool git
$HasGh  = Test-Tool gh

# ── Console fallback menu ────────────────────────────────────────────────────
function Show-ConsoleMenu {
    Write-Host ""
    Write-Host "=== InstaladorBUDA (console mode) ===" -ForegroundColor Cyan
    Write-Host "git: $(if($HasGit){'OK'}else{'MISSING'})   gh: $(if($HasGh){'OK'}else{'MISSING'})   release repo: $ReleaseRepo"
    while ($true) {
        Write-Host ""
        for ($i = 0; $i -lt $Apps.Count; $i++) { Write-Host "  $($i+1)) $($Apps[$i].name)" }
        if ($Tasks.Count -gt 0) { Write-Host "  t) tasks" }
        Write-Host "  q) quit"
        $sel = Read-Host "Target"
        if ($sel -eq 'q') { return }
        if ($sel -eq 't' -and $Tasks.Count -gt 0) {
            for ($j = 0; $j -lt $Tasks.Count; $j++) { Write-Host "  $($j+1)) $($Tasks[$j].name)" }
            $ts = Read-Host "Task"; $tj = 0
            if ([int]::TryParse($ts, [ref]$tj) -and $tj -ge 1 -and $tj -le $Tasks.Count) {
                $task = $Tasks[$tj - 1]; $rr = Resolve-TaskRepoRoot $task
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
        $idx = 0; if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $Apps.Count) { continue }
        $app = $Apps[$idx - 1]

        $cur  = Get-CurrentVersion $app
        $next = Get-NextVersion $cur
        $ver  = Read-Host "Version (current $cur) [$next]"
        if ([string]::IsNullOrWhiteSpace($ver)) { $ver = $next }

        Write-Host ""
        $canUpload = [bool]$app.uploadScript -or (@($app.models).Count -gt 0)
        Write-Host "  a) Upload models$(if($canUpload){''}else{'  (n/a)'})"
        Write-Host "  b) Deploy — push tag $($app.tagPrefix)$ver"
        Write-Host "  c) Trigger workflow (no tag)"
        $act = Read-Host "Action"

        $notes = ''
        # Both Deploy (push tag, 'b') and Trigger (dispatch, 'c') use the note as the release body.
        if ($act -eq 'c' -or $act -eq 'b') {
            $notes = Read-Host "Release notes (optional, single line)"
        }
        $cmds = switch ($act) {
            'a' { Build-UploadCommands $app }
            'b' { Build-TagCommands $app $ver $notes }
            'c' { Build-DispatchCommands $app $ver $true $notes }
            default { @() }
        }
        if (-not $cmds) { Write-Host "Nothing to do." -ForegroundColor Yellow; continue }

        Write-Host ""
        Write-Host "Commands:" -ForegroundColor Cyan
        $cmds | ForEach-Object { Write-Host "  $_" }
        $go = Read-Host "Run now? (y = run / anything else = just print)"
        if ($go -eq 'y') {
            Push-Location $app.repoRoot
            try { foreach ($c in $cmds) { Write-Host "> $c" -ForegroundColor DarkGray; Invoke-Expression $c } }
            finally { Pop-Location }
        }
    }
}

# ── GUI ──────────────────────────────────────────────────────────────────────
function Show-Gui {
    # WinForms needs an STA thread; pwsh (PS7) defaults to MTA. Relaunch self STA when run as .ps1.
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        if ($script:SelfPath) {
            Start-Process pwsh -ArgumentList @('-STA', '-ExecutionPolicy', 'Bypass', '-File', $script:SelfPath) | Out-Null
            return
        }
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:LastCommands = @()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'InstaladorBUDA'
    $form.Size = New-Object System.Drawing.Size(600, 760)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.Text = 'Target app:'; $lblTarget.Location = '20,20'; $lblTarget.Size = '90,22'
    $cmbTarget = New-Object System.Windows.Forms.ComboBox
    $cmbTarget.Location = '115,18'; $cmbTarget.Size = '220,24'; $cmbTarget.DropDownStyle = 'DropDownList'
    $Apps | ForEach-Object { [void]$cmbTarget.Items.Add($_.name) }
    if ($cmbTarget.Items.Count -gt 0) { $cmbTarget.SelectedIndex = 0 }

    $lblVer = New-Object System.Windows.Forms.Label
    $lblVer.Text = 'Version:'; $lblVer.Location = '20,56'; $lblVer.Size = '90,22'
    $txtVer = New-Object System.Windows.Forms.TextBox
    $txtVer.Location = '115,54'; $txtVer.Size = '120,24'
    $lblCur = New-Object System.Windows.Forms.Label
    $lblCur.Location = '245,56'; $lblCur.Size = '320,22'; $lblCur.ForeColor = [System.Drawing.Color]::Gray

    $chkPublish = New-Object System.Windows.Forms.CheckBox
    $chkPublish.Text = 'Publish to website (attach installers to the release)'
    $chkPublish.Location = '115,84'; $chkPublish.Size = '440,22'; $chkPublish.Checked = $true

    $chkDry = New-Object System.Windows.Forms.CheckBox
    $chkDry.Text = 'Dry run — show the command, do not execute'
    $chkDry.Location = '115,108'; $chkDry.Size = '440,22'

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Steps'; $grp.Location = '20,140'; $grp.Size = '545,110'

    $btnUpload = New-Object System.Windows.Forms.Button
    $btnUpload.Text = '1. Upload models'; $btnUpload.Location = '15,28'; $btnUpload.Size = '160,32'
    $btnDeploy = New-Object System.Windows.Forms.Button
    $btnDeploy.Text = '2. Deploy (push tag)'; $btnDeploy.Location = '190,28'; $btnDeploy.Size = '160,32'
    $btnDispatch = New-Object System.Windows.Forms.Button
    $btnDispatch.Text = 'or: Trigger workflow'; $btnDispatch.Location = '365,28'; $btnDispatch.Size = '160,32'
    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = 'Copy last command'; $btnCopy.Location = '15,68'; $btnCopy.Size = '160,28'
    $btnActions = New-Object System.Windows.Forms.Button
    $btnActions.Text = 'Open Actions page'; $btnActions.Location = '365,68'; $btnActions.Size = '160,28'
    $grp.Controls.AddRange(@($btnUpload, $btnDeploy, $btnDispatch, $btnCopy, $btnActions))

    # Tasks (non-release utilities, e.g. rebuild the Tesseract bundle)
    $grpTask = New-Object System.Windows.Forms.GroupBox
    $grpTask.Text = 'Tasks'; $grpTask.Location = '20,256'; $grpTask.Size = '545,64'
    $cmbTask = New-Object System.Windows.Forms.ComboBox
    $cmbTask.Location = '15,26'; $cmbTask.Size = '385,24'; $cmbTask.DropDownStyle = 'DropDownList'
    $Tasks | ForEach-Object { [void]$cmbTask.Items.Add($_.name) }
    if ($cmbTask.Items.Count -gt 0) { $cmbTask.SelectedIndex = 0 }
    $btnTask = New-Object System.Windows.Forms.Button
    $btnTask.Text = 'Run / copy'; $btnTask.Location = '410,24'; $btnTask.Size = '115,28'
    $btnTask.Enabled = ($Tasks.Count -gt 0)
    $grpTask.Controls.AddRange(@($cmbTask, $btnTask))

    # Release notes — becomes the GitHub Release body (apps whose dispatchInputs use {notes}).
    $grpNotes = New-Object System.Windows.Forms.GroupBox
    $grpNotes.Text = 'Release notes (Deploy / Trigger use this as the release message)'
    $grpNotes.Location = '20,326'; $grpNotes.Size = '545,120'
    $txtNotes = New-Object System.Windows.Forms.TextBox
    $txtNotes.Location = '15,24'; $txtNotes.Size = '515,82'
    $txtNotes.Multiline = $true; $txtNotes.ScrollBars = 'Vertical'
    $txtNotes.AcceptsReturn = $true
    $txtNotes.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $grpNotes.Controls.Add($txtNotes)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = '20,456'; $logBox.Size = '545,180'
    $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
    $logBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $logBox.ForeColor = [System.Drawing.Color]::Gainsboro
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = '20,644'; $status.Size = '545,30'
    $gitOk = if ($HasGit) { 'git OK' } else { 'git MISSING' }
    $ghOk  = if ($HasGh)  { 'gh OK' }  else { 'gh MISSING' }
    $status.Text = "$gitOk   |   $ghOk   |   release repo: $ReleaseRepo"
    $status.ForeColor = if ($HasGit -and $HasGh) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::Firebrick }

    $form.Controls.AddRange(@($lblTarget, $cmbTarget, $lblVer, $txtVer, $lblCur, $chkPublish, $chkDry, $grp, $grpTask, $grpNotes, $logBox, $status))

    $appendLog = { param($text) $logBox.AppendText(("{0}  {1}{2}" -f (Get-Date -Format 'HH:mm:ss'), $text, [Environment]::NewLine)) }

    $refresh = {
        $app = Get-App $cmbTarget.SelectedItem
        if (-not $app) { return }
        $cur = Get-CurrentVersion $app
        $lblCur.Text = "current: $cur   ->   tag: $($app.tagPrefix)"
        if ([string]::IsNullOrWhiteSpace($txtVer.Text) -or $txtVer.Tag -ne $app.name) {
            $txtVer.Text = Get-NextVersion $cur
            $txtVer.Tag  = $app.name
        }
        $canUpload = [bool]$app.uploadScript -or (@($app.models).Count -gt 0)
        $btnUpload.Enabled = $canUpload
        $btnUpload.Text = if ($canUpload) { '1. Upload models' } else { '1. Upload models (n/a)' }
    }

    $run = {
        param($commands, $label, $needsGh, $repoRoot)
        if (-not $commands -or $commands.Count -eq 0) { & $appendLog "Nothing to do for this target."; return }
        $script:LastCommands = $commands

        if ($chkDry.Checked) {
            & $appendLog "[dry run] $label :"
            & $appendLog "    cd `"$repoRoot`""
            $commands | ForEach-Object { & $appendLog "    $_" }
            & $appendLog "Use 'Copy last command' to grab it."
            return
        }
        if (($needsGh -and -not $HasGh) -or (-not $needsGh -and -not $HasGit)) {
            $tool = if ($needsGh) { 'gh' } else { 'git' }
            & $appendLog "$tool not found — showing the command instead (install it, or run elsewhere):"
            $commands | ForEach-Object { & $appendLog "    $_" }
            return
        }
        $msg = "This will run, in`n$repoRoot :`n`n" + ($commands -join "`n") + "`n`nContinue?"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, "Confirm — $label", 'YesNo', 'Question')
        if ($ans -ne 'Yes') { & $appendLog "Cancelled: $label"; return }

        # Write the commands to a temp .ps1 and run THAT. Passing them inline via -Command
        # double-parses the string, so any command that contains its OWN quotes (e.g. a
        # WriteAllText("...") + FromBase64String('...') release note) collides and fails to
        # parse. In a script file every command is written verbatim — no escaping needed.
        $rr  = $repoRoot.Replace("'", "''")
        $lbl = ($label -replace '[\r\n]', ' ').Replace("'", "''")
        $lines = @(
            "Set-Location -LiteralPath '$rr'"
            "Write-Host '=== InstaladorBUDA: $lbl ===' -ForegroundColor Cyan"
        ) + $commands + @(
            "Write-Host ''"
            "Write-Host 'Done. Close this window when finished.' -ForegroundColor Green"
        )
        $tmp = Join-Path $env:TEMP ("instaladorbuda-run-" + [guid]::NewGuid().ToString('N') + ".ps1")
        Set-Content -LiteralPath $tmp -Value $lines -Encoding UTF8
        Start-Process pwsh -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $tmp) | Out-Null
        & $appendLog "Launched in a new console: $label"
        $commands | ForEach-Object { & $appendLog "    $_" }
    }

    $cmbTarget.Add_SelectedIndexChanged({ & $refresh })
    $btnUpload.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        & $run (Build-UploadCommands $app) "Upload models ($($app.name))" $true $app.repoRoot
    })
    $btnDeploy.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        $v = $txtVer.Text.Trim()
        if (-not $v) { & $appendLog "Enter a version first."; return }
        # Release notes ride along as the annotated tag message → the workflow uses them
        # as the release body. Empty notes fall back to a lightweight tag + default message.
        & $run (Build-TagCommands $app $v $txtNotes.Text) "Deploy $($app.name) v$v (push tag)" $false $app.repoRoot
    })
    $btnDispatch.Add_Click({
        $app = Get-App $cmbTarget.SelectedItem
        $v = $txtVer.Text.Trim()
        if (-not $v) { & $appendLog "Enter a version first."; return }
        $notes = $txtNotes.Text
        $usesNotes = @($app.dispatchInputs | Where-Object { "$($_.value)".Contains('{notes}') }).Count -gt 0
        if ($usesNotes -and [string]::IsNullOrWhiteSpace($notes)) {
            & $appendLog "Tip: Release notes are empty — the release will use a default message."
        }
        & $run (Build-DispatchCommands $app $v $chkPublish.Checked $notes) "Trigger $($app.name) workflow v$v" $true $app.repoRoot
    })
    $btnCopy.Add_Click({
        if ($script:LastCommands) {
            Set-Clipboard -Value ($script:LastCommands -join [Environment]::NewLine)
            & $appendLog "Copied last command to clipboard."
        } else { & $appendLog "No command yet — click a step first." }
    })
    $btnActions.Add_Click({ Start-Process $ActionsUrl | Out-Null })
    $btnTask.Add_Click({
        if ($cmbTask.SelectedIndex -lt 0) { return }
        $task = $Tasks[$cmbTask.SelectedIndex]
        $repoRoot = Resolve-TaskRepoRoot $task
        $script:LastCommands = @($task.command)
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
    })

    & $refresh
    & $appendLog "Ready. Pick a target, set the version, then Upload / Deploy."
    if (-not ($HasGit -and $HasGh)) {
        & $appendLog "Note: git/gh not both present — actions fall back to printing the command."
        $chkDry.Checked = $true
    }

    [void]$form.ShowDialog()
}

# ── Entry point ──────────────────────────────────────────────────────────────
if ($Console) { Show-ConsoleMenu; return }
try {
    Show-Gui
} catch {
    Write-Warning "GUI unavailable ($($_.Exception.Message)). Falling back to console menu."
    Show-ConsoleMenu
}
