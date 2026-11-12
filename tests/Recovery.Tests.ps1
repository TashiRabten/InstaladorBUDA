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


$calls = New-Object System.Collections.Generic.List[string]
$ghState = @{ Api = 0; Active = $false; Body = ''; Sha = ('a'*40); PrState = 'OPEN' }
function gh {
    $line = $args -join ' '; $calls.Add($line); $global:LASTEXITCODE = 0
    if ($line -like 'api *') { $ghState.Api++; $attempt = if ($ghState.Api -eq 1) { 1 } else { 2 }; $status = if ($ghState.Active) { 'in_progress' } else { 'completed' }; return (@{run_attempt=$attempt;status=$status}|ConvertTo-Json) }
    if ($line -like 'pr view *') { return (@{state=$ghState.PrState;isDraft=$false;headRefOid=$ghState.Sha;url='https://example.test/pr/7';title='Test PR'}|ConvertTo-Json) }
    if ($line -like 'pr create *') { $index=[array]::IndexOf($args,'--body-file'); $ghState.Body=[IO.File]::ReadAllText($args[$index+1]) }
    if ($line -like 'repo view *') { return 'PRIVATE' }
    if ($line -like 'release list*' -or $line -like 'run list*') { return '[]' }
}
function Start-Sleep { [CmdletBinding(SupportsShouldProcess)] param($Seconds) if ($PSCmdlet.ShouldProcess('test clock','Skip waiting')) { return } }
$commands = Build-RerunCommands 'Owner/Repo' '42' $true
& ([scriptblock]::Create(($commands -join "`n")))
Assert-That ([bool]($calls -match '^run rerun 42 --repo Owner/Repo --failed$')) 'failed-only retry uses selected run'
Assert-That ($ghState.Api -ge 2) 'retry waits for a new attempt'
Assert-That ([bool]($calls -match '^run watch 42 .*--exit-status')) 'retry follows result of selected run'
$calls.Clear(); $ghState.Active=$true; $ghState.Api=0
try { & ([scriptblock]::Create(((Build-RerunCommands 'Owner/Repo' '42') -join "`n"))); Assert-That $false 'active run refused' } catch { Assert-That $true 'active run refused' }
Assert-That (-not [bool]($calls -match '^run rerun')) 'active run is never resubmitted'
$ghState.Active=$false
$body="First line`nSecond line 'quoted' and literal `$()"
& ([scriptblock]::Create(((Build-CreatePrCommands 'Owner/Repo' 'main' 'feature/test' "Title 'quoted'" $body) -join "`n")))
Assert-Equal $ghState.Body $body 'multiline PR body preserved through a temporary body file'
& ([scriptblock]::Create(((Build-MergePrCommands 'Owner/Repo' '7') -join "`n")))
Assert-That ([bool]($calls -match ('--match-head-commit '+$ghState.Sha))) 'merge pins the inspected head commit'
Assert-That (-not [bool]($calls -match '--admin|--delete-branch')) 'merge preserves normal repository checks and branches'
$calls.Clear()
& ([scriptblock]::Create(((Build-ClosePrCommands 'Owner/Repo' '7') -join "`n")))
Assert-That ([bool]($calls -match '^pr close 7 --repo Owner/Repo$')) 'close closes the selected PR'
Assert-That (-not [bool]($calls -match '--delete-branch')) 'close keeps the branch'
$calls.Clear(); $ghState.PrState = 'MERGED'
try { & ([scriptblock]::Create(((Build-ClosePrCommands 'Owner/Repo' '7') -join "`n"))); Assert-That $false 'close refuses a PR that is not open' } catch { Assert-That $true 'close refuses a PR that is not open' }
Assert-That (-not [bool]($calls -match '^pr close')) 'a merged or closed PR is never closed again'
$ghState.PrState = 'OPEN'
foreach ($bad in @('0','-1','42;bad')) {
    try { Build-RerunCommands 'Owner/Repo' $bad | Out-Null; Assert-That $false "bad run ID rejected: $bad" } catch { Assert-That $true "bad run ID rejected: $bad" }
    try { Build-ClosePrCommands 'Owner/Repo' $bad | Out-Null; Assert-That $false "bad PR number rejected: $bad" } catch { Assert-That $true "bad PR number rejected: $bad" }
}
try { Build-CreatePrCommands 'Owner/Repo' main main title body | Out-Null; Assert-That $false 'same branch refused' } catch { Assert-That $true 'same branch refused' }

# The GUI and CLI share the visible fields; preview-only requests cannot mutate GitHub.
$AppDir = $testRoot; $HasGit=$true; $HasGh=$true
$script:AppRegistry = [BudaAppRegistry]::new((Join-Path $testRoot 'apps.json'))
$script:Config = $script:AppRegistry.Config
$script:Tasks=@()
$ReleaseRepo="TestOwner/Releases"
$form=New-Object System.Windows.Forms.Form
$form.StartPosition="Manual"; $form.Location=New-Object System.Drawing.Point(-4000,-4000)
$form.Size=New-Object System.Drawing.Size(900,900)
$form.ShowInTaskbar=$false
$tabs=New-Object System.Windows.Forms.TabControl
$tabs.Dock='Fill'; $form.Controls.Add($tabs)
$state=[hashtable]::Synchronized(@{Tabs=$tabs;Form=$form;CliConfirmed=$false})
$tabs.Tag=$state
$tabs.TabPages.Add((New-JobTab -Tabs $tabs -Number 1))
$form.Show(); [System.Windows.Forms.Application]::DoEvents()
$reply=Invoke-CockpitRequest $state ([pscustomobject]@{command='action';action='pr-create';session=1;dryRun=$true;prBase='main';prHead='feature/test';prTitle='Preview title';prBody=$body})
Assert-That $reply.ok 'CLI create PR reaches visible control'
$tab=$tabs.TabPages[0].Tag
Assert-That ([bool](($tab.LastCommands -join "`n") -match 'gh pr create')) 'GUI builds PR create job in dry run'
Assert-Equal $tab.Controls.PrBody.Text ($body.Replace("`n","`r`n")) 'CLI populates visible PR body'
Assert-That ($null -ne (Get-PullRequestButton $tab.Controls 'PrClose')) 'the Pull requests section has a Close PR button'
$reply=Invoke-CockpitRequest $state ([pscustomobject]@{command='action';action='pr-close';session=1;dryRun=$true;prNumber='7'})
Assert-That $reply.ok 'CLI close PR reaches visible control'
Assert-That ([bool](($tab.LastCommands -join "`n") -match 'gh pr close')) 'GUI builds PR close job in dry run'
Assert-Equal $tab.Controls.PrNumber.Text '7' 'CLI populates visible PR number'
$tab.LoadedRuns=@([pscustomobject]@{databaseId=42;status='completed';conclusion='failure'})
[void]$tab.Controls.Run.Items.Add('Failed run'); $tab.Controls.Run.SelectedIndex=0
$reply=Invoke-CockpitRequest $state ([pscustomobject]@{command='action';action='rerun';session=1;runId='42';dryRun=$true})
Assert-That $reply.ok 'CLI retry reaches visible control'
Assert-That ([bool](($tab.LastCommands -join "`n") -match 'gh run rerun')) 'GUI retry command generated'
$tab.LastJob=@{Commands=@('Write-Output retry-ok');Label='Local failed job';Root=(Get-App $tab.Controls.Target.SelectedItem).repoRoot;FollowUp=@()};$tab.LastExitCode=1
$reply=Invoke-CockpitRequest $state ([pscustomobject]@{command='action';action='retry-last-job';session=1;dryRun=$true})
Assert-That ($tab.LastCommands[0] -eq 'Write-Output retry-ok') 'last failed local job can be retried'
$pathBefore=$env:PATH; $dryBefore=$tab.Controls.DryRun.Checked
$tab.Controls.DryRun.Checked=$false; $tab.CliConfirmed=$true
try {
    $env:PATH=''
    try { & $tab.StartJob @('Write-Output unused') 'Test failed process launch' $false $testRoot } catch { $launchError=$_.Exception.Message }
    Assert-That (-not $tab.IsRunning) 'failed process start releases session for retry'
    Assert-That ($tab.LastExitCode -eq -1) 'failed process start is recorded as failure'
} finally { $env:PATH=$pathBefore; $tab.CliConfirmed=$false; $tab.Controls.DryRun.Checked=$dryBefore }
# Render the actual PR group for layout review.
$group=$tab.Controls.PrBase.Parent
$bitmap=New-Object System.Drawing.Bitmap($group.Width,$group.Height)
$group.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)))
$bitmap.Save((Join-Path $env:TEMP 'InstaladorBUDA-pr-preview.png'));$bitmap.Dispose()
$form.Close();$form.Dispose()
Write-Output "Recovery checks: $testPassed passed, $($testFailures.Count) failed"
if ($testFailures.Count) { exit 1 }
exit 0
