# Add app: the registry entry, the wiring check, and the GUI and CLI add paths end to end.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\AddApp.Tests.ps1
#
# The script reruns itself dot-sourced in a fresh STA Windows PowerShell 5.1, the runtime of the
# exe: the GUI handlers are .GetNewClosure() blocks, and those see only functions defined at global
# scope, as in the exe. Everything is written to a temporary folder; gh is replaced by a function
# that answers the read-only calls (visibility, release list), so nothing reaches GitHub.
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

# ── Load the cockpit as the exe does: the registry class, then the modules the entrypoint loads ──
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
$fakeGh = @{ Visibility = 'PRIVATE'; Calls = New-Object System.Collections.Generic.List[string] }
function gh {
    $line = $args -join ' '
    $fakeGh.Calls.Add($line)
    $global:LASTEXITCODE = 0
    if ($line -match '^repo view \S+ --json visibility') { return $fakeGh.Visibility }
    if ($line -match '^release list') { return '[]' }
    return ''
}

function Initialize-TestRepository {
    param([string]$Path, [string]$Remote)
    [void](New-Item -ItemType Directory -Path $Path -Force)
    & git -C $Path init -q
    & git -C $Path symbolic-ref HEAD refs/heads/main
    & git -C $Path -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m 'Initial commit'
    if ($Remote) { & git -C $Path remote add origin "https://github.com/$Remote.git" }
}

function Write-TestFile {
    param([string]$Path, [string]$Text)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$releaseWorkflow = @'
name: Build installers
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Version (x.y.z)"
        required: true
      publish:
        type: boolean
        default: false
      release_notes:
        required: false
  push:
    tags:
      - 'novoapp-v*'   # release tags

env:
  RELEASE_REPO: TestOwner/Releases
  RELEASE_BRANCH: novo-app

jobs:
  build:
    runs-on: windows-latest
    steps:
      - run: echo "${{ secrets.GH_PAT }} ${{ secrets.GITHUB_TOKEN }} ${{ secrets.OCR_TOKEN }}"
'@

$work = Join-Path $env:TEMP ('instaladorbuda-addapp-' + [guid]::NewGuid().ToString('N'))
$form = $null
try {
    # ── Fixtures ──
    $existing = Join-Path $work 'Existente'
    $novo = Join-Path $work 'NovoApp'
    $gitOnly = Join-Path $work 'SoGit'
    Initialize-TestRepository $existing 'TestOwner/Existente'
    Initialize-TestRepository $novo 'TestOwner/NovoApp'
    Initialize-TestRepository $gitOnly ''
    Write-TestFile (Join-Path $novo '.github\workflows\build-app-installers.yml') $releaseWorkflow
    Write-TestFile (Join-Path $novo '.github\workflows\ci.yml') "on:`n  push:`n    branches: [main]`n"
    $existingBlock = @'
    {
      "name": "Existente",
      "repoRoot": "@@ROOT@@",
      "tagPrefix": "",
      "workflow": "",
      "releaseBranch": "",
      "versionFromGitTag": "",
      "uploadScript": null,
      "models": [],
      "dispatchInputs": []
    }
'@.Replace('@@ROOT@@', $existing.Replace('\', '\\'))
    $registryPath = Join-Path $work 'apps.json'
    Write-TestFile $registryPath ("{`r`n  `"_comment`": `"kept as written`",`r`n  `"apps`": [`r`n" + $existingBlock + "  ],`r`n  `"tasks`": []`r`n}`r`n")

    $AppDir = $work
    $cfgFile = $registryPath
    $script:AppRegistry = [BudaAppRegistry]::new($registryPath)
    $script:Config = $script:AppRegistry.Config
    $script:Tasks = @()
    $ReleaseRepo = 'TestOwner/DefaultReleases'
    $ActionsUrl = 'https://github.com/TestOwner/Global/actions'
    $script:ReleaseVersionCache = @{}
    $script:ControlPipeName = 'InstaladorBUDA.Test'
    $HasGit = $true
    $HasGh = $true

    # ── Release workflow parsing ──
    $wf = Read-AppWorkflowProfile (Join-Path $novo '.github\workflows\build-app-installers.yml')
    Assert-Equal $wf.tagPrefix 'novoapp-v' 'workflow: tag prefix from push tags'
    Assert-Equal $wf.versionFromGitTag 'novoapp-v*' 'workflow: version tag glob'
    Assert-Equal (@($wf.dispatchInputs | ForEach-Object { "$($_.name)=$($_.value)" }) -join ',') 'version={version},publish={publish},release_notes={notes}' 'workflow: dispatch inputs mapped'
    Assert-Equal $wf.releaseRepo 'TestOwner/Releases' 'workflow: RELEASE_REPO'
    Assert-Equal $wf.releaseBranch 'novo-app' 'workflow: RELEASE_BRANCH'
    Assert-Equal ($wf.secrets -join ',') 'GH_PAT,OCR_TOKEN' 'workflow: secrets read, without GITHUB_TOKEN'
    $inlinePath = Join-Path $work 'wf\inline.yml'
    Write-TestFile $inlinePath "on:`n  workflow_dispatch:`n    inputs:`n      version:`n        required: true`n      flavor:`n        required: true`n  push:`n    tags: ['v*']`nenv:`n  RELEASE_TARGET: site`n"
    $inline = Read-AppWorkflowProfile $inlinePath
    Assert-Equal $inline.tagPrefix 'v' 'workflow: inline tag list'
    Assert-Equal ($inline.unmappedInputs -join ',') 'flavor' 'workflow: an input the cockpit cannot fill is reported'
    Assert-Equal $inline.releaseBranch 'site' 'workflow: RELEASE_TARGET counts as the release branch'
    $rangePath = Join-Path $work 'wf\range.yml'
    Write-TestFile $rangePath "on:`n  push:`n    tags:`n      - `"legendas-v[0-9]*`"`n"
    Assert-Equal (Read-AppWorkflowProfile $rangePath).versionFromGitTag 'legendas-v*' 'workflow: character-class tag pattern'
    Assert-Equal (Find-AppReleaseWorkflow $novo) 'build-app-installers.yml' 'workflow: build-app-installers.yml is preferred'
    Assert-Equal (Find-AppReleaseWorkflow $gitOnly) '' 'workflow: none in a Git-only project'

    # ── The entry Add app writes ──
    $entry = Build-AppRegistryEntry -Name 'NovoApp' -RepoRoot $novo -GitHubRepo 'TestOwner/NovoApp'
    Assert-Equal (@([BudaAppRegistry]::MissingFields($entry)).Count) 0 'entry: every required field present'
    Assert-That ($entry.manageVisibility -eq $true) 'entry: visibility toggle on'
    Assert-Equal $entry.githubRepo 'TestOwner/NovoApp' 'entry: own repository'
    Assert-Equal $entry.releaseRepo 'TestOwner/Releases' 'entry: release repository from the workflow'
    Assert-Equal $entry.workflow 'build-app-installers.yml' 'entry: workflow'
    Assert-That ($entry.versionFromReleaseTag -eq $true) 'entry: version read from published releases'
    $gitOnlyEntry = Build-AppRegistryEntry -Name 'SoGit' -RepoRoot $gitOnly -GitHubRepo 'TestOwner/SoGit'
    Assert-Equal "$($gitOnlyEntry.workflow)|$($gitOnlyEntry.tagPrefix)|$(@($gitOnlyEntry.dispatchInputs).Count)" '||0' 'entry: Git-only has no release fields'
    Assert-Equal $gitOnlyEntry.releaseRepo 'TestOwner/SoGit' 'entry: Git-only releases default to its own repository'
    Assert-Equal (Resolve-AppRepo $gitOnlyEntry) 'TestOwner/SoGit' 'repo: githubRepo before the first push'
    $nested = Join-Path $novo 'sub'
    [void](New-Item -ItemType Directory -Path $nested -Force)
    Assert-Equal (Resolve-AppRepo ([pscustomobject]@{ repoRoot = $nested; githubRepo = 'TestOwner/Sub' })) 'TestOwner/Sub' 'repo: a folder inside another repository keeps its own githubRepo'
    Assert-Equal (Get-AppActionsUrl $entry) 'https://github.com/TestOwner/NovoApp/actions/workflows/build-app-installers.yml' 'actions page: the app repository'
    $locked = [pscustomobject]@{ name = 'Old'; repoRoot = $novo; githubRepo = 'TestOwner/NovoApp'; manageVisibility = $false; workflow = ''; tagPrefix = '' }
    Assert-That (-not (@(Get-AppWiringReport $locked) | Where-Object { $_.area -eq 'visibility' }).ok) 'wiring: manageVisibility:false is reported'

    # ── Registry writes ──
    $before = [IO.File]::ReadAllText($registryPath)
    $partial = [pscustomobject]@{ name = 'Partial'; repoRoot = $novo; githubRepo = 'TestOwner/Partial' }
    $partialError = ''
    try { [void]$script:AppRegistry.Add($partial) } catch { $partialError = $_.Exception.Message }
    Assert-That ($partialError -match 'missing: releaseRepo, manageVisibility') 'registry: an incomplete entry is rejected'
    Assert-That ([IO.File]::ReadAllText($registryPath) -ceq $before) 'registry: a rejected entry leaves apps.json unchanged'

    # ── GUI and CLI: two sessions in a shown (off-screen) window ──
    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.Size = New-Object System.Drawing.Size(900, 900)
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $form.Controls.Add($tabs)
    [void]$tabs.Handle
    $guiState = [hashtable]::Synchronized(@{ Tabs = $tabs; Form = $form; JobCounter = 0; CliConfirmed = $false })
    $tabs.Tag = $guiState
    foreach ($number in 1..2) { $tabs.TabPages.Add((New-JobTab -Tabs $tabs -Number $number)) }
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    # CLI add-app with a release workflow.
    $reply = Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'add-app'; session = '1'; name = 'NovoApp'; repoRoot = $novo; githubRepo = 'TestOwner/NovoApp' })
    Assert-That ([bool]$reply.ok) 'cli add-app: ok'
    Assert-That ([bool]$reply.data.fullyWired) "cli add-app: fully wired ($(@($reply.data.wiring | Where-Object { -not $_.ok } | ForEach-Object { $_.area }) -join ','))"
    Assert-Equal (@($reply.data.wiring | ForEach-Object { $_.area }) -join ',') 'registry,projectFolder,git,githubRepo,visibility,actionsPage,actionsSecrets,release' 'cli add-app: wiring covers every control family'
    Assert-Equal $reply.data.entry.dispatchInputs.Count 3 'cli add-app: reply carries the entry'
    $written = @(([IO.File]::ReadAllText($registryPath) | ConvertFrom-Json).apps | Where-Object { $_.name -eq 'NovoApp' })
    Assert-Equal $written.Count 1 'apps.json: NovoApp written once'
    Assert-Equal (@([BudaAppRegistry]::MissingFields($written[0])).Count) 0 'apps.json: NovoApp has every required field'
    Assert-That ([IO.File]::ReadAllText($registryPath).Contains($existingBlock)) 'apps.json: the existing entry is kept byte for byte'
    $one = $tabs.TabPages[0].Tag.Controls
    $two = $tabs.TabPages[1].Tag.Controls
    Assert-That ($two.Target.Items.Contains('NovoApp')) 'gui: the new target appears in the other session'
    Assert-Equal $one.Target.SelectedItem 'NovoApp' 'gui: the new target is selected'
    Assert-Equal $one.Visibility.Text 'currently: private' 'visibility: read from GitHub'
    Assert-That ($one.Buttons.MakePublic.Enabled -and $one.Buttons.MakePrivate.Enabled) 'visibility: Make public / Make private enabled'
    Assert-That ($one.Buttons.Deploy.Enabled -and $one.Buttons.Dispatch.Enabled -and $one.Buttons.ReleasePlan.Enabled) 'release: steps enabled'
    Assert-That ($one.Buttons.GitStatus.Enabled -and $one.Buttons.Actions.Enabled) 'git and Actions page enabled'
    $status = Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'status'; session = '1' })
    $session = @($status.data.sessions)[0]
    Assert-Equal "$($session.visibility)|$($session.visibilityRepo)|$($session.visibilityToggle)" 'currently: private|TestOwner/NovoApp|True' 'cli status: visibility, its repository and the toggle'
    $listed = @((Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'list' })).data.targets | Where-Object { $_.name -eq 'NovoApp' })
    Assert-Equal "$($listed[0].githubRepo)|$($listed[0].releaseRepo)|$($listed[0].manageVisibility)|$(@($listed[0].bundles).Count)" 'TestOwner/NovoApp|TestOwner/Releases|True|0' 'cli list: repository fields, no null bundles'
    [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'action'; action = 'make-public'; session = '1'; dryRun = $true }))
    Assert-That ($one.Log.Text.Contains("gh repo edit 'TestOwner/NovoApp' --visibility public")) 'visibility: the toggle targets the app repository (dry run)'
    $one.DryRun.Checked = $false

    # GUI Add app button with a Git-only project, in the second session.
    $tabs.SelectedTab = $tabs.TabPages[1]
    $two.BootstrapName.Text = 'SoGit'; $two.BootstrapRoot.Text = $gitOnly; $two.BootstrapRepo.Text = 'TestOwner/SoGit'
    Expand-CollapsibleSectionsFor $two.Buttons.AddApp
    [System.Windows.Forms.Application]::DoEvents()
    $two.Buttons.AddApp.PerformClick()
    $gitOnlyState = $tabs.TabPages[1].Tag
    Assert-Equal $gitOnlyState.LastAddedApp 'SoGit' 'gui add app: registered'
    Assert-Equal @($gitOnlyState.LastAddedWiring | Where-Object { -not $_.ok }).Count 0 'gui add app: fully wired'
    $soGit = Get-App 'SoGit'
    Assert-Equal "$($soGit.githubRepo)|$($soGit.releaseRepo)|$($soGit.manageVisibility)|$($soGit.workflow)" 'TestOwner/SoGit|TestOwner/SoGit|True|' 'gui add app: Git-only entry'
    Assert-Equal $two.Visibility.Text 'currently: private' 'gui add app: visibility read before the first push'
    Assert-That ($two.Buttons.MakePublic.Enabled -and -not $two.Buttons.Deploy.Enabled) 'gui add app: toggle on, release steps off'
    Assert-That ($one.Target.Items.Contains('SoGit')) 'gui add app: the first session sees it too'
    Assert-That ($two.Log.Text.Contains('[ok] visibility')) 'gui add app: the log shows the wiring check'

    # A second add with the same name changes nothing.
    $beforeDuplicate = [IO.File]::ReadAllText($registryPath)
    $duplicateError = ''
    try { [void](Invoke-CockpitRequest $guiState ([pscustomobject]@{ command = 'add-app'; session = '1'; name = 'NovoApp'; repoRoot = $novo; githubRepo = 'TestOwner/NovoApp' })) }
    catch { $duplicateError = $_.Exception.Message }
    Assert-That ($duplicateError -match 'already registered') 'cli add-app: a duplicate name is refused'
    Assert-That ([IO.File]::ReadAllText($registryPath) -ceq $beforeDuplicate) 'cli add-app: a refused duplicate leaves apps.json unchanged'
    Assert-That (-not ($fakeGh.Calls | Where-Object { $_ -match '^repo edit|^repo create|^secret set' })) 'no GitHub change was attempted'

    # ── The real ScanBUDA entry (read-only; skipped on a machine without the checkout) ──
    $realRegistry = Join-Path $testRoot 'apps.json'
    $scan = ([BudaAppRegistry]::new($realRegistry)).Get('ScanBUDA')
    if ($scan -and (Test-Path -LiteralPath ([string]$scan.repoRoot) -PathType Container)) {
        $scanReport = @(Get-AppWiringReport $scan)
        Assert-Equal (@($scanReport | Where-Object { -not $_.ok } | ForEach-Object { "$($_.area): $($_.detail)" }) -join ' / ') '' 'ScanBUDA: every control wired'
        Assert-Equal (Resolve-AppRepo $scan) 'TashiRabten/ScanBUDA' 'ScanBUDA: visibility acts on its own repository'
        Assert-Equal (Get-AppActionsUrl $scan) 'https://github.com/TashiRabten/ScanBUDA/actions/workflows/build-app-installers.yml' 'ScanBUDA: Actions page'
    } else { Write-Output 'skip ScanBUDA checks: no ScanBUDA checkout on this machine' }
} catch {
    $testFailures.Add("unexpected error: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)")
    Write-Output "FAIL unexpected error: $($_.Exception.Message)"
    Write-Output $_.InvocationInfo.PositionMessage
} finally {
    if ($form) { $form.Close(); $form.Dispose() }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("{0} passed, {1} failed" -f $testPassed, $testFailures.Count)
exit [int]($testFailures.Count -gt 0)
