# Argument construction only: profiles stay in memory and no agent process is started.
param([switch]$Inner)

if (-not $Inner) {
    $self = $MyInvocation.MyCommand.Path
    $command = ". '{0}' -Inner" -f $self.Replace("'", "''")
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -Command $command
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in @('CodeCli.ps1', 'AgentProfiles.ps1', 'AgentTerminal.ps1')) {
    . (Join-Path $testRoot ('modules\' + $module))
}

$testPassed = 0
$testFailures = New-Object System.Collections.Generic.List[string]
function Assert-Profile {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:testPassed++; Write-Output "ok   $Name" }
    else { $script:testFailures.Add($Name); Write-Output "FAIL $Name" }
}
function Assert-ProfileEqual {
    param([string]$Actual, [string]$Expected, [string]$Name)
    Assert-Profile ($Actual -ceq $Expected) "$Name (expected '$Expected', got '$Actual')"
}

foreach ($command in @('codex', 'codex.exe', 'codex.cmd', 'C:\Program Files\Agent\codex.exe', '"C:\Program Files\Agent\codex.cmd"')) {
    $profile = New-CodeCliAgentProfile -Command $command -Arguments 'exec -'
    Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) '--disable apps exec --dangerously-bypass-approvals-and-sandbox -' 'existing command forms disable account applications before exec'
    Assert-ProfileEqual $profile.Arguments 'exec -' 'building a command leaves the saved argument field unchanged'
}

foreach ($permission in @('full', 'edit', 'read')) {
    $expectedFlags = @{
        full = '--dangerously-bypass-approvals-and-sandbox'
        edit = '--sandbox workspace-write'
        read = '--sandbox read-only'
    }
    $profile = New-CodeCliAgentProfile -Command 'codex' -Arguments 'exec --json -' -Permission $permission -Model 'fixture-model'
    $expected = '--disable apps exec ' + $expectedFlags[$permission] + ' -m "fixture-model" --json -'
    Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) $expected 'permission, model, structured output and stdin survive the default'
    Assert-ProfileEqual (Get-CodeCliTerminalArguments $profile) ($expectedFlags[$permission] + ' -m "fixture-model"') 'interactive terminal keeps only permission and model'
}

$custom = 'exec --sandbox read-only -m "custom-model" --json -c mcp_servers.fixture.command="fixture.exe" -'
$profile = New-CodeCliAgentProfile -Command 'codex' -Arguments $custom -Permission full -Model 'ignored-model'
Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) ('--disable apps ' + $custom) 'explicit permissions and model plus local server configuration remain unchanged'

$profile = New-CodeCliAgentProfile -Command 'codex' -Arguments 'exec resume --last --json -' -Permission read
Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) '--disable apps exec --sandbox read-only resume --last --json -' 'continued sessions retain their command and stdin'

$overrides = @(
    '--enable apps', '--enable=apps', '--disable apps', '--disable=apps',
    '--enable "apps"', '--enable="apps"', '--disable "apps"', '--disable="apps"',
    '-c features.apps=true', '-c features.apps=false',
    '-c "features.apps=true"', '-c "features.apps=false"',
    '--config features.apps=true', '--config features.apps=false',
    '--config=features.apps=true', '--config=features.apps=false',
    '--config "features.apps=true"', '--config="features.apps=false"'
)
foreach ($override in $overrides) {
    foreach ($arguments in @(
        ($override + ' exec --sandbox read-only -'),
        ('exec --sandbox read-only ' + $override + ' -')
    )) {
        $profile = New-CodeCliAgentProfile -Command 'codex' -Arguments $arguments
        Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) $arguments ('explicit account setting wins: ' + $override)
    }
}

foreach ($option in @('--enable memory', '--disable apps_extra', '-c features.apps_extra=true', '--config features.memory=true')) {
    $arguments = 'exec --sandbox read-only ' + $option + ' -'
    $profile = New-CodeCliAgentProfile -Command 'codex' -Arguments $arguments
    Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) ('--disable apps ' + $arguments) 'unrelated feature settings do not override the account default'
}

foreach ($arguments in @(
    'exec --sandbox read-only -c "custom=text --enable apps" -',
    'exec --sandbox read-only -- "--enable apps"',
    'exec --sandbox read-only -- --enable apps'
)) {
    $profile = New-CodeCliAgentProfile -Command 'codex' -Arguments $arguments
    Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) ('--disable apps ' + $arguments) 'quoted values and prompt text are not feature overrides'
}

$profile = New-CodeCliAgentProfile -Command 'codex' -Arguments 'exec --enable apps --json -' -Permission read -Model 'fixture-model'
Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) 'exec --sandbox read-only -m "fixture-model" --enable apps --json -' 'account opt-in still receives profile permission and model'
Assert-ProfileEqual (Get-CodeCliTerminalArguments $profile) '--sandbox read-only -m "fixture-model"' 'chat opt-in does not leak into the terminal command'

$profile = New-CodeCliAgentProfile -Command 'claude' -Arguments '-p --output-format stream-json --verbose {prompt}' -Permission read -Model 'fixture-model'
Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) '--permission-mode plan --model "fixture-model" -p --output-format stream-json --verbose {prompt}' 'second agent retains prompt and output flags'
$profile = New-CodeCliAgentProfile -Command 'kiro-cli' -Arguments 'chat --no-interactive' -Permission full
Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) 'chat --trust-all-tools --no-interactive' 'third agent retains its chat command'
Assert-ProfileEqual (Get-CodeCliTerminalArguments $profile) 'chat --trust-all-tools' 'third agent terminal remains interactive'
$profile = New-CodeCliAgentProfile -Command 'custom-agent.exe' -Arguments '--enable apps {prompt}'
Assert-ProfileEqual (Get-CodeCliEffectiveArguments $profile) '--enable apps {prompt}' 'custom agents retain their literal arguments'

$oldProfile = '{"Id":"saved-profile","Name":"Saved agent","Command":"codex","Arguments":"exec -","PromptMode":"stdin","Permission":"read","Model":""}' | ConvertFrom-Json
$before = $oldProfile | ConvertTo-Json -Compress
Assert-ProfileEqual (Get-CodeCliEffectiveArguments $oldProfile) '--disable apps exec --sandbox read-only -' 'existing saved profile shape needs no migration'
Assert-ProfileEqual ($oldProfile | ConvertTo-Json -Compress) $before 'existing saved profile remains unmodified'

Write-Output ("Passed: {0}; failed: {1}" -f $testPassed, $testFailures.Count)
if ($testFailures.Count) { exit 1 }
exit 0
