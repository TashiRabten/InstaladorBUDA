# ── Suggested changes in the cockpit window: the session section, Configurar…, and what both windows ──
# share (sign-in, the step runner, the submissions list). The windows themselves are FixSuggestWindow.ps1
# (contributor) and FixInboxWindow.ps1 (maintainer). Every button runs Invoke-FixWindowStep, and the CLI
# clicks the same buttons (FixInboxCli.ps1). Sizes are design pixels in $UI, through Px / Set-Box.

$UI.FixSuggest = @{ Width = 760; Height = 600; MinWidth = 700; MinHeight = 560 }
$UI.FixInbox = @{ Width = 1024; Height = 720; MinWidth = 1024; MinHeight = 640 }
$UI.FixSettings = @{ Width = 720; Height = 510; LabelW = 190; FieldX = 210; FieldW = 494 }

function Add-FixControl {
    param($Parent, [string]$Type, [string]$Text, [double]$X, [double]$Y, [double]$Width, [double]$Height, [string]$Anchor = 'Top,Left')
    $control = New-Object "System.Windows.Forms.$Type"
    if ($Text) { $control.Text = $Text }
    if ($Type -eq 'Label') { $control.TextAlign = 'MiddleLeft'; $control.AutoEllipsis = $true }
    Set-Box $control $X $Y $Width $Height
    $control.Anchor = $Anchor
    $Parent.Controls.Add($control)
    # A one-line text box takes its height from its font (the parent's, now): centre it in its row, level
    # with the row's MiddleLeft label, as Set-Field does in the session tab.
    if ($Type -eq 'TextBox' -and $Height -eq $UI.RowH) { $control.Top = (Px $Y) + [int][Math]::Floor(((Px $UI.RowH) - $control.Height) / 2) }
    return $control
}

# A window of this feature: the cockpit's font, sized in design pixels (Px), scaled once.
function Build-FixForm {
    param([string]$Title, $Layout, [switch]$Fixed)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title; $form.StartPosition = 'CenterParent'; $form.ShowInTaskbar = $false
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None   # Px scales; WinForms must not scale again
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.ClientSize = [System.Drawing.Size]::new((Px $Layout.Width), (Px $Layout.Height))
    if ($Fixed) { $form.FormBorderStyle = 'FixedDialog'; $form.MinimizeBox = $false; $form.MaximizeBox = $false }
    elseif ($Layout.MinWidth) { $form.MinimumSize = [System.Drawing.Size]::new((Px $Layout.MinWidth), (Px $Layout.MinHeight)) }
    $form.Add_Load({ param($s, $e) Sync-FixFormToScreen $s })
    return $form
}

# A window taller or wider than its screen's work area hid its bottom row (Abrir PR…, Fechar) on a scaled
# laptop screen: "Sugestões recebidas" is 720 design px, 1080 px at 150 %, on a 1032 px work area. At load,
# after the controls are in place, it shrinks to the work area: the bottom-anchored row moves up and the
# middle (the report, the list) takes the difference.
function Sync-FixFormToScreen {
    param($Form)
    $work = [System.Windows.Forms.Screen]::FromControl($(if ($Form.Owner) { $Form.Owner } else { $Form })).WorkingArea
    $min = $Form.MinimumSize
    $Form.MinimumSize = [System.Drawing.Size]::new([Math]::Min($min.Width, $work.Width), [Math]::Min($min.Height, $work.Height))
    $Form.Size = [System.Drawing.Size]::new([Math]::Min($Form.Width, $work.Width), [Math]::Min($Form.Height, $work.Height))
    $Form.Left = [Math]::Max($work.Left, [Math]::Min($Form.Left, $work.Right - $Form.Width))
    $Form.Top = [Math]::Max($work.Top, [Math]::Min($Form.Top, $work.Bottom - $Form.Height))
}

function Add-FixListView {
    param($Parent, [double]$X, [double]$Y, [double]$Width, [double]$Height, [object[]]$Columns)
    $list = Add-FixControl $Parent 'ListView' '' $X $Y $Width $Height 'Top,Left,Right'
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false
    foreach ($c in $Columns) { [void]$list.Columns.Add([string]$c[0], (Px ([double]$c[1]))) }
    return $list
}

# The session's group: the two windows, the registry check and signing, and the settings. Returns the
# group and its height in design pixels.
function Build-FixSuggestionsSection {
    param($TabState, $Tabs, $Font, [double]$Width, [double]$Y)
    if (-not $Tabs.Tag.FixShared) { $Tabs.Tag.FixShared = [hashtable]::Synchronized(@{ Session = $null; Registry = $null }) }
    $TabState.FixShared = $Tabs.Tag.FixShared
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = 'Sugestões de mudança (PR sem acesso ao GitHub)'
    $names = [ordered]@{ Suggest = 'Sugerir mudança (PR)...'; Inbox = 'Sugestões recebidas...'; RegistryVerify = 'Verificar registro'; RegistrySign = 'Assinar registro...'; Settings = 'Configurar...' }
    $buttons = @{}
    foreach ($n in $names.Keys) { $b = New-Object System.Windows.Forms.Button; $b.Text = $names[$n]; $b.Font = $Font; $buttons[$n] = $b }
    $rowY = $UI.BoxTop
    [void](Set-ButtonRow @($buttons.Suggest, $buttons.Inbox) $UI.BoxPad $rowY 170)
    $rowY += $UI.BoxRowPitch
    [void](Set-ButtonRow @($buttons.RegistryVerify, $buttons.RegistrySign, $buttons.Settings) $UI.BoxPad $rowY 140)
    $height = $rowY + $UI.BtnH + $UI.BoxPad
    Set-Box $group $UI.Pad $Y $Width $height
    $group.Anchor = 'Top,Left,Right'
    $group.Controls.AddRange(@($buttons.Values))
    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($buttons.Suggest, 'Contributor: send a .budafix your app signed to the private Supabase inbox, with your own account; then follow its status.')
    $tips.SetToolTip($buttons.Inbox, 'Maintainer: list the inbox, verify a bundle with the installed BundleTool against the release tag, read what it adds and its diff, then open the PR.')
    $tips.SetToolTip($buttons.RegistryVerify, 'BundleTool registry-verify: checks the developer registry against the root public key and lists the developers in the log.')
    $tips.SetToolTip($buttons.RegistrySign, 'Opens a console that runs BundleTool registry-sign; the root password is typed there, never in the cockpit.')
    $state = $TabState
    $buttons.Suggest.Add_Click({ Open-FixWindow $state 'suggest' }.GetNewClosure())
    $buttons.Inbox.Add_Click({ Open-FixWindow $state 'inbox' }.GetNewClosure())
    $buttons.RegistryVerify.Add_Click({ Invoke-FixRegistryStep $state }.GetNewClosure())
    $buttons.RegistrySign.Add_Click({ Invoke-FixRegistrySignStep $state }.GetNewClosure())
    $buttons.Settings.Add_Click({ Show-FixInboxSettingsDialog $state }.GetNewClosure())
    $TabState.FixButtons = $buttons
    return [pscustomobject]@{ Group = $group; Height = $height }
}

# One window of each kind per session; a second click brings the open one back.
function Open-FixWindow {
    param($TabState, [ValidateSet('suggest', 'inbox')][string]$Kind)
    $key = if ($Kind -eq 'suggest') { 'FixSuggest' } else { 'FixInbox' }
    $open = $TabState[$key]
    if ($open -and -not $open.Form.IsDisposed) {
        if ($open.Form.WindowState -eq 'Minimized') { $open.Form.WindowState = 'Normal' }
        $open.Form.Activate()
        return $open
    }
    $owner = $null
    foreach ($b in @($TabState.FixButtons.Values)) { if ($b.FindForm()) { $owner = $b.FindForm(); break } }
    try {
        $window = if ($Kind -eq 'suggest') { Show-FixSuggestWindow $TabState $owner } else { Show-FixInboxWindow $TabState $owner }
        $TabState[$key] = $window
        # The session's Dry run box decides what the buttons do: follow it while the window is open.
        $dryBox = $TabState.Controls.DryRun
        $follow = [EventHandler]{ if (-not $window.Form.IsDisposed) { Show-FixSessionLabel $window; Sync-FixWindowButtons $window } }.GetNewClosure()
        $dryBox.add_CheckedChanged($follow)
        $window.Form.Add_FormClosed({ $TabState[$key] = $null; $dryBox.remove_CheckedChanged($follow) }.GetNewClosure())
        return $window
    } catch {
        & $TabState.AppendLog "Sugestões: a janela não abriu: $($_.Exception.Message)"
        throw
    }
}

function Build-FixWindowState {
    param($TabState, [string]$Kind, $Form)
    return [hashtable]::Synchronized(@{
        Kind = $Kind; Form = $Form; TabState = $TabState; Shared = $TabState.FixShared
        Controls = @{}; Buttons = @{}; Rows = @(); Summary = $null; Verification = $null
        Busy = $false; LastError = $null; LastStatus = ''; CliConfirmed = $false; CliNote = $null; CliOverrideCeiling = $false
        LastPrUrl = $null; LastOutcome = $null; LastSent = $null
        Passphrase = $null; CliMaxPerHour = $null; LastRegistered = $null
        CliDeveloper = $null; LastInvite = $null; InviteForm = $null; LastNewKeys = $null; LastPublished = $null
    })
}

function Test-FixDryRun { param($Window) return [bool]$Window.TabState.Controls.DryRun.Checked }

function Write-FixWindowStatus {
    param($Window, [string]$Text, [bool]$IsError = $false)
    $Window.LastStatus = $Text
    $label = $Window.Controls.Status
    if (-not $label) { return }
    $label.Text = $Text
    $label.ForeColor = if ($IsError) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DimGray }
}

function Write-FixLog {
    param($Window, [string[]]$Lines)
    foreach ($line in $Lines) { & $Window.TabState.AppendLog "Sugestões: $line" }
}

# Every button of both windows lands here: one step at a time, errors to the status line and the log.
function Invoke-FixWindowStep {
    param($Window, [string]$Step)
    if ($Window.Busy) { return }
    $Window.Busy = $true; $Window.LastError = $null
    $Window.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        switch ($Step) {
            'sign-in' { Invoke-FixSignIn $Window }
            'sign-out' { $Window.Shared.Session = $null; Write-FixWindowStatus $Window 'Saiu da conta: o token foi descartado.'; Show-FixSessionLabel $Window }
            'passphrase-use' { Invoke-FixUsePassphrase $Window }
            'passphrase-forget' { Clear-FixPassphrase $Window; Write-FixWindowStatus $Window 'Frase-senha esquecida.' }
            'suggest-pick' { Select-FixSuggestBundle $Window }
            'suggest-load' { Import-FixSuggestBundle $Window $Window.Controls.Bundle.Text.Trim() }
            'suggest-send' { Send-FixSuggestion $Window }
            'suggest-refresh' { Sync-FixSuggestRows $Window }
            'inbox-refresh' { Sync-FixInboxRows $Window }
            'inbox-verify' { Invoke-FixInboxVerifyRow $Window }
            'inbox-verify-file' { Invoke-FixInboxPickFile $Window }
            'inbox-open-pr' { Invoke-FixInboxOpenPr $Window }
            'inbox-decline' { Invoke-FixInboxDecline $Window }
            'inbox-merge' { Invoke-FixInboxMerge $Window }
            'inbox-register' { Invoke-FixInboxRegister $Window }
            'inbox-open' { Invoke-FixInboxSetOpen $Window $true }
            'inbox-close' { Invoke-FixInboxSetOpen $Window $false }
            'inbox-add-developer' { Invoke-FixInboxAddDeveloper $Window }
            'inbox-new-keys' { Invoke-FixInboxNewKeys $Window }
            'inbox-publish-registry' { Invoke-FixInboxPublishRegistry $Window }
            'settings' { Show-FixInboxSettingsDialog $Window.TabState $Window.Form; Show-FixSessionLabel $Window }
            default { throw "Passo desconhecido: $Step" }
        }
    } catch {
        $Window.LastError = $_.Exception.Message
        Write-FixWindowStatus $Window $_.Exception.Message $true
        Write-FixLog $Window @($_.Exception.Message)
    } finally {
        $Window.Busy = $false
        $Window.Form.Cursor = [System.Windows.Forms.Cursors]::Default
        Sync-FixWindowButtons $Window
    }
}

function Confirm-FixStep {
    param($Window, [string]$Question, [string]$Title, [string]$Icon = 'Question')
    if ($Window.CliConfirmed) { return $true }
    $answer = [System.Windows.Forms.MessageBox]::Show($Window.Form, $Question, $Title, 'YesNo', $Icon)
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

# The contributor's e-mail / password row. The password box is cleared after every attempt.
function Add-FixSignInRow {
    param($Window, [double]$Y, [double]$Width)
    $f = $Window.Form; $c = $Window.Controls; $b = $Window.Buttons
    [void](Add-FixControl $f 'Label' 'E-mail:' 16 $Y 56 $UI.RowH)
    $c.Email = Add-FixControl $f 'TextBox' '' 76 $Y 250 $UI.RowH
    [void](Add-FixControl $f 'Label' 'Senha:' 338 $Y 50 $UI.RowH)
    $c.Password = Add-FixControl $f 'TextBox' '' 392 $Y ($Width - 392 - 196) $UI.RowH 'Top,Left,Right'
    $c.Password.UseSystemPasswordChar = $true; $c.Password.MaxLength = 256
    $b.SignIn = Add-FixControl $f 'Button' 'Entrar' ($Width - 188) ($Y - 4) 84 $UI.BtnH 'Top,Right'
    $b.SignOut = Add-FixControl $f 'Button' 'Sair' ($Width - 96) ($Y - 4) 80 $UI.BtnH 'Top,Right'
    $c.Session = Add-FixControl $f 'Label' '' 16 ($Y + 34) ($Width - 32) $UI.RowH 'Top,Left,Right'
    $c.Session.ForeColor = [System.Drawing.Color]::DimGray
    $c.Email.Text = [string](Get-FixInboxSettings).email
    $w = $Window
    $b.SignIn.Add_Click({ Invoke-FixWindowStep $w 'sign-in' }.GetNewClosure())
    $b.SignOut.Add_Click({ Invoke-FixWindowStep $w 'sign-out' }.GetNewClosure())
    $c.Password.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Invoke-FixWindowStep $w 'sign-in' } }.GetNewClosure())
}

# The maintainer's row: the admin passphrase (the one the glossary removals use). It is checked by listing
# the inbox, then held as a SecureString in this window only, until Esquecer or the window closes.
function Add-FixPassphraseRow {
    param($Window, [double]$Y, [double]$Width)
    $f = $Window.Form; $c = $Window.Controls; $b = $Window.Buttons
    [void](Add-FixControl $f 'Label' 'Frase-senha de administrador:' 16 $Y 196 $UI.RowH)
    $c.Passphrase = Add-FixControl $f 'TextBox' '' 216 $Y ($Width - 216 - 196) $UI.RowH 'Top,Left,Right'
    $c.Passphrase.UseSystemPasswordChar = $true; $c.Passphrase.MaxLength = 512
    $b.UsePassphrase = Add-FixControl $f 'Button' 'Usar' ($Width - 188) ($Y - 4) 84 $UI.BtnH 'Top,Right'
    $b.ForgetPassphrase = Add-FixControl $f 'Button' 'Esquecer' ($Width - 96) ($Y - 4) 80 $UI.BtnH 'Top,Right'
    $c.Session = Add-FixControl $f 'Label' '' 16 ($Y + 34) ($Width - 32) $UI.RowH 'Top,Left,Right'
    $c.Session.ForeColor = [System.Drawing.Color]::DimGray
    $w = $Window
    $b.UsePassphrase.Add_Click({ Invoke-FixWindowStep $w 'passphrase-use' }.GetNewClosure())
    $b.ForgetPassphrase.Add_Click({ Invoke-FixWindowStep $w 'passphrase-forget' }.GetNewClosure())
    $c.Passphrase.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Invoke-FixWindowStep $w 'passphrase-use' } }.GetNewClosure())
    $f.Add_FormClosed({ Clear-FixPassphrase $w }.GetNewClosure())
}

function Invoke-FixUsePassphrase {
    param($Window)
    $secure = ConvertTo-FixSecureText $Window.Controls.Passphrase.Text
    $Window.Controls.Passphrase.Clear()
    if (Test-FixDryRun $Window) {
        $secure.Dispose()
        $plan = Get-FixInboxList (Get-FixInboxSettings) $null '' -DryRun
        Write-FixLog $Window (@('[dry run] conferir a frase-senha listando a caixa:') + @($plan.Requests | ForEach-Object { "    $_" }))
        Write-FixWindowStatus $Window 'Dry run: nada foi enviado; a frase-senha não ficou guardada.'
        return
    }
    Write-FixWindowStatus $Window 'Conferindo a frase-senha...'
    try { [void](Get-FixInboxList (Get-FixInboxSettings) $secure '') } catch { $secure.Dispose(); throw }
    Clear-FixPassphrase $Window
    $Window.Passphrase = $secure
    Show-FixSessionLabel $Window
    Write-FixLog $Window @('frase-senha de administrador aceita (guardada só na memória desta janela).')
    Sync-FixInboxRows $Window
    Write-FixWindowStatus $Window "Frase-senha aceita: $(@($Window.Rows).Count) sugestão(ões) na caixa."
}

function Clear-FixPassphrase {
    param($Window)
    if ($Window.Passphrase) { $Window.Passphrase.Dispose() }
    $Window.Passphrase = $null
    if ($Window.Controls.Session -and -not $Window.Form.IsDisposed) { Show-FixSessionLabel $Window }
}

function Show-FixSessionLabel {
    param($Window)
    $settings = Get-FixInboxSettings
    $where = if ($settings.supabaseUrl) { $settings.supabaseUrl } else { 'caixa não configurada (Configurar...)' }
    $s = $Window.Shared.Session
    $text = if ($Window.Kind -eq 'inbox') {
                if ($Window.Passphrase) { "Frase-senha de administrador na memória desta janela (até Esquecer ou fechar). $where" } else { "Sem frase-senha. $where" }
            } elseif ($s -and [datetime]::UtcNow -lt $s.ExpiresAt) { "Conectado como $($s.Email) (conta $($s.UserId)) em $where; a sessão vale até $($s.ExpiresAt.ToLocalTime().ToString('HH:mm'))." }
            else { "Sem sessão. $where" }
    if (Test-FixDryRun $Window) { $text += '   [Dry run ligado na sessão: nada é enviado]' }
    $Window.Controls.Session.Text = $text
}

function Invoke-FixSignIn {
    param($Window)
    $settings = Get-FixInboxSettings
    $email = $Window.Controls.Email.Text.Trim()
    $secure = ConvertTo-FixSecureText $Window.Controls.Password.Text
    $Window.Controls.Password.Clear()
    try {
        if (Test-FixDryRun $Window) {
            $plan = Connect-FixInbox $settings $email $null -DryRun
            Write-FixLog $Window (@('[dry run] entrar:') + @($plan.Requests | ForEach-Object { "    $_" }))
            Write-FixWindowStatus $Window 'Dry run: nada foi enviado.'
            return
        }
        Write-FixWindowStatus $Window 'Entrando...'
        $Window.Shared.Session = Connect-FixInbox $settings $email $secure
    } finally { $secure.Dispose() }
    if ($settings.email -ne $email) { $settings.email = $email; Save-FixInboxSettings $settings }
    Show-FixSessionLabel $Window
    Write-FixLog $Window @("conectado como $($Window.Shared.Session.Email).")
    Sync-FixSuggestRows $Window
}

function Show-FixRows {
    param($Window, $Rows, [scriptblock]$Cells)
    $list = $Window.Controls.Rows
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($row in @($Rows)) {
            $values = @(& $Cells $row | ForEach-Object { [string]$_ })
            $item = New-Object System.Windows.Forms.ListViewItem($values[0])
            foreach ($v in ($values | Select-Object -Skip 1)) { [void]$item.SubItems.Add($v) }
            $item.Tag = $row
            [void]$list.Items.Add($item)
        }
    } finally { $list.EndUpdate() }
}

function Format-FixWhen {
    param([string]$Iso)
    if (-not $Iso) { return '' }
    try { return ([datetime]$Iso).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { return $Iso }
}

# ── Configurar… : where the inbox, the install, the registry and the worktrees are ─────────────────

function Get-FixSettingsFields {
    return @(
        @('supabaseUrl', 'URL do Supabase:'), @('publishableKey', 'Chave publicável:'), @('suggestionsFolder', 'Pasta dos pacotes:'),
        @('tradutorInstall', 'Instalação do TradutorBUDA:'), @('scanInstall', 'Instalação do ScanBUDA:'),
        @('suiteInstall', 'Instalação do SuiteBUDA:'), @('registryPath', 'Registro (developers.json):'),
        @('rootKeyPath', 'Chave pública raiz (.pub):'), @('inboxFolder', 'Pacotes baixados:'), @('worktreeRoot', 'Pasta das worktrees:'))
}

function Get-FixSettingValue {
    param($Settings, [string]$Name)
    $app = @{ tradutorInstall = 'TradutorBUDA'; scanInstall = 'ScanBUDA'; suiteInstall = 'SuiteBUDA' }[$Name]
    if ($app) { return [string]$Settings.installs.$app }
    return [string]$Settings.$Name
}

# The one place settings change (the dialog's Save and the CLI's fix-settings). A secret key is refused.
function Save-FixInboxSettingsFrom {
    param([hashtable]$Values)
    $settings = Get-FixInboxSettings
    foreach ($name in @($Values.Keys)) {
        $value = ([string]$Values[$name]).Trim()
        $app = @{ tradutorInstall = 'TradutorBUDA'; scanInstall = 'ScanBUDA'; suiteInstall = 'SuiteBUDA' }[$name]
        if ($app) { $settings.installs[$app] = $value; continue }
        if (-not ($settings.PSObject.Properties.Name -contains $name) -or $name -in @('installs', 'registrySeenVersion', 'email')) { throw "Campo desconhecido: $name" }
        $settings.$name = $value
    }
    if ($settings.supabaseUrl) { $why = Test-FixInboxUrl $settings.supabaseUrl; if ($why) { throw $why } }
    if ($settings.publishableKey) { $why = Test-FixInboxPublishableKey $settings.publishableKey; if ($why) { throw $why } }
    $settings.supabaseUrl = ([string]$settings.supabaseUrl).TrimEnd('/')
    Save-FixInboxSettings $settings
    return $settings
}

function Show-FixInboxSettingsDialog {
    param($TabState, $Owner)
    $layout = $UI.FixSettings
    $form = Build-FixForm 'Sugestões de mudança — configurar' $layout -Fixed
    $settings = Get-FixInboxSettings
    $boxes = @{}; $y = 16
    foreach ($field in Get-FixSettingsFields) {
        [void](Add-FixControl $form 'Label' $field[1] 16 $y $layout.LabelW $UI.RowH)
        $boxes[$field[0]] = Add-FixControl $form 'TextBox' (Get-FixSettingValue $settings $field[0]) $layout.FieldX $y $layout.FieldW $UI.RowH
        $y += 40
    }
    $note = Add-FixControl $form 'Label' 'A chave publicável é pública por desenho (vale só sob as regras de linha do banco); uma chave secreta (sb_secret_…) é recusada. A senha nunca fica aqui: ela é digitada só ao entrar e só o token da sessão fica na memória.' 16 $y ($layout.Width - 32) 44
    $note.TextAlign = 'TopLeft'; $note.ForeColor = [System.Drawing.Color]::DimGray
    $save = Add-FixControl $form 'Button' 'Salvar' ($layout.Width - 224) ($layout.Height - 48) 100 $UI.BtnH
    $cancel = Add-FixControl $form 'Button' 'Cancelar' ($layout.Width - 116) ($layout.Height - 48) 100 $UI.BtnH
    $form.CancelButton = $cancel
    $outcome = @{ Saved = $false }
    $state = $TabState
    $save.Add_Click({
        $values = @{}
        foreach ($k in $boxes.Keys) { $values[$k] = $boxes[$k].Text }
        try {
            [void](Save-FixInboxSettingsFrom $values)
            $outcome.Saved = $true
            & $state.AppendLog 'Sugestões: configuração salva.'
            $form.Close()
        } catch { [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Configuração', 'OK', 'Warning') }
    }.GetNewClosure())
    $cancel.Add_Click({ $form.Close() }.GetNewClosure())
    if (-not $Owner) { $Owner = $TabState.FixButtons.Settings.FindForm() }
    try { if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() } } finally { $form.Dispose() }
    return $outcome
}

# ── The developer registry: verify (read-only) and sign (in a console of its own) ─────────────────

function Invoke-FixRegistryStep {
    param($TabState)
    $TabState.FixRegistryError = $null
    $TabState.FixShared.Registry = $null
    try {
        $result = Invoke-FixRegistryVerify (Get-FixInboxSettings)
        $TabState.FixShared.Registry = $result
        foreach ($line in (Format-FixRegistryReport $result)) { & $TabState.AppendLog "Sugestões: $line" }
    } catch {
        $TabState.FixRegistryError = $_.Exception.Message
        & $TabState.AppendLog "Sugestões: verificar registro: $($_.Exception.Message)"
    }
}

function Invoke-FixRegistrySignStep {
    param($TabState)
    $request = $TabState.FixPendingSign
    $TabState.FixPendingSign = $null
    $TabState.FixRegistrySignError = $null
    try {
        $settings = Get-FixInboxSettings
        $owner = $TabState.FixButtons.RegistrySign.FindForm()
        $folder = Split-Path -Parent ([string]$settings.registryPath)
        $unsigned = if ($request) { [string]$request.In } else { @(Invoke-BudaFilePicker -Key 'fix.registry-unsigned' -Purpose File -Title 'O registro a assinar (JSON sem assinatura)' -Owner $owner -DefaultFolder $folder -Filters @(@{ Name = 'JSON (*.json)'; Pattern = '*.json' })) | Select-Object -First 1 }
        if (-not $unsigned) { & $TabState.AppendLog 'Sugestões: assinatura do registro cancelada.'; return }
        $root = if ($request) { [string]$request.RootIdentity } else { @(Invoke-BudaFilePicker -Key 'fix.root-identity' -Purpose File -Title 'A identidade raiz (o arquivo protegido por senha)' -Owner $owner -DefaultFolder $folder) | Select-Object -First 1 }
        if (-not $root) { & $TabState.AppendLog 'Sugestões: assinatura do registro cancelada.'; return }
        $line = Get-FixRegistrySignCommandLine $settings $unsigned $root
        if ($TabState.Controls.DryRun.Checked) { & $TabState.AppendLog "Sugestões: [dry run] abriria um console com: $line"; return }
        if (-not $TabState.CliConfirmed) {
            $answer = [System.Windows.Forms.MessageBox]::Show($owner, "Abrir um console que assina`n$unsigned`ncom a chave raiz e grava`n$($settings.registryPath)?`n`nA senha da raiz é digitada no console, não aqui.", 'Assinar registro', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { & $TabState.AppendLog 'Sugestões: assinatura do registro cancelada.'; return }
        }
        Open-FixRegistrySignConsole $line
        & $TabState.AppendLog 'Sugestões: console aberto para registry-sign. Digite a senha da raiz lá; depois clique Verificar registro.'
    } catch {
        $TabState.FixRegistrySignError = $_.Exception.Message
        & $TabState.AppendLog "Sugestões: assinar registro: $($_.Exception.Message)"
    }
}
