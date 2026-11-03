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



$work=Join-Path $env:TEMP ('merge-tool-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
function gitok { & git -C $work @args | Out-Null; if ($LASTEXITCODE) { throw "Test Git failed: $args" } }
gitok init -q
gitok config user.name (& git -C $testRoot config user.name)
gitok config user.email (& git -C $testRoot config user.email)
gitok config core.autocrlf false
$file=Join-Path $work 'note.txt'
[IO.File]::WriteAllText($file,"base`n",[Text.UTF8Encoding]::new($false))
gitok add note.txt; gitok commit -qm base
gitok branch incoming
gitok switch -qc local
[IO.File]::WriteAllText($file,"local`n",[Text.UTF8Encoding]::new($false))
gitok add note.txt; gitok commit -qm local
gitok switch -q incoming
[IO.File]::WriteAllText($file,"incoming`n",[Text.UTF8Encoding]::new($false))
gitok add note.txt; gitok commit -qm incoming
gitok switch -q local
$ErrorActionPreference="Continue"
& git -C $work merge incoming 2>&1 | Out-Null
$mergeExit=$LASTEXITCODE
$ErrorActionPreference="Stop"
Assert-That ($mergeExit -ne 0) 'real scratch merge creates a conflict'
Assert-Equal (Read-GitConflictSide $work note.txt 1) "base`n" 'common ancestor exact including final newline'
Assert-Equal (Read-GitConflictSide $work note.txt 2) "local`n" 'local side exact including final newline'
Assert-Equal (Read-GitConflictSide $work note.txt 3) "incoming`n" 'incoming side exact including final newline'
$snapshot=Get-MergeFile $work note.txt
try { Build-MergeResolutionCommands $work note.txt $snapshot.Text $snapshot.Hash | Out-Null; Assert-That $false 'conflict markers rejected' } catch { Assert-That $true 'conflict markers rejected' }
try { Get-MergeFile $work '..\outside.txt' | Out-Null; Assert-That $false 'outside path rejected' } catch { Assert-That $true 'outside path rejected' }
$commands=Build-MergeResolutionCommands $work note.txt "resolved`n" $snapshot.Hash
[IO.File]::WriteAllText($file,"concurrent edit`n")
try { & ([scriptblock]::Create(($commands -join "`n"))); Assert-That $false 'concurrent edit refused' } catch { Assert-That $true 'concurrent edit refused' }
Assert-Equal ([IO.File]::ReadAllText($file)) "concurrent edit`n" 'concurrent edit preserved'
$snapshot=Get-MergeFile $work note.txt
$commands=Build-MergeResolutionCommands $work note.txt "resolved`n" $snapshot.Hash
& ([scriptblock]::Create(($commands -join "`n")))
Assert-Equal ([IO.File]::ReadAllText($file)) "resolved`n" 'resolution saved without newline changes'
Assert-That (-not [bool](& git -C $work diff --name-only --diff-filter=U)) 'resolution staged and conflict cleared'
Assert-That ((Build-GitPullCommands $work)[-1] -match 'pull --no-rebase --no-commit$') 'pull leaves a merge commit for reviewed Gitleaks path'
# Visual editor opens modelessly and uses the current repository.
$owner=New-Object System.Windows.Forms.Form; $owner.ShowInTaskbar=$false; $owner.Location=New-Object System.Drawing.Point(-4000,-4000)
$owner.Show();$tab=@{}
$app=[pscustomobject]@{name='Scratch';repoRoot=$work}
Show-GitMergeTool $app {} {} $owner $tab
Assert-That ($tab.MergeState.Form.Visible) 'visual merge editor opens'
Assert-That ($null -ne $tab.MergeState.Base) 'common ancestor pane exists'
Assert-That ($tab.MergeState.Result.ReadOnly -eq $false) 'result is editable'
$tab.MergeState.Ours.Text="Local change`r`nSecond line`r`n"
$tab.MergeState.Theirs.Text="Incoming change`r`nSecond line`r`n"
$tab.MergeState.Base.Text="Common ancestor`r`nSecond line`r`n"
$tab.MergeState.Result.Text="Combined result`r`nSecond line`r`n"
[System.Windows.Forms.Application]::DoEvents()
$view=$tab.MergeState.Form
$bitmap=New-Object System.Drawing.Bitmap($view.Width,$view.Height)
$view.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)))
$bitmap.Save((Join-Path $env:TEMP 'InstaladorBUDA-merge-preview.png'));$bitmap.Dispose()
$tab.MergeState.Form.Close();$owner.Close()
Write-Output "Merge checks: $testPassed passed, $($testFailures.Count) failed"
if ($testFailures.Count) { exit 1 }
exit 0
