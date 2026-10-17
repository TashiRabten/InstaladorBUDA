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

.PARAMETER Cli
    Send one JSON command to the visible cockpit, for example:
    -Cli '{"command":"status"}' or -Cli '{"command":"action","action":"dispatch","tab":1}'.

.EXAMPLE
    .\InstaladorBUDA.ps1
.EXAMPLE
    .\InstaladorBUDA.ps1 -Console
#>
[CmdletBinding()]
param(
    [switch]$Console,
    [string]$ConfigPath,
    [string]$Cli
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

$script:ControlPipeName = 'InstaladorBUDA.Control.v1'

function Send-CockpitPipeRequest {
    param([string]$Json, [int]$ConnectTimeoutMs = 2500)
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $script:ControlPipeName,
        [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
    try {
        $pipe.Connect($ConnectTimeoutMs)
        $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.Encoding]::UTF8, 4096, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine($Json)
        $line = $reader.ReadLine()
        if (-not $line) { throw 'The cockpit closed the command connection without a response.' }
        return ($line | ConvertFrom-Json)
    } finally {
        $pipe.Dispose()
    }
}

function Invoke-CockpitCli {
    param([string]$Json)
    try { $request = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $request = [pscustomobject]@{ command = $Json.Trim() }
    }
    if (-not $request.command) {
        throw 'CLI input must be JSON with a command property. Run with -Cli ''{"command":"help"}''.'
    }

    $requestJson = $request | ConvertTo-Json -Compress -Depth 12
    try { $response = Send-CockpitPipeRequest $requestJson }
    catch {
        if ($request.command -eq 'start') {
            $guiExe = Join-Path $AppDir 'InstaladorBUDA.exe'
            if (Test-Path $guiExe) {
                Start-Process -FilePath $guiExe -WorkingDirectory $AppDir | Out-Null
            } elseif ($PSCommandPath) {
                $engine = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' }
                          else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
                Start-Process -FilePath $engine -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") `
                    -WorkingDirectory $AppDir -WindowStyle Hidden | Out-Null
            } else { throw 'Cannot locate InstaladorBUDA.exe or its source script to start the cockpit.' }

            $deadline = [datetime]::UtcNow.AddSeconds(20)
            do {
                Start-Sleep -Milliseconds 300
                try { $response = Send-CockpitPipeRequest $requestJson 500; break } catch { }
            } while ([datetime]::UtcNow -lt $deadline)
            if (-not $response) { throw 'The cockpit did not start its command endpoint within 20 seconds.' }
        } else {
            throw "The visible cockpit is not running. Start it with -Cli '{`"command`":`"start`"}' or open InstaladorBUDA.exe. Details: $($_.Exception.Message)"
        }
    }

    if ($request.waitMs -gt 0 -and $request.command -eq 'action' -and $request.action -ne 'update' -and $response.ok -and $response.data.tabId) {
        $tabId = $response.data.tabId
        $deadline = [datetime]::UtcNow.AddMilliseconds([Math]::Min([int]$request.waitMs, 3600000))
        do {
            Start-Sleep -Milliseconds 1000
            $statusJson = [pscustomobject]@{ command = 'status'; tab = $tabId } | ConvertTo-Json -Compress
            $response = Send-CockpitPipeRequest $statusJson
            $tabStatus = $response.data.tabs | Where-Object { $_.id -eq $tabId } | Select-Object -First 1
        } while ($tabStatus -and $tabStatus.running -and [datetime]::UtcNow -lt $deadline)
        if ($tabStatus -and $tabStatus.running) { $response | Add-Member -NotePropertyName timedOut -NotePropertyValue $true -Force }
    }

    [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress -Depth 12))
    if (-not $response.ok) { exit 1 }
}

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
    param($app, [string[]]$SelectedModels)
    if ($app.uploadScript) {
        $p = Join-Path $app.repoRoot $app.uploadScript
        $cmd = "pwsh -ExecutionPolicy Bypass -File `"$p`""
        # One comma-joined word, no quotes: `pwsh -File` cannot pass an array, so the names reach
        # the script as the single string "a,b", which the script splits. The quoted form this
        # used to send ('a','b') arrived with its quotes and failed as one unknown model name
        # (2026-10-07: "Unknown model ''tibetan-tts-onnx','dictionaries''").
        if ($SelectedModels -and @($SelectedModels).Count -gt 0) {
            $cmd += " -Models " + (@($SelectedModels) -join ',')
        }
        return @($cmd)
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

# Console-mode model picker for apps that declare uploadModels (e.g. SegBUDA — several
# model folders live on different machines, so uploading the full default set fails
# locally when one of them isn't present here). Returns $null when the app has no
# uploadModels (caller falls back to the plain, un-scoped upload); returns an array
# (possibly empty) of selected model names otherwise.
function Select-UploadModelsConsole {
    param($app)
    if (-not $app.uploadModels -or @($app.uploadModels).Count -eq 0) { return $null }
    Write-Host ""
    Write-Host "Models available for $($app.name):" -ForegroundColor Cyan
    $defaultIdx = @()
    for ($i = 0; $i -lt $app.uploadModels.Count; $i++) {
        $m = $app.uploadModels[$i]
        $exists = Test-Path (Join-Path $app.repoRoot $m.path)
        $flags = @()
        if ($m.default) { $flags += 'default' }
        if (-not $exists) { $flags += 'NOT FOUND LOCALLY' }
        $suffix = if ($flags.Count -gt 0) { "  [$($flags -join ', ')]" } else { '' }
        Write-Host ("  $($i + 1)) $($m.name)$suffix")
        if ($m.default -and $exists) { $defaultIdx += ($i + 1) }
    }
    $pick = Read-Host "Models to upload — comma-separated #s, 'all', or blank for default [$($defaultIdx -join ',')]"
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = $defaultIdx -join ',' }
    if ($pick -eq 'all') { return @($app.uploadModels | ForEach-Object { $_.name }) }
    $sel = @()
    foreach ($tok in ($pick -split ',')) {
        $n = 0
        if ([int]::TryParse($tok.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $app.uploadModels.Count) {
            $sel += $app.uploadModels[$n - 1].name
        }
    }
    return $sel
}

# Console-mode bundle picker for apps that declare "bundles" (SegBUDA's tiered
# installers). Lets a single tier (e.g. essential, for a photilines-only fix) be
# rebuilt + published via workflow_dispatch without touching the others' assets in
# that release — the build-segbuda.yml matrix reads this back as its own "bundles"
# input and filters bundles.json to just the selected ids. Returns $null when the app
# has no "bundles" (caller passes 'all', the workflow's own default); returns a
# comma-joined id string otherwise.
function Select-BundlesConsole {
    param($app)
    if (-not $app.bundles -or @($app.bundles).Count -eq 0) { return $null }
    Write-Host ""
    Write-Host "Bundles available for $($app.name):" -ForegroundColor Cyan
    $defaultIdx = @()
    for ($i = 0; $i -lt $app.bundles.Count; $i++) {
        $b = $app.bundles[$i]
        $suffix = if ($b.default) { '  [default]' } else { '' }
        Write-Host ("  $($i + 1)) $($b.name)  ($($b.id))$suffix")
        if ($b.default) { $defaultIdx += ($i + 1) }
    }
    $pick = Read-Host "Bundles to build/tag — comma-separated #s, 'all', or blank for default [$($defaultIdx -join ',')]"
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = $defaultIdx -join ',' }
    if ($pick -eq 'all') { return (($app.bundles | ForEach-Object { $_.id }) -join ',') }
    $sel = @()
    foreach ($tok in ($pick -split ',')) {
        $n = 0
        if ([int]::TryParse($tok.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $app.bundles.Count) {
            $sel += $app.bundles[$n - 1].id
        }
    }
    return ($sel -join ',')
}

# 'all' when the picker's selection covers every bundle the app declares (so a full Deploy
# stays a plain tag push), else the selection unchanged.
function Resolve-BundleSelection {
    param($app, [string]$Selection)
    if ([string]::IsNullOrWhiteSpace($Selection) -or $Selection -eq 'all') { return 'all' }
    $picked = @($Selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $every  = @($app.bundles | ForEach-Object { $_.id })
    if (@($every | Where-Object { $picked -notcontains $_ }).Count -eq 0) { return 'all' }
    return ($picked -join ',')
}

function Build-TagCommands {
    param($app, [string]$Version, [string]$ReleaseNotes = '', [string]$Bundles = 'all')
    $repo = $app.repoRoot
    $tag  = "$($app.tagPrefix)$Version"
    if ($app.outputKind -eq 'container-image') {
        # Image tags are immutable release identifiers. Never move an existing image tag;
        # use the workflow-dispatch action to retry a failed image build instead.
        return @("git -C `"$repo`" tag $tag", "git -C `"$repo`" push origin $tag")
    }
    # A tag push carries no workflow inputs, so a bundle subset rides in the annotated tag
    # message as a "Bundles: <ids>" line. build-segbuda.yml's manifest job reads it (and
    # prepare-release strips it from the release body); no line → every bundle.
    if (-not [string]::IsNullOrWhiteSpace($Bundles) -and $Bundles -ne 'all') {
        $body = $ReleaseNotes.TrimEnd()
        $ReleaseNotes = if ($body) { "$body`n`nBundles: $Bundles" } else { "Bundles: $Bundles" }
    }
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
    param($app, [string]$Version, [bool]$Publish, [string]$ReleaseNotes = '', [string]$Bundles = 'all')
    $argList = @()
    foreach ($inp in $app.dispatchInputs) {
        if ($inp.onlyIfPublish -and -not $Publish) { continue }
        $val = [string]$inp.value
        $val = $val.Replace('{version}', $Version).Replace('{publish}', $Publish.ToString().ToLower())
        # {bundles} — comma-joined bundle ids from the picker (SegBUDA-style apps only;
        # a no-op replace for apps whose dispatchInputs don't reference it).
        $val = $val.Replace('{bundles}', $Bundles)
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

# ── Publish-from-run helpers (publish an already-built run, no rebuild) ───────
# Parse the owner/repo slug out of a git remote URL (https or ssh).
function Get-RepoSlug {
    param([string]$repoRoot)
    try {
        $url = & git -C $repoRoot remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $url -and $url -match '[:/]([^/:]+/[^/]+?)(?:\.git)?/?\s*$') {
            return $Matches[1]
        }
    } catch { }
    return $null
}

# The repo whose Actions runs hold this app's build (always the app's own repo).
function Resolve-AppRepo { param($app) Get-RepoSlug $app.repoRoot }

# The repo that hosts this app's RELEASES (GlossarioBUDA for the BUDA apps; the app's
# own repo for the standalone utilities). Explicit apps.json releaseRepo wins; else
# fall back to releaseRepoDefault.
function Resolve-ReleaseRepo {
    param($app)
    if ($app.releaseRepo) { return $app.releaseRepo }
    return $ReleaseRepo
}

# Recent runs for a workflow (newest first), as objects with databaseId/conclusion/etc.
function Get-WorkflowRuns {
    param([string]$repo, [string]$workflow, [int]$limit = 20)
    if (-not $repo -or -not $workflow) { return @() }
    try {
        $json = & gh run list --repo $repo --workflow $workflow --limit $limit `
            --json databaseId,displayTitle,conclusion,status,createdAt,headBranch 2>$null
        if ($LASTEXITCODE -eq 0 -and $json) { return @($json | ConvertFrom-Json) }
    } catch { }
    return @()
}

# Current visibility of a repo ('public'/'private'/'internal'), or $null if unknown
# (gh missing, not authenticated, repo not resolved, etc).
function Get-RepoVisibility {
    param([string]$repo)
    if (-not $repo) { return $null }
    try {
        $out = & gh repo view $repo --json visibility --jq '.visibility' 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return $out.Trim().ToLower() }
    } catch { }
    return $null
}

# Flip a repo's visibility. Going private -> public or public -> private both need
# --accept-visibility-change-consequences on recent gh versions (drops stars/watchers
# notices, detaches from any public fork network, etc.) — pass it unconditionally so
# the command doesn't stall waiting on an interactive prompt.
function Build-VisibilityCommands {
    param([string]$repo, [string]$Visibility)
    return @(
        "gh repo edit '$repo' --visibility $Visibility --accept-visibility-change-consequences",
        "Write-Host 'Repo $repo is now $Visibility.' -ForegroundColor Green"
    )
}

# Workflow file names available in a repo (for the workflow picker dropdown).
function Get-RepoWorkflows {
    param([string]$repo)
    if (-not $repo) { return @() }
    try {
        $out = & gh api "repos/$repo/actions/workflows" --jq '.workflows[].path' 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return @($out | ForEach-Object { Split-Path $_ -Leaf }) }
    } catch { }
    return @()
}

# Publish a FINISHED run's installer artifacts to the release WITHOUT rebuilding:
# download the run's .exe/.pkg/.dmg/.msi artifacts and attach them to the release tag
# (creating the release on the right repo/branch if needed, then un-drafting it). The
# generic, per-app version of publish-segbuda-from-run.yml.
function Build-PublishFromRunCommands {
    param($app, [string]$AppRepo, [string]$RunId, [string]$Version, [string]$ReleaseNotes = '')
    $relRepo = Resolve-ReleaseRepo $app
    $tag     = "$($app.tagPrefix)$Version"
    $target  = $app.releaseBranch
    $title   = ("$($app.name) $tag").Replace("'", "''")
    $notes   = if ([string]::IsNullOrWhiteSpace($ReleaseNotes)) {
        "$($app.name) $tag - published from run $RunId (no rebuild)."
    } else { $ReleaseNotes }
    $notes     = $notes.Replace("'", "''")
    $targetArg = if ([string]::IsNullOrWhiteSpace($target))  { '' } else { "--target '$target'" }
    $repoArg   = if ([string]::IsNullOrWhiteSpace($AppRepo)) { '' } else { "--repo '$AppRepo'" }
    return @(
        "`$dl = Join-Path `$env:TEMP 'instalador-pub-$RunId'; if (Test-Path `$dl) { Remove-Item -Recurse -Force `$dl }",
        "gh run download $RunId $repoArg --dir `$dl",
        "`$inst = Get-ChildItem -Path `$dl -Recurse -File | Where-Object { `$_.Extension -in '.exe','.pkg','.dmg','.msi' }",
        "if (-not `$inst) { throw 'No installers (.exe/.pkg/.dmg/.msi) in run $RunId artifacts. A green TEST run has them; a publish run uploads to the release directly - use Un-draft instead.' }",
        "Write-Host ('Found ' + `$inst.Count + ' installer(s):'); `$inst | ForEach-Object { Write-Host ('  ' + `$_.Name) }",
        "if (-not (gh release view '$tag' --repo '$relRepo' 2>`$null)) { gh release create '$tag' --repo '$relRepo' $targetArg --title '$title' --notes '$notes' --draft }",
        "gh release upload '$tag' `$inst.FullName --repo '$relRepo' --clobber",
        "gh release edit '$tag' --repo '$relRepo' --draft=false | Out-Null",
        "Write-Host 'Published $tag to $relRepo from run $RunId - no rebuild.' -ForegroundColor Green"
    )
}

# Un-draft a release that a publish RUN already built + uploaded to (but didn't
# finalize). No artifacts, no rebuild - just flip the draft flag public.
function Build-UndraftCommands {
    param($app, [string]$Version)
    $relRepo = Resolve-ReleaseRepo $app
    $tag = "$($app.tagPrefix)$Version"
    return @(
        "if (-not (gh release view '$tag' --repo '$relRepo' 2>`$null)) { throw 'Release $tag not found on $relRepo - nothing to un-draft.' }",
        "gh release edit '$tag' --repo '$relRepo' --draft=false",
        "Write-Host 'Un-drafted $tag on $relRepo - now public (no rebuild).' -ForegroundColor Green"
    )
}

# ── Git (status / add / commit / push in the target app's repo) ───────────────
# Every git call names the repo with -C, quoted, like the tag commands above. core.quotepath=false makes a
# file name with accents or Tibetan print as written instead of as octal escapes (\303\251).

function Get-GitBranch {
    param($app)
    $b = & git -C $app.repoRoot rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $b) { return "$b".Trim() }
    return $null
}

function Build-GitStatusCommands {
    param($app)
    return @("git -C $(Quote-PS $app.repoRoot) -c core.quotepath=false status")
}

# The paths typed in the Add field, one each: a "double-quoted" span keeps its spaces (a file named
# "Screenshot 2026-09-02 171631.png"), anything else splits on whitespace. "." is every change.
function Split-GitPaths {
    param([string]$Text)
    $out = @()
    foreach ($m in [regex]::Matches("$Text", '"([^"]*)"|(\S+)')) {
        $p = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        if ($p) { $out += $p }
    }
    return ,$out
}

function Build-GitAddCommands {
    param($app, [string]$Paths)
    $list = Split-GitPaths $Paths
    if ($list.Count -eq 0) { return @() }
    $quoted = ($list | ForEach-Object { Quote-PS $_ }) -join ' '
    return @("git -C $(Quote-PS $app.repoRoot) add -- $quoted")
}

# The message goes through a file (git commit -F), base64 in the command list like the release note in
# Build-TagCommands, so several lines, accents and quotes reach git as typed. The first line rides along as
# a comment, so the confirmation shows what is being committed. The file name is per call: two tabs can
# commit at once.
function Build-GitCommitCommands {
    param($app, [string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return @() }
    $first = ($Message.Trim() -split "`r?`n")[0]
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Message.Trim()))
    $tmp = '$env:TEMP\instaladorbuda-commit-' + [guid]::NewGuid().ToString('N') + '.txt'
    return @(
        "# message: $first",
        "[IO.File]::WriteAllText(`"$tmp`", [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))",
        "git -C $(Quote-PS $app.repoRoot) -c core.quotepath=false commit -F `"$tmp`"",
        "Remove-Item `"$tmp`" -ErrorAction SilentlyContinue"
    )
}

# A plain push of the current branch to its upstream — never --force.
function Build-GitPushCommands {
    param($app)
    return @("git -C $(Quote-PS $app.repoRoot) push")
}

# ── Update: rebuild this exe from the .ps1 and restart it ─────────────────────
# The build cannot run inside this process: build-exe.ps1 stops whatever runs the exe it overwrites — this
# window — and a child whose output this window reads would lose its pipe with it. So a detached helper (its own
# console window, nothing redirected) waits for this process to exit, runs build-exe.ps1 and starts the new exe.
# If the build fails, its window stays open with the error and the old exe (or the .ps1) is started instead, so
# the cockpit never ends up gone.
function Build-UpdateHelperLines {
    param([string]$Dir, [int]$ParentPid)
    $d = Quote-PS $Dir
    return @(
        "`$host.UI.RawUI.WindowTitle = 'InstaladorBUDA - update'"
        "Write-Host 'Waiting for InstaladorBUDA to close...' -ForegroundColor Cyan"
        "Wait-Process -Id $ParentPid -ErrorAction SilentlyContinue"
        "Set-Location -LiteralPath $d"
        "`$exe = Join-Path $d 'InstaladorBUDA.exe'"
        'try {'
        "    & (Join-Path $d 'build-exe.ps1')"
        "    Write-Host 'Starting the new InstaladorBUDA.exe...' -ForegroundColor Green"
        "    Start-Process -FilePath `$exe -WorkingDirectory $d"
        '    Start-Sleep -Seconds 2'
        '} catch {'
        "    Write-Host ''"
        '    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red'
        "    if (Test-Path `$exe) { Start-Process -FilePath `$exe -WorkingDirectory $d }"
        "    else { Start-Process pwsh -ArgumentList @('-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $d 'InstaladorBUDA.ps1')) -WorkingDirectory $d }"
        "    Read-Host 'Press Enter to close this window'"
        '}'
        'Remove-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue'
    )
}

function Start-UpdateHelper {
    param([string]$Dir, [int]$ParentPid)
    $tmp = Join-Path $env:TEMP ("instaladorbuda-update-" + [guid]::NewGuid().ToString('N') + ".ps1")
    Set-Content -LiteralPath $tmp -Value (Build-UpdateHelperLines $Dir $ParentPid) -Encoding UTF8
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`""
    # Its own console window: nothing in it is tied to this process, which is about to exit.
    $psi.UseShellExecute = $true
    $psi.WorkingDirectory = $Dir
    [void][System.Diagnostics.Process]::Start($psi)
}

# What each git step shows after it ran, in the same job: the state it left.
function Build-GitAfterLines {
    param($app, [string]$Step)
    $r = Quote-PS $app.repoRoot
    switch ($Step) {
        'add'    { return @("Write-Host ''", "git -C $r -c core.quotepath=false status --short --branch") }
        'commit' { return @("Write-Host ''", "git -C $r log --oneline -1", "git -C $r -c core.quotepath=false status --short --branch") }
        'push'   { return @("Write-Host ''", "git -C $r status --short --branch") }
        default  { return @() }
    }
}

# ── Following a build to its result (tab log and console) ──────────────────────
# After Deploy / Trigger, these follow the workflow run the step just started — each
# job and step as it starts and finishes — and then report the release (draft or
# published, and its files), so the result is in the log instead of on GitHub. After
# Publish from run / Un-draft they only report the release. In the GUI their source is
# written into the job's own script (Build-FollowUpLines), so they run in the job's pwsh
# process and stream into the tab like any other output; they therefore use only gh and
# plain PowerShell. A '::status::<text>' line is not logged: the tab shows <text> in its
# title instead (see $run).

# gh's JSON output as objects; $null when gh printed nothing (not found, not signed in,
# offline) — piping nothing-at-all into ConvertFrom-Json would throw instead.
function Read-GhJson {
    param([string[]]$GhArgs)
    $json = & gh @GhArgs 2>$null
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json)
}

# GitHub timestamps as UTC DateTime. pwsh's ConvertFrom-Json already returns them as UTC
# DateTime, Windows PowerShell 5.1 leaves them as strings; "0001-01-01" means "not yet".
function ConvertTo-UtcTime {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    $t = if ($Value -is [datetime]) {
        if ($Value.Kind -eq 'Local') { $Value.ToUniversalTime() } else { [datetime]::SpecifyKind($Value, 'Utc') }
    } else { [DateTimeOffset]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
    if ($t.Year -lt 2000) { return $null }
    return $t
}

function Format-Duration {
    param($From, $To)
    if (-not $From -or -not $To) { return '' }
    $s = [int][Math]::Max(0, ($To - $From).TotalSeconds)
    if ($s -ge 3600) { return ('{0}h {1:00}m' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60)) }
    if ($s -ge 60)   { return ('{0}m {1:00}s' -f [Math]::Floor($s / 60), ($s % 60)) }
    return "${s}s"
}

# Finds the run a Deploy (-Event push, -Branch = the tag) or Trigger (-Event
# workflow_dispatch) just started — the newest one created after -Since — and reports
# its jobs and steps until it completes. Returns @{ Id; Url; Conclusion }, or $null when
# no run appeared within -FindMinutes.
function Watch-WorkflowRun {
    param([string]$Repo, [string]$Workflow, [string]$Event, [string]$Branch, [datetime]$Since,
          [int]$PollSeconds = 8, [int]$FindMinutes = 3, [switch]$StatusLines)
    $status = { param($t) if ($StatusLines) { Write-Host "::status::$t" } }
    $ok = [char]0x2713; $bad = [char]0x2717; $started = [char]0x25B6; $skipped = [char]0x00B7

    Write-Host ''
    Write-Host "Following $Workflow on $Repo ..." -ForegroundColor Cyan
    & $status 'waiting for the run...'
    $listArgs = @('run', 'list', '--repo', $Repo, '--workflow', $Workflow, '--event', $Event,
                  '--limit', '10', '--json', 'databaseId,createdAt,url')
    if ($Branch) { $listArgs += @('--branch', $Branch) }
    $deadline = (Get-Date).AddMinutes($FindMinutes)
    while ($true) {
        # 60 s of slack for clock skew between this machine and GitHub. ForEach-Object
        # unrolls the array, which Windows PowerShell's ConvertFrom-Json emits as one object.
        $run = @(Read-GhJson $listArgs | ForEach-Object { $_ }) |
            Where-Object { $_ -and (ConvertTo-UtcTime $_.createdAt) -ge $Since.AddSeconds(-60) } |
            Sort-Object { ConvertTo-UtcTime $_.createdAt } -Descending | Select-Object -First 1
        if ($run) { break }
        if ((Get-Date) -gt $deadline) {
            Write-Host "No $Workflow run appeared on $Repo within $FindMinutes min - check the Actions page." -ForegroundColor Yellow
            return $null
        }
        Start-Sleep -Seconds 5
    }
    Write-Host "Run $($run.databaseId): $($run.url)"

    # What has been reported already, so each start and each finish is logged once.
    $jobSeen = @{}; $stepSeen = @{}
    while ($true) {
        $v = Read-GhJson @('run', 'view', "$($run.databaseId)", '--repo', $Repo, '--json', 'status,conclusion,jobs')
        if ($v) {
            $jobs = @($v.jobs)
            foreach ($j in $jobs) {
                $jk = "$($j.databaseId)$($j.name)"
                if ($j.status -ne 'queued' -and $j.status -ne 'waiting' -and -not $jobSeen[$jk]) {
                    $jobSeen[$jk] = 'started'
                    Write-Host "[$($j.name)] started"
                }
                foreach ($s in @($j.steps)) {
                    # GitHub's own bookkeeping steps say nothing about the build.
                    if ($s.name -eq 'Set up job' -or $s.name -eq 'Complete job' -or $s.name -like 'Post *') { continue }
                    $sk = "$jk/$($s.number)"
                    if ($s.status -eq 'in_progress' -and -not $stepSeen[$sk]) {
                        $stepSeen[$sk] = 'started'
                        Write-Host "[$($j.name)]   $started $($s.name)"
                    } elseif ($s.status -eq 'completed' -and $stepSeen[$sk] -ne 'done') {
                        $stepSeen[$sk] = 'done'
                        $mark = switch ($s.conclusion) { 'success' { $ok } 'skipped' { $skipped } default { $bad } }
                        $note = if ($s.conclusion -eq 'success') { '' } else { " ($($s.conclusion))" }
                        $dur  = Format-Duration (ConvertTo-UtcTime $s.startedAt) (ConvertTo-UtcTime $s.completedAt)
                        Write-Host "[$($j.name)]   $mark $($s.name)$note$(if ($dur -and $s.conclusion -ne 'skipped') { "  $dur" })"
                    }
                }
                if ($j.status -eq 'completed' -and $jobSeen[$jk] -ne 'done') {
                    $jobSeen[$jk] = 'done'
                    $mark = if ($j.conclusion -eq 'success') { $ok } elseif ($j.conclusion -eq 'skipped') { $skipped } else { $bad }
                    $dur  = Format-Duration (ConvertTo-UtcTime $j.startedAt) (ConvertTo-UtcTime $j.completedAt)
                    Write-Host "[$($j.name)] $mark $($j.conclusion)$(if ($dur) { "  $dur" })" -ForegroundColor $(if ($j.conclusion -in 'success', 'skipped') { 'Green' } else { 'Red' })
                }
            }
            $done = @($jobs | Where-Object { $_.status -eq 'completed' }).Count
            if ($v.status -eq 'completed') {
                $ends = @($jobs | ForEach-Object { ConvertTo-UtcTime $_.completedAt } | Where-Object { $_ })
                $end  = if ($ends.Count) { ($ends | Measure-Object -Maximum).Maximum } else { $null }
                $dur  = Format-Duration (ConvertTo-UtcTime $run.createdAt) $end
                Write-Host ''
                Write-Host "Run finished: $($v.conclusion)$(if ($dur) { " in $dur" })" -ForegroundColor $(if ($v.conclusion -eq 'success') { 'Green' } else { 'Red' })
                return @{ Id = $run.databaseId; Url = $run.url; Conclusion = $v.conclusion }
            }
            & $status "building ($done/$($jobs.Count) jobs done)"
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

# Reports a release: draft or published, and each attached file. Returns $false when
# the release does not exist.
function Show-ReleaseStatus {
    param([string]$Repo, [string]$Tag)
    $r = Read-GhJson @('release', 'view', $Tag, '--repo', $Repo, '--json', 'tagName,isDraft,isPrerelease,publishedAt,url,assets')
    Write-Host ''
    if (-not $r) {
        Write-Host "Release ${Tag}: not found on $Repo." -ForegroundColor Yellow
        return $false
    }
    if ($r.isDraft) {
        Write-Host "Release ${Tag} on ${Repo}: DRAFT - not public yet (Un-draft release publishes it)." -ForegroundColor Yellow
    } else {
        $when = ConvertTo-UtcTime $r.publishedAt
        $pre  = if ($r.isPrerelease) { ' (pre-release)' } else { '' }
        Write-Host "Release ${Tag} on ${Repo}: PUBLISHED$pre$(if ($when) { ' ' + $when.ToLocalTime().ToString('yyyy-MM-dd HH:mm') })" -ForegroundColor Green
    }
    $assets = @($r.assets)
    if ($assets.Count -eq 0) { Write-Host '  (no files attached)' -ForegroundColor Yellow }
    foreach ($a in $assets) {
        $state = if ($a.state -and $a.state -ne 'uploaded') { "  ($($a.state))" } else { '' }
        Write-Host ('  {0,-44} {1,9:N1} MB{2}' -f $a.name, ($a.size / 1MB), $state)
    }
    Write-Host "  $($r.url)"
    return $true
}

# A test build (Publish unchecked) makes no release; its installers are run artifacts.
function Show-RunArtifacts {
    param([string]$Repo, [string]$RunId)
    $list = @((Read-GhJson @('api', "repos/$Repo/actions/runs/$RunId/artifacts")).artifacts)
    Write-Host ''
    if ($list.Count -eq 0 -or -not $list[0]) { Write-Host "Test build - no release, and no artifacts on run $RunId."; return }
    Write-Host "Test build - no release. Artifacts on run ${RunId} (Publish selected run releases them):"
    foreach ($a in $list) { Write-Host ('  {0,-44} {1,9:N1} MB' -f $a.name, ($a.size_in_bytes / 1MB)) }
}

# Follows what a step started and reports the result. -Kind: 'push' (Deploy),
# 'dispatch' (Trigger), 'release' (Publish from run / Un-draft: no build to follow).
# Returns the exit code for the job: 0, or 1 when the run did not succeed or the
# release it should have made is missing.
function Invoke-FollowUp {
    param([string]$Kind, [string]$AppRepo, [string]$Workflow, [string]$ReleaseRepo, [string]$Tag,
          [bool]$Publish, [datetime]$Since, [int]$LastExit = 0, [switch]$StatusLines, [switch]$ImageOnly)
    if ($LastExit -ne 0) {
        Write-Host "The last command failed (exit $LastExit) - not following the build." -ForegroundColor Red
        return $LastExit
    }
    $code = 0
    if ($Kind -ne 'release') {
        if (-not $AppRepo) { Write-Host 'No GitHub remote found for this app - cannot follow the build.' -ForegroundColor Yellow; return 0 }
        $event  = if ($Kind -eq 'push') { 'push' } else { 'workflow_dispatch' }
        $branch = if ($Kind -eq 'push') { $Tag } else { '' }
        $run = Watch-WorkflowRun -Repo $AppRepo -Workflow $Workflow -Event $event -Branch $branch -Since $Since -StatusLines:$StatusLines
        if (-not $run) { return 0 }
        if ($run.Conclusion -ne 'success') { $code = 1 }
        if ($ImageOnly) {
            if ($code -eq 0) {
                if ($StatusLines) { Write-Host '::status::image published; Flux will watch for its new tag' }
                Write-Host "Container image workflow succeeded for $Tag. Flux image automation can advance the Kubernetes manifest; this job does not wait for cluster rollout." -ForegroundColor Green
            }
            return $code
        }
        if (-not $Publish) { Show-RunArtifacts -Repo $AppRepo -RunId $run.Id; return $code }
    }
    if ($StatusLines) { Write-Host '::status::checking the release...' }
    if (-not (Show-ReleaseStatus -Repo $ReleaseRepo -Tag $Tag)) { $code = 1 }
    return $code
}

# The lines a GUI job appends after its commands to run Invoke-FollowUp in the job's own
# process: the helpers' source, then one call. $__since (set by the job script before
# its commands) is when the step started, so the run it caused can be told from older ones.
function Build-FollowUpLines {
    param($app, [string]$Kind, [string]$Version, [bool]$Publish)
    if (-not $HasGh) { return @("Write-Host 'gh not found - cannot follow the build or report the release.' -ForegroundColor Yellow") }
    $defs = foreach ($f in 'Read-GhJson', 'ConvertTo-UtcTime', 'Format-Duration', 'Watch-WorkflowRun', 'Show-ReleaseStatus', 'Show-RunArtifacts', 'Invoke-FollowUp') {
        "function $f {" + [Environment]::NewLine + (Get-Item "function:$f").ScriptBlock.ToString() + [Environment]::NewLine + '}'
    }
    # A command that already failed keeps its exit code: the follow-up's own result only fills in an OK job.
    $call = '$__fu = Invoke-FollowUp -StatusLines -LastExit ([int]$LASTEXITCODE) -Since $__since' +
        " -Kind $Kind -Publish `$$($Publish.ToString().ToLower())" +
        ' -AppRepo '     + (Quote-PS (Resolve-AppRepo $app)) +
        ' -Workflow '    + (Quote-PS $app.workflow) +
        ' -ReleaseRepo ' + (Quote-PS (Resolve-ReleaseRepo $app)) +
        ' -Tag '         + (Quote-PS "$($app.tagPrefix)$Version")
    if ($app.outputKind -eq 'container-image') { $call += ' -ImageOnly' }
    return @($defs) + $call + 'if (-not $__code) { $__code = $__fu }'
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

# ── GUI ──────────────────────────────────────────────────────────────────────
# Structure: one TabControl fills the form. Each real tab is a fully independent job
# runner built by New-JobTab — its own Target/Version/Notes/Steps/log, so several
# deploys can run side by side without their output or fields interfering with each
# other. A trailing "+" tab spawns a new job tab when selected (the standard WinForms
# idiom for an add-tab button, since TabControl has no built-in one).

# ── GUI layout ───────────────────────────────────────────────────────────────
# Every position and size in the GUI is in design pixels — pixels at 100% Windows
# scaling — and goes through Px, which scales it to the screen's real DPI once. The exe
# is DPI-aware so its text is sharp, which means Windows no longer enlarges the window
# for it: at 150% the 9 pt font is drawn 1.5x larger, and positions left at their 100%
# values crowd the rows together and clip the labels. Change spacing here, not in
# New-JobTab.
$UI = @{
    Pad          = 20     # outer margin of a tab's content
    ContentWidth = 720    # a tab's content width; boxes run from Pad to ContentWidth - Pad
    LabelWidth   = 100    # row labels ("Target app:", "Version:")
    FieldX       = 130    # where a row's input starts
    RowH         = 26     # a label, text box, combo box or check box
    RowPitch     = 42     # top of one field row to the top of the next
    CheckPitch   = 32     # between the two stacked check boxes
    BoxGap       = 18     # between one group box and the next
    BoxTop       = 30     # first row inside a group box, below its caption
    BoxPad       = 16     # a group box's inner left / right / bottom padding
    BoxRowPitch  = 46     # top of one row inside a group box to the next
    BoxLabelW    = 72     # "Workflow:" / "Run:" inside a group box
    BtnH         = 34     # button height
    BtnGap       = 16     # between buttons in a row
    BtnTextPad   = 32     # caption-to-edge padding inside a button
    NotesH       = 80     # release-notes text box
    MessageH     = 56     # the Git group's commit-message box (two lines and a bit)
    LogH         = 150    # log box
    StatusH      = 30     # git / gh status line
    TopBarH      = 50     # the strip above the tabs holding Update (a button and its margin)
    WindowWidth  = 780    # main window, before it is capped to the screen
    WindowHeight = 1150
}

# Screen DPI / 96, read once: 1.5 at 150% in the DPI-aware exe; 1.0 for a .ps1 under
# pwsh, which is not DPI-aware (Windows stretches that whole window instead).
function Get-UiScale {
    if (-not $script:UiScale) {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try { $script:UiScale = $g.DpiX / 96.0 } finally { $g.Dispose() }
    }
    return $script:UiScale
}

function Px([double]$Value) { [int][Math]::Round($Value * (Get-UiScale)) }

# Places a control, in design pixels.
function Set-Box {
    param($Control, [double]$X, [double]$Y, [double]$Width, [double]$Height)
    $Control.SetBounds((Px $X), (Px $Y), (Px $Width), (Px $Height))
}

# Places a single-line text box or combo box centred in a RowH-high row at $Y, level
# with that row's MiddleLeft label. Its height is decided by its font, not by us, so the
# font is set first (a control not yet on the form has the default font).
function Set-Field {
    param($Control, $Font, [double]$X, [double]$Y, [double]$Width)
    $Control.Font = $Font
    Set-Box $Control $X $Y $Width $UI.RowH
    $Control.Top = (Px $Y) + [int][Math]::Floor(((Px $UI.RowH) - $Control.Height) / 2)
}

# The width a button needs for its caption, in design pixels, never below $MinWidth.
# Measured with TextRenderer (the GDI path Button itself draws with) at the real DPI, then
# converted back to design pixels so Set-Box scales it like everything else. $Caption
# measures a different text than the one the button shows now.
function Get-ButtonWidth {
    param([System.Windows.Forms.Button]$Button, [double]$MinWidth = 110, [string]$Caption)
    $text = if ($Caption) { $Caption } else { $Button.Text }
    $px = [System.Windows.Forms.TextRenderer]::MeasureText($text, $Button.Font).Width
    return [Math]::Max($MinWidth, [Math]::Ceiling($px / (Get-UiScale)) + $UI.BtnTextPad)
}

# Lays buttons left to right from $X on row $Y, each as wide as its caption needs.
# Returns the X just past the last one, so a later row can line up under this one.
function Set-ButtonRow {
    param([System.Windows.Forms.Button[]]$Buttons, [double]$X, [double]$Y, [double]$MinWidth = 110)
    foreach ($b in $Buttons) {
        $w = Get-ButtonWidth $b $MinWidth
        Set-Box $b $X $Y $w $UI.BtnH
        $X += $w + $UI.BtnGap
    }
    return $X
}

function Convert-CliList {
    param($Value)
    if ($null -eq $Value) { return ,@() }
    if ($Value -is [string]) { return ,@($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return ,@($Value | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ })
}

function Test-CliProperty {
    param($Object, [string]$Name)
    return ($Object -and ($Object.PSObject.Properties.Name -contains $Name))
}

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
        return [pscustomobject]@{ ok = $true; command = 'help'; data = @{ commands = @('start','close','list','status','new-tab','select-tab','configure','action'); actions = @('upload','deploy','dispatch','load-runs','publish-run','undraft','make-public','make-private','open-actions','open-release','copy-command','task','git-status','git-add','git-commit','git-push','update'); pipe = $script:ControlPipeName; example = '{"command":"action","tab":1,"action":"dispatch","target":"SegBUDA","version":"1.0.18","bundles":["essential"],"notes":"Release notes","confirm":true,"waitMs":120000}' } }
    }
    if ($command -eq 'list') {
        $targets = @($Apps | ForEach-Object { [pscustomobject]@{ name = $_.name; repoRoot = $_.repoRoot; workflow = $_.workflow; tagPrefix = $_.tagPrefix; bundles = @($_.bundles); models = @($_.uploadModels | ForEach-Object { $_.name }) } })
        return [pscustomobject]@{ ok = $true; command = 'list'; data = @{ targets = $targets; tasks = @($Tasks | ForEach-Object { [pscustomobject]@{ name = $_.name; runOn = $_.runOn } }) } }
    }
    if ($command -eq 'status') { return (Get-CockpitStatus $GuiState $Request) }
    if ($command -eq 'start') { return (Get-CockpitStatus $GuiState $Request) }
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
        }
        if (Test-CliProperty $Request 'version') { $c.Version.Text = [string]$Request.version }
        if (Test-CliProperty $Request 'publish') { $c.Publish.Checked = [bool]$Request.publish }
        if (Test-CliProperty $Request 'dryRun') { $c.DryRun.Checked = [bool]$Request.dryRun }
        if (Test-CliProperty $Request 'notes') { $c.Notes.Text = [string]$Request.notes }
        if (Test-CliProperty $Request 'workflow') { $c.Workflow.Text = [string]$Request.workflow }
        if (Test-CliProperty $Request 'gitPaths') { $c.GitAdd.Text = [string]$Request.gitPaths }
        if (Test-CliProperty $Request 'commitMessage') { $c.GitMessage.Text = [string]$Request.commitMessage }
        if (Test-CliProperty $Request 'taskName') {
            $idx = -1
            for ($i = 0; $i -lt $c.Task.Items.Count; $i++) { if ($c.Task.Items[$i] -eq $Request.taskName) { $idx = $i; break } }
            if ($idx -lt 0) { throw "Unknown task '$($Request.taskName)'." }
            $c.Task.SelectedIndex = $idx
        }
        & $state.AppendLog ("CLI configured target=$($c.Target.SelectedItem), version=$($c.Version.Text).")
        if ($command -eq 'configure') {
            return [pscustomobject]@{ ok = $true; command = $command; data = @{ tabId = $state.Id; target = "$($c.Target.SelectedItem)"; version = $c.Version.Text } }
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
    $confirmationActions = @('upload','deploy','dispatch','publish-run','undraft','make-public','make-private','git-add','git-commit','git-push','task')
    if ($actionName -in $confirmationActions -and -not $c.DryRun.Checked -and -not $Request.confirm) {
        throw "$actionName requires confirm:true (or set dryRun:true to preview only)."
    }
    switch ($actionName) {
        'upload' {
            $state.CliModels = @(Resolve-CliModels $app $Request.models)
            $button = $c.Buttons.Upload
        }
        { $_ -in @('deploy','dispatch') } {
            if (-not $c.Version.Text.Trim()) { throw 'Set version before deploy or dispatch.' }
            if ($app.bundles -and @($app.bundles).Count -gt 0) { $state.CliBundles = Resolve-CliBundles $app $Request.bundles }
            $button = if ($actionName -eq 'deploy') { $c.Buttons.Deploy } else { $c.Buttons.Dispatch }
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
    Set-Field $cmbTarget $uiFont $UI.FieldX $y 240
    $Apps | ForEach-Object { [void]$cmbTarget.Items.Add($_.name) }
    if ($cmbTarget.Items.Count -gt 0) { $cmbTarget.SelectedIndex = 0 }

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
    $btnDispatch = New-Object System.Windows.Forms.Button
    $btnDispatch.Text = 'or: Trigger workflow'; $btnDispatch.Font = $uiFont
    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = 'Copy last command'; $btnCopy.Font = $uiFont
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
    [void](Set-ButtonRow @($btnCopy) $col1X $rowY 160)
    [void](Set-ButtonRow @($btnActions) $col3X $rowY 160)
    $boxH = $rowY + $UI.BtnH + $UI.BoxPad
    Set-Box $grp $UI.Pad $y $boxWidth $boxH
    $grp.Anchor = 'Top,Left,Right'
    $grp.Controls.AddRange(@($btnUpload, $btnDeploy, $btnDispatch, $btnCopy, $btnActions))
    $y += $boxH + $UI.BoxGap

    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($btnDispatch, "With 'Publish to website' checked, this DOES create a real tag + release (same gh release create/finalize path as Deploy) — it just doesn't push a local git tag, so InstaladorBUDA's 'current version' won't see it until you 'git fetch --tags'.")
    $tips.SetToolTip($btnDeploy, 'Pushes a real git tag locally, which always rebuilds every bundle.')

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
    $btnTask.Enabled = ($Tasks.Count -gt 0)
    $taskW = Get-ButtonWidth $btnTask 115
    $taskX = $boxWidth - $UI.BoxPad - $taskW
    Set-Box $btnTask $taskX $rowY $taskW $UI.BtnH
    $btnTask.Anchor = 'Top,Right'
    $cmbTask = New-Object System.Windows.Forms.ComboBox
    $cmbTask.DropDownStyle = 'DropDownList'
    Set-Field $cmbTask $uiFont $UI.BoxPad ($rowY + $inset) ($taskX - $UI.BtnGap - $UI.BoxPad)
    $cmbTask.Anchor = 'Top,Left,Right'
    $Tasks | ForEach-Object { [void]$cmbTask.Items.Add($_.name) }
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
    $panel.Controls.AddRange(@($lblTarget, $cmbTarget, $lblVer, $txtVer, $lblCur, $chkPublish, $chkDry, $grp, $grpPub, $grpVis, $grpTask, $grpGit, $grpNotes, $logBox, $status))
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
        $grpGit.Text = if ($branch) { "Git  ->  $($app.name)  [$branch]   $($app.repoRoot)" }
                       else { "Git  ->  $($app.repoRoot)  (not a git repo)" }
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
    $btnDeploy.Add_Click({
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
        $label = if ($isImageOnly) { "Publish $($app.name) image v$v (push tag)" }
                 elseif ($bundles -eq 'all') { "Deploy $($app.name) v$v (push tag)" }
                 else { "Deploy $($app.name) v$v (push tag, bundles: $bundles)" }
        & $run (Build-TagCommands $app $v $notes $bundles) $label $false $app.repoRoot (Build-FollowUpLines $app 'push' $v $true)
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
        $task = $Tasks[$cmbTask.SelectedIndex]
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
        Log = $logBox; Visibility = $lblVis
        Buttons = @{
            Upload = $btnUpload; Deploy = $btnDeploy; Dispatch = $btnDispatch; Copy = $btnCopy; Actions = $btnActions
            LoadRuns = $btnLoadRuns; PublishRun = $btnPubRun; Undraft = $btnUndraft; ReleasePage = $btnRelPage
            MakePublic = $btnMakePublic; MakePrivate = $btnMakePrivate; Task = $btnTask
            GitAdd = $btnGitAdd; GitCommit = $btnGitCommit; GitStatus = $btnGitStatus; GitPush = $btnGitPush
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

# ── Entry point ──────────────────────────────────────────────────────────────
if ($Cli) { Invoke-CockpitCli -Json $Cli; return }
if ($Console) { Show-ConsoleMenu; return }
try {
    Show-Gui
} catch {
    Write-Warning "GUI unavailable ($($_.Exception.Message)). Falling back to console menu."
    Show-ConsoleMenu
}
