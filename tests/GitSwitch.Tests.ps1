# Switch branch: from the CLI's git-switch, on temporary repositories (a bare one stands for GitHub). The target is
# fast-forwarded from the remote when that loses nothing, the local changes come along (git switch --merge), an
# untracked file that would be overwritten stops it with nothing changed, and a branch with commits the remote lacks
# is refused.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\GitSwitch.Tests.ps1
#
# The script reruns itself dot-sourced in a fresh STA Windows PowerShell 5.1, the runtime of the exe. The jobs run for
# real, through the same job runner as the window; gh is replaced by a function, so nothing reaches GitHub.
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
function Read-Text { param([string]$Path) [IO.File]::ReadAllText($Path).Replace("`r`n", "`n") }
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

$work = Join-Path $env:TEMP ('instaladorbuda-switch-' + [guid]::NewGuid().ToString('N'))
$form = $null
try {
    # GitHub: a bare repository. A, the cockpit's repository, works on a branch; B moves main on ahead of A's main.
    $origin = Join-Path $work 'origin.git'; $a = Join-Path $work 'A'; $b = Join-Path $work 'B'
    [void](New-Item -ItemType Directory -Path $origin -Force)
    [void](Invoke-TestGit -C $origin init -q --bare)
    [void](Invoke-TestGit -C $origin symbolic-ref HEAD refs/heads/main)
    [void](Invoke-TestGit clone -q $origin $a)
    [void](Invoke-TestGit -C $a symbolic-ref HEAD refs/heads/main)
    [void](Invoke-TestGit -C $a config core.autocrlf false)   # the cockpit's jobs use this repository's setting too
    Write-Text (Join-Path $a 'doc.md') "a`nb`nc`nd`n"; Write-Text (Join-Path $a 'shared.txt') "s1`n"; Write-Text (Join-Path $a 'conflict.txt') "x`n"
    [void](Invoke-TestGit -C $a add -A); [void](Invoke-TestGit -C $a commit -q -m base); [void](Invoke-TestGit -C $a push -q -u origin main)
    [void](Invoke-TestGit -C $a switch -q -c feature)
    Write-Text (Join-Path $a 'other.txt') "f1`n"
    [void](Invoke-TestGit -C $a add -A); [void](Invoke-TestGit -C $a commit -q -m feature); [void](Invoke-TestGit -C $a push -q -u origin feature)
    [void](Invoke-TestGit clone -q $origin $b)
    Write-Text (Join-Path $b 'doc.md') "A`nb`nc`nd`n"; Write-Text (Join-Path $b 'shared.txt') "s2`n"; Write-Text (Join-Path $b 'added.txt') "new on main`n"
    [void](Invoke-TestGit -C $b add -A); [void](Invoke-TestGit -C $b commit -q -m 'main moves on'); [void](Invoke-TestGit -C $b push -q origin main)
    # A's local changes on feature: the last line of doc.md (main changed the first), main's shared.txt as it is, a
    # file of its own, and an untracked added.txt where main has one.
    Write-Text (Join-Path $a 'doc.md') "a`nb`nc`nD`n"; Write-Text (Join-Path $a 'shared.txt') "s2`n"
    Write-Text (Join-Path $a 'notes.txt') "keep me`n"; Write-Text (Join-Path $a 'added.txt') "mine`n"
    Assert-Equal (Get-Branch $a) 'feature' 'fixture: A is on feature'

    # The command builder.
    $cmds = @(Build-GitSwitchCommands $a 'main')
    Assert-That (($cmds -join '|') -match "switch --merge 'main'") 'builder: switch --merge to the branch'
    Assert-That (($cmds -join '|') -match "fetch origin 'main:main'") 'builder: fast-forward the branch from the remote first'
    foreach ($bad in @('..', '-x', 'a b', 'x/', 'a..b', 'x.lock')) {
        $refused = $null
        try { [void](Build-GitSwitchCommands $a $bad) } catch { $refused = $_.Exception.Message }
        Assert-That ([bool]($refused -match 'Not a branch name')) "builder: '$bad' is refused"
    }

    # A window on a registry with only A.
    $registryPath = Join-Path $work 'apps.json'
    $entry = '{ "name": "Repo", "repoRoot": "@@ROOT@@", "tagPrefix": "", "workflow": "", "releaseBranch": "", "versionFromGitTag": "", "uploadScript": null, "models": [], "dispatchInputs": [] }'
    Write-Text $registryPath ("{`r`n  `"apps`": [`r`n    " + $entry.Replace('@@ROOT@@', $a.Replace('\', '\\')) + "`r`n  ],`r`n  `"tasks`": []`r`n}`r`n")
    $AppDir = $work; $cfgFile = $registryPath
    $script:AppRegistry = [BudaAppRegistry]::new($registryPath); $script:Config = $script:AppRegistry.Config; $script:Tasks = @()
    $ReleaseRepo = 'TestOwner/Releases'; $ActionsUrl = 'https://github.com/TestOwner/Global/actions'
    $script:ReleaseVersionCache = @{}; $script:ControlPipeName = 'InstaladorBUDA.SwitchTest'; $HasGit = $true; $HasGh = $true
    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false; $form.Location = New-Object System.Drawing.Point(-4000, -4000); $form.Size = New-Object System.Drawing.Size(900, 900)
    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'; $form.Controls.Add($tabs)
    $guiState = [hashtable]::Synchronized(@{ Tabs = $tabs; Form = $form; JobCounter = 0; CliConfirmed = $false })
    $tabs.Tag = $guiState
    $tabs.TabPages.Add((New-JobTab -Tabs $tabs -Number 1))
    $form.Show(); [System.Windows.Forms.Application]::DoEvents()
    $tab = $tabs.TabPages[0].Tag; $c = $tab.Controls
    Assert-That ([bool]$c.Buttons.GitSwitch -and $c.Buttons.GitSwitch.Enabled) 'window: Switch branch... is there and on'
    Assert-That ($c.Buttons.GitSwitch.Parent -eq $c.Buttons.GitPull.Parent) 'window: it sits in the Git group'
    Assert-That ((Get-CockpitHelp).data.actions -contains 'git-switch') 'help: git-switch is listed'

    $refused = $null
    try { [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-switch'; session = '1'; gitBranch = 'main' })) } catch { $refused = $_.Exception.Message }
    Assert-That ([bool]($refused -match 'confirm:true')) 'CLI: without confirm:true it is refused'
    $refused = $null
    try { [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-switch'; session = '1'; confirm = $true })) } catch { $refused = $_.Exception.Message }
    Assert-That ([bool]($refused -match 'gitBranch')) 'CLI: without gitBranch it is refused'

    $reply = Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-switch'; session = '1'; gitBranch = 'main'; dryRun = $true })
    Assert-That ($reply.ok -and (($tab.LastCommands -join '|') -match 'switch --merge')) 'dry run: the commands are shown'
    Assert-Equal (Get-Branch $a) 'feature' 'dry run: nothing switched'

    # For real, with an untracked added.txt where main has one: refused, nothing changed.
    $c.DryRun.Checked = $false
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-switch'; session = '1'; gitBranch = 'main'; confirm = $true }))
    Assert-That (Wait-TabJob $tab) 'untracked in the way: the job finished'
    Assert-That ($tab.LastExitCode -ne 0) 'untracked in the way: the job failed'
    Assert-Equal (Get-Branch $a) 'feature' 'untracked in the way: still on feature'
    Assert-Equal (Read-Text (Join-Path $a 'doc.md')) "a`nb`nc`nD`n" 'untracked in the way: the local doc is untouched'
    Assert-Equal (Read-Text (Join-Path $a 'added.txt')) "mine`n" 'untracked in the way: the untracked file is untouched'

    # Without it: on main, main fast-forwarded to the remote, the local changes kept.
    Remove-Item (Join-Path $a 'added.txt')
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-switch'; session = '1'; gitBranch = 'main'; confirm = $true }))
    Assert-That (Wait-TabJob $tab) 'switch: the job finished'
    Assert-Equal $tab.LastExitCode 0 'switch: the job ended with exit code 0'
    Assert-Equal (Get-Branch $a) 'main' 'switch: on main'
    Assert-Equal (Invoke-TestGit -C $a rev-parse main | Select-Object -First 1) (Invoke-TestGit -C $a rev-parse origin/main | Select-Object -First 1) 'switch: main is the remote main (fast-forwarded)'
    Assert-Equal (Read-Text (Join-Path $a 'doc.md')) "A`nb`nc`nD`n" 'switch: main''s line and the local line, merged'
    Assert-Equal (Read-Text (Join-Path $a 'added.txt')) "new on main`n" 'switch: main''s new file is there'
    Assert-Equal (Read-Text (Join-Path $a 'notes.txt')) "keep me`n" 'switch: the untracked file is kept'
    Assert-Equal ((Invoke-TestGit -C $a status --porcelain) -join ',') ' M doc.md,?? notes.txt' 'switch: only the real local change is left'

    # A local change that cannot merge: switched, the file named, the step failed for Resolve conflicts.
    [void](Invoke-TestGit -C $a add -- doc.md); [void](Invoke-TestGit -C $a commit -q -m 'doc on main'); [void](Invoke-TestGit -C $a push -q origin main)
    [void](Invoke-TestGit -C $b fetch -q origin); [void](Invoke-TestGit -C $b switch -q main); [void](Invoke-TestGit -C $b merge -q --ff-only origin/main)
    Write-Text (Join-Path $b 'conflict.txt') "x-main`n"; [void](Invoke-TestGit -C $b add -A); [void](Invoke-TestGit -C $b commit -q -m 'main changes conflict.txt'); [void](Invoke-TestGit -C $b push -q origin main)
    [void](Invoke-TestGit -C $a switch -q -c topic)
    Write-Text (Join-Path $a 'conflict.txt') "x-local`n"
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-switch'; session = '1'; gitBranch = 'main'; confirm = $true }))
    Assert-That (Wait-TabJob $tab) 'conflict: the job finished'
    Assert-That ($tab.LastExitCode -ne 0) 'conflict: the step failed'
    Assert-That ([bool]($c.Log.Text -match 'conflicts to settle with Resolve conflicts: conflict.txt')) 'conflict: the file is named in the log'
    Assert-Equal (Get-Branch $a) 'main' 'conflict: switched to main'
    Assert-That ((Read-Text (Join-Path $a 'conflict.txt')) -match '<<<<<<<') 'conflict: the markers are there to settle'
    Write-Text (Join-Path $a 'conflict.txt') "x-main`n"; [void](Invoke-TestGit -C $a add -- conflict.txt)
    [void](Invoke-TestGit -C $a commit -q -m 'settled'); [void](Invoke-TestGit -C $a push -q origin main)

    # A branch with a commit the remote lacks: refused, still on main.
    [void](Invoke-TestGit -C $a branch side main)
    [void](Invoke-TestGit -C $a fetch -q origin)
    [void](Invoke-TestGit -C $b fetch -q origin); [void](Invoke-TestGit -C $b switch -q -c side origin/main)
    Write-Text (Join-Path $b 'side.txt') "b`n"; [void](Invoke-TestGit -C $b add -A); [void](Invoke-TestGit -C $b commit -q -m 'b side'); [void](Invoke-TestGit -C $b push -q -u origin side)
    $tree = Invoke-TestGit -C $a rev-parse 'main^{tree}' | Select-Object -First 1
    $mine = Invoke-TestGit -C $a commit-tree $tree -p main -m 'a side' | Select-Object -First 1
    [void](Invoke-TestGit -C $a update-ref refs/heads/side $mine)
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-switch'; session = '1'; gitBranch = 'side'; confirm = $true }))
    Assert-That (Wait-TabJob $tab) 'diverged: the job finished'
    Assert-That ($tab.LastExitCode -ne 0) 'diverged: the job failed'
    Assert-That ([bool]($c.Log.Text -match 'not a fast-forward')) 'diverged: the log says why'
    Assert-Equal (Get-Branch $a) 'main' 'diverged: still on main'
    Assert-Equal (Invoke-TestGit -C $a rev-parse side | Select-Object -First 1) $mine 'diverged: the local commit is kept'
} finally {
    if ($form) { $form.Close(); $form.Dispose() }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "Switch checks: $testPassed passed, $($testFailures.Count) failed"
if ($testFailures.Count) { exit 1 }
exit 0
