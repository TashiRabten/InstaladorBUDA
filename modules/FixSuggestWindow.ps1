# ── "Sugerir mudança (PR)" — the contributor's window ────────────────────────────────────────────
# Pick the .budafix the app signed (~/.tradutorbuda/sugestoes), read what its manifest says, sign in to the
# inbox with the contributor's own account, send it, and follow its status. The list shows the local
# record of what was sent (last known status) until the account is signed in, then the inbox's rows.

function Show-FixSuggestWindow {
    param($TabState, $Owner)
    $layout = $UI.FixSuggest
    $form = Build-FixForm 'Sugerir mudança (PR)' $layout
    $w = Build-FixWindowState $TabState 'suggest' $form
    $c = $w.Controls; $b = $w.Buttons; $width = $layout.Width
    [void](Add-FixControl $form 'Label' 'Pacote (.budafix):' 16 12 120 $UI.RowH)
    $c.Bundle = Add-FixControl $form 'TextBox' '' 140 12 ($width - 140 - 128) $UI.RowH 'Top,Left,Right'
    $b.Pick = Add-FixControl $form 'Button' 'Escolher...' ($width - 120) 8 104 $UI.BtnH 'Top,Right'
    $c.Summary = Add-FixControl $form 'TextBox' '' 16 50 ($width - 32) 200 'Top,Left,Right'
    $c.Summary.Multiline = $true; $c.Summary.ReadOnly = $true; $c.Summary.ScrollBars = 'Vertical'; $c.Summary.MaxLength = 0
    $c.Summary.Text = 'Escolha o pacote .budafix assinado pelo TradutorBUDA, ScanBUDA ou SuiteBUDA em Enviar como sugestão.'
    Add-FixSignInRow $w 266 $width
    $b.Send = Add-FixControl $form 'Button' 'Enviar sugestão' 16 336 160 $UI.BtnH
    $b.Refresh = Add-FixControl $form 'Button' 'Atualizar status' 184 336 150 $UI.BtnH
    $b.Settings = Add-FixControl $form 'Button' 'Configurar...' ($width - 136) 336 120 $UI.BtnH 'Top,Right'
    $c.Rows = Add-FixListView $form 16 380 ($width - 32) 166 @(@('Nº', 50), @('Enviado', 120), @('Título', 300), @('Status', 90), @('PR', 150))
    $c.Rows.Anchor = 'Top,Bottom,Left,Right'
    $c.Status = Add-FixControl $form 'Label' '' 16 ($layout.Height - 42) ($width - 140) $UI.RowH 'Bottom,Left,Right'
    $b.Close = Add-FixControl $form 'Button' 'Fechar' ($width - 116) ($layout.Height - 46) 100 $UI.BtnH 'Bottom,Right'
    $b.Pick.Add_Click({ Invoke-FixWindowStep $w 'suggest-pick' }.GetNewClosure())
    $c.Bundle.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Invoke-FixWindowStep $w 'suggest-load' } }.GetNewClosure())
    $b.Send.Add_Click({ Invoke-FixWindowStep $w 'suggest-send' }.GetNewClosure())
    $b.Refresh.Add_Click({ Invoke-FixWindowStep $w 'suggest-refresh' }.GetNewClosure())
    $b.Settings.Add_Click({ Invoke-FixWindowStep $w 'settings' }.GetNewClosure())
    $b.Close.Add_Click({ $form.Close() }.GetNewClosure())
    Show-FixSessionLabel $w
    Show-FixSuggestRows $w @(Get-FixSentRecords) $true
    Sync-FixWindowButtons $w
    if ($Owner) { $form.Show($Owner) } else { $form.Show() }
    if ($w.Shared.Session) { Invoke-FixWindowStep $w 'suggest-refresh' }
    return $w
}

function Select-FixSuggestBundle {
    param($Window)
    $settings = Get-FixInboxSettings
    $picked = @(Invoke-BudaFilePicker -Key 'fix.suggest-bundle' -Purpose File -Title 'O pacote de sugestão que o app assinou' -Owner $Window.Form `
        -CurrentFile $Window.Controls.Bundle.Text.Trim() -DefaultFolder ([string]$settings.suggestionsFolder) -Filters @(@{ Name = 'Pacote de sugestão (*.budafix)'; Pattern = '*.budafix' }))
    if ($picked.Count -eq 0) { return }
    Import-FixSuggestBundle $Window ([string]$picked[0])
}

function Import-FixSuggestBundle {
    param($Window, [string]$Path)
    $Window.Summary = $null
    if (-not $Path) { throw 'Escolha um pacote .budafix.' }
    $Window.Controls.Bundle.Text = $Path
    $summary = Read-FixBundleManifest $Path
    $Window.Summary = $summary
    $Window.Controls.Summary.Text = Format-FixBundleSummary $summary
    $sent = @(Get-FixSentRecords | Where-Object { [string]$_.sha256 -eq $summary.sha256 })
    if ($sent.Count) { Write-FixWindowStatus $Window "Este pacote já foi enviado (nº $($sent[0].id), status $($sent[0].status))." }
    else { Write-FixWindowStatus $Window 'Pacote lido. Entre com a sua conta e clique Enviar sugestão.' }
}

function Send-FixSuggestion {
    param($Window)
    $summary = $Window.Summary
    if (-not $summary) { throw 'Escolha um pacote .budafix primeiro.' }
    $settings = Get-FixInboxSettings
    if (Test-FixDryRun $Window) {
        $plan = Send-FixBundleToInbox $settings $null $summary -DryRun
        Write-FixLog $Window (@("[dry run] enviar '$($summary.title)':") + @($plan.Requests | ForEach-Object { "    $_" }))
        $Window.LastSent = $plan
        Write-FixWindowStatus $Window 'Dry run: os pedidos estão no log da sessão; nada foi enviado.'
        return
    }
    Assert-FixInboxSession $Window.Shared.Session
    $question = "Enviar '$($summary.title)' ($($summary.app) $($summary.appVersion), $(@($summary.files).Count) arquivo(s)) para a caixa de sugestões em $($settings.supabaseUrl)?`n`nO mantenedor lê o pacote antes de qualquer PR. Nada dos seus documentos vai junto."
    if (-not (Confirm-FixStep $Window $question 'Enviar sugestão')) { Write-FixWindowStatus $Window 'Envio cancelado.'; return }
    Write-FixWindowStatus $Window 'Enviando...'
    $sent = Send-FixBundleToInbox $settings $Window.Shared.Session $summary
    $Window.LastSent = $sent
    Save-FixSentRecord $sent.Row $summary.path
    Write-FixLog $Window @("sugestão nº $($sent.Row.id) '$($summary.title)' na caixa, status $($sent.Row.status).")
    Sync-FixSuggestRows $Window
    if ($sent.AlreadySent) { Write-FixWindowStatus $Window "Este pacote já estava na caixa (nº $($sent.Row.id), status $($sent.Row.status))." }
    else { Write-FixWindowStatus $Window "Enviado: sugestão nº $($sent.Row.id), status $($sent.Row.status)." }
}

# The inbox's rows for this account (RLS returns only its own), kept in the local record too.
function Sync-FixSuggestRows {
    param($Window)
    if (Test-FixDryRun $Window) {
        $plan = Get-FixOwnSubmissions (Get-FixInboxSettings) $null -DryRun
        Write-FixLog $Window (@('[dry run] atualizar status:') + @($plan.Requests | ForEach-Object { "    $_" }))
        Show-FixSuggestRows $Window @(Get-FixSentRecords) $true
        return
    }
    if (-not $Window.Shared.Session) { Show-FixSuggestRows $Window @(Get-FixSentRecords) $true; Write-FixWindowStatus $Window 'Último status conhecido. Entre para atualizar.'; return }
    $rows = @(Get-FixOwnSubmissions (Get-FixInboxSettings) $Window.Shared.Session)
    foreach ($row in $rows) { Save-FixSentRecord $row (@(Get-FixSentRecords | Where-Object { $_.sha256 -eq $row.bundle_sha256 } | ForEach-Object { $_.bundle }) | Select-Object -First 1) }
    $Window.Rows = $rows
    Show-FixSuggestRows $Window $rows $false
    Write-FixWindowStatus $Window "$($rows.Count) sugestão(ões) desta conta na caixa."
}

function Show-FixSuggestRows {
    param($Window, $Rows, [bool]$Local)
    if ($Local) { $Window.Rows = @($Rows) }
    $cells = if ($Local) { { param($r) $r.id, (Format-FixWhen $r.createdAt), $r.title, $r.status, $r.prUrl } }
             else { { param($r) $r.id, (Format-FixWhen $r.created_at), $r.title, $r.status, $r.pr_url } }
    Show-FixRows $Window $Rows $cells
}

function Sync-FixWindowButtons {
    param($Window)
    $b = $Window.Buttons
    $dry = Test-FixDryRun $Window
    if ($Window.Kind -eq 'suggest') {
        $signedIn = [bool]$Window.Shared.Session
        $b.SignOut.Enabled = $signedIn
        $b.Send.Enabled = [bool]$Window.Summary -and ($signedIn -or $dry)
        return
    }
    $admin = [bool]$Window.Passphrase -or $dry
    $row = Get-FixSelectedRow $Window
    $v = $Window.Verification
    $b.ForgetPassphrase.Enabled = [bool]$Window.Passphrase
    foreach ($name in @('Refresh', 'Register', 'OpenInbox', 'CloseInbox', 'AddDeveloper', 'NewKeys', 'PublishRegistry')) { $b[$name].Enabled = $admin }
    $b.Verify.Enabled = [bool]$row -and $admin
    $b.OpenPr.Enabled = [bool]$v -and [bool]$v.Result.valid
    $b.Decline.Enabled = [bool]$row -and [string]$row.status -in @('received', 'pr-opened') -and $admin
    $b.Merge.Enabled = [bool]$row -and [string]$row.status -eq 'pr-opened' -and [bool]$row.pr_url
}
