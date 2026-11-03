# Suggested changes end to end, with no network: a contributor sends a signed .budafix to the inbox and
# follows its status; the maintainer lists it, verifies it with TradutorBUDA's BundleTool against a worktree
# at the release tag, reads the report and the diff, opens the PR, merges or declines; the registry is
# verified. GUI clicks and CLI requests go through the same buttons.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\FixInbox.Tests.ps1 [-TradutorRepo DIR] [-Runtime DIR]
#
# Fakes: Supabase is tests\FixInboxFakes.ps1 (in memory, with the draft schema's row rules); GitHub is a bare
# repository on disk as origin plus a gh.cmd that records its arguments. Real: git, Gitleaks (when found
# beside InstaladorBUDA), and BundleTool — from TradutorBUDA's compiled classes (target\classes) packed with
# Gson into a temporary TradutorBUDA.jar, run with the installed runtime. Without those the end-to-end part
# is skipped and says so. Everything is written under %TEMP%; nothing reaches Supabase or GitHub.
param([switch]$Inner, [string]$TradutorRepo, [string]$Runtime)

if (-not $Inner) {
    $self = $MyInvocation.MyCommand.Path
    $command = ". '{0}' -Inner -TradutorRepo '{1}' -Runtime '{2}'" -f $self.Replace("'", "''"), $TradutorRepo.Replace("'", "''"), $Runtime.Replace("'", "''")
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -Command $command
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $testRoot 'modules\AppRegistry.psm1'))))
$entrypoint = [IO.File]::ReadAllText((Join-Path $testRoot 'InstaladorBUDA.ps1'))
foreach ($moduleMatch in [regex]::Matches($entrypoint, "Join-Path \`$AppDir '(modules\\[^']+\.ps1)'")) { . (Join-Path $testRoot $moduleMatch.Groups[1].Value) }
. (Join-Path $PSScriptRoot 'FixInboxFakes.ps1')
function Get-App { param([string]$Name) $script:AppRegistry.Get($Name) }

$testPassed = 0
$testFailures = New-Object System.Collections.Generic.List[string]
function Assert-That { param([bool]$Condition, [string]$Name) if ($Condition) { $script:testPassed++; Write-Output "ok   $Name" } else { $script:testFailures.Add($Name); Write-Output "FAIL $Name" } }
function Assert-Equal { param($Actual, $Expected, [string]$Name) Assert-That ([string]$Actual -ceq [string]$Expected) "$Name (expected '$Expected', got '$Actual')" }
function Invoke-Git { param([string[]]$GitArgs) $r = Invoke-FixProcess 'git' $GitArgs; if ($r.ExitCode) { throw "git $($GitArgs -join ' '): $($r.Error)" }; return $r.Output.Trim() }
function Write-Crlf { param([string]$Path, [string]$Text) [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force); [IO.File]::WriteAllText($Path, $Text.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false)) }
function Get-Sha { param([string]$Path) (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Invoke-Cli { param([hashtable]$Request) $r = [pscustomobject]$Request; return (Invoke-CockpitRequest $guiState $r) }
function Invoke-CliError { param([hashtable]$Request) try { [void](Invoke-Cli $Request); return '' } catch { return $_.Exception.Message } }
function Wait-Job { param($Tab, [int]$Seconds = 240) $end = [datetime]::UtcNow.AddSeconds($Seconds); while ($Tab.IsRunning -and [datetime]::UtcNow -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }; [System.Windows.Forms.Application]::DoEvents() }
function Get-Status { return (Invoke-Cli @{ command = 'action'; action = 'fix-status'; session = '1' }).data }

$work = Join-Path $env:TEMP ('instaladorbuda-fixinbox-' + [guid]::NewGuid().ToString('N'))
$form = $null
try {
    [void](New-Item -ItemType Directory -Path $work -Force)
    # ── Unit checks that need nothing installed ──
    Assert-That ((Test-FixInboxPublishableKey 'sb_secret_abc') -match 'secreta') 'key: a secret key is refused'
    $jwt = 'eyJhbGciOiJIUzI1NiJ9.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"role":"service_role"}')).TrimEnd('=') + '.sig'
    Assert-That ((Test-FixInboxPublishableKey $jwt) -match 'service_role') 'key: a service_role JWT is refused'
    Assert-Equal (Test-FixInboxPublishableKey 'sb_publishable_abc') '' 'key: a publishable key is accepted'
    Assert-That ((Test-FixInboxUrl 'http://evil.example') -match 'https') 'url: plain http off loopback is refused'
    Assert-That (Test-FixBranchName 'contrib/tenzin/corrige') 'branch: contrib/<id>/<slug> accepted'
    Assert-That (-not (Test-FixBranchName 'main') -and -not (Test-FixBranchName 'contrib/tenzin/../main')) 'branch: anything else refused'
    # A window taller than the screen's work area shrinks to it, and its bottom-anchored row stays inside.
    $screenArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $tall = New-Object System.Windows.Forms.Form
    $tall.StartPosition = 'Manual'; $tall.Location = [System.Drawing.Point]::new($screenArea.Left, $screenArea.Top)
    $tall.ClientSize = [System.Drawing.Size]::new(600, $screenArea.Height + 300)
    $tall.MinimumSize = [System.Drawing.Size]::new(500, $screenArea.Height + 200)
    $bottomButton = New-Object System.Windows.Forms.Button
    $bottomButton.SetBounds(16, $tall.ClientSize.Height - 46, 120, 30); $bottomButton.Anchor = 'Bottom,Left'
    $tall.Controls.Add($bottomButton)
    Sync-FixFormToScreen $tall
    Assert-That ($tall.Height -le $screenArea.Height -and $tall.Bottom -le $screenArea.Bottom) 'window: a window taller than the work area fits in it'
    Assert-That ($bottomButton.Bottom -le $tall.ClientSize.Height) 'window: its bottom-anchored row is still inside'
    $tall.Dispose()

    # ── Prerequisites for the end-to-end part ──
    if (-not $TradutorRepo) { $TradutorRepo = Join-Path (Split-Path -Parent $testRoot) 'tradutorbuda' }
    if (-not $Runtime) { $Runtime = Join-Path $env:LOCALAPPDATA 'TradutorBUDA\runtime' }
    $classes = Join-Path $TradutorRepo 'target\classes'
    $installedJar = Join-Path $env:LOCALAPPDATA 'TradutorBUDA\app\TradutorBUDA.jar'
    $missing = @()
    if (-not (Test-Path -LiteralPath (Join-Path $classes 'com\example\glossariobuda\selfcode\BundleTool.class'))) { $missing += "BundleTool.class under $classes (build TradutorBUDA)" }
    if (-not (Test-Path -LiteralPath (Join-Path $Runtime 'bin\java.exe'))) { $missing += "a Java runtime at $Runtime" }
    if (-not (Test-Path -LiteralPath $installedJar)) { $missing += "Gson (taken from $installedJar)" }
    if ($missing.Count) { Write-Output ("skip end to end: missing " + ($missing -join '; ')); throw 'SKIP' }

    # ── BundleTool: TradutorBUDA's target\classes and Gson packed into one jar, run with the installed runtime ──
    # The cockpit's own lookup (<install>\runtime\bin\java.exe + <install>\app\TradutorBUDA.jar) is checked on an
    # empty stand-in folder first; then the test points it at that jar, so the installed app is never touched.
    $install = Join-Path $work 'install'
    foreach ($f in @('runtime\bin\java.exe', 'app\TradutorBUDA.jar')) { [void](New-Item -ItemType File -Path (Join-Path $install $f) -Force) }
    $probe = Get-FixBundleToolCommand ([pscustomobject]@{ installs = @{ TradutorBUDA = $install } }) 'TradutorBUDA'
    Assert-Equal "$($probe.Java)|$($probe.Jar)|$($probe.MainClass)" "$install\runtime\bin\java.exe|$install\app\TradutorBUDA.jar|com.example.glossariobuda.selfcode.BundleTool" 'BundleTool: found inside the install'
    $noInstall = ''
    try { [void](Get-FixBundleToolCommand ([pscustomobject]@{ installs = @{ TradutorBUDA = (Join-Path $work 'nada') } }) 'TradutorBUDA') } catch { $noInstall = $_.Exception.Message }
    Assert-That ($noInstall -match 'Configurar') 'BundleTool: a missing install says where to set it'
    $jar = Join-Path $work 'TradutorBUDA.jar'
    $out = [IO.Compression.ZipFile]::Open($jar, 'Create')
    try {
        $prefix = (Resolve-Path -LiteralPath $classes).Path.TrimEnd('\') + '\'
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $classes 'com') -Recurse -File -Filter '*.class') {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($out, $f.FullName, $f.FullName.Substring($prefix.Length).Replace('\', '/'))
        }
        $gson = [IO.Compression.ZipFile]::OpenRead($installedJar)
        try {
            foreach ($e in $gson.Entries | Where-Object { $_.FullName -like 'com/google/gson/*' -and $_.FullName -notlike '*/' }) {
                $target = $out.CreateEntry($e.FullName); $src = $e.Open(); $dst = $target.Open()
                try { $src.CopyTo($dst) } finally { $src.Dispose(); $dst.Dispose() }
            }
        } finally { $gson.Dispose() }
    } finally { $out.Dispose() }
    $java = Join-Path $Runtime 'bin\java.exe'
    $tool = 'com.example.glossariobuda.selfcode.BundleTool'
    $FixTestTool = [pscustomobject]@{ Java = $java; Jar = $jar; MainClass = $tool }
    function Get-FixBundleToolCommand { param($Settings, [string]$App) return $FixTestTool }

    # ── Temporary root and developer identities, and the root-signed registry (BundleTool, --password-env) ──
    $env:FIXINBOX_TEST_PASSWORD = 'senha do teste ' + [guid]::NewGuid().ToString('N')
    $keys = Join-Path $work 'keys'; [void](New-Item -ItemType Directory -Path $keys -Force)
    $rootId = (Invoke-FixProcess $java @('-cp', $jar, $tool, 'identity-create', '--out', "$keys\root.json", '--name', 'Raiz', '--email', 'raiz@example.org', '--password-env', 'FIXINBOX_TEST_PASSWORD')).Output | ConvertFrom-Json
    $devId = (Invoke-FixProcess $java @('-cp', $jar, $tool, 'identity-create', '--out', "$keys\tenzin.json", '--name', 'Tenzin', '--email', 'tenzin@example.org', '--password-env', 'FIXINBOX_TEST_PASSWORD')).Output | ConvertFrom-Json
    Assert-That ($devId.keyId -match '^[0-9a-f]{16}$' -and $rootId.publicKey -like 'ssh-ed25519 *') 'fixture: identities created by BundleTool'
    $unsigned = @{ format = 'buda-developer-registry'; version = 1; developers = @(@{ id = 'tenzin'; name = 'Tenzin'; email = 'tenzin@example.org'; publicKey = $devId.publicKey; apps = @('TradutorBUDA'); ceiling = @('FILE_WRITE') }) }
    [IO.File]::WriteAllText("$keys\developers.unsigned.json", ($unsigned | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $registry = Join-Path $keys 'developers.json'
    $signed = Invoke-FixProcess $java @('-cp', $jar, $tool, 'registry-sign', '--in', "$keys\developers.unsigned.json", '--root-identity', "$keys\root.json", '--out', $registry, '--password-env', 'FIXINBOX_TEST_PASSWORD')
    Assert-Equal $signed.ExitCode 0 "fixture: registry signed by the root ($($signed.Output.Trim()))"
    [IO.File]::WriteAllText("$keys\root.pub", [string]$rootId.publicKey, [Text.UTF8Encoding]::new($false))

    # ── TradutorBUDA's repository at release 1.8.6, with a bare repository as its GitHub ──
    $repo = Join-Path $work 'tradutorbuda'; $origin = Join-Path $work 'origin.git'
    $fixture = 'src/main/java/com/example/glossariobuda/ui/BundleFixture.java'
    [void](New-Item -ItemType Directory -Path $repo -Force)
    Invoke-Git @('init', '-q', '--bare', $origin) | Out-Null
    Invoke-Git @('-C', $repo, 'init', '-q') | Out-Null
    Invoke-Git @('-C', $repo, 'symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
    Invoke-Git @('-C', $repo, 'config', 'user.name', 'Maintainer Test') | Out-Null
    Invoke-Git @('-C', $repo, 'config', 'user.email', 'maintainer@example.invalid') | Out-Null
    $other = 'src/main/java/com/example/glossariobuda/ui/Outro.java'
    $releaseText = @{ $fixture = "package com.example.glossariobuda.ui;`n`nclass BundleFixture {`n   int v = 1;`n}`n"; $other = "package com.example.glossariobuda.ui;`n`nclass Outro { }`n" }
    foreach ($f in $releaseText.Keys) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $repo $f)) -Force)
        [IO.File]::WriteAllText((Join-Path $repo $f), $releaseText[$f])
    }
    Invoke-Git @('-C', $repo, '-c', 'core.autocrlf=false', 'add', '-A') | Out-Null
    Invoke-Git @('-C', $repo, '-c', 'core.autocrlf=false', 'commit', '-q', '-m', 'Release 1.8.6') | Out-Null
    Invoke-Git @('-C', $repo, 'tag', '-a', 'tradutor-buda-v1.8.6', '-m', 'v1.8.6') | Out-Null
    Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $origin) | Out-Null
    Invoke-Git @('-C', $repo, 'push', '-q', 'origin', 'main', 'tradutor-buda-v1.8.6') | Out-Null

    # ── Bundles as the contributor's app writes them: base sums of the shipped (CRLF) files ──
    $shipped = Join-Path $work 'shipped'
    foreach ($f in $releaseText.Keys) { Write-Crlf (Join-Path $shipped $f) $releaseText[$f] }
    Write-Crlf (Join-Path $work 'new\BundleFixture.java') "package com.example.glossariobuda.ui;`n`nclass BundleFixture {`n   int v = 2;   // corrigido`n}`n"
    Write-Crlf (Join-Path $work 'new\Outro.java') "package com.example.glossariobuda.ui;`n`nclass Outro {`n   String nome() { return `"outro`"; }`n}`n"
    Write-Crlf (Join-Path $work 'new\OutroExec.java') "package com.example.glossariobuda.ui;`n`nclass Outro {`n   void abre() throws Exception { new ProcessBuilder(`"notepad`").start(); }`n}`n"
    Write-Crlf (Join-Path $work 'new\Novo.java') "package com.example.glossariobuda.ui;`n`nclass Novo { }`n"
    $rel = $fixture.Substring('src/main/java/'.Length); $relOther = $other.Substring('src/main/java/'.Length)
    $baseSha = Get-Sha (Join-Path $shipped $fixture); $otherSha = Get-Sha (Join-Path $shipped $other)
    $sugestoes = Join-Path $work 'sugestoes'; [void](New-Item -ItemType Directory -Path $sugestoes -Force)
    $make = { param($Out, $Title, $Slug, $Caps, [string[]]$Files)
        $r = Invoke-FixProcess $java (@('-cp', $jar, (Join-Path $PSScriptRoot 'fixtures\MakeBundle.java'), $Out, "$keys\tenzin.json", 'FIXINBOX_TEST_PASSWORD', $Title, $Slug, '1.8.6', $Caps) + $Files)
        if ($r.ExitCode) { throw "MakeBundle: $($r.Error)" } }
    $good = Join-Path $sugestoes 'corrige.budafix'
    & $make $good 'Corrige o valor do marcador' 'corrige-marcador' '-' @($rel, $baseSha, (Join-Path $work 'new\BundleFixture.java'), $relOther, $otherSha, (Join-Path $work 'new\Outro.java'))
    $over = Join-Path $sugestoes 'executa.budafix'
    & $make $over 'Abre um programa' 'abre-programa' 'EXEC' @($relOther, $otherSha, (Join-Path $work 'new\OutroExec.java'))
    $bad = Join-Path $sugestoes 'protegido.budafix'
    & $make $bad 'Mexe na segurança' 'mexe-seguranca' '-' @('com/example/glossariobuda/security/CodeGate.java', $otherSha, (Join-Path $work 'new\Novo.java'))
    $newFile = Join-Path $sugestoes 'novo.budafix'
    & $make $newFile 'Acrescenta uma classe' 'acrescenta-classe' '-' @('com/example/glossariobuda/ui/Novo.java', '-', (Join-Path $work 'new\Novo.java'))
    Assert-That ((Test-Path $good) -and (Test-Path $over) -and (Test-Path $bad) -and (Test-Path $newFile)) 'fixture: four signed bundles written by FixBundles.write'

    # ── The cockpit: settings, the app registry, a session in an off-screen window ──
    $settingsFile = Join-Path $work 'fix-inbox.json'; $sentFile = Join-Path $work 'fix-sent.json'
    function Get-FixInboxSettingsPath { return $settingsFile }
    function Get-FixInboxSentPath { return $sentFile }
    $cfg = Join-Path $work 'apps.json'
    $entry = [ordered]@{ name = 'TradutorBUDA'; repoRoot = $repo; githubRepo = 'TestOwner/TradutorBUDA'; releaseRepo = 'TestOwner/Releases'; manageVisibility = $false
        tagPrefix = 'tradutor-buda-v'; workflow = ''; releaseBranch = ''; versionFromGitTag = 'tradutor-buda-v*'; uploadScript = $null; models = @(); dispatchInputs = @() }
    [IO.File]::WriteAllText($cfg, (@{ apps = @($entry); tasks = @() } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $AppDir = $testRoot; $cfgFile = $cfg
    $script:AppRegistry = [BudaAppRegistry]::new($cfg); $script:Config = $script:AppRegistry.Config; $script:Tasks = @()
    $ReleaseRepo = 'TestOwner/Releases'; $ActionsUrl = 'https://github.com/TestOwner/TradutorBUDA/actions'
    $script:ReleaseVersionCache = @{}; $script:ControlPipeName = 'InstaladorBUDA.FixTest'; $HasGit = $true; $HasGh = $true
    $bin = Join-Path $work 'bin'; [void](New-Item -ItemType Directory -Path $bin -Force)
    $env:FAKE_GH_LOG = Join-Path $work 'gh.log'
    [IO.File]::WriteAllText((Join-Path $bin 'gh.cmd'), "@echo off`r`necho %*>>`"%FAKE_GH_LOG%`"`r`nif `"%1 %2`"==`"pr create`" echo https://github.com/TestOwner/TradutorBUDA/pull/7`r`nexit /b 0`r`n")
    $env:PATH = "$bin;$env:PATH"
    function gh { $global:LASTEXITCODE = 0; if (($args -join ' ') -match '^repo view') { return 'PRIVATE' }; return '' }

    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false; $form.Location = New-Object System.Drawing.Point(-4000, -4000); $form.Size = New-Object System.Drawing.Size(900, 900)
    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'; $form.Controls.Add($tabs); [void]$tabs.Handle
    $guiState = [hashtable]::Synchronized(@{ Tabs = $tabs; Form = $form; JobCounter = 1; CliConfirmed = $false })
    $tabs.Tag = $guiState
    $tabs.TabPages.Add((New-JobTab -Tabs $tabs -Number 1))
    $form.Show(); [System.Windows.Forms.Application]::DoEvents()
    $tab = $tabs.TabPages[0].Tag
    $tab.Controls.DryRun.Checked = $false
    Assert-That ([bool]$tab.FixButtons.Suggest -and [bool]$tab.FixButtons.Inbox) 'gui: the session has the suggestions section'

    Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-settings'; session = '1'; supabaseUrl = 'https://fake.supabase.co' }) -match 'confirm') 'cli fix-settings: needs confirm'
    Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-settings'; session = '1'; publishableKey = 'sb_secret_nope'; confirm = $true }) -match 'secreta') 'cli fix-settings: a secret key is refused'
    $reply = Invoke-Cli @{ command = 'action'; action = 'fix-settings'; session = '1'; confirm = $true; supabaseUrl = 'https://fake-project.supabase.co/'
        publishableKey = $FakeInbox.Key; suggestionsFolder = $sugestoes; tradutorInstall = $install; registryPath = $registry; rootKeyPath = "$keys\root.pub"
        inboxFolder = (Join-Path $work 'inbox'); worktreeRoot = (Join-Path $work 'worktrees') }
    Assert-Equal $reply.data.settings.supabaseUrl 'https://fake-project.supabase.co' 'cli fix-settings: saved, trailing slash dropped'
    Assert-That (-not ((Get-Content -Raw $settingsFile) -match 'password|senha')) 'settings file: no password field'

    # ── Registry ──
    $reply = Invoke-Cli @{ command = 'action'; action = 'fix-registry-verify'; session = '1' }
    Assert-That ([bool]$reply.data.registry.valid) 'cli fix-registry-verify: the registry checks against the root'
    Assert-Equal (@($reply.data.registry.developers | ForEach-Object { "$($_.id)|$($_.branchPrefix)|$($_.active)" }) -join ',') 'tenzin|contrib/tenzin/|True' 'registry: developers listed'
    Assert-Equal $reply.data.settings.registrySeenVersion 1 'registry: the version seen is remembered (rollback guard)'
    Assert-That ($tab.Controls.Log.Text.Contains('Registro de desenvolvedores confere')) 'registry: the session log shows the developers'
    $tab.Controls.DryRun.Checked = $true
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-registry-sign'; session = '1'; in = "$keys\developers.unsigned.json"; rootIdentity = "$keys\root.json" })
    Assert-That ($tab.Controls.Log.Text -match '\[dry run\] abriria um console com: .*registry-sign') 'cli fix-registry-sign (dry run): shows the console command'
    $tab.Controls.DryRun.Checked = $false
    Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-registry-sign'; session = '1'; in = 'x'; rootIdentity = 'y' }) -match 'confirm') 'cli fix-registry-sign: needs confirm'

    . (Join-Path $PSScriptRoot 'FixInbox.Flow.ps1')
} catch {
    if ($_.Exception.Message -ne 'SKIP') {
        $testFailures.Add("unexpected error: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)")
        Write-Output "FAIL unexpected error: $($_.Exception.Message)"
        Write-Output $_.InvocationInfo.PositionMessage
    }
} finally {
    if ($form) { foreach ($t in @($tabs.TabPages)) { foreach ($k in @('FixSuggest', 'FixInbox')) { if ($t.Tag[$k]) { $t.Tag[$k].Form.Close() } } }; $form.Close(); $form.Dispose() }
    Remove-Item Env:FIXINBOX_TEST_PASSWORD -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ("{0} passed, {1} failed" -f $testPassed, $testFailures.Count)
exit [int]($testFailures.Count -gt 0)
