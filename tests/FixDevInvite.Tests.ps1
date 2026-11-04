# "Adicionar desenvolvedor..." with no network: the form's rules, the request to the dev-invite Edge Function (the
# publishable key on apikey only, the passphrase in the body, nothing in a dry run), each outcome through the real
# Sugestões recebidas window driven by the CLI (sent; the quota and the built-in sender, which open the link window;
# an account that existed), the link never in a CLI reply, and the next registry version written for signing.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\FixDevInvite.Tests.ps1
#
# Fakes: Supabase is tests\FixInboxFakes.ps1; the registry check and the signing console are stand-ins (BundleTool is
# tested in FixInbox.Tests.ps1). Everything is written under %TEMP%.
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
foreach ($moduleMatch in [regex]::Matches($entrypoint, "Join-Path \`$AppDir '(modules\\[^']+\.ps1)'")) { . (Join-Path $testRoot $moduleMatch.Groups[1].Value) }
. (Join-Path $PSScriptRoot 'FixInboxFakes.ps1')
function Get-App { param([string]$Name) $script:AppRegistry.Get($Name) }

$testPassed = 0
$testFailures = New-Object System.Collections.Generic.List[string]
function Assert-That { param([bool]$Condition, [string]$Name) if ($Condition) { $script:testPassed++; Write-Output "ok   $Name" } else { $script:testFailures.Add($Name); Write-Output "FAIL $Name" } }
function Assert-Equal { param($Actual, $Expected, [string]$Name) Assert-That ([string]$Actual -ceq [string]$Expected) "$Name (expected '$Expected', got '$Actual')" }
function Invoke-Cli { param([hashtable]$Request) $r = [pscustomobject]$Request; return (Invoke-CockpitRequest $guiState $r) }
function Invoke-CliError { param([hashtable]$Request) try { [void](Invoke-Cli $Request); return '' } catch { return $_.Exception.Message } }
function Get-LastInviteCall { return ($FakeInbox.Calls | Where-Object { $_.Uri -like '*/functions/v1/dev-invite' } | Select-Object -Last 1) }
function Add-Developer { param([hashtable]$Fields) $r = @{ command = 'action'; action = 'fix-inbox-add-developer'; session = '1'; confirm = $true }; foreach ($k in $Fields.Keys) { $r[$k] = $Fields[$k] }; return (Invoke-Cli $r) }

$work = Join-Path $env:TEMP ('instaladorbuda-devinvite-' + [guid]::NewGuid().ToString('N'))
$form = $null
try {
    [void](New-Item -ItemType Directory -Path $work -Force)

    # ── The form's rules ──
    Assert-Equal (Get-FixDeveloperId 'Tenzin Wangmo') 'tenzin-wangmo' 'id: from the name'
    Assert-Equal (Get-FixDeveloperId '  José da Silva Ç ') 'jose-da-silva-c' 'id: without accents or spaces at the ends'
    Assert-That ((Get-FixDeveloperId ('a' * 60)).Length -le 40) 'id: at most 40 characters'
    $all = Build-FixDeveloperRequest 'Tenzin Wangmo' ' Tenzin@Example.ORG ' '' $true @() ''
    Assert-Equal (@($all.InboxApps) -join ',') 'SuiteBUDA' 'all apps: SuiteBUDA in the inbox (a developer of the whole suite)'
    Assert-That ($null -ne $all.RegistryApps -and @($all.RegistryApps).Count -eq 0) 'all apps: an empty list in the registry (every app), never [null]'
    Assert-Equal $all.Email 'tenzin@example.org' 'request: the e-mail in lower case'
    Assert-Equal $all.Id 'tenzin-wangmo' 'request: the id follows the name when not given'
    $some = Build-FixDeveloperRequest 'Pema' 'pema@example.org' 'pema' $false @('ScanBUDA', 'OutroApp', 'ScanBUDA') "ssh-ed25519   AAAAC3Nza  Pema"
    Assert-Equal "$(@($some.InboxApps) -join ',')|$(@($some.RegistryApps) -join ',')" 'ScanBUDA|ScanBUDA' 'some apps: the same known apps in both, once'
    Assert-Equal $some.PublicKey 'ssh-ed25519 AAAAC3Nza Pema' 'request: the key on one line'
    Assert-Equal (Test-FixDeveloperRequest $all) '' 'request: a good one passes'
    Assert-That ((Test-FixDeveloperRequest (Build-FixDeveloperRequest 'X' 'sem-arroba' 'x' $true @() '')) -match 'e-mail') 'request: a bad e-mail is refused'
    Assert-That ((Test-FixDeveloperRequest (Build-FixDeveloperRequest 'X' 'x@example.org' 'Com-Maiuscula' $true @() '')) -match 'id') 'request: an id with capitals is refused'
    Assert-That ((Test-FixDeveloperRequest (Build-FixDeveloperRequest 'X' 'x@example.org' 'x' $false @() '')) -match 'app') 'request: no app is refused'
    Assert-That ((Test-FixDeveloperRequest (Build-FixDeveloperRequest 'X' 'x@example.org' 'x' $true @() 'ssh-rsa AAAA')) -match 'ssh-ed25519') 'request: a key that is not ed25519 is refused'

    # ── The cockpit: settings, a registry to extend, a session in an off-screen window ──
    $settingsFile = Join-Path $work 'fix-inbox.json'; $sentFile = Join-Path $work 'fix-sent.json'
    function Get-FixInboxSettingsPath { return $settingsFile }
    function Get-FixInboxSentPath { return $sentFile }
    $keys = Join-Path $work 'registry'; [void](New-Item -ItemType Directory -Path $keys -Force)
    $registry = Join-Path $keys 'developers.json'
    $v6 = [ordered]@{ format = 'buda-developer-registry'; version = 6; developers = @(
            [ordered]@{ apps = @('ScanBUDA', 'SuiteBUDA'); publicKey = 'ssh-ed25519 AAAAexistente'; ceiling = @('FILE_WRITE'); email = 'raiz@example.org'; id = 'mantenedor'; name = 'Mantenedor'; senior = $true; active = $true })
        signature = [ordered]@{ alg = 'Ed25519'; keyId = '0123456789abcdef'; value = 'assinatura' } }
    [IO.File]::WriteAllText($registry, (ConvertTo-Json -InputObject $v6 -Depth 6), [Text.UTF8Encoding]::new($false))
    foreach ($f in @('root.pub', 'root.json')) { [IO.File]::WriteAllText((Join-Path $keys $f), 'raiz de teste') }
    # The registry check and the console are BundleTool's (FixInbox.Tests.ps1): stand-ins that record what they got.
    $script:VerifyValid = $true
    function Invoke-FixRegistryVerify { param($Settings, [string]$App = 'TradutorBUDA') return [pscustomobject]@{ valid = $script:VerifyValid; version = 6; problems = @('assinatura não confere'); developers = @() } }
    $script:SignCalls = New-Object System.Collections.Generic.List[string]
    function Get-FixRegistrySignCommandLine { param($Settings, [string]$UnsignedPath, [string]$RootIdentityPath, [string]$App = 'TradutorBUDA') return "registry-sign --in $UnsignedPath --root-identity $RootIdentityPath --out $($Settings.registryPath)" }
    function Open-FixRegistrySignConsole { param([string]$CommandLine) $script:SignCalls.Add($CommandLine) }

    $cfg = Join-Path $work 'apps.json'
    [IO.File]::WriteAllText($cfg, (@{ apps = @(); tasks = @() } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $AppDir = $testRoot; $cfgFile = $cfg
    $script:AppRegistry = [BudaAppRegistry]::new($cfg); $script:Config = $script:AppRegistry.Config; $script:Tasks = @()
    $ReleaseRepo = 'TestOwner/Releases'; $ActionsUrl = 'https://github.com/TestOwner/X/actions'
    $script:ReleaseVersionCache = @{}; $script:ControlPipeName = 'InstaladorBUDA.DevInviteTest'; $HasGit = $true; $HasGh = $true
    function gh { $global:LASTEXITCODE = 0; return '' }

    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false; $form.Location = New-Object System.Drawing.Point(-4000, -4000); $form.Size = New-Object System.Drawing.Size(900, 900)
    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'; $form.Controls.Add($tabs); [void]$tabs.Handle
    $guiState = [hashtable]::Synchronized(@{ Tabs = $tabs; Form = $form; JobCounter = 1; CliConfirmed = $false })
    $tabs.Tag = $guiState
    $tabs.TabPages.Add((New-JobTab -Tabs $tabs -Number 1))
    $form.Show(); [System.Windows.Forms.Application]::DoEvents()
    $tab = $tabs.TabPages[0].Tag
    $tab.Controls.DryRun.Checked = $false
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-settings'; session = '1'; confirm = $true; supabaseUrl = 'https://fake-project.supabase.co'
        publishableKey = $FakeInbox.Key; registryPath = $registry; rootKeyPath = (Join-Path $keys 'root.pub') })

    # ── The window: the button waits for the passphrase ──
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox'; session = '1' })
    $w = $tab.FixInbox
    Assert-That ([bool]$w.Buttons.AddDeveloper -and -not $w.Buttons.AddDeveloper.Enabled) 'window: Adicionar desenvolvedor... is there, off without the passphrase'
    Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-inbox-add-developer'; session = '1'; name = 'X'; email = 'x@example.org' }) -match 'confirm') 'cli: needs confirm'
    Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-inbox-add-developer'; session = '1'; name = 'X'; email = 'x@example.org'; passphrase = 'x'; confirm = $true }) -match 'credential') 'cli: a passphrase in the JSON is refused'
    $w.Controls.Passphrase.Text = $FakeInbox.Passphrase
    Invoke-FixWindowStep $w 'passphrase-use'
    Assert-That ([bool]$w.Passphrase -and $w.Buttons.AddDeveloper.Enabled) 'window: with the passphrase the button is on'

    # ── Dry run: nothing is sent ──
    $tab.Controls.DryRun.Checked = $true
    $before = $FakeInbox.Calls.Count
    [void](Add-Developer @{ name = 'Seco'; email = 'seco@example.org' })
    Assert-That ($FakeInbox.Calls.Count -eq $before -and $tab.Controls.Log.Text -match '\[dry run\] adicionar seco') 'dry run: logged, nothing sent'
    $tab.Controls.DryRun.Checked = $false

    # ── Sent by Supabase: no link window ──
    $reply = Add-Developer @{ name = 'Tenzin Wangmo'; email = 'Tenzin@example.org' }
    $last = $reply.data.inbox.lastInvite
    Assert-Equal "$($last.developerId)|$($last.emailSent)|$($last.outcome)|$($last.linkShown)" 'tenzin-wangmo|True|sent|False' 'sent: the reply says Supabase e-mailed it'
    $call = Get-LastInviteCall
    Assert-That ($call.Headers.apikey -eq $FakeInbox.Key -and -not $call.Headers.ContainsKey('Authorization')) 'request: the publishable key on apikey only'
    $body = $call.Body | ConvertFrom-Json
    Assert-Equal "$($body.passphrase)|$($body.email)|$($body.developerId)|$(@($body.apps) -join ',')" "$($FakeInbox.Passphrase)|tenzin@example.org|tenzin-wangmo|SuiteBUDA" 'request: passphrase, e-mail, id and apps in the body'
    Assert-That ($body.senior -eq $false -and $last.senior -eq $false) 'request: not senior unless asked'
    Assert-That ($FakeInbox.Users['tenzin@example.org'].Active -and $FakeInbox.Users['tenzin@example.org'].DeveloperId -eq 'tenzin-wangmo') 'sent: the account is a developer'
    Assert-That (-not $w.InviteForm) 'sent: no link window'

    # ── The quota: the account is made, the link opens in a window, never in the reply ──
    $reply = Add-Developer @{ name = 'Pema Cota'; email = 'cota@example.org'; apps = @('ScanBUDA') }
    $last = $reply.data.inbox.lastInvite
    Assert-Equal "$($last.emailSent)|$($last.outcome)|$($last.linkShown)" 'False|quota|True' 'quota: the reply says the link was shown'
    Assert-Equal (@((Get-LastInviteCall).Body | ConvertFrom-Json | ForEach-Object { $_.apps }) -join ',') 'ScanBUDA' 'quota: only the chosen app'
    $text = ConvertTo-Json -InputObject $reply -Depth 8
    Assert-That (-not ($text -match 'token_hash|fakehash')) 'the CLI reply never carries the link'
    $linkForm = $w.InviteForm
    Assert-That ($linkForm -and $linkForm.Visible) 'quota: the link window is open'
    $boxes = @($linkForm.Controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] })
    $labels = (@($linkForm.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] } | ForEach-Object { $_.Text }) -join ' ')
    Assert-That ($labels -match 'cota de e-mail') 'quota: the window says the quota was met'
    Assert-That (@($boxes | Where-Object { $_.Text -eq 'https://glossariobudacompact.netlify.app/set-password?token_hash=fakehash-uid-2&type=invite' }).Count -eq 1) 'quota: the link to the site page'
    Assert-That (@($boxes | Where-Object { $_.Multiline -and $_.Text -match 'Olá, Pema Cota!' -and $_.Text -match 'fakehash-uid-2' -and $_.Text -match 'ScanBUDA' }).Count -eq 1) 'quota: a message ready to send, with the link'
    Assert-That ($tab.Controls.Log.Text -notmatch 'fakehash') 'quota: the link is not in the session log'
    $linkForm.Close(); [System.Windows.Forms.Application]::DoEvents()

    # ── The built-in sender (only the organization's members): the same, with its own reason ──
    $reply = Add-Developer @{ name = 'Dawa Fora'; email = 'fora@example.org' }
    Assert-Equal "$($reply.data.inbox.lastInvite.outcome)|$($reply.data.inbox.lastInvite.linkShown)" 'not_authorized|True' 'built-in sender: the link window'
    $labels = (@($w.InviteForm.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] } | ForEach-Object { $_.Text }) -join ' ')
    Assert-That ($labels -match 'organização') 'built-in sender: the window says why'
    $w.InviteForm.Close(); [System.Windows.Forms.Application]::DoEvents()

    # ── An account that existed: no e-mail, a recovery link; with the key, the next registry version to sign ──
    $key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINovaChaveDoTenzin Tenzin'
    $reply = Add-Developer @{ name = 'Tenzin Wangmo'; email = 'tenzin@example.org'; publicKey = $key }
    $last = $reply.data.inbox.lastInvite
    Assert-Equal "$($last.outcome)|$($last.linkShown)" 'exists|True' 'exists: a recovery link, shown'
    Assert-That ((@($w.InviteForm.Controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] -and -not $_.Multiline }).Text) -match 'type=recovery') 'exists: the link sets a new password'
    $w.InviteForm.Close(); [System.Windows.Forms.Application]::DoEvents()
    $draft = $last.registryDraft
    Assert-Equal ([IO.Path]::GetFileName($draft)) 'developers-v7-para-assinar.json' 'registry: the next version beside the registry'
    $doc = [IO.File]::ReadAllText($draft) | ConvertFrom-Json
    $added = @($doc.developers | Where-Object { $_.id -eq 'tenzin-wangmo' })
    Assert-That ($doc.version -eq 7 -and -not ($doc.PSObject.Properties.Name -contains 'signature')) 'registry: version 7, no signature carried over'
    Assert-That ($added.Count -eq 1 -and $added[0].publicKey -eq $key -and @($added[0].apps).Count -eq 0 -and @($added[0].ceiling).Count -eq 0 -and $added[0].active -and -not $added[0].senior) 'registry: the new developer, every app, no ceiling, not senior'
    Assert-That ([IO.File]::ReadAllText($draft) -match '"apps":\s*\[\s*\]' -and [IO.File]::ReadAllText($draft) -notmatch 'null') 'registry: "apps": [] in the file, no null'
    $kept = @($doc.developers | Where-Object { $_.id -eq 'mantenedor' })
    Assert-That ($kept.Count -eq 1 -and $kept[0].senior -and @($kept[0].ceiling) -join ',' -eq 'FILE_WRITE') 'registry: the others are kept as they were'
    Assert-That ($script:SignCalls.Count -eq 1 -and $script:SignCalls[0] -match [regex]::Escape($draft) -and $script:SignCalls[0] -match 'root\.json') 'registry: the signing console opens with the draft and the root identity beside root.pub'

    # ── Senior: asked in the request, kept in the reply, written to the registry entry ──
    $seniorKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISeniorDoKarma Karma'
    $reply = Add-Developer @{ name = 'Karma Senior'; email = 'karma@example.org'; publicKey = $seniorKey; senior = $true }
    $last = $reply.data.inbox.lastInvite
    Assert-That (((Get-LastInviteCall).Body | ConvertFrom-Json).senior -eq $true -and $last.senior) 'senior: in the request and the reply'
    $entry = @(([IO.File]::ReadAllText($last.registryDraft) | ConvertFrom-Json).developers | Where-Object { $_.id -eq 'karma-senior' })
    Assert-That ($entry.Count -eq 1 -and $entry[0].senior -eq $true -and $entry[0].publicKey -eq $seniorKey) 'senior: "senior": true in the registry entry'

    # ── Chaves novas...: the keys the apps registered that the registry lacks go into its next version ──
    function Get-TestKeyRow { param($Id, $Email, $Name, $Apps, $Senior, $KeyApps, $KeyId, $Key)
        [pscustomobject]@{ developer_id = $Id; email = $Email; name = $Name; apps = $Apps; senior = $Senior; active = $true; key_apps = $KeyApps
            key_id = $KeyId; public_key = $Key; registered_at = '2026-11-04T12:00:00Z' } }
    [void]$FakeInbox.AccessKeys.Add((Get-TestKeyRow 'mantenedor' 'raiz@example.org' 'Mantenedor' @('SuiteBUDA') $true @('TradutorBUDA') '0123456789abcdef' 'ssh-ed25519 AAAAexistente'))
    [void]$FakeInbox.AccessKeys.Add((Get-TestKeyRow 'serafim' 'serafim@example.org' 'Serafim' @('SuiteBUDA') $true @('TradutorBUDA') 'aaaabbbbccccdddd' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISerafimTradutor Serafim'))
    [void]$FakeInbox.AccessKeys.Add((Get-TestKeyRow 'serafim' 'serafim@example.org' 'Serafim' @('SuiteBUDA') $true @('ScanBUDA') 'eeeeffff00001111' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISerafimScan Serafim'))
    [void]$FakeInbox.AccessKeys.Add((Get-TestKeyRow 'pema' 'pema@example.org' 'Pema' @('ScanBUDA') $false @('ScanBUDA') '1111222233334444' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPemaScan Pema'))
    $signBefore = $script:SignCalls.Count
    $nk = (Invoke-Cli @{ command = 'action'; action = 'fix-inbox-new-keys'; session = '1'; confirm = $true }).data.inbox.lastNewKeys
    Assert-Equal "$($nk.requested)|$(@($nk.added) -join ',')" '4|serafim,serafim,pema' 'new keys: the three keys the registry lacks; the one it has is left out'
    $doc = [IO.File]::ReadAllText([string]$nk.draft) | ConvertFrom-Json
    $ser = @($doc.developers | Where-Object { $_.id -eq 'serafim' }); $pema = @($doc.developers | Where-Object { $_.id -eq 'pema' })
    Assert-That ($doc.version -eq 7 -and $ser.Count -eq 2 -and @($ser | Where-Object { $_.senior -and @($_.apps).Count -eq 0 }).Count -eq 2) 'new keys: both keys of a senior developer of every app, senior, every app'
    Assert-That ($pema.Count -eq 1 -and (@($pema[0].apps) -join ',') -eq 'ScanBUDA' -and -not $pema[0].senior) 'new keys: a ScanBUDA developer gets ScanBUDA only, not senior'
    Assert-That (@($doc.developers | Where-Object { $_.id -eq 'mantenedor' }).Count -eq 1 -and [IO.File]::ReadAllText([string]$nk.draft) -notmatch 'null') 'new keys: nothing removed, no null'
    Assert-That ($script:SignCalls.Count -eq $signBefore + 1 -and $script:SignCalls[$script:SignCalls.Count - 1] -match [regex]::Escape([string]$nk.draft)) 'new keys: the signing console opens with the draft'

    # ── Publicar registro: the signed file as text, where the apps fetch it ──
    $published = (Invoke-Cli @{ command = 'action'; action = 'fix-registry-publish'; session = '1'; confirm = $true }).data.inbox.lastPublished
    Assert-That ($published -eq 6 -and $FakeInbox.Published.Count -eq 1 -and $FakeInbox.Published[0] -eq [IO.File]::ReadAllText($registry)) 'publish: the signed file, byte for byte, as v6'
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-registry-publish'; session = '1'; confirm = $true })
    Assert-That ($FakeInbox.Published.Count -eq 1) 'publish: the same file again changes nothing'
    $script:VerifyValid = $false
    $err = Invoke-CliError @{ command = 'action'; action = 'fix-registry-publish'; session = '1'; confirm = $true }
    Assert-That ($err -match 'não confere' -and $FakeInbox.Published.Count -eq 1) 'publish: a registry that does not verify is not sent'
    $script:VerifyValid = $true
    Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-registry-publish'; session = '1' }) -match 'confirm') 'publish: needs confirm'

    # ── The same key under another id, and a registry that does not check, are refused ──
    $reply = $null
    $err = Invoke-CliError @{ command = 'action'; action = 'fix-inbox-add-developer'; session = '1'; confirm = $true; name = 'Outro'; email = 'outro@example.org'; publicKey = 'ssh-ed25519 AAAAexistente' }
    Assert-That ($err -match 'já está no registro') 'registry: a key already there under another id is refused'
    $script:VerifyValid = $false
    $err = Invoke-CliError @{ command = 'action'; action = 'fix-inbox-add-developer'; session = '1'; confirm = $true; name = 'Novo'; email = 'novo@example.org'; publicKey = $key.Replace('Tenzin', 'Novo').Replace('INova', 'INovb') }
    Assert-That ($err -match 'não confere') 'registry: one that does not check is not extended'
    $script:VerifyValid = $true

    # ── A wrong passphrase ──
    $w.Passphrase = ConvertTo-FixSecureText 'frase errada'
    $err = Invoke-CliError @{ command = 'action'; action = 'fix-inbox-add-developer'; session = '1'; confirm = $true; name = 'Y'; email = 'y@example.org' }
    Assert-That ($err -match 'recusou a frase-senha') 'a wrong passphrase is said plainly'
} catch {
    if ($_.Exception.Message -ne 'SKIP') { $testFailures.Add("unexpected: $($_.Exception.Message) $($_.ScriptStackTrace)"); Write-Output "FAIL unexpected: $($_.Exception.Message)" }
} finally {
    if ($form) { $form.Close(); $form.Dispose() }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output ''
Write-Output "$testPassed passed, $($testFailures.Count) failed"
if ($testFailures.Count) { $testFailures | ForEach-Object { Write-Output "  - $_" }; exit 1 }
exit 0
