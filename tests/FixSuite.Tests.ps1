param([string]$ModuleRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'))

$ErrorActionPreference = 'Stop'
$passed = 0
$failed = 0
function Assert-FixSuite {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:passed++; Write-Output "ok $Message" }
    else { $script:failed++; Write-Output "FAIL $Message" }
}
$UI = @{}
foreach ($name in @('FixInbox.ps1', 'FixReview.ps1', 'FixPullRequest.ps1', 'FixInboxGui.ps1', 'ReleaseOperations.ps1')) {
    . (Join-Path $ModuleRoot $name)
}
function Quote-PS { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Uses the production command helper name.')] param([string]$Value) return "'" + $Value.Replace("'", "''") + "'" }

function Test-FixSuitePlans {
    param($work, $suite, $tradutor, $settings)
    $entry = [pscustomobject]@{ name = 'SuiteBUDA'; tagPrefix = 'suitebuda-v'; repoRoot = $work }
    Assert-FixSuite ((Get-FixReleaseTag $entry '1.0.0') -eq 'suitebuda-v1.0.0') 'SuiteBUDA release tag remains version-bound'
    [void](New-Item -ItemType Directory -Path (Join-Path $work '.git'))
    function Invoke-FixGit {
        param([string[]]$Arguments, [switch]$PumpUi)
        return [pscustomobject]@{ ExitCode = 0; Output = '0123456789abcdef'; Error = '' }
    }
    $release = Initialize-FixReleaseWorktree $settings $entry '1.0.0'
    Assert-FixSuite ($release.SourceRoot.Replace('\', '/') -like '*/app/src/main/java') 'review checks SuiteBUDA sources under app/src/main/java'
    Test-FixSuiteInitialBase $settings $entry
    $plan = @{ RepoRoot = $work; Worktree = (Join-Path $work 'pr'); Branch = 'contrib/tenzin/suite-mudanca'; Tag = 'suitebuda-v1.0.0';
        BundlePath = (Join-Path $work 'sample.budafix'); BundleSha = ('a' * 64); Tool = $suite; RegistryArgs = @('--registry', 'developers.json', '--root', 'root.pub'); SourceRoot = 'app/src/main/java' }
    $preflight = (Build-FixPrPreflightLines $plan) -join "`n"
    Assert-FixSuite ($preflight -match "Join-Path \`$__wt 'app/src/main/java'") 'PR applies under the same SuiteBUDA source root'
    if ($suite) {
        $apply = (Build-FixPrApplyLines $plan) -join "`n"
        Assert-FixSuite ($apply -match "org.budasuite.SuiteBUDA '--bundle-tool' bundle-apply") 'PR apply uses the trusted launcher dispatcher'
        Assert-FixSuite ($apply -match "add -A -- 'app/src/main/java'") 'PR stages only SuiteBUDA Java sources'
        Assert-FixSuite ($apply -match '--registry.*developers.json.*--root.*root.pub.*--base.*--into') 'signature registry and base verification remain mandatory'
    } else { 1..3 | ForEach-Object { Assert-FixSuite $false 'SuiteBUDA PR apply support' } }
    $plan.Remove('SourceRoot')
    $plan.Tool = $tradutor
    $legacy = (Build-FixPrPreflightLines $plan) -join "`n"
    Assert-FixSuite ($legacy -match "Join-Path \`$__wt 'src[/\\]main[/\\]java'") 'existing app source root stays compatible'
}

function Test-FixSuiteInitialBase {
    param($settings, $entry)
    if (-not (Get-Command Get-FixReleaseBase -ErrorAction SilentlyContinue)) {
        1..5 | ForEach-Object { Assert-FixSuite $false 'initial SuiteBUDA baseline handling' }
        return
    }
    $refused = ''
    try { Get-FixReleaseBase $entry '0.0.0' | Out-Null } catch { $refused = $_.Exception.Message }
    Assert-FixSuite ($refused -match 'suggestionBaseCommit') 'unreleased SuiteBUDA requires explicit initial commit'
    $entry | Add-Member -NotePropertyName suggestionBaseCommit -NotePropertyValue 'main'
    $refused = $false
    try { Get-FixReleaseBase $entry '0.0.0' | Out-Null } catch { $refused = $true }
    Assert-FixSuite $refused 'mutable branch cannot replace the initial commit'
    $entry.suggestionBaseCommit = '0123456789abcdef0123456789abcdef01234567'
    $base = Get-FixReleaseBase $entry '0.0.0'
    Assert-FixSuite ($base.Reference -ceq $entry.suggestionBaseCommit) 'initial baseline remains an exact immutable commit'
    $base = Get-FixReleaseBase $entry '1.0.0'
    Assert-FixSuite ($base.Reference -eq 'refs/tags/suitebuda-v1.0.0') 'published release always resolves its version tag'
    $refused = $false
    try { Initialize-FixReleaseWorktree $settings $entry '0.0.0' | Out-Null } catch { $refused = $_.Exception.Message -match 'commit resolvido' }
    Assert-FixSuite $refused 'resolved initial commit must match the configured value'
}

function Test-FixSuiteInstallSettings {
    $script:suiteSettings = [pscustomobject]@{ installs = @{ TradutorBUDA = 'old-tradutor'; ScanBUDA = 'old-scan'; SuiteBUDA = 'old-suite' }; supabaseUrl = ''; publishableKey = '' }
    function Get-FixInboxSettings { return $script:suiteSettings }
    function Save-FixInboxSettings { param($Settings) $script:suiteSettings = $Settings }
    $fields = @(Get-FixSettingsFields | ForEach-Object { $_[0] })
    Assert-FixSuite ($fields -contains 'suiteInstall' -and $fields -contains 'scanInstall') 'GUI and CLI expose every supported install'
    Assert-FixSuite ((Get-FixSettingValue $script:suiteSettings 'suiteInstall') -eq 'old-suite') 'settings dialog reads SuiteBUDA install independently'
    $saved = Save-FixInboxSettingsFrom @{ suiteInstall = ' new-suite '; scanInstall = 'new-scan' }
    Assert-FixSuite ($saved.installs.SuiteBUDA -eq 'new-suite' -and $saved.installs.ScanBUDA -eq 'new-scan') 'CLI and GUI save install fields in their matching apps'
    Assert-FixSuite ($saved.installs.TradutorBUDA -eq 'old-tradutor') 'SuiteBUDA setting preserves the existing app install'
    Assert-FixSuite ($UI.FixSettings.Height -ge (16 + 40 * $fields.Count + 92)) 'settings fields and note fit above the buttons'
}

function Test-FixSuiteDispatch {
    $config = Join-Path (Split-Path -Parent $ModuleRoot) 'apps.json'
    $app = ([IO.File]::ReadAllText($config) | ConvertFrom-Json).apps | Where-Object { $_.name -eq 'SuiteBUDA' }
    Assert-FixSuite ($app.githubRepo -eq 'TashiRabten/SuiteBUDA' -and $app.releaseRepo -eq 'TashiRabten/GlossarioBUDA') 'SuiteBUDA source and release repositories remain distinct'
    $commands = (Build-DispatchCommands $app '1.0.0' $false) -join "`n"
    Assert-FixSuite ($commands -match '^gh workflow run build-suitebuda-installer.yml ' -and $commands -match "'version=1.0.0'" -and $commands -match "'publish=false'") 'SuiteBUDA test build dispatches the Windows EXE workflow without publishing'
    $commands = (Build-DispatchCommands $app '1.0.0' $true) -join "`n"
    Assert-FixSuite ($commands -match "'publish=true'") 'SuiteBUDA publish input is explicit in the dispatch plan'
}

$work = Join-Path $env:TEMP ('instaladorbuda-suite-bridge-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $work)
    $tools = Get-FixAppTools
    Assert-FixSuite ($tools.ContainsKey('SuiteBUDA')) 'SuiteBUDA is a supported bundle app'
    $summary = [pscustomobject]@{ app = 'SuiteBUDA'; appVersion = '1.0.0'; keyId = '0123456789abcdef'; slug = 'suite-mudanca'; title = 'Correção da suíte'; description = '' }
    $accepted = $true
    try { Assert-FixSubmissionFields $summary } catch { $accepted = $false }
    Assert-FixSuite $accepted 'SuiteBUDA submission fields accepted'
    $summary.app = 'UnknownApp'
    $rejected = $false
    try { Assert-FixSubmissionFields $summary } catch { $rejected = $true }
    Assert-FixSuite $rejected 'unknown apps remain refused'
    foreach ($name in @('runtime/bin/java.exe', 'app/SuiteBUDA.jar', 'app/TradutorBUDA.jar')) {
        $file = Join-Path $work $name
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force)
        [void](New-Item -ItemType File -Path $file)
    }
    $settings = [pscustomobject]@{ installs = @{ SuiteBUDA = $work; TradutorBUDA = $work }; worktreeRoot = $work }
    $suite = $null
    try { $suite = Get-FixBundleToolCommand $settings 'SuiteBUDA' } catch { $suite = $null }
    Assert-FixSuite ($null -ne $suite -and $suite.MainClass -eq 'org.budasuite.SuiteBUDA') 'SuiteBUDA uses the trusted release launcher'
    Assert-FixSuite ($null -ne $suite -and @($suite.Arguments) -contains '--bundle-tool') 'SuiteBUDA launcher receives the headless dispatcher'
    $tradutor = Get-FixBundleToolCommand $settings 'TradutorBUDA'
    Assert-FixSuite ($tradutor.MainClass -eq 'com.example.glossariobuda.selfcode.BundleTool' -and @($tradutor.Arguments | Where-Object { $_ }).Count -eq 0) 'existing tool invocation stays compatible'
    function Invoke-FixProcess {
        param($FileName, [string[]]$Arguments, $TimeoutSec, [switch]$PumpUi)
        $script:capturedArguments = $Arguments
        return [pscustomobject]@{ ExitCode = 0; Output = '{"valid":true}'; Error = '' }
    }
    if ($suite) {
        $result = Invoke-FixBundleTool $settings 'SuiteBUDA' @('bundle-verify', '--bundle', 'sample.budafix')
        Assert-FixSuite ($result.valid -and ($capturedArguments -join '|') -match 'org.budasuite.SuiteBUDA\|--bundle-tool\|bundle-verify\|--bundle\|sample.budafix$') 'verification args reach dispatcher in original order'
    } else { Assert-FixSuite $false 'verification args reach dispatcher in original order' }

    Test-FixSuitePlans $work $suite $tradutor $settings
    Test-FixSuiteInstallSettings
    Test-FixSuiteDispatch
} finally {
    $target = [IO.Path]::GetFullPath($work)
    if ($target.StartsWith([IO.Path]::GetFullPath($env:TEMP), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
Write-Output "$passed passed, $failed failed"
exit [int]($failed -gt 0)
