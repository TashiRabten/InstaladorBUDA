# Unstage: the paths in the Add field leave the next commit and their files stay as they are, from the
# window's button and from the CLI's git-unstage, on a temporary repository.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\GitUnstage.Tests.ps1
#
# The script reruns itself dot-sourced in a fresh STA Windows PowerShell 5.1, the runtime of the exe:
# the GUI handlers are .GetNewClosure() blocks, and those see only functions defined at global scope,
# as in the exe. The jobs run for real, through the same job runner as the window; gh is replaced by a
# function, so nothing reaches GitHub.
param([switch]$Inner)

if (-not $Inner) {
    $self = $MyInvocation.MyCommand.Path
    # The inner run ends with exit, which ends that powershell.exe with the result.
    $command = ". '{0}' -Inner" -f $self.Replace("'", "''")
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -Command $command
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Load the cockpit as the exe does: the registry class, then the modules the entrypoint loads.
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

# Read-only stand-in for the GitHub CLI: a function wins over gh.exe in command lookup.
function gh {
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -match '^repo view') { return 'PRIVATE' }
    return ''
}

# git writes progress to stderr; under 'Stop' Windows PowerShell 5.1 would turn that into an error.
function Invoke-TestGit {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return @(& git.exe @args 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $old }
}
function Get-StagedPaths { param([string]$Root) @(Invoke-TestGit -C $Root -c core.quotepath=false diff --cached --name-only) }
function Get-TextHash { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

# The job runner reads the process output on a WinForms Timer, so the test pumps messages while it waits.
function Wait-TabJob {
    param($Tab, [int]$TimeoutSeconds = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($Tab.IsRunning -and [DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    return (-not $Tab.IsRunning)
}

$work = Join-Path $env:TEMP ('instaladorbuda-unstage-' + [guid]::NewGuid().ToString('N'))
$form = $null
try {
    # A commit, then the next commit's work staged with ".": a changed file, a new file, and two that
    # should not go (a backup, and a name with spaces).
    $repo = Join-Path $work 'Repo'
    [void](New-Item -ItemType Directory -Path $repo -Force)
    [void](Invoke-TestGit -C $repo init -q)
    [void](Invoke-TestGit -C $repo symbolic-ref HEAD refs/heads/main)
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'), "first`r`n")
    [void](Invoke-TestGit -C $repo add -- tracked.txt)
    [void](Invoke-TestGit -C $repo -c user.name=Test -c user.email=test@example.invalid commit -q -m 'Initial commit')
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'), "second`r`n")
    [IO.File]::WriteAllText((Join-Path $repo 'new.ps1'), "Write-Output new`r`n")
    [IO.File]::WriteAllText((Join-Path $repo 'notes.bak'), "backup`r`n")
    [IO.File]::WriteAllText((Join-Path $repo 'Shortcut (2).lnk'), 'link')
    [void](Invoke-TestGit -C $repo add -- .)
    $hashBak = Get-TextHash (Join-Path $repo 'notes.bak')
    $hashLink = Get-TextHash (Join-Path $repo 'Shortcut (2).lnk')
    Assert-Equal ((Get-StagedPaths $repo) -join ',') 'Shortcut (2).lnk,new.ps1,notes.bak,tracked.txt' 'fixture: four paths staged'

    # The command builders.
    $app = [pscustomobject]@{ name = 'Repo'; repoRoot = $repo }
    $expected = "git -C $(Quote-PS $repo) restore --staged -- $(Quote-PS 'notes.bak') $(Quote-PS 'Shortcut (2).lnk')"
    Assert-Equal ((Build-GitUnstageCommands $app 'notes.bak "Shortcut (2).lnk"') -join '|') $expected 'builder: one restore --staged line, a quoted span kept whole'
    Assert-Equal ((Build-GitAddCommands $app 'a.txt') -join '|') "git -C $(Quote-PS $repo) add -- $(Quote-PS 'a.txt')" 'builder: Add builds the same command as before'
    Assert-Equal @(Build-GitUnstageCommands $app '   ').Count 0 'builder: an empty field builds nothing'

    # A window with one session, on a registry with only the temporary repository.
    $registryPath = Join-Path $work 'apps.json'
    $entry = '{ "name": "Repo", "repoRoot": "@@ROOT@@", "tagPrefix": "", "workflow": "", "releaseBranch": "", "versionFromGitTag": "", "uploadScript": null, "models": [], "dispatchInputs": [] }'
    $registryText = "{`r`n  `"apps`": [`r`n    " + $entry.Replace('@@ROOT@@', $repo.Replace('\', '\\')) + "`r`n  ],`r`n  `"tasks`": []`r`n}`r`n"
    [IO.File]::WriteAllText($registryPath, $registryText, (New-Object System.Text.UTF8Encoding($false)))
    $AppDir = $work
    $cfgFile = $registryPath
    $script:AppRegistry = [BudaAppRegistry]::new($registryPath)
    $script:Config = $script:AppRegistry.Config
    $script:Tasks = @()
    $ReleaseRepo = 'TestOwner/Releases'
    $ActionsUrl = 'https://github.com/TestOwner/Global/actions'
    $script:ReleaseVersionCache = @{}
    $script:ControlPipeName = 'InstaladorBUDA.UnstageTest'
    $HasGit = $true
    $HasGh = $true

    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.Size = New-Object System.Drawing.Size(900, 900)
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $form.Controls.Add($tabs)
    $guiState = [hashtable]::Synchronized(@{ Tabs = $tabs; Form = $form; JobCounter = 0; CliConfirmed = $false })
    $tabs.Tag = $guiState
    $tabs.TabPages.Add((New-JobTab -Tabs $tabs -Number 1))
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $tab = $tabs.TabPages[0].Tag
    $c = $tab.Controls
    Assert-Equal $c.Target.SelectedItem 'Repo' 'window: the temporary repository is the target'
    Assert-That $c.Buttons.GitUnstage.Enabled 'window: Unstage is on for a repository with a branch'
    Assert-That ($c.Buttons.GitUnstage.Parent -eq $c.Buttons.GitAdd.Parent) 'window: Unstage sits in the Git group, beside Add'
    Assert-That ((Get-CockpitHelp).data.actions -contains 'git-unstage') 'help: git-unstage is listed'

    # The CLI: no confirmation, no change; a dry run fills the field and shows the command only.
    $refused = $null
    try { [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-unstage'; session = '1'; gitPaths = 'notes.bak' })) }
    catch { $refused = $_.Exception.Message }
    Assert-That ([bool]($refused -match 'confirm:true')) 'CLI: git-unstage without confirm:true is refused'
    $reply = Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-unstage'; session = '1'; gitPaths = 'notes.bak "Shortcut (2).lnk"'; dryRun = $true })
    Assert-That $reply.ok 'CLI: a dry run reaches the visible Unstage button'
    Assert-Equal $c.GitAdd.Text 'notes.bak "Shortcut (2).lnk"' 'CLI: gitPaths fills the visible Add field'
    Assert-Equal ($tab.LastCommands -join '|') $expected 'CLI: the job holds the restore --staged command'
    Assert-Equal (Get-StagedPaths $repo).Count 4 'dry run: nothing left the index'
    # The git actions share one lookup in the CLI; the others still reach their own buttons.
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-add'; session = '1'; gitPaths = 'new.ps1'; dryRun = $true }))
    Assert-Equal ($tab.LastCommands -join '|') "git -C $(Quote-PS $repo) add -- $(Quote-PS 'new.ps1')" 'CLI: git-add still reaches the Add button'
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-status'; session = '1'; dryRun = $true }))
    Assert-That ([bool](($tab.LastCommands -join '|') -match ' status$')) 'CLI: git-status still reaches the Status button'

    # The CLI for real: the two named paths leave the index, their files stay.
    $c.DryRun.Checked = $false
    $reply = Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'git-unstage'; session = '1'; gitPaths = 'notes.bak "Shortcut (2).lnk"'; confirm = $true })
    Assert-That $reply.ok 'CLI: git-unstage with confirm:true is accepted'
    Assert-That (Wait-TabJob $tab) 'CLI: the job finished'
    Assert-Equal $tab.LastExitCode 0 'CLI: the job ended with exit code 0'
    Assert-Equal ((Get-StagedPaths $repo) -join ',') 'new.ps1,tracked.txt' 'CLI: only the named paths left the index'
    Assert-Equal (Get-TextHash (Join-Path $repo 'notes.bak')) $hashBak 'CLI: the backup on disk is untouched'
    Assert-Equal (Get-TextHash (Join-Path $repo 'Shortcut (2).lnk')) $hashLink 'CLI: the file with spaces on disk is untouched'
    $short = Invoke-TestGit -C $repo -c core.quotepath=false status --short
    Assert-That ([bool]($short -contains '?? notes.bak')) 'CLI: a new file that left the index is untracked again'
    Assert-That ([bool]($c.Log.Text -match 'restore --staged')) 'CLI: the visible log shows the command'

    # The button: a changed tracked file leaves the index and keeps its change on disk.
    $c.GitAdd.Text = 'tracked.txt'
    $tab.CliConfirmed = $true   # answers the Yes/No dialog, as a CLI request with confirm:true does
    try { $c.Buttons.GitUnstage.PerformClick() } finally { $tab.CliConfirmed = $false }
    Assert-That (Wait-TabJob $tab) 'button: the job finished'
    Assert-Equal $tab.LastExitCode 0 'button: the job ended with exit code 0'
    Assert-Equal ((Get-StagedPaths $repo) -join ',') 'new.ps1' 'button: the changed file left the index'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $repo 'tracked.txt'))) "second`r`n" 'button: its change is still on disk'
    Assert-Equal ((Invoke-TestGit -C $repo diff --name-only) -join ',') 'tracked.txt' 'button: the change is unstaged, not lost'

    # An empty field explains what to type and runs nothing.
    $c.GitAdd.Text = ''
    $before = $tab.LastCommands
    $c.Buttons.GitUnstage.PerformClick()
    Assert-That ([bool]($c.Log.Text -match 'Type what to unstage first')) 'button: an empty field says what to type'
    Assert-That ([object]::ReferenceEquals($before, $tab.LastCommands)) 'button: an empty field runs nothing'
} finally {
    if ($form) { $form.Close(); $form.Dispose() }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "Unstage checks: $testPassed passed, $($testFailures.Count) failed"
if ($testFailures.Count) { exit 1 }
exit 0
