if (-not (Get-Command Get-Sha256File -ErrorAction SilentlyContinue)) {
    function Get-Sha256File([string]$Path) {
        $full = (Resolve-Path -LiteralPath $Path).ProviderPath
        $sha  = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.IO.File]::ReadAllBytes($full)
            return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
    }
}
# ── "Sugestões recebidas" — the maintainer's window ──────────────────────────────────────────────
# With the admin passphrase (fix_inbox_* functions): list the inbox, fetch a bundle and verify it with the
# installed BundleTool against a worktree at the release tag. The report puts the problems, what the
# change adds and what goes beyond the developer's ceiling FIRST, then the diff. Nothing is built before
# "Abrir PR…" is confirmed; "Mesclar PR…" and "Recusar…" are separate confirmed actions. Also: register
# the verified registry's developers in the inbox, open or close the inbox (the kill switch), and add a new
# developer (FixDevInvite.ps1).

function Show-FixInboxWindow {
    param($TabState, $Owner)
    $layout = $UI.FixInbox
    $form = Build-FixForm 'Sugestões recebidas' $layout
    $w = Build-FixWindowState $TabState 'inbox' $form
    $c = $w.Controls; $b = $w.Buttons; $width = $layout.Width; $bottom = $layout.Height - 46
    Add-FixPassphraseRow $w 14 $width
    $b.Refresh = Add-FixControl $form 'Button' 'Atualizar lista' 16 84 140 $UI.BtnH
    $b.Verify = Add-FixControl $form 'Button' 'Baixar e verificar' 164 84 160 $UI.BtnH
    $b.VerifyFile = Add-FixControl $form 'Button' 'Verificar arquivo local...' 332 84 200 $UI.BtnH
    $b.Settings = Add-FixControl $form 'Button' 'Configurar...' ($width - 136) 84 120 $UI.BtnH 'Top,Right'
    $b.Register = Add-FixControl $form 'Button' 'Registrar desenvolvedores...' 16 126 220 $UI.BtnH
    $b.OpenInbox = Add-FixControl $form 'Button' 'Abrir a caixa' 244 126 120 $UI.BtnH
    $b.CloseInbox = Add-FixControl $form 'Button' 'Fechar a caixa' 372 126 130 $UI.BtnH
    $b.AddDeveloper = Add-FixControl $form 'Button' 'Adicionar desenvolvedor...' 510 126 210 $UI.BtnH
    $b.NewKeys = Add-FixControl $form 'Button' 'Chaves novas...' 728 126 130 $UI.BtnH
    $b.PublishRegistry = Add-FixControl $form 'Button' 'Publicar registro' 866 126 142 $UI.BtnH
    $c.Rows = Add-FixListView $form 16 170 ($width - 32) 140 @(@('Nº', 46), @('Recebido', 112), @('Desenvolvedor', 110), @('App', 96), @('Versão', 60), @('Título', 270), @('Status', 80), @('PR', 60))
    $c.Report = Add-FixControl $form 'TextBox' '' 16 320 ($width - 32) ($bottom - 332) 'Top,Bottom,Left,Right'
    $c.Report.Multiline = $true; $c.Report.ReadOnly = $true; $c.Report.ScrollBars = 'Both'; $c.Report.WordWrap = $false; $c.Report.MaxLength = 0
    $c.Report.Font = New-Object System.Drawing.Font('Consolas', 9)
    $c.Report.Text = 'Escolha uma sugestão e clique Baixar e verificar, ou verifique um arquivo local.' + [Environment]::NewLine + 'O relatório mostra primeiro os problemas e as capacidades; o diff vem depois.'
    $b.OpenPr = Add-FixControl $form 'Button' 'Abrir PR...' 16 $bottom 120 $UI.BtnH 'Bottom,Left'
    $b.Decline = Add-FixControl $form 'Button' 'Recusar...' 144 $bottom 110 $UI.BtnH 'Bottom,Left'
    $b.Merge = Add-FixControl $form 'Button' 'Mesclar PR...' 262 $bottom 130 $UI.BtnH 'Bottom,Left'
    $c.Status = Add-FixControl $form 'Label' '' 400 ($bottom + 4) ($width - 400 - 124) $UI.RowH 'Bottom,Left,Right'
    $b.Close = Add-FixControl $form 'Button' 'Fechar' ($width - 116) $bottom 100 $UI.BtnH 'Bottom,Right'
    $steps = @{ Refresh = 'inbox-refresh'; Verify = 'inbox-verify'; VerifyFile = 'inbox-verify-file'; Settings = 'settings'; OpenPr = 'inbox-open-pr'
        Decline = 'inbox-decline'; Merge = 'inbox-merge'; Register = 'inbox-register'; OpenInbox = 'inbox-open'; CloseInbox = 'inbox-close'
        AddDeveloper = 'inbox-add-developer'; NewKeys = 'inbox-new-keys'; PublishRegistry = 'inbox-publish-registry' }
    foreach ($name in $steps.Keys) { $step = $steps[$name]; $b[$name].Add_Click({ Invoke-FixWindowStep $w $step }.GetNewClosure()) }
    $c.Rows.Add_SelectedIndexChanged({ Sync-FixWindowButtons $w }.GetNewClosure())
    $b.Close.Add_Click({ $form.Close() }.GetNewClosure())
    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($b.OpenPr, 'Worktree at the release tag on the branch the registry assigns → bundle-apply → commit as you → Gitleaks → push → gh pr create --base main. Asks first.')
    $tips.SetToolTip($b.Merge, 'gh pr merge --merge into main. Only after the build, the targeted tests and the Codacy mirror on the PR worktree.')
    $tips.SetToolTip($b.Register, 'fix_inbox_register_developer for each developer of the verified, root-signed registry (each one invited first, in Authentication > Users, with the same e-mail).')
    $tips.SetToolTip($b.NewKeys, 'fix_inbox_developer_keys: the keys invited people registered from their apps that the registry lacks go into its next version; the signing console opens (root password there).')
    $tips.SetToolTip($b.PublishRegistry, 'dev_registry_publish: the signed registry, after BundleTool verifies it, where the apps fetch it. Only an invited developer compiles in the apps.')
    $tips.SetToolTip($b.CloseInbox, 'The kill switch: fix_inbox_set_open false. New suggestions are refused until the inbox is opened again.')
    $tips.SetToolTip($b.AddDeveloper, 'dev-invite (Supabase): approves the e-mail, creates the account, e-mails the invitation (or gives you the link when Supabase cannot) and makes it a developer. With the public key: the next registry version and its signing console.')
    Show-FixSessionLabel $w
    Sync-FixWindowButtons $w
    if ($Owner) { $form.Show($Owner) } else { $form.Show() }
    $c.Passphrase.Focus() | Out-Null
    return $w
}

function Get-FixSelectedRow {
    param($Window)
    $list = $Window.Controls.Rows
    if (-not $list -or $list.SelectedItems.Count -eq 0) { return $null }
    return $list.SelectedItems[0].Tag
}

function Select-FixInboxRow {
    param($Window, [long]$Id)
    foreach ($item in $Window.Controls.Rows.Items) {
        if ([long]$item.Tag.id -eq $Id) { $item.Selected = $true; $item.EnsureVisible(); Sync-FixWindowButtons $Window; return $item.Tag }
    }
    throw "A sugestão nº $Id não está na lista (clique Atualizar lista)."
}

function Show-FixInboxRows {
    param($Window, $Rows)
    $Window.Rows = @($Rows)
    Show-FixRows $Window $Rows { param($r) $r.id, (Format-FixWhen $r.created_at), $r.developer_id, $r.app, $r.app_version, $r.title, $r.status, $(if ($r.pr_url) { ($r.pr_url -split '/')[-1] } else { '' }) }
    Sync-FixWindowButtons $Window
}

function Sync-FixInboxRow {
    param($Window, $Row)
    if (-not $Row) { return }
    $selected = Get-FixSelectedRow $Window
    $rows = @($Window.Rows | ForEach-Object { if ([long]$_.id -eq [long]$Row.id) { $Row } else { $_ } })
    Show-FixInboxRows $Window $rows
    if ($selected) { try { [void](Select-FixInboxRow $Window ([long]$selected.id)) } catch { Write-Debug 'row left the list' } }
}

function Sync-FixInboxRows {
    param($Window)
    $settings = Get-FixInboxSettings
    if (Test-FixDryRun $Window) {
        $plan = Get-FixInboxList $settings $null '' -DryRun
        Write-FixLog $Window (@('[dry run] listar a caixa:') + @($plan.Requests | ForEach-Object { "    $_" }))
        Write-FixWindowStatus $Window 'Dry run: nada foi pedido ao Supabase. Use Verificar arquivo local... para um pacote em disco.'
        return
    }
    Send-FixPendingStatuses $Window
    $rows = @(Get-FixInboxList $settings $Window.Passphrase '')
    $found = @(Find-FixLostPullRequests $Window $rows)
    if ($found.Count) {
        foreach ($f in $found) { Add-FixPendingStatus $f.Id $f.Fields }
        Send-FixPendingStatuses $Window
        $rows = @(Get-FixInboxList $settings $Window.Passphrase '')
    }
    Show-FixInboxRows $Window $rows
    $waiting = @($rows | Where-Object { $_.status -eq 'received' }).Count
    Write-FixWindowStatus $Window "$($rows.Count) sugestão(ões); $waiting aguardando leitura."
}

function Invoke-FixInboxVerifyRow {
    param($Window)
    $row = Get-FixSelectedRow $Window
    if (-not $row) { throw 'Escolha uma sugestão da lista.' }
    $settings = Get-FixInboxSettings
    if (Test-FixDryRun $Window) {
        $plan = Save-FixBundleFromInbox $settings $null $row '' -DryRun
        Write-FixLog $Window (@("[dry run] baixar a sugestão nº $($row.id):") + @($plan.Requests | ForEach-Object { "    $_" }))
        return
    }
    Write-FixWindowStatus $Window "Baixando a sugestão nº $($row.id)..."
    $path = Save-FixBundleFromInbox $settings $Window.Passphrase $row ([string]$settings.inboxFolder)
    Invoke-FixInboxVerifyFile $Window $path ([long]$row.id)
}

function Invoke-FixInboxPickFile {
    param($Window)
    $request = $Window.CliBundle
    $Window.CliBundle = $null
    $path = $request
    if (-not $path) {
        $path = @(Invoke-BudaFilePicker -Key 'fix.inbox-bundle' -Purpose File -Title 'Um pacote de sugestão para verificar' -Owner $Window.Form `
            -DefaultFolder ([string](Get-FixInboxSettings).inboxFolder) -Filters @(@{ Name = 'Pacote de sugestão (*.budafix)'; Pattern = '*.budafix' })) | Select-Object -First 1
    }
    if (-not $path) { return }
    $id = 0
    $row = Get-FixSelectedRow $Window
    $sha = (Get-Sha256File $path)
    if ($row -and [string]$row.bundle_sha256 -eq $sha) { $id = [long]$row.id }
    Invoke-FixInboxVerifyFile $Window ([string]$path) $id
}

# Verifies $Path against the release its manifest names and fills the report: verdict, problems and
# capabilities first, then the diff. $SubmissionId is the inbox row it came from (0: a local file).
function Invoke-FixInboxVerifyFile {
    param($Window, [string]$Path, [long]$SubmissionId)
    $Window.Verification = $null
    $Window.Controls.Report.Text = ''
    $summary = Read-FixBundleManifest $Path
    $app = Get-App $summary.app
    if (-not $app) { throw "O app '$($summary.app)' do pacote não está em apps.json." }
    $settings = Get-FixInboxSettings
    Write-FixWindowStatus $Window "Preparando a árvore da release $($summary.appVersion) (uma vez por versão)..."
    $release = Initialize-FixReleaseWorktree $settings $app $summary.appVersion
    if ($release.TagNote) { Write-FixLog $Window @("base da release: $($release.TagNote).") }
    Write-FixWindowStatus $Window 'Verificando com o BundleTool...'
    $result = Invoke-FixBundleVerify $settings $summary.app $Path $release.SourceRoot
    $report = @(Format-FixVerification $result $summary $release.Tag)
    $diff = if ($result.valid -or $result.changes) { Get-FixBundleDiff $Path $release.SourceRoot $result.changes } else { '' }
    $Window.Verification = @{ Result = $result; Summary = $summary; Release = $release; BundlePath = $Path; SubmissionId = $SubmissionId; App = $app; DiffChars = $diff.Length }
    $nl = [Environment]::NewLine
    $Window.Controls.Report.Text = ($report -join $nl) + $nl + $nl + '──────── DIFF (contra a release ' + $release.Tag + ') ────────' + $nl + $diff.Replace("`r`n", "`n").Replace("`n", $nl)
    Write-FixLog $Window (@("verificação de $([IO.Path]::GetFileName($Path)):") + @($report | ForEach-Object { "    $_" }))
    $verdict = if ($result.valid) { 'O pacote confere. Leia o relatório e o diff; Abrir PR... pede confirmação.' } else { 'O pacote NÃO confere: veja os problemas no topo do relatório.' }
    Write-FixWindowStatus $Window $verdict (-not $result.valid)
}

function Invoke-FixInboxOpenPr {
    param($Window)
    $v = $Window.Verification
    if (-not $v -or -not $v.Result.valid) { throw 'Verifique um pacote que confira antes de abrir o PR.' }
    $result = $v.Result
    if (-not (Test-FixBranchName $result.branch)) { throw "O verificador devolveu uma branch inválida: $($result.branch)" }
    if (@($result.overCeiling).Count -gt 0) {
        $over = @($result.overCeiling) -join ', '
        if ($Window.CliConfirmed -and -not $Window.CliOverrideCeiling) { throw "PR não aberto: a mudança acrescenta $over, acima do teto do desenvolvedor; abri-lo é decisão sua (overrideCeiling:true)." }
        if (-not $Window.CliConfirmed -and -not (Confirm-FixStep $Window "A mudança acrescenta $over, acima do teto do desenvolvedor $($result.developer).`n`nAbrir o PR mesmo assim (decisão sua, registrada no commit)?" 'Acima do teto' 'Warning')) {
            Write-FixWindowStatus $Window 'PR não aberto: capacidades acima do teto sem a sua decisão.'
            return
        }
    }
    $settings = Get-FixInboxSettings
    $scanner = Resolve-GitBootstrapScanner $Window.TabState.Controls.BootstrapScanner.Text.Trim() $AppDir
    if (-not $scanner) { throw 'O Gitleaks não foi encontrado, então nada foi feito (Gitleaks path na seção de bootstrap, PATH ou uma pasta gitleaks_* ao lado do InstaladorBUDA).' }
    $repoSlug = Resolve-AppRepo $v.App
    if ($repoSlug -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "O repositório GitHub de $($v.App.name) não foi encontrado." }
    $message = Get-FixCommitMessage $result $v.Summary $v.Release.Tag $v.SubmissionId
    if (@($result.overCeiling).Count -gt 0) { $message += "`nCapacidades acima do teto aceitas pelo mantenedor: $(@($result.overCeiling) -join ', ')." }
    $messageFile = Write-FixTempText 'commit' $message
    $bodyFile = Write-FixTempText 'pr' (Get-FixPullRequestBody $result $message)
    $resultFile = Join-Path $env:TEMP ('instaladorbuda-pr-' + [guid]::NewGuid().ToString('N') + '.txt')
    $plan = @{
        RepoRoot = [string]$v.App.repoRoot; Worktree = Join-Path ([string]$settings.worktreeRoot) "$($v.App.name)\$($result.branch.Replace('/', '-'))"
        Branch = [string]$result.branch; Tag = $v.Release.Tag; BundlePath = $v.BundlePath; BundleSha = $v.Summary.sha256
        SourceRoot = (Get-FixSourceRoot $v.Summary.app)
        BaseRef = $v.Release.BaseRef
        Tool = (Get-FixBundleToolCommand $settings $v.Summary.app); RegistryArgs = (Get-FixRegistryArguments $settings); Scanner = $scanner
        GitHubRepo = $repoSlug; Title = ([string]$result.title -replace '[\r\n]+', ' ').Trim(); MessageFile = $messageFile; BodyFile = $bodyFile; ResultFile = $resultFile
    }
    $commands = Build-FixPullRequestCommands $plan
    Invoke-FixJob $Window $commands "Abrir PR $($result.branch)" ([string]$v.App.repoRoot) 'pr' $resultFile @($messageFile, $bodyFile) $v.SubmissionId $null
}

# Hands the commands to the session's job runner (its confirmation lists them; a dry run only logs them).
function Invoke-FixJob {
    param($Window, [string[]]$Commands, [string]$Label, [string]$RepoRoot, [string]$Kind, [string]$ResultFile, [string[]]$TempFiles, [long]$SubmissionId, [hashtable]$Fields)
    $w = $Window
    $onDone = { Complete-FixPullRequest $w $Kind $ResultFile $TempFiles $SubmissionId $Fields }.GetNewClosure()
    $tab = $Window.TabState
    $tab.CliConfirmed = [bool]$Window.CliConfirmed
    try { & $tab.StartJob $Commands $Label $true $RepoRoot $null $onDone } finally { $tab.CliConfirmed = $false }
    if (-not $tab.IsRunning) {
        foreach ($f in @($TempFiles)) { if ($f) { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue } }
        $what = if (Test-FixDryRun $Window) { 'Dry run: os comandos estão no log da sessão; nada foi executado.' } else { 'Nada foi executado (cancelado, ou a sessão já tem um job).' }
        Write-FixWindowStatus $Window $what
        return
    }
    Write-FixWindowStatus $Window "$Label em andamento: acompanhe no log da sessão."
}

function Invoke-FixInboxMerge {
    param($Window)
    $row = Get-FixSelectedRow $Window
    if (-not $row -or $row.status -ne 'pr-opened' -or -not $row.pr_url) { throw 'Escolha uma sugestão com PR aberto.' }
    $app = Get-App ([string]$row.app)
    if (-not $app) { throw "O app '$($row.app)' não está em apps.json." }
    $question = "Mesclar $($row.pr_url) em main?`n`nFaça isto só depois do build, dos testes do que mudou e do espelho do Codacy na worktree do PR."
    if (-not (Confirm-FixStep $Window $question 'Mesclar PR' 'Warning')) { Write-FixWindowStatus $Window 'Mesclagem cancelada.'; return }
    $resultFile = Join-Path $env:TEMP ('instaladorbuda-merge-' + [guid]::NewGuid().ToString('N') + '.txt')
    $commands = Build-FixMergeCommands (Resolve-AppRepo $app) ([string]$row.pr_url) $resultFile
    $Window.CliConfirmed = $true
    try { Invoke-FixJob $Window $commands "Mesclar PR da sugestão nº $($row.id)" ([string]$app.repoRoot) 'merge' $resultFile @() ([long]$row.id) @{ status = 'merged' } }
    finally { $Window.CliConfirmed = $false }
}

function Invoke-FixInboxDecline {
    param($Window)
    $row = Get-FixSelectedRow $Window
    if (-not $row) { throw 'Escolha uma sugestão da lista.' }
    $note = if ($null -ne $Window.CliNote) { [string]$Window.CliNote } else { Read-FixNote $Window "Por que a sugestão nº $($row.id) foi recusada? (o desenvolvedor lê esta nota)" }
    if ($null -eq $note) { Write-FixWindowStatus $Window 'Recusa cancelada.'; return }
    if ($note.Length -gt 4000) { throw 'A nota passa de 4000 caracteres.' }
    if (-not (Confirm-FixStep $Window "Marcar a sugestão nº $($row.id) como recusada?" 'Recusar sugestão' 'Warning')) { Write-FixWindowStatus $Window 'Recusa cancelada.'; return }
    $fields = @{ status = 'declined'; maintainer_note = $note }
    $settings = Get-FixInboxSettings
    if ($row.status -eq 'pr-opened' -and $row.pr_url) {
        # Its PR is open: close it on GitHub first (a job), then the row is written.
        $app = Get-App ([string]$row.app)
        if (-not $app) { throw "O app '$($row.app)' não está em apps.json." }
        $resultFile = Join-Path $env:TEMP ('instaladorbuda-close-' + [guid]::NewGuid().ToString('N') + '.txt')
        $commands = Build-FixCloseCommands (Resolve-AppRepo $app) ([string]$row.pr_url) $resultFile
        $Window.CliConfirmed = $true
        try { Invoke-FixJob $Window $commands "Recusar a sugestão nº $($row.id) e fechar o PR" ([string]$app.repoRoot) 'decline' $resultFile @() ([long]$row.id) $fields }
        finally { $Window.CliConfirmed = $false }
        return
    }
    if (Test-FixDryRun $Window) {
        $plan = Send-FixSubmissionStatus $settings $null ([long]$row.id) $fields -DryRun
        Write-FixLog $Window (@('[dry run] recusar:') + @($plan.Requests | ForEach-Object { "    $_" }))
        return
    }
    [void](Send-FixSubmissionStatus $settings $Window.Passphrase ([long]$row.id) $fields)
    Sync-FixInboxRow $Window (Get-FixInboxRowById $Window ([long]$row.id))
    Write-FixLog $Window @("sugestão nº $($row.id) recusada.")
    Write-FixWindowStatus $Window "Sugestão nº $($row.id) recusada."
}

function Read-FixNote {
    param($Window, [string]$Question)
    $form = Build-FixForm 'Nota para o desenvolvedor' @{ Width = 520; Height = 240 } -Fixed
    [void](Add-FixControl $form 'Label' $Question 16 12 488 $UI.RowH)
    $box = Add-FixControl $form 'TextBox' '' 16 44 488 130
    $box.Multiline = $true; $box.ScrollBars = 'Vertical'; $box.AcceptsReturn = $true; $box.MaxLength = 4000
    $ok = Add-FixControl $form 'Button' 'OK' 296 190 100 $UI.BtnH
    $cancel = Add-FixControl $form 'Button' 'Cancelar' 404 190 100 $UI.BtnH
    $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'; $form.AcceptButton = $null; $form.CancelButton = $cancel
    try {
        if ($form.ShowDialog($Window.Form) -ne 'OK') { return $null }
        return $box.Text.Trim()
    } finally { $form.Dispose() }
}

# fix_inbox_set_status returns nothing: the row is read back from the list.
function Get-FixInboxRowById {
    param($Window, [long]$Id)
    $rows = @(Get-FixInboxList (Get-FixInboxSettings) $Window.Passphrase '')
    return ($rows | Where-Object { [long]$_.id -eq $Id } | Select-Object -First 1)
}

# Registers in the inbox (fix_inbox_register_developer) each developer of the registry BundleTool has just
# verified against the root key: the inbox's copy follows the root-signed one. Each needs an invited account.
function Invoke-FixInboxRegister {
    param($Window)
    $settings = Get-FixInboxSettings
    $developers = @(Get-FixRegistryDevelopers $settings)
    $ready = @($developers | Where-Object { $_.email })
    foreach ($d in @($developers | Where-Object { -not $_.email })) { Write-FixLog $Window @("o desenvolvedor $($d.id) não tem e-mail no registro: não foi registrado na caixa.") }
    if ($ready.Count -eq 0) { throw 'O registro não tem desenvolvedores com e-mail para registrar na caixa.' }
    if (Test-FixDryRun $Window) {
        foreach ($d in $ready) { Write-FixLog $Window (@("[dry run] registrar $($d.id):") + @((Register-FixInboxDeveloper $settings $null $d -DryRun).Requests | ForEach-Object { "    $_" })) }
        return
    }
    $names = ($ready | ForEach-Object { "$($_.id) <$($_.email)>$(if (-not $_.active) { ' (revogado)' })" }) -join "`n"
    if (-not (Confirm-FixStep $Window "Registrar na caixa os desenvolvedores do registro verificado?`n`n$names`n`nCada conta precisa ter sido convidada antes (Authentication > Users), com o mesmo e-mail." 'Registrar desenvolvedores')) { Write-FixWindowStatus $Window 'Registro cancelado.'; return }
    $results = @()
    foreach ($d in $ready) {
        try { $uid = Register-FixInboxDeveloper $settings $Window.Passphrase $d; $results += [pscustomobject]@{ id = $d.id; ok = $true; userId = [string]$uid } }
        catch { $results += [pscustomobject]@{ id = $d.id; ok = $false; error = $_.Exception.Message } }
    }
    $Window.LastRegistered = $results
    Write-FixLog $Window @($results | ForEach-Object { if ($_.ok) { "desenvolvedor $($_.id) registrado na caixa (conta $($_.userId))." } else { "desenvolvedor $($_.id) NÃO registrado: $($_.error)" } })
    $failed = @($results | Where-Object { -not $_.ok }).Count
    if ($failed) { throw "$failed de $($results.Count) desenvolvedor(es) não foram registrados (veja o log da sessão)." }
    Write-FixWindowStatus $Window "$($results.Count) desenvolvedor(es) registrado(s) na caixa."
}

function Invoke-FixInboxSetOpen {
    param($Window, [bool]$Open)
    $settings = Get-FixInboxSettings
    $cap = $Window.CliMaxPerHour
    $what = if ($Open) { 'abrir' } else { 'fechar' }
    if (Test-FixDryRun $Window) {
        Write-FixLog $Window (@("[dry run] $what a caixa:") + @((Send-FixInboxOpen $settings $null $Open $cap -DryRun).Requests | ForEach-Object { "    $_" }))
        return
    }
    $question = if ($Open) { 'Abrir a caixa de sugestões? Os desenvolvedores registrados voltam a poder enviar.' } else { 'Fechar a caixa de sugestões? Todo envio novo é recusado até abri-la de novo.' }
    if (-not (Confirm-FixStep $Window $question 'Caixa de sugestões' 'Warning')) { Write-FixWindowStatus $Window 'Nada mudou.'; return }
    [void](Send-FixInboxOpen $settings $Window.Passphrase $Open $cap)
    $state = if ($Open) { 'aberta' } else { 'fechada' }
    Write-FixLog $Window @("caixa de sugestões $state$(if ($null -ne $cap) { ", até $cap por hora" }).")
    Write-FixWindowStatus $Window "Caixa $state."
}
