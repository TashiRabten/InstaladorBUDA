function Get-LatestPublishedVersion {
    param($app)
    if (-not $app.tagPrefix) { return $null }
    $releaseRepo = if ($app.releaseRepo) { [string]$app.releaseRepo } else { [string]$ReleaseRepo }
    $cacheKey = "$releaseRepo|$($app.tagPrefix)"
    if ($script:ReleaseVersionCache.ContainsKey($cacheKey)) {
        $cached = $script:ReleaseVersionCache[$cacheKey]
        if ([DateTime]::UtcNow - $cached.CheckedAt -lt [TimeSpan]::FromMinutes(2)) { return $cached.Version }
    }

    $latestText = $null
    $latestVersion = $null
    $lookupError = $null
    try {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is unavailable.' }
        $raw = & gh release list --repo $releaseRepo --limit 100 --json tagName,isDraft,isPrerelease 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Could not read published releases.' }
        $releases = @((($raw -join "`n") | ConvertFrom-Json))
        foreach ($release in $releases) {
            if ($release.isDraft -or $release.isPrerelease) { continue }
            $tag = [string]$release.tagName
            if (-not $tag.StartsWith([string]$app.tagPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $candidate = $tag.Substring(([string]$app.tagPrefix).Length)
            try { $parsed = [version]$candidate } catch { continue }
            if (-not $latestVersion -or $parsed -gt $latestVersion) {
                $latestVersion = $parsed
                $latestText = $candidate
            }
        }
    } catch { $lookupError = $_.Exception.Message }

    $script:ReleaseVersionCache[$cacheKey] = @{ Version = $latestText; CheckedAt = [DateTime]::UtcNow; Error = $lookupError }
    return $latestText
}

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
        if ($app.versionFromReleaseTag) {
            $published = Get-LatestPublishedVersion $app
            if ($published) { return $published }
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
    param($app, [string]$Version, [string]$ReleaseNotes = '', [string]$Bundles = 'all', [bool]$ReplaceExistingTag = $false)
    $repo = $app.repoRoot
    $tag  = "$($app.tagPrefix)$Version"
    $tagState = Get-GitTagState $app $tag
    if ($app.outputKind -eq 'container-image' -and $ReplaceExistingTag) {
        throw 'Container image tags are immutable; use workflow dispatch to retry a build.'
    }
    if ($ReplaceExistingTag -and -not $tagState.RemoteTagExists) {
        throw "Remote tag $tag does not exist, so there is no existing tag to move."
    }
    if (-not $ReplaceExistingTag -and ($tagState.LocalTagExists -or $tagState.RemoteTagExists -or $tagState.ReleaseExists)) {
        throw "Tag or release $tag already exists. Choose a new version, or explicitly use retag-deploy with replaceExistingTag:true and confirm:true."
    }
    $tagOption = if ($ReplaceExistingTag) { '-f ' } else { '' }
    $pushOption = if ($ReplaceExistingTag) { "--force-with-lease=refs/tags/${tag}:$($tagState.RemoteTagObject) " } else { '' }
    if ($app.outputKind -eq 'container-image') {
        return @("git -C `"$repo`" tag $tag", "git -C `"$repo`" push origin refs/tags/$tag")
    }
    # A tag push carries no workflow inputs, so a bundle subset rides in the annotated tag
    # message as a "Bundles: <ids>" line. build-segbuda.yml's manifest job reads it (and
    # prepare-release strips it from the release body); no line → every bundle.
    if (-not [string]::IsNullOrWhiteSpace($Bundles) -and $Bundles -ne 'all') {
        $body = $ReleaseNotes.TrimEnd()
        $ReleaseNotes = if ($body) { "$body`n`nBundles: $Bundles" } else { "Bundles: $Bundles" }
    }
    if ([string]::IsNullOrWhiteSpace($ReleaseNotes)) {
        # No note → lightweight tag; the build workflow uses its default release message.
        return @("git -C `"$repo`" tag $tagOption$tag", "git -C `"$repo`" push $pushOption origin refs/tags/$tag")
    }
    # Note provided → ANNOTATED tag carrying the note as its message. The build
    # workflow reads the tag message on a tag push and uses it as the GitHub Release
    # body, so the same note appears whether you Deploy (push tag) or Trigger (dispatch).
    # Base64 keeps the (possibly multi-line) note a single safe token in the command list.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ReleaseNotes))
    $tmp = '$env:TEMP\instaladorbuda-relnote.txt'
    return @(
        "[IO.File]::WriteAllText(`"$tmp`", [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))",
        "git -C `"$repo`" tag $tagOption-a $tag -F `"$tmp`"",
        "git -C `"$repo`" push $pushOption origin refs/tags/$tag",
        "Remove-Item `"$tmp`" -ErrorAction SilentlyContinue"
    )
}

function Get-GitTagState {
    param($app, [string]$Tag)
    $repo = [string]$app.repoRoot
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is unavailable; cannot check whether the release tag already exists.' }
    & git -C $repo show-ref --verify --quiet "refs/tags/$Tag" 2>$null
    $localExists = $LASTEXITCODE -eq 0
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $remoteLines = @(& git -C $repo ls-remote --refs --tags origin "refs/tags/$Tag" 2>&1)
        $remoteExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousErrorActionPreference }
    if ($remoteExit -ne 0) { throw "Could not check remote tag $Tag. Check the origin remote and network, then retry." }
    $remoteExists = $remoteLines.Count -gt 0
    $remoteObject = $null
    if ($remoteExists) { $remoteObject = ([string]$remoteLines[0] -split '\s+')[0] }

    $releaseExists = $false
    if ($app.outputKind -ne 'container-image') {
        $releaseRepo = if ($app.releaseRepo) { [string]$app.releaseRepo } else { [string]$ReleaseRepo }
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is unavailable; cannot verify whether a release already exists.' }
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $releaseOutput = @(& gh release view $Tag --repo $releaseRepo --json tagName 2>&1)
            $releaseExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        if ($releaseExit -eq 0) {
            $releaseExists = $true
        } else {
            $releaseError = $releaseOutput -join "`n"
            if ($releaseError -match '(?i)(release not found|not found \(HTTP 404\)|HTTP 404)') {
                $releaseExists = $false
            } else {
                throw "Could not check release $Tag in $releaseRepo. $releaseError"
            }
        }
    }
    return [pscustomobject]@{
        LocalTagExists = $localExists
        RemoteTagExists = $remoteExists
        RemoteTagObject = $remoteObject
        ReleaseExists = $releaseExists
    }
}

function Get-ReleasePlan {
    param($app, [string]$RequestedVersion = '')
    $repo = [string]$app.repoRoot
    if ([string]::IsNullOrWhiteSpace([string]$app.tagPrefix)) { throw "$($app.name) has no release tag prefix configured." }
    $latest = $null
    $versionSource = 'default'
    $releaseLookupError = $null
    if ($app.versionFromReleaseTag) {
        $latest = Get-LatestPublishedVersion $app
        $releaseRepoForVersion = if ($app.releaseRepo) { [string]$app.releaseRepo } else { [string]$ReleaseRepo }
        $cacheKey = "$releaseRepoForVersion|$($app.tagPrefix)"
        if ($script:ReleaseVersionCache.ContainsKey($cacheKey)) { $releaseLookupError = $script:ReleaseVersionCache[$cacheKey].Error }
        if ($latest) { $versionSource = 'published-release' }
    }
    if (-not $latest) {
        $latest = Get-CurrentVersion $app
        $versionSource = if ($app.versionFromGitTag) { 'local-tag' } else { 'default' }
    }
    $suggested = Get-NextVersion $latest
    $version = if ([string]::IsNullOrWhiteSpace($RequestedVersion)) { $suggested } else { $RequestedVersion.Trim() }
    $tag = "$($app.tagPrefix)$version"
    $tagState = Get-GitTagState $app $tag
    $releaseRepo = if ($app.releaseRepo) { [string]$app.releaseRepo } else { [string]$ReleaseRepo }
    $branch = Get-GitBranch $app
    $head = & git -C $repo rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { $head = $null }
    $workingTree = @(& git -C $repo status --short --branch 2>$null)
    $dirtyPaths = @($workingTree | Where-Object { $_ -and $_ -notmatch '^## ' })
    $blockers = @()
    $warnings = @()
    if ($releaseLookupError) { $warnings += "Published release lookup failed; using the local version source. $releaseLookupError" }
    if ($tagState.LocalTagExists) { $blockers += "Local tag $tag already exists." }
    if ($tagState.RemoteTagExists) { $blockers += "Remote tag $tag already exists." }
    if ($tagState.ReleaseExists) { $blockers += "GitHub release $tag already exists." }
    if ($dirtyPaths.Count -gt 0) { $warnings += "Working tree has $($dirtyPaths.Count) changed or untracked path(s); the tag will point at HEAD only." }
    if ($branch -eq 'HEAD') { $warnings += 'Repository is on a detached HEAD.' }
    $release = $null
    if ($app.outputKind -ne 'container-image') {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $json = @(& gh release view $tag --repo $releaseRepo --json tagName,isDraft,isPrerelease,publishedAt 2>&1)
            $releaseExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        if ($releaseExit -eq 0 -and $json) { try { $release = (($json -join "`n") | ConvertFrom-Json) } catch { } }
    }
    return [pscustomobject]@{
        ok = $true
        command = 'release-plan'
        data = @{
            target = $app.name
            repoRoot = $repo
            releaseRepo = $releaseRepo
            workflow = $app.workflow
            latestPublishedVersion = $latest
            versionSource = $versionSource
            suggestedVersion = $suggested
            requestedVersion = $version
            tag = $tag
            canDeployWithoutMovingTag = ($blockers.Count -eq 0)
            blockers = $blockers
            warnings = $warnings
            branch = [string]$branch
            head = [string]$head
            workingTree = $workingTree
            workingTreeClean = ($dirtyPaths.Count -eq 0)
            localTagExists = [bool]$tagState.LocalTagExists
            remoteTagExists = [bool]$tagState.RemoteTagExists
            releaseExists = [bool]$tagState.ReleaseExists
            release = $release
        }
    }
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
    if (-not $app -or [string]::IsNullOrWhiteSpace([string]$app.repoRoot)) { return $null }
    $repoRoot = [string]$app.repoRoot
    if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) { return $null }
    try {
        $b = & git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $b -and "$b".Trim() -ne 'HEAD') { return "$b".Trim() }
        $b = & git -C $repoRoot symbolic-ref --quiet --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $b) { return "$b".Trim() }
    } catch {
        return $null
    }
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

# Push the current branch; set the upstream on the first push to an empty remote.
function Build-GitPushCommands {
    param($app)
    $repo = Quote-PS $app.repoRoot
    return @("`$upstream = git -C $repo rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>`$null; if (`$LASTEXITCODE -eq 0) { git -C $repo push } else { git -C $repo push -u origin HEAD }")
}

# Gitleaks runs in the same job before git commit / git push and ends the job on a finding or a scanner
# error, so nothing it flags is committed or sent to GitHub. Commit scans the staged changes; push scans the
# commits the upstream does not have yet (the whole history on a first push). Findings print redacted. The
# repository's own .gitleaks.toml, when present, is used. The job goes on after a failing line, hence the exit.
function Build-GitSecretScanCommand {
    param($app, [string]$ScannerPath, [ValidateSet('commit', 'push')][string]$Step)
    $repo = Quote-PS $app.repoRoot
    $scanner = Quote-PS $ScannerPath
    $flags = '--redact --no-banner --no-color -v'
    if ($Step -eq 'commit') {
        $prepare = ''
        $scan = "& $scanner git --pre-commit --staged $flags $repo"
        $outcome = 'nothing was committed'
    } else {
        $prepare = "`$__upstream = git -C $repo rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>`$null; " +
            "`$__range = if (`$LASTEXITCODE -eq 0) { `"`$__upstream..HEAD`" } else { 'HEAD' }; "
        $scan = "& $scanner git `"--log-opts=`$__range`" $flags $repo"
        $outcome = 'nothing was pushed'
    }
    # A scanner that cannot start sets no exit code, so the catch ends the job too: the gate fails closed.
    return $prepare +
        "try { $scan } catch { Write-Host `"Gitleaks could not run: `$(`$_.Exception.Message) $outcome.`" -ForegroundColor Red; exit 1 }; " +
        "if (`$LASTEXITCODE) { Write-Host 'Gitleaks stopped this step (finding redacted above, or scanner error); $outcome.' -ForegroundColor Red; exit `$LASTEXITCODE }"
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
    if ($script:AppRegistry.Apps.Count -gt 0) { return $script:AppRegistry.Apps[0].repoRoot }
    return (Get-Location).Path
}

# ── Environment probe ────────────────────────────────────────────────────────
