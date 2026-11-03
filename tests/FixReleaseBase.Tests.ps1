param([string]$ModuleRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'))
# The release base when its tag is missing from the clone (a release made by Trigger, which tags only the release
# repository): the tag from GitHub, else the commit of the build that uploaded the release's installer, tagged in
# the clone only. git and gh are fakes that record every call; nothing reaches a network.

$ErrorActionPreference = 'Stop'
$passed = 0
$failed = 0
function Assert-FixBase {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:passed++; Write-Output "ok $Message" }
    else { $script:failed++; Write-Output "FAIL $Message" }
}
$UI = @{}
foreach ($name in @('FixInbox.ps1', 'FixReview.ps1', 'FixPullRequest.ps1', 'FixInboxGui.ps1', 'ReleaseOperations.ps1')) {
    . (Join-Path $ModuleRoot $name)
}
$ReleaseRepo = 'TashiRabten/GlossarioBUDA'
$Sha = '7de9e1889e04cba0428731f83963c8dcffc47c8f'
$Build = @{ databaseId = 41488762753; headSha = $Sha; createdAt = '2026-11-02T17:11:24Z'; updatedAt = '2026-11-02T17:18:30Z' }
$Older = @{ databaseId = 41100000000; headSha = ('b' * 40); createdAt = '2026-10-27T08:52:15Z'; updatedAt = '2026-10-27T09:10:00Z' }

# What the fake clone and GitHub hold.
function Initialize-FixBaseWorld {
    param([bool]$LocalTag = $false, [bool]$RemoteTag = $false, [bool]$HasCommit = $false, [object[]]$Runs = @($Build, $Older),
        [object[]]$Assets = @(@{ name = 'ScanBUDA-1.0.16.exe'; updatedAt = '2026-11-02T17:17:15Z' }, @{ name = 'ScanBUDA-1.0.16-arm64.pkg'; updatedAt = '2026-11-02T17:16:00Z' }))
    $script:world = @{ LocalTag = $LocalTag; RemoteTag = $RemoteTag; HasCommit = $HasCommit; TaggedAt = ''; Runs = $Runs; Assets = $Assets
        Git = New-Object System.Collections.Generic.List[string]; Gh = New-Object System.Collections.Generic.List[string] }
}

function Get-FixBaseAnswer { param([int]$Code = 0, [string]$Out = '', [string]$Err = '') return [pscustomobject]@{ ExitCode = $Code; Output = $Out; Error = $Err } }

function Invoke-FixGit {
    param([string[]]$Arguments, [switch]$PumpUi)
    $line = $Arguments -join ' '
    $script:world.Git.Add($line)
    switch -Regex ($line) {
        'rev-parse --verify --quiet refs/tags/\S+\^\{commit\}$' { if ($script:world.LocalTag) { return (Get-FixBaseAnswer -Out "$Sha`n") }; return (Get-FixBaseAnswer -Code 1) }
        'rev-parse --verify --quiet ([0-9a-f]{40})\^\{commit\}$' { if ($script:world.HasCommit) { return (Get-FixBaseAnswer -Out "$($Matches[1])`n") }; return (Get-FixBaseAnswer -Code 1) }
        'fetch --no-tags origin \+refs/tags/' { if ($script:world.RemoteTag) { $script:world.LocalTag = $true; return (Get-FixBaseAnswer) }; return (Get-FixBaseAnswer -Code 128 -Err "fatal: couldn't find remote ref") }
        'cat-file -e \S+\^\{commit\}$' { if ($script:world.HasCommit) { return (Get-FixBaseAnswer) }; return (Get-FixBaseAnswer -Code 1) }
        'fetch --no-tags origin [0-9a-f]{40}$' { $script:world.HasCommit = $true; return (Get-FixBaseAnswer) }
        ' tag \S+ ([0-9a-f]{40})$' { $script:world.LocalTag = $true; $script:world.TaggedAt = $Matches[1]; return (Get-FixBaseAnswer) }
        'remote get-url origin$' { return (Get-FixBaseAnswer -Out "https://github.com/TashiRabten/TradutorBUDA.git`n") }
        default { return (Get-FixBaseAnswer) }
    }
}

function Invoke-FixGh {
    param([string[]]$Arguments)
    $line = $Arguments -join ' '
    $script:world.Gh.Add($line)
    if ($line -match '^release view ') { return (Get-FixBaseAnswer -Out (ConvertTo-Json -InputObject @{ assets = @($script:world.Assets) } -Depth 4)) }
    if ($line -match '^run list ') { return (Get-FixBaseAnswer -Out (ConvertTo-Json -InputObject @($script:world.Runs) -Depth 4)) }
    return (Get-FixBaseAnswer -Code 1 -Err "unexpected gh call: $line")
}

function Get-FixBaseRefusal {
    param($Settings, $Entry, [string]$Version)
    try { Initialize-FixReleaseWorktree $Settings $Entry $Version | Out-Null; return '' } catch { return $_.Exception.Message }
}

function Test-FixBaseTagPresent {
    param($Settings, $Scan)
    Initialize-FixBaseWorld -LocalTag $true
    $release = Initialize-FixReleaseWorktree $Settings $Scan '1.0.16'
    Assert-FixBase ($release.Commit -eq $Sha -and -not $release.TagNote) 'a tag in the clone is used as before'
    Assert-FixBase ($script:world.Gh.Count -eq 0 -and -not ($script:world.Git -match 'fetch')) 'with the tag there, nothing is fetched or asked of GitHub'

    Initialize-FixBaseWorld -RemoteTag $true
    $release = Initialize-FixReleaseWorktree $Settings $Scan '1.0.16'
    Assert-FixBase ($release.TagNote -match 'veio do GitHub' -and $script:world.Gh.Count -eq 0) 'a tag pushed from another machine is fetched, not looked up'
    Assert-FixBase (-not $script:world.TaggedAt) 'a fetched tag is not created again'
}

function Test-FixBaseFromBuild {
    param($Settings, $Scan)
    Initialize-FixBaseWorld
    $release = Initialize-FixReleaseWorktree $Settings $Scan '1.0.16'
    Assert-FixBase ($script:world.TaggedAt -eq $Sha -and $release.Commit -eq $Sha) 'the tag is created at the commit of the build that uploaded the installer'
    Assert-FixBase ($release.TagNote -match '41488762753' -and $release.TagNote -match 'sem push') 'the log names the build and says nothing was pushed'
    Assert-FixBase (-not ($script:world.Git -match '(^|\s)push(\s|$)')) 'nothing is pushed, so no build starts'
    Assert-FixBase (@($script:world.Git -match "fetch --no-tags origin $Sha$").Count -eq 1) 'a commit missing from the clone is fetched by its hash'
    Assert-FixBase ($script:world.Gh[0] -match '^release view scanbuda-v1\.0\.16 --repo TashiRabten/GlossarioBUDA ') 'the release is read from the release repository'
    Assert-FixBase ($script:world.Gh[1] -match '^run list --repo TashiRabten/ScanBUDA --workflow build-app-installers\.yml ') 'the builds are read from the app repository and its workflow'

    Initialize-FixBaseWorld -HasCommit $true
    [void](Initialize-FixReleaseWorktree $Settings $Scan '1.0.16')
    Assert-FixBase (-not ($script:world.Git -match "fetch --no-tags origin $Sha$") -and $script:world.TaggedAt -eq $Sha) 'a commit already in the clone is tagged without fetching'

    Initialize-FixBaseWorld -Runs @(@{ databaseId = 1; headSha = $Sha; createdAt = '2026-11-02T17:17:15Z'; updatedAt = '2026-11-02T17:17:15Z' })
    [void](Initialize-FixReleaseWorktree $Settings $Scan '1.0.16')
    Assert-FixBase ($script:world.TaggedAt -eq $Sha) 'an upload at the very edge of the run still belongs to it'
}

function Test-FixBaseRefusals {
    param($Settings, $Scan)
    Initialize-FixBaseWorld -Runs @($Build, @{ databaseId = 2; headSha = ('c' * 40); createdAt = '2026-11-02T17:12:00Z'; updatedAt = '2026-11-02T17:20:00Z' })
    $refusal = Get-FixBaseRefusal $Settings $Scan '1.0.16'
    Assert-FixBase ($refusal -match '2 execu' -and $refusal -match 'exatamente uma' -and -not $script:world.TaggedAt) 'two builds running at the upload: refused, nothing tagged'

    Initialize-FixBaseWorld -Runs @($Older)
    $refusal = Get-FixBaseRefusal $Settings $Scan '1.0.16'
    Assert-FixBase ($refusal -match '0 execu' -and -not $script:world.TaggedAt) 'no build running at the upload: refused, nothing tagged'

    Initialize-FixBaseWorld -Assets @(@{ name = 'ScanBUDA-1.0.16-arm64.pkg'; updatedAt = '2026-11-02T17:16:00Z' })
    $refusal = Get-FixBaseRefusal $Settings $Scan '1.0.16'
    Assert-FixBase ($refusal -match '\.exe' -and -not $script:world.TaggedAt) 'a release without a Windows installer: refused'

    Initialize-FixBaseWorld -Runs @($Build, @{ databaseId = 3; headSha = ('d' * 40); createdAt = '2026-11-02T18:00:00Z'; updatedAt = '2026-11-02T18:30:00Z' }) `
        -Assets @(@{ name = 'ScanBUDA-1.0.16.exe'; updatedAt = '2026-11-02T17:17:15Z' }, @{ name = 'ScanBUDA-1.0.16-setup.exe'; updatedAt = '2026-11-02T18:10:00Z' })
    $refusal = Get-FixBaseRefusal $Settings $Scan '1.0.16'
    Assert-FixBase ($refusal -match 'um .nico commit' -and -not $script:world.TaggedAt) 'installers from two commits: refused'
    Assert-FixBase ($refusal -match '^A base scanbuda-v1\.0\.16 n') 'every refusal still starts by naming the missing base'
}

function Test-FixBaseOtherApps {
    param($Settings, $Repo)
    $tradutor = [pscustomobject]@{ name = 'TradutorBUDA'; tagPrefix = 'tradutor-buda-v'; repoRoot = $Repo; workflow = 'build-app-installers.yml' }
    Initialize-FixBaseWorld -Assets @(@{ name = 'TradutorBUDA-1.8.11.exe'; updatedAt = '2026-11-02T17:16:39Z' }) `
        -Runs @(@{ databaseId = 41488727193; headSha = $Sha; createdAt = '2026-11-02T17:11:10Z'; updatedAt = '2026-11-02T17:17:00Z' })
    $release = Initialize-FixReleaseWorktree $Settings $tradutor '1.8.11'
    Assert-FixBase ($script:world.Gh[0] -match '--repo TashiRabten/GlossarioBUDA ' -and $script:world.Gh[1] -match '--repo TashiRabten/TradutorBUDA ') 'without githubRepo or releaseRepo: the default release repository and the clone origin'
    Assert-FixBase ($release.Tag -eq 'tradutor-buda-v1.8.11' -and $script:world.TaggedAt -eq $Sha) 'TradutorBUDA gets its tag the same way'

    $suite = [pscustomobject]@{ name = 'SuiteBUDA'; tagPrefix = 'suitebuda-v'; repoRoot = $Repo; githubRepo = 'TashiRabten/SuiteBUDA'; workflow = 'build-suitebuda-installer.yml'; suggestionBaseCommit = ('e' * 40) }
    Initialize-FixBaseWorld
    $refusal = Get-FixBaseRefusal $Settings $suite '0.0.0'
    Assert-FixBase ($refusal -match 'n.o existe neste reposit' -and $script:world.Gh.Count -eq 0 -and -not ($script:world.Git -match 'fetch')) 'a configured initial commit is never looked up or fetched'
}

function Test-FixBaseTimes {
    $utc = ConvertTo-FixUtc '2026-11-02T17:17:15Z'
    Assert-FixBase ($utc.Kind -eq [DateTimeKind]::Utc -and $utc.Hour -eq 17 -and $utc.Second -eq 15) 'ISO times from gh are read as UTC'
    $local = [datetime]::SpecifyKind([datetime]'2026-11-02 11:17:15', [DateTimeKind]::Local)
    Assert-FixBase ((ConvertTo-FixUtc $local) -eq $local.ToUniversalTime()) 'DateTime values (PowerShell 7) are turned to UTC'
}

$work = Join-Path $env:TEMP ('fixbase-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $repo = Join-Path $work 'repo'
    [void](New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force)
    $settings = [pscustomobject]@{ worktreeRoot = (Join-Path $work 'worktrees') }
    $scan = [pscustomobject]@{ name = 'ScanBUDA'; tagPrefix = 'scanbuda-v'; repoRoot = $repo; githubRepo = 'TashiRabten/ScanBUDA'; releaseRepo = 'TashiRabten/GlossarioBUDA'; workflow = 'build-app-installers.yml' }
    $steps = [ordered]@{ TagPresent = { Test-FixBaseTagPresent $settings $scan }; FromBuild = { Test-FixBaseFromBuild $settings $scan }
        Refusals = { Test-FixBaseRefusals $settings $scan }; OtherApps = { Test-FixBaseOtherApps $settings $repo }; Times = { Test-FixBaseTimes } }
    foreach ($step in $steps.GetEnumerator()) {
        try { & $step.Value } catch { Assert-FixBase $false "$($step.Key) stopped: $($_.Exception.Message)" }
    }
} finally {
    $target = [IO.Path]::GetFullPath($work)
    if ($target.StartsWith([IO.Path]::GetFullPath($env:TEMP), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Output "$passed passed, $failed failed"
exit [int]($failed -gt 0)
