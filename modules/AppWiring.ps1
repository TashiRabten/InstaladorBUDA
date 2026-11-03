# ── App wiring: everything Add app needs to register an app with every control working ──
# A registered app reaches the cockpit through one apps.json entry. Each control reads a few of
# its fields: the visibility toggle reads githubRepo (or the origin remote) and manageVisibility,
# the release steps read workflow/tagPrefix/releaseRepo/releaseBranch/dispatchInputs, the Git
# group and the agent chat read repoRoot. Build-AppRegistryEntry builds the whole entry in one step
# from the project folder and its release workflow; Get-AppWiringReport checks each control's
# fields. The GUI's Add app button and the CLI add-app command both go through these functions.

$script:AppRepoPattern = '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
$script:WorkflowFilePattern = '^[A-Za-z0-9_.-]+\.ya?ml$'
# The workflow inputs the release steps know how to fill (Build-DispatchCommands substitutes them).
$script:DispatchInputTokens = @{ version = '{version}'; publish = '{publish}'; release_notes = '{notes}'; notes = '{notes}'; bundles = '{bundles}' }

function Get-YamlIndent {
    param([string]$Line)
    return ($Line.Length - $Line.TrimStart().Length)
}

function Test-YamlContentLine {
    param([string]$Line)
    $trimmed = $Line.Trim()
    return ($trimmed -and -not $trimmed.StartsWith('#'))
}

function ConvertFrom-YamlScalar {
    param([string]$Text)
    $value = ($Text -replace '\s+#.*$', '').Trim()
    return $value.Trim([char[]]@("'", '"')).Trim()
}

# The keys one level below a "<key>:" block, for example the inputs under workflow_dispatch.
function Get-YamlChildKeys {
    param([string[]]$Lines, [int]$Start, [int]$ParentIndent)
    $keys = New-Object System.Collections.Generic.List[string]
    $childIndent = -1
    for ($i = $Start; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not (Test-YamlContentLine $line)) { continue }
        $indent = Get-YamlIndent $line
        if ($indent -le $ParentIndent) { break }
        if ($childIndent -lt 0) { $childIndent = $indent }
        if ($indent -eq $childIndent -and $line -match '^\s*([A-Za-z0-9_-]+):') { $keys.Add($Matches[1]) }
    }
    return $keys.ToArray()
}

function Get-WorkflowDispatchInputNames {
    param([string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\s*workflow_dispatch:\s*$') { continue }
        $dispatchIndent = Get-YamlIndent $Lines[$i]
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if (-not (Test-YamlContentLine $Lines[$j])) { continue }
            if ((Get-YamlIndent $Lines[$j]) -le $dispatchIndent) { break }
            if ($Lines[$j] -match '^\s*inputs:\s*$') { return @(Get-YamlChildKeys $Lines ($j + 1) (Get-YamlIndent $Lines[$j])) }
        }
    }
    return @()
}

# The first tag pattern under "push: tags:", inline ("tags: ['v*']") or as a list ("- 'x-v*'").
function Get-WorkflowPushTagPattern {
    param([string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\s*push:\s*$') { continue }
        $pushIndent = Get-YamlIndent $Lines[$i]
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if (-not (Test-YamlContentLine $Lines[$j])) { continue }
            if ((Get-YamlIndent $Lines[$j]) -le $pushIndent) { break }
            if ($Lines[$j] -notmatch '^\s*tags:\s*(.*)$') { continue }
            $inline = ($Matches[1] -replace '\s+#.*$', '').Trim()
            if ($inline) { return (ConvertFrom-YamlScalar (($inline.Trim('[', ']') -split ',')[0])) }
            for ($k = $j + 1; $k -lt $Lines.Count; $k++) {
                if (-not (Test-YamlContentLine $Lines[$k])) { continue }
                if ($Lines[$k] -match '^\s*-\s*(.+)$') { return (ConvertFrom-YamlScalar $Matches[1]) }
                break
            }
        }
    }
    return ''
}

# What a release workflow tells the cockpit: its tag prefix, the dispatch inputs it takes, the
# repository and branch its releases go to, and the repository secrets it reads.
function Read-AppWorkflowProfile {
    param([string]$WorkflowPath)
    $lines = [System.IO.File]::ReadAllLines($WorkflowPath)
    $text = $lines -join "`n"
    $tagPattern = Get-WorkflowPushTagPattern $lines
    $tagPrefix = $tagPattern -replace '[\*\?\[].*$', ''
    $inputs = New-Object System.Collections.Generic.List[object]
    $unmapped = New-Object System.Collections.Generic.List[string]
    foreach ($inputName in @(Get-WorkflowDispatchInputNames $lines)) {
        $token = $script:DispatchInputTokens[$inputName]
        if ($token) { $inputs.Add([pscustomobject][ordered]@{ name = $inputName; value = $token }) }
        else { $unmapped.Add($inputName) }
    }
    $releaseRepo = ''
    $repoMatch = [regex]::Match($text, '(?m)^\s*RELEASE_REPO:\s*[''"]?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)[''"]?\s*$')
    if ($repoMatch.Success) { $releaseRepo = $repoMatch.Groups[1].Value }
    $releaseBranch = ''
    $branchMatch = [regex]::Match($text, '(?m)^\s*RELEASE_(?:BRANCH|TARGET):\s*[''"]?([A-Za-z0-9_./-]+)[''"]?\s*$')
    if ($branchMatch.Success) { $releaseBranch = $branchMatch.Groups[1].Value }
    $secrets = @([regex]::Matches($text, 'secrets\.([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -ne 'GITHUB_TOKEN' } | Sort-Object -Unique)
    return [pscustomobject][ordered]@{
        workflow = Split-Path -Leaf $WorkflowPath
        tagPattern = $tagPattern
        tagPrefix = $tagPrefix
        versionFromGitTag = $(if ($tagPrefix) { "$tagPrefix*" } else { '' })
        dispatchInputs = $inputs.ToArray()
        unmappedInputs = $unmapped.ToArray()
        releaseRepo = $releaseRepo
        releaseBranch = $releaseBranch
        secrets = $secrets
    }
}

# The project's release workflow: build-app-installers.yml (the BUDA convention), then
# build-installers.yml, else the only workflow with both a push-tag trigger and dispatch inputs.
function Find-AppReleaseWorkflow {
    param([string]$RepoRoot)
    $dir = Join-Path $RepoRoot '.github\workflows'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return '' }
    $files = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match $script:WorkflowFilePattern } | Sort-Object Name)
    foreach ($preferred in @('build-app-installers.yml', 'build-installers.yml')) {
        $hit = $files | Where-Object { $_.Name -ieq $preferred } | Select-Object -First 1
        if ($hit) { return $hit.Name }
    }
    $candidates = @($files | Where-Object {
        $candidate = Read-AppWorkflowProfile $_.FullName
        $candidate.tagPrefix -and @($candidate.dispatchInputs).Count -gt 0
    })
    if ($candidates.Count -eq 1) { return $candidates[0].Name }
    return ''
}

function Get-AppWorkflowProfile {
    param($App)
    $workflow = [string]$App.workflow
    if ($workflow -notmatch $script:WorkflowFilePattern -or -not $App.repoRoot) { return $null }
    $path = Join-Path ([string]$App.repoRoot) ".github\workflows\$workflow"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Read-AppWorkflowProfile $path)
}

# One complete apps.json entry: every field the controls read, with the release fields taken
# from the project's release workflow when it has one. The visibility toggle is on; set
# manageVisibility to false in apps.json afterwards for a repository the cockpit must not change.
function Build-AppRegistryEntry {
    param([string]$Name, [string]$RepoRoot, [string]$GitHubRepo)
    if ($GitHubRepo -notmatch $script:AppRepoPattern) { throw 'GitHub repository must be owner/name, for example TashiRabten/ScanBUDA.' }
    $workflow = Find-AppReleaseWorkflow $RepoRoot
    $wfProfile = $null
    if ($workflow) { $wfProfile = Read-AppWorkflowProfile (Join-Path $RepoRoot ".github\workflows\$workflow") }
    $hasRelease = [bool]($wfProfile -and $wfProfile.tagPrefix)
    $dispatchInputs = [object[]]@()
    if ($hasRelease) { $dispatchInputs = [object[]]@($wfProfile.dispatchInputs) }
    $releaseRepo = $GitHubRepo
    if ($hasRelease -and $wfProfile.releaseRepo) { $releaseRepo = [string]$wfProfile.releaseRepo }
    $comment = 'Registered by Add app: Git controls, repository bootstrap and visibility; no release workflow found in .github/workflows.'
    if ($hasRelease) {
        $comment = "Registered by Add app from .github/workflows/$workflow (tags $($wfProfile.tagPattern)); releases go to $releaseRepo."
    }
    return [pscustomobject][ordered]@{
        name = $Name
        _comment = $comment
        repoRoot = $RepoRoot
        githubRepo = $GitHubRepo
        releaseRepo = $releaseRepo
        manageVisibility = $true
        tagPrefix = $(if ($hasRelease) { [string]$wfProfile.tagPrefix } else { '' })
        workflow = $(if ($hasRelease) { $workflow } else { '' })
        releaseBranch = $(if ($hasRelease) { [string]$wfProfile.releaseBranch } else { '' })
        versionFromGitTag = $(if ($hasRelease) { [string]$wfProfile.versionFromGitTag } else { '' })
        versionFromReleaseTag = $hasRelease
        uploadScript = $null
        models = @()
        dispatchInputs = $dispatchInputs
    }
}

# The app's own GitHub page for its workflow runs; the global actionsUrl only when the app has
# no repository yet.
function Get-AppActionsUrl {
    param($App)
    $repo = ''
    if ($App) { $repo = [string](Resolve-AppRepo $App) }
    if ($repo -notmatch $script:AppRepoPattern) { return $ActionsUrl }
    $url = "https://github.com/$repo/actions"
    if ([string]$App.workflow -match $script:WorkflowFilePattern) { $url += "/workflows/$($App.workflow)" }
    return $url
}

function Build-AppWiringCheck {
    param([string]$Area, [bool]$Ok, [string]$Detail)
    return [pscustomobject][ordered]@{ area = $Area; ok = $Ok; detail = $Detail }
}

function Get-AppRepositoryWiring {
    param($App)
    $root = [string]$App.repoRoot
    $remote = ''
    if ($root -and (Test-Path -LiteralPath (Join-Path $root '.git'))) { $remote = [string](Get-RepoSlug $root) }
    $field = [string]$App.githubRepo
    $repo = [string](Resolve-AppRepo $App)
    $checks = New-Object System.Collections.Generic.List[object]
    if ($repo -notmatch $script:AppRepoPattern) {
        $checks.Add((Build-AppWiringCheck 'githubRepo' $false 'No GitHub repository: set githubRepo in apps.json or add an origin remote.'))
    } elseif ($remote -and $field -and $remote -ine $field) {
        $checks.Add((Build-AppWiringCheck 'githubRepo' $false "The origin remote ($remote) differs from githubRepo ($field)."))
    } else {
        $source = if ($remote) { 'origin remote' } else { 'githubRepo field; no origin remote yet' }
        $checks.Add((Build-AppWiringCheck 'githubRepo' $true "$repo ($source)"))
    }
    $hasRepo = $repo -match $script:AppRepoPattern
    $locked = $null -ne $App.manageVisibility -and -not [bool]$App.manageVisibility
    if (-not $hasRepo) { $checks.Add((Build-AppWiringCheck 'visibility' $false 'Make public / Make private need the GitHub repository.')) }
    elseif ($locked) { $checks.Add((Build-AppWiringCheck 'visibility' $false "Locked by manageVisibility:false; Make public / Make private stay off for $repo.")) }
    else { $checks.Add((Build-AppWiringCheck 'visibility' $true "Make public / Make private act on $repo; the label reads its visibility from GitHub.")) }
    $checks.Add((Build-AppWiringCheck 'actionsPage' $hasRepo "Open Actions page opens $(Get-AppActionsUrl $App)."))
    $secretNames = @()
    $wfProfile = Get-AppWorkflowProfile $App
    if ($wfProfile) { $secretNames = @($wfProfile.secrets) }
    $secretDetail = if ($secretNames.Count -gt 0) { "the workflow reads $($secretNames -join ', ')" } else { 'the workflow reads no repository secret' }
    $checks.Add((Build-AppWiringCheck 'actionsSecrets' $hasRepo "Actions secrets... manages $repo ($secretDetail)."))
    return $checks.ToArray()
}

function Get-AppReleaseWiring {
    param($App)
    $workflow = [string]$App.workflow
    if (-not $workflow) { return (Build-AppWiringCheck 'release' $true 'Git-only target: no release workflow, so the release steps stay off.') }
    if (-not [string]$App.tagPrefix) { return (Build-AppWiringCheck 'release' $false "Workflow $workflow has no tagPrefix: Deploy and Release plan cannot name the tag.") }
    $wfProfile = Get-AppWorkflowProfile $App
    if (-not $wfProfile) { return (Build-AppWiringCheck 'release' $false "Workflow file .github/workflows/$workflow was not found in $($App.repoRoot).") }
    # An input the entry passes (a placeholder or a fixed value such as models_release_tag) is wired;
    # one it leaves out makes Trigger workflow fall back to the workflow default.
    $configured = @($App.dispatchInputs | ForEach-Object { [string]$_.name })
    $workflowInputs = @($wfProfile.dispatchInputs | ForEach-Object { $_.name }) + @($wfProfile.unmappedInputs)
    $missing = @($workflowInputs | Where-Object { $configured -notcontains $_ })
    if ($missing.Count -gt 0) { return (Build-AppWiringCheck 'release' $false "Workflow inputs without a dispatchInputs value: $($missing -join ', ').") }
    $branch = if ($App.releaseBranch) { " on $($App.releaseBranch)" } else { '' }
    return (Build-AppWiringCheck 'release' $true "Deploy / Trigger / Release plan / Publish from run use $workflow, tag $($App.tagPrefix)<version>, releases in $(Resolve-ReleaseRepo $App)$branch.")
}

# One line per control family: does the entry give that control what it reads? No network call,
# so Add app can report at once; the visibility label reads GitHub separately.
function Get-AppWiringReport {
    param($App)
    $checks = New-Object System.Collections.Generic.List[object]
    $root = [string]$App.repoRoot
    $hasFolder = $root -and (Test-Path -LiteralPath $root -PathType Container)
    $absent = @([BudaAppRegistry]::MissingFields($App))
    $registryDetail = if ($absent.Count -eq 0) { 'Every field the controls read is present.' } else { "Defaults apply for: $($absent -join ', ')." }
    $checks.Add((Build-AppWiringCheck 'registry' ([bool]$App.name -and [bool]$root) $registryDetail))
    $folderDetail = if ($hasFolder) { "$root (Git, Git ignore..., Agent chat..., bootstrap)" } else { "Project folder does not exist: $root" }
    $checks.Add((Build-AppWiringCheck 'projectFolder' $hasFolder $folderDetail))
    $hasGit = $hasFolder -and (Test-Path -LiteralPath (Join-Path $root '.git'))
    $branch = if ($hasGit) { Get-GitBranch $App } else { $null }
    $gitDetail = if ($branch) { "Git group on branch $branch." }
                 elseif ($hasGit) { 'Git repository without a commit yet: the Git buttons turn on after the first commit (Prepare and stage / Commit and push).' }
                 else { 'Not a Git repository yet: Create private repo, then Preflight / Prepare and stage / Commit and push.' }
    $checks.Add((Build-AppWiringCheck 'git' $hasGit $gitDetail))
    foreach ($check in @(Get-AppRepositoryWiring $App)) { $checks.Add($check) }
    $checks.Add((Get-AppReleaseWiring $App))
    return $checks.ToArray()
}

function Format-AppWiringReport {
    param([object[]]$Report)
    return @($Report | ForEach-Object { '  [{0}] {1}: {2}' -f $(if ($_.ok) { 'ok' } else { '!!' }), $_.area, $_.detail })
}

# The CLI list reply: the registry as each control sees it.
function Get-CockpitTargetList {
    return @($script:AppRegistry.Apps | ForEach-Object {
        $app = $_
        [pscustomobject]@{
            name = $app.name; repoRoot = $app.repoRoot; githubRepo = [string](Resolve-AppRepo $app)
            releaseRepo = [string](Resolve-ReleaseRepo $app); releaseBranch = [string]$app.releaseBranch
            workflow = $app.workflow; tagPrefix = $app.tagPrefix
            manageVisibility = ($null -eq $app.manageVisibility -or [bool]$app.manageVisibility)
            bundles = @($app.bundles | Where-Object { $_ })
            models = @($app.uploadModels | Where-Object { $_ } | ForEach-Object { $_.name })
        }
    })
}
