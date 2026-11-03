# The two flows of tests\FixInbox.Tests.ps1 (dot-sourced by it, after its fixtures exist).

$contributorId = '11111111-1111-4111-8111-111111111111'
Add-FakeInboxUser 'tenzin@example.org' 'senha-tenzin' $contributorId       # invited, not yet registered
$adminPassphrase = $FakeInbox.Passphrase
if (-not (Resolve-GitBootstrapScanner '' $AppDir)) {
    Write-Output 'note: no Gitleaks beside InstaladorBUDA; a stand-in that finds nothing is used for the PR job'
    [IO.File]::WriteAllText((Join-Path $bin 'gitleaks.cmd'), "@echo off`r`nexit /b 0`r`n")
    $tab.Controls.BootstrapScanner.Text = Join-Path $bin 'gitleaks.cmd'
}
function Get-Row { param([int]$Id) return ($FakeInbox.Rows | Where-Object { $_.id -eq $Id } | Select-Object -First 1) }
function Use-Passphrase { param($Window, [string]$Text) $Window.Controls.Passphrase.Text = $Text; $Window.Buttons.UsePassphrase.PerformClick() }

# ── Contributor before being registered: the inbox refuses the row ──
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-suggest'; session = '1'; password = 'x' }) -match 'credential') 'cli: a password field is refused'
$reply = Invoke-Cli @{ command = 'action'; action = 'fix-suggest'; session = '1'; bundle = $good; email = 'tenzin@example.org' }
$sw = $tab.FixSuggest
Assert-That ($sw -and $sw.Form.Visible) 'cli fix-suggest: the window opened'
Assert-Equal $reply.data.suggest.bundle.title 'Corrige o valor do marcador' 'suggest: the manifest is read'
Assert-Equal $reply.data.suggest.bundle.keyId $devId.keyId 'suggest: the key id comes from the signature'
Assert-That ($sw.Controls.Summary.Text.Contains('changed  com/example/glossariobuda/ui/BundleFixture.java') -and $sw.Controls.Summary.Text.Contains('changed  com/example/glossariobuda/ui/Outro.java')) 'suggest: files and what happens to each'
Assert-That (-not $sw.Buttons.Send.Enabled) 'suggest: Enviar is off before signing in'
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-suggest-send'; session = '1'; confirm = $true }) -match 'not available') 'cli fix-suggest-send: refused before signing in'
$sw.Controls.Password.Text = 'errada'; $sw.Buttons.SignIn.PerformClick()
Assert-That ($sw.LastError -match 'incorretos') 'sign-in: a wrong password is refused'
Assert-Equal $sw.Controls.Password.Text '' 'sign-in: the password box is cleared after each try'
$sw.Controls.Password.Text = 'senha-tenzin'; $sw.Buttons.SignIn.PerformClick()
Assert-That ([bool]$tab.FixShared.Session -and $tab.FixShared.Session.UserId -eq $contributorId) 'sign-in: the session is kept in memory'
Assert-That ($sw.Buttons.Send.Enabled) 'suggest: Enviar is on after signing in'
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-suggest-send'; session = '1'; confirm = $true }) -match 'não está registrada') 'rules: an account not registered as a developer cannot send'

# ── Maintainer: the admin passphrase, the registry into the inbox, the kill switch ──
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-inbox'; session = '1'; passphrase = 'x' }) -match 'credential') 'cli: a passphrase field is refused'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox'; session = '1' })
$iw = $tab.FixInbox
Use-Passphrase $iw 'não é esta'
Assert-That ($iw.LastError -match 'frase-senha' -and -not $iw.Passphrase -and $iw.Controls.Passphrase.Text -eq '') 'passphrase: a wrong one is refused, cleared and not kept'
Use-Passphrase $iw $adminPassphrase
Assert-That ([bool]$iw.Passphrase -and $iw.Controls.Passphrase.Text -eq '') 'passphrase: accepted, kept as a SecureString, box cleared'
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-inbox-register'; session = '1' }) -match 'confirm') 'cli fix-inbox-register: needs confirm'
$reply = Invoke-Cli @{ command = 'action'; action = 'fix-inbox-register'; session = '1'; confirm = $true }
$tenzin = $FakeInbox.Users['tenzin@example.org']
Assert-Equal "$($tenzin.DeveloperId)|$($tenzin.KeyId)|$($tenzin.Apps -join ',')|$($tenzin.Active)" "tenzin|$($devId.keyId)|TradutorBUDA|True" 'register: the verified registry''s developer is in the inbox'
Assert-Equal (@($reply.data.inbox.lastRegistered | ForEach-Object { "$($_.id):$($_.ok)" }) -join ',') 'tenzin:True' 'cli fix-inbox-register: reports each developer'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-close'; session = '1'; confirm = $true })
Assert-That (-not $FakeInbox.Open) 'kill switch: the inbox is closed'
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-suggest-send'; session = '1'; confirm = $true }) -match 'closed') 'kill switch: a closed inbox refuses a suggestion'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-open'; session = '1'; confirm = $true; maxPerHour = 5 })
Assert-That ($FakeInbox.Open -and $FakeInbox.MaxPerHour -eq 5) 'kill switch: open again, with the hourly cap'

# ── Contributor: Sugerir mudança (PR) ──
$before = $FakeInbox.Calls.Count
$tab.Controls.DryRun.Checked = $true
[void](Invoke-Cli @{ command = 'action'; action = 'fix-suggest-send'; session = '1' })
Assert-Equal $FakeInbox.Calls.Count $before 'dry run send: nothing reaches the inbox'
Assert-That ($tab.Controls.Log.Text.Contains('[dry run] enviar') -and $tab.Controls.Log.Text.Contains('bundle_b64')) 'dry run send: the requests are in the log'
$tab.Controls.DryRun.Checked = $false
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-suggest-send'; session = '1' }) -match 'confirm') 'cli fix-suggest-send: needs confirm'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-suggest-send'; session = '1'; confirm = $true })
$row1 = Get-Row 1
Assert-Equal "$($row1.status)|$($row1.user_id)|$($row1.key_id)|$($row1.slug)" "received|$contributorId|$($devId.keyId)|corrige-marcador" 'send: one row, received, as the contributor, with their key'
Assert-That ([Convert]::ToBase64String([IO.File]::ReadAllBytes($good)) -ceq $row1.bundle_b64 -and $row1.bundle_sha256 -eq (Get-Sha $good)) 'send: the bundle travels in the row, with its SHA-256'
$insert = @($FakeInbox.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/rest/v1/fix_submissions*' } | Select-Object -Last 1)[0]
Assert-That ($insert.Body -notmatch '"(user_id|status)"' -and $insert.Uri -notmatch 'bundle_b64') 'send: the database fills user_id and status; the reply leaves the bundle out'
Assert-Equal @(Get-FixSentRecords).Count 1 'send: kept in the local record'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-suggest-send'; session = '1'; confirm = $true })
Assert-Equal $FakeInbox.Rows.Count 1 'send again: not sent twice'
Assert-That ($tab.FixSuggest.LastStatus -match 'já estava') 'send again: says it is already in the inbox'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-suggest'; session = '1'; bundle = $over })
[void](Invoke-Cli @{ command = 'action'; action = 'fix-suggest-send'; session = '1'; confirm = $true })
Assert-Equal $FakeInbox.Rows.Count 2 'send: a second suggestion'
$tab.FixSuggest.Form.Close(); [System.Windows.Forms.Application]::DoEvents()
[void](Invoke-Cli @{ command = 'action'; action = 'fix-sign-out'; session = '1' })
$reply = Invoke-Cli @{ command = 'action'; action = 'fix-suggest'; session = '1' }
Assert-Equal (@($reply.data.suggest.rows | ForEach-Object { "$($_.id):$($_.status)" }) -join ',') '2:received,1:received' 'later open: the last known status, before signing in'
$tab.FixSuggest.Form.Close(); [System.Windows.Forms.Application]::DoEvents()

# ── Maintainer: Sugestões recebidas ──
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-refresh'; session = '1' })
Assert-Equal (@($iw.Rows | ForEach-Object { "$($_.id):$($_.developer_id)" }) -join ',') '2:tenzin,1:tenzin' 'inbox: every row, with its developer'
$reply = Invoke-Cli @{ command = 'action'; action = 'fix-inbox-verify'; session = '1'; id = 1 }
$v = $reply.data.inbox.verification
Assert-That ([bool]$v.valid) "verify: the bundle checks ($(@($v.problems) -join '; '))"
Assert-Equal $v.branch 'contrib/tenzin/corrige-marcador' 'verify: the branch is the registry''s'
Assert-Equal "$($v.tag)|$($v.submissionId)" 'tradutor-buda-v1.8.6|1' 'verify: against the release tag, bound to row 1'
$report = $iw.Controls.Report.Text
Assert-That ($report.IndexOf('VEREDITO') -eq 0 -and $report.IndexOf('CAPACIDADES') -lt $report.IndexOf('DIFF') -and $report.IndexOf('Arquivos:') -lt $report.IndexOf('DIFF')) 'report: verdict and capabilities first, the diff after'
Assert-That ($report.Contains('+   int v = 2;   // corrigido') -and $report.Contains('-   int v = 1;') -and $report.Contains('+   String nome()')) 'report: the diff shows both changes'
Assert-Equal (Invoke-Git @('-C', $repo, 'branch', '--list', 'contrib/*')) '' 'verify: no branch before Abrir PR'

$tab.Controls.DryRun.Checked = $true
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-open-pr'; session = '1' })
Assert-That ($tab.Controls.Log.Text.Contains('[dry run] Abrir PR contrib/tenzin/corrige-marcador') -and $tab.Controls.Log.Text.Contains('gh pr create')) 'dry run Abrir PR: the commands are in the log'
Assert-Equal (Invoke-Git @('-C', $repo, 'branch', '--list', 'contrib/*')) '' 'dry run Abrir PR: no branch'
$tab.Controls.DryRun.Checked = $false
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-inbox-open-pr'; session = '1' }) -match 'confirm') 'cli fix-inbox-open-pr: needs confirm'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-open-pr'; session = '1'; confirm = $true })
Wait-Job $tab
Assert-That ($tab.Controls.Log.Text.Contains('--- finished (OK) ---')) 'pr job: finished OK'
$prRef = 'refs/heads/contrib/tenzin/corrige-marcador'
Assert-Equal (Invoke-Git @('--git-dir', $origin, 'for-each-ref', '--format=%(refname)', 'refs/heads/contrib')) $prRef 'pr: the branch reached the stand-in GitHub'
$msg = Invoke-Git @('--git-dir', $origin, 'log', '-1', '--format=%an|%B', $prRef)
Assert-That ($msg.StartsWith('Maintainer Test|Corrige o valor do marcador')) 'pr: committed as the maintainer, with the suggested title'
Assert-That ($msg.Contains('Sugerido por Tenzin') -and $msg -notmatch '(?i)co-authored-by|generated') 'pr: the contributor credited by name, no other attribution'
Assert-Equal (Invoke-Git @('--git-dir', $origin, 'rev-parse', "$prRef^")) (Invoke-Git @('--git-dir', $origin, 'rev-parse', 'tradutor-buda-v1.8.6^{commit}')) 'pr: one commit on top of the release tag'
$blob = Invoke-Git @('--git-dir', $origin, 'show', "${prRef}:$fixture")
Assert-That ($blob.Contains('int v = 2;') -and -not $blob.Contains("`r")) 'pr: the committed file is the suggested one, stored with LF'
$ghLog = [IO.File]::ReadAllText($env:FAKE_GH_LOG)
Assert-That ($ghLog -match 'pr create --repo TestOwner/TradutorBUDA --base main --head contrib/tenzin/corrige-marcador') 'pr: gh pr create --base main from the contrib branch'
$row1 = Get-Row 1
Assert-Equal "$($row1.status)|$($row1.pr_url)" 'pr-opened|https://github.com/TestOwner/TradutorBUDA/pull/7' 'pr: status and address written back (fix_inbox_set_status)'
Assert-Equal (Invoke-Git @('-C', $repo, 'status', '--porcelain')) '' 'pr: the main checkout is untouched'

$reply = Invoke-Cli @{ command = 'action'; action = 'fix-inbox-verify'; session = '1'; bundle = $over }
$v = $reply.data.inbox.verification
Assert-That ([bool]$v.valid -and (@($v.overCeiling) -join ',') -eq 'EXEC' -and $v.submissionId -eq 0) 'over ceiling: valid, EXEC beyond the ceiling, a local file'
Assert-That ($iw.Controls.Report.Text.IndexOf('ACIMA DO TETO') -lt $iw.Controls.Report.Text.IndexOf('DIFF')) 'over ceiling: said before the diff'
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-inbox-open-pr'; session = '1'; confirm = $true }) -match 'teto') 'over ceiling: no PR without overrideCeiling'
$reply = Invoke-Cli @{ command = 'action'; action = 'fix-inbox-verify'; session = '1'; bundle = $bad }
Assert-That (-not $reply.data.inbox.verification.valid -and (@($reply.data.inbox.verification.problems) -join ' ') -match 'protected') 'protected path: refused by the verifier'
Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-inbox-open-pr'; session = '1'; confirm = $true }) -match 'not available') 'protected path: Abrir PR stays off'
$reply = Invoke-Cli @{ command = 'action'; action = 'fix-inbox-verify'; session = '1'; bundle = $newFile }
if ($reply.data.inbox.verification.valid) { Assert-That $true 'new file: a bundle that adds a class verifies' }
else { Write-Output "note: a bundle that adds a class does not verify yet ($(@($reply.data.inbox.verification.problems) -join '; ')) - TradutorBUDA FixBundles drops the null base from the manifest it signed" }
$newDiff = Get-FixBundleDiff $newFile (Join-Path $work 'shipped\src\main\java') ([pscustomobject]@{ 'com/example/glossariobuda/ui/Novo.java' = 'new' })
Assert-That ($newDiff.Contains('=== new: com/example/glossariobuda/ui/Novo.java') -and $newDiff.Contains('+class Novo { }')) 'diff: a new file is shown whole'

Assert-That ((Invoke-CliError @{ command = 'action'; action = 'fix-inbox-decline'; session = '1'; id = 2; confirm = $true }) -match 'note') 'decline: needs a note'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-decline'; session = '1'; id = 2; note = 'Precisa de outro caminho.'; confirm = $true })
Assert-Equal "$((Get-Row 2).status)|$((Get-Row 2).maintainer_note)" 'declined|Precisa de outro caminho.' 'decline: status and note on the row'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-merge'; session = '1'; id = 1; confirm = $true })
Wait-Job $tab
Assert-Equal (Get-Row 1).status 'merged' 'merge: the row says merged'
Assert-That ([IO.File]::ReadAllText($env:FAKE_GH_LOG) -match 'pr merge https://github.com/TestOwner/TradutorBUDA/pull/7 --repo TestOwner/TradutorBUDA --merge') 'merge: gh pr merge --merge, a separate confirmed action'

$statusJson = (Get-Status) | ConvertTo-Json -Depth 12
$leaks = @($FakeInbox.Calls | Where-Object { $_.Uri.Contains('frase') -or $_.Uri.Contains('senha') }).Count
Assert-That ($leaks -eq 0 -and -not $tab.Controls.Log.Text.Contains($adminPassphrase) -and -not $statusJson.Contains($adminPassphrase) -and -not $statusJson.Contains('tok-')) 'secrets: the passphrase and the token never reach a URL, the log or the CLI'
Assert-That (-not ((Get-Content -Raw $settingsFile) -match 'senha-tenzin|frase de administrador')) 'secrets: neither is saved in the settings'
Assert-That ([bool]$reply.data -and (Get-Status).inbox.passphraseSet) 'cli fix-status: says a passphrase is held, never which'
[void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-forget'; session = '1' })
Assert-That (-not $iw.Passphrase) 'cli fix-inbox-forget: the passphrase is dropped'
$iw.Form.Close(); [System.Windows.Forms.Application]::DoEvents()

# ── Contributor again: the status is back ──
[void](Invoke-Cli @{ command = 'action'; action = 'fix-suggest'; session = '1' })
$sw = $tab.FixSuggest
$sw.Controls.Password.Text = 'senha-tenzin'; $sw.Buttons.SignIn.PerformClick()
Assert-Equal (@($sw.Rows | ForEach-Object { "$($_.id):$($_.status)" }) -join ',') '2:declined,1:merged' 'contributor: sees declined and merged'
Assert-Equal (@(Get-FixSentRecords | ForEach-Object { "$($_.id):$($_.status)" }) -join ',') '2:declined,1:merged' 'contributor: the local record follows'
