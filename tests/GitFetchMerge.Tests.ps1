param([switch]$Inner)

if (-not $Inner) {
    $self = $MyInvocation.MyCommand.Path
    $command = ". '{0}' -Inner" -f $self.Replace("'", "''")
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -Command $command
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $testRoot 'modules\AppRegistry.psm1'))))
$entrypoint = [IO.File]::ReadAllText((Join-Path $testRoot 'InstaladorBUDA.ps1'))
foreach ($moduleMatch in [regex]::Matches($entrypoint, "Join-Path \`$AppDir '(modules\\[^']+\.ps1)'")) {
    . (Join-Path $testRoot $moduleMatch.Groups[1].Value)
}
function Get-App { param([string]$Name) $script:AppRegistry.Get($Name) }

$testPassed = 0
$testFailures = New-Object System.Collections.Generic.List[string]
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:testPassed++; Write-Output "ok   $Name" }
    else { $script:testFailures.Add($Name); Write-Output "FAIL $Name" }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    Assert-That ([string]$Actual -ceq [string]$Expected) "$Name (expected '$Expected', got '$Actual')"
}
function gh { $global:LASTEXITCODE = 0; return '' }
function Invoke-TestGit {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return @(& git.exe -c user.name=Test -c user.email=test@example.invalid -c core.autocrlf=false @args 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $old }
}
function Write-Text { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }
function Read-Text { param([string]$Path) [IO.File]::ReadAllText($Path) }
function Get-Branch { param([string]$Root) (Invoke-TestGit -C $Root branch --show-current | Select-Object -First 1) }
function Wait-TabJob {
    param($Tab, [int]$TimeoutSeconds = 90)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($Tab.IsRunning -and [DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    return (-not $Tab.IsRunning)
}

$work = Join-Path $env:TEMP ('instaladorbuda-fetch-merge-' + [guid]::NewGuid().ToString('N'))
$form = $null
try {
    $origin = Join-Path $work 'origin.git'; $a = Join-Path $work 'A'; $b = Join-Path $work 'B'
    [void](New-Item -ItemType Directory -Path $origin -Force)
    [void](Invoke-TestGit -C $origin init -q --bare)
    [void](Invoke-TestGit -C $origin symbolic-ref HEAD refs/heads/main)
    [void](Invoke-TestGit clone -q $origin $a)
    Write-Text (Join-Path $a 'doc.md') "base`n"
    [void](Invoke-TestGit -C $a add -A); [void](Invoke-TestGit -C $a commit -q -m base); [void](Invoke-TestGit -C $a push -q -u origin main)
    [void](Invoke-TestGit clone -q $origin $b)
    Write-Text (Join-Path $b 'remote.txt') "remote`n"
    [void](Invoke-TestGit -C $b add -A); [void](Invoke-TestGit -C $b commit -q -m remote); [void](Invoke-TestGit -C $b push -q origin main)

    $registryPath = Join-Path $work 'apps.json'
    $entry = '{ "name": "Repo", "repoRoot": "@@ROOT@@", "tagPrefix": "", "workflow": "", "releaseBranch": "", "versionFromGitTag": "", "uploadScript": null, "models": [], "dispatchInputs": [] }'
    Write-Text $registryPath ('{"apps":[' + $entry.Replace('@@ROOT@@', $a.Replace('\', '\\')) + '],"tasks":[]}')
    $AppDir = $work; $cfgFile = $registryPath
    $script:AppRegistry = [BudaAppRegistry]::new($registryPath); $script:Config = $script:AppRegistry.Config; $script:Tasks = @()
    $ReleaseRepo = 'TestOwner/Releases'; $ActionsUrl = 'https://github.com/TestOwner/Global/actions'
    $script:ReleaseVersionCache = @{}; $script:ControlPipeName = 'InstaladorBUDA.FetchMergeTest'; $HasGit = $true; $HasGh = $true
    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false; $form.Location = New-Object System.Drawing.Point(-4000, -4000); $form.Size = New-Object System.Drawing.Size(900, 900)
    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'; $form.Controls.Add($tabs)
    $guiState = [hashtable]::Synchronized(@{ Tabs = $tabs; Form = $form; JobCounter = 0; CliConfirmed = $false })
    $tabs.Tag = $guiState
    $tabs.TabPages.Add((New-JobTab -Tabs $tabs -Number 1))
    $form.Show(); [System.Windows.Forms.Application]::DoEvents()
    $tab = $tabs.TabPages[0].Tag; $c = $tab.Controls
    foreach ($action in @('git-fetch','git-merge','git-fast-forward')) {
        Assert-That ((Get-CockpitHelp).data.actions -contains $action) "help: $action is listed"
        $refused = $null
        try { [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action'; action=$action; session='1'; gitRef='origin/main'})) } catch { $refused=$_.Exception.Message }
        Assert-That ([bool]($refused -match 'confirm:true')) "$action needs confirmation"
    }
    Assert-That ([bool]$c.Buttons.GitFetch -and $c.Buttons.GitFetch.Enabled) 'Fetch button available'
    Assert-That ([bool]$c.Buttons.GitMerge -and $c.Buttons.GitMerge.Enabled) 'Merge button available'
    Assert-That ([bool]$c.Buttons.GitFastForward -and $c.Buttons.GitFastForward.Enabled) 'Fast-forward button available'
    foreach ($bad in @('', '-x', 'a b', 'a..b', 'x.lock', 'x/', 'origin/main;echo')) {
        $refused=$null
        try { [void](Build-GitMergeCommands $a $bad) } catch { $refused=$_.Exception.Message }
        Assert-That ([bool]($refused -match 'Not a commit')) "invalid reference refused: $bad"
    }
    $before=Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-fetch';session='1';dryRun=$true}))
    Assert-Equal (Invoke-TestGit -C $a rev-parse origin/main | Select-Object -First 1) $before 'dry fetch leaves references unchanged'
    Write-Text (Join-Path $a 'local.txt') "preserve`n"
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-fetch';session='1';dryRun=$false;confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'fetch completes'
    Assert-Equal $tab.LastExitCode 0 'fetch succeeds with local changes'
    Assert-Equal (Read-Text (Join-Path $a 'local.txt')) "preserve`n" 'fetch preserves local work'
    Assert-Equal (Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1) $before 'fetch preserves HEAD'
    Assert-That (-not (Test-Path (Join-Path $a 'remote.txt'))) 'fetch does not populate worktree'
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-merge';session='1';gitRef='origin/main';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'dirty merge finishes'
    Assert-That ($tab.LastExitCode -ne 0) 'dirty merge is refused'
    Assert-Equal (Read-Text (Join-Path $a 'local.txt')) "preserve`n" 'dirty merge preserves local work'
    Move-Item -LiteralPath (Join-Path $a 'local.txt') -Destination (Join-Path $work 'local-kept.txt')
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-merge';session='1';gitRef='origin/main';dryRun=$true}))
    Assert-Equal (Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1) $before 'dry merge preserves HEAD'
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-merge';session='1';gitRef='origin/main';dryRun=$false;confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'fast-forward completes'
    Assert-Equal $tab.LastExitCode 0 'fast-forward succeeds'
    Assert-Equal ((Read-Text (Join-Path $a 'remote.txt')).TrimEnd()) 'remote' 'merged file available'
    Write-Text (Join-Path $b 'doc.md') "remote change`n"
    [void](Invoke-TestGit -C $b add -A); [void](Invoke-TestGit -C $b commit -q -m next); [void](Invoke-TestGit -C $b push -q origin main)
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-fetch';session='1';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'fetch next fast-forward completes'
    Write-Text (Join-Path $a 'doc.md') "local change`n"
    $before=Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-fast-forward';session='1';gitRef='origin/main';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'overlapping fast-forward finishes'
    Assert-That ($tab.LastExitCode -ne 0) 'overlapping fast-forward is refused'
    Assert-Equal (Read-Text (Join-Path $a 'doc.md')) "local change`n" 'overlapping local work is preserved'
    Assert-Equal (Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1) $before 'overlap preserves HEAD'
    Write-Text (Join-Path $a 'doc.md') "base`n"
    Write-Text (Join-Path $a 'notes.txt') "keep notes`n"
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-fast-forward';session='1';gitRef='origin/main';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'dirty fast-forward finishes'
    Assert-Equal $tab.LastExitCode 0 'dirty fast-forward succeeds with unrelated local work'
    Assert-Equal (Read-Text (Join-Path $a 'notes.txt')) "keep notes`n" 'unrelated local work is preserved'
    Assert-Equal ((Read-Text (Join-Path $a 'doc.md')).TrimEnd()) 'remote change' 'fast-forward updates tracked content'
    Move-Item -LiteralPath (Join-Path $a 'notes.txt') -Destination (Join-Path $work 'notes-kept.txt')
    Write-Text (Join-Path $a 'a.txt') "a`n"; [void](Invoke-TestGit -C $a add -A); [void](Invoke-TestGit -C $a commit -q -m local)
    Write-Text (Join-Path $b 'b.txt') "b`n"; [void](Invoke-TestGit -C $b add -A); [void](Invoke-TestGit -C $b commit -q -m incoming); [void](Invoke-TestGit -C $b push -q origin main)
    $before=Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-fetch';session='1';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'second fetch completes'
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-fast-forward';session='1';gitRef='origin/main';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'divergent fast-forward finishes'
    Assert-That ($tab.LastExitCode -ne 0) 'divergent fast-forward is refused'
    Assert-Equal (Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1) $before 'divergence preserves HEAD'
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-merge';session='1';gitRef='origin/main';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'divergent merge completes'
    Assert-Equal $tab.LastExitCode 0 'divergent merge succeeds'
    Assert-Equal (Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1) $before 'divergent merge remains uncommitted'
    Assert-That ([bool](Invoke-TestGit -C $a rev-parse -q --verify MERGE_HEAD)) 'merge ready for review'
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='git-merge';session='1';gitRef='origin/main';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'repeat merge finishes'
    Assert-That ($tab.LastExitCode -ne 0) 'existing merge is refused'
    Assert-That ((Get-CockpitHelp).data.actions -contains 'merge-quit') 'help: merge-quit is listed'
    Assert-That ($null -ne $c.Buttons.GitMergeQuit) 'Git group has a standalone Forget merge button'
    Assert-That ([bool]$c.Buttons.GitMergeQuit.Enabled) 'Forget merge button is available for a Git target'
    $refused=$null
    try { [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='merge-quit';session='1'})) } catch { $refused=$_.Exception.Message }
    Assert-That ([bool]($refused -match 'confirm:true')) 'merge-quit needs confirmation'
    $mergeFile=Read-Text (Join-Path $a 'doc.md')
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{command='action';action='merge-quit';session='1';confirm=$true}))
    Assert-That (Wait-TabJob $tab) 'forget merge finishes'
    Assert-Equal $tab.LastExitCode 0 'forget merge succeeds'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $a '.git\MERGE_HEAD'))) 'forget merge clears merge state'
    Assert-Equal (Invoke-TestGit -C $a rev-parse HEAD | Select-Object -First 1) $before 'forget merge preserves HEAD'
    Assert-Equal (Read-Text (Join-Path $a 'doc.md')) $mergeFile 'forget merge preserves working files'
} finally {
    if ($form) { $form.Close(); $form.Dispose() }
}
Write-Output "Fetch/merge checks: $testPassed passed, $($testFailures.Count) failed"
Write-Output "Temporary fixtures retained: $work"
if ($testFailures.Count) { exit 1 }
exit 0
