# ── "Adicionar desenvolvedor..." in Sugestões recebidas: the maintainer fills one form, the cockpit does the rest ──
# With the admin passphrase already in the window, the dev-invite Edge Function (SuiteBUDA supabase/functions/dev-invite)
# approves the e-mail, creates the account, has Supabase e-mail the invitation and makes the account a developer, so the
# person's apps register their key themselves on the first /sugerir. When Supabase did not send the e-mail (its hourly
# quota, or its built-in sender, which writes only to the members of the Supabase organization), the account is created
# anyway and a window says why, with the link and a message ready to send. With the person's public key, the next
# version of the root-signed registry is written beside it and the signing console opens (the root password is typed
# there, never here). The link is shown only in that window: it is not logged and not returned to the CLI.

$UI.FixDevInvite = @{ Width = 600; Height = 420 }
$UI.FixInviteLink = @{ Width = 640; Height = 470 }
$script:FixDevApps = @('TradutorBUDA', 'ScanBUDA')

# 'Tenzin Wangmo' → 'tenzin-wangmo': the developer id (branch contrib/<id>/, the registry's id), without accents.
function Get-FixDeveloperId {
    param([string]$Name)
    $plain = $Name.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    $id = ($plain.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($id.Length -gt 40) { $id = $id.Substring(0, 40).TrimEnd('-') }
    return $id
}

# One request from the form or the CLI. All apps: 'SuiteBUDA' for the inbox (a developer of the whole suite) and no
# app at all in the registry (FixBundles reads an empty list as every app); otherwise the same apps in both.
function Build-FixDeveloperRequest {
    param([string]$Name, [string]$Email, [string]$Id, [bool]$AllApps, [string[]]$Apps, [string]$PublicKey)
    # Lists, not $(if …): Windows PowerShell turns an empty array returned that way into $null, and @($null) into [null].
    $inbox = New-Object 'System.Collections.Generic.List[string]'
    $registry = New-Object 'System.Collections.Generic.List[string]'
    if ($AllApps) { $inbox.Add('SuiteBUDA') }
    else { foreach ($app in $script:FixDevApps) { if ($Apps -contains $app) { $inbox.Add($app); $registry.Add($app) } } }
    $name = $Name.Trim()
    $developerId = if ($Id.Trim()) { $Id.Trim() } else { Get-FixDeveloperId $name }
    return [pscustomobject]@{
        Name = $name; Email = $Email.Trim().ToLowerInvariant(); Id = $developerId; AllApps = $AllApps
        InboxApps = $inbox.ToArray(); RegistryApps = $registry.ToArray(); PublicKey = ($PublicKey -replace '\s+', ' ').Trim()
    }
}

# What is wrong with a request ('' when nothing): the rules the function and the database apply, said before sending.
function Test-FixDeveloperRequest {
    param($Developer)
    if ($Developer.Name.Length -lt 1 -or $Developer.Name.Length -gt 120) { return 'Escreva o nome (até 120 caracteres).' }
    if ($Developer.Email.Length -gt 254 -or $Developer.Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return 'Escreva um e-mail válido.' }
    if ($Developer.Id -cnotmatch '^[a-z0-9][a-z0-9-]{0,39}$') { return 'O id deve ter só letras minúsculas sem acento, números e hífens (até 40), começando por letra ou número.' }
    if (@($Developer.InboxApps).Count -eq 0) { return 'Escolha pelo menos um app, ou Todos os apps.' }
    if ($Developer.PublicKey -and $Developer.PublicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( .*)?$') { return 'A chave pública deve ser a linha ssh-ed25519 … que o app mostra em Segurança do código.' }
    return ''
}

# POST /functions/v1/dev-invite with the passphrase from the window's SecureString. The publishable key goes on apikey
# only: it is not a JWT, and the function checks the passphrase itself.
function Send-FixDevInvite {
    param($Settings, [Security.SecureString]$Passphrase, $Developer, [switch]$DryRun)
    $uri = (Get-FixInboxBaseUrl $Settings) + '/functions/v1/dev-invite'
    $fields = @{ email = $Developer.Email; name = $Developer.Name; developerId = $Developer.Id; apps = @($Developer.InboxApps) }
    if ($DryRun) { return [pscustomobject]@{ DryRun = $true; Requests = @("POST $uri  $(ConvertTo-Json -InputObject $fields -Compress) + passphrase (não mostrada)") } }
    Assert-FixInboxConfigured $Settings
    if (-not $Passphrase -or $Passphrase.Length -eq 0) { throw 'Digite a frase-senha de administrador e clique Usar.' }
    $r = Invoke-FixInboxSecretPost $uri @{ apikey = [string]$Settings.publishableKey } $fields 'passphrase' $Passphrase
    $j = $null
    try { $j = $r.Text | ConvertFrom-Json } catch { $j = $null }
    if ($r.Status -eq 200 -and $j -and $j.userId) { return $j }
    # The account exists but the developer row failed: the link still matters, and adding again finishes it.
    if ($r.Status -eq 500 -and $j -and $j.error -eq 'grant' -and $j.userId) { return $j }
    if ($r.Status -eq 401) { throw "A caixa recusou a frase-senha de administrador ($(Get-FixInboxError $r))." }
    if ($r.Status -eq 404) { throw 'A função dev-invite não está no Supabase (SuiteBUDA supabase/functions/dev-invite): nada foi feito.' }
    throw "O Supabase não adicionou o desenvolvedor: $(Get-FixInboxError $r)"
}

# Why the e-mail was or was not sent, in the maintainer's words.
function Get-FixInviteOutcomeText {
    param($Result)
    switch ([string]$Result.outcome) {
        'sent' { return "O Supabase mandou o convite para $($Result.email)." }
        'quota' { return 'A cota de e-mail do Supabase acabou por agora (o limite é por hora). A conta foi criada: mande você o convite.' }
        'not_authorized' { return 'O Supabase não manda e-mail para este endereço: sem SMTP próprio, o remetente embutido escreve só para os membros da sua organização no Supabase. A conta foi criada: mande você o convite.' }
        'exists' { return "A conta $($Result.email) já existia, e nenhum e-mail foi mandado. Se a pessoa ainda não criou a senha, mande este link: ele define uma senha nova." }
        default { return "O Supabase não conseguiu mandar o e-mail ($($Result.emailError)). A conta foi criada: mande você o convite." }
    }
}

function Get-FixInviteMessage {
    param($Developer, $Result)
    $apps = if ($Developer.AllApps) { 'todos os apps BUDA' } else { @($Developer.InboxApps) -join ' e ' }
    $nl = [Environment]::NewLine
    return "Olá, $($Developer.Name)!" + $nl + $nl +
        "Você foi convidado(a) como desenvolvedor(a) da Suite BUDA ($apps)." + $nl +
        'Abra este link para criar a sua senha (ele vale uma vez só; se der erro, me peça outro):' + $nl +
        [string]$Result.link + $nl + $nl +
        "Depois, use o e-mail $($Developer.Email) e essa senha quando o SuiteBUDA ou um app BUDA pedir a conta (por exemplo, ao enviar uma sugestão)."
}

# The next version of the root-signed registry with this developer, unsigned, beside the registry. The registry is
# verified first, so what is added to is what the root signed; the signature block is not carried over.
function Write-FixRegistryDraft {
    param($Settings, $Developer)
    $check = Invoke-FixRegistryVerify $Settings
    if (-not $check.valid) { throw ('O registro atual não confere, então ele não foi estendido: ' + (@($check.problems) -join '; ')) }
    $doc = [IO.File]::ReadAllText([string]$Settings.registryPath) | ConvertFrom-Json
    $sameKey = @($doc.developers | Where-Object { ([string]$_.publicKey -split ' ')[1] -eq ($Developer.PublicKey -split ' ')[1] -and [string]$_.id -ne $Developer.Id })
    if ($sameKey.Count) { throw "Esta chave pública já está no registro, com o id $($sameKey[0].id)." }
    $entry = [pscustomobject][ordered]@{
        id = $Developer.Id; name = $Developer.Name; email = $Developer.Email; publicKey = $Developer.PublicKey
        apps = @($Developer.RegistryApps); ceiling = @(); active = $true
    }
    $version = [long]$doc.version + 1
    $developers = @($doc.developers | Where-Object { [string]$_.id -ne $Developer.Id }) + @($entry)
    $draft = [pscustomobject][ordered]@{ format = [string]$doc.format; version = $version; developers = $developers }
    $path = Join-Path (Split-Path -Parent ([string]$Settings.registryPath)) "developers-v$version-para-assinar.json"
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $draft -Depth 6), [Text.UTF8Encoding]::new($false))
    return $path
}

# The root identity beside the root public key (root.pub → root.json), or the one the maintainer picks.
function Get-FixRootIdentityPath {
    param($Settings, $Owner)
    $beside = [IO.Path]::ChangeExtension([string]$Settings.rootKeyPath, '.json')
    if ($beside -and (Test-Path -LiteralPath $beside -PathType Leaf)) { return $beside }
    return (@(Invoke-BudaFilePicker -Key 'fix.root-identity' -Purpose File -Title 'A identidade raiz (o arquivo protegido por senha)' -Owner $Owner `
        -DefaultFolder (Split-Path -Parent ([string]$Settings.registryPath))) | Select-Object -First 1)
}

# The step behind the button: the form (or the CLI's request), one confirmation, the function, then what is left.
function Invoke-FixInboxAddDeveloper {
    param($Window)
    $developer = if ($Window.CliDeveloper) { $Window.CliDeveloper } else { Read-FixDeveloperForm $Window }
    $Window.CliDeveloper = $null
    if (-not $developer) { Write-FixWindowStatus $Window 'Nenhum desenvolvedor adicionado.'; return }
    $why = Test-FixDeveloperRequest $developer
    if ($why) { throw $why }
    $settings = Get-FixInboxSettings
    if (Test-FixDryRun $Window) {
        Write-FixLog $Window (@("[dry run] adicionar $($developer.Id):") + @((Send-FixDevInvite $settings $null $developer -DryRun).Requests | ForEach-Object { "    $_" }))
        if ($developer.PublicKey) { Write-FixLog $Window @("    e escrever a próxima versão do registro com a chave dele, para assinar.") }
        Write-FixWindowStatus $Window 'Dry run: nada foi enviado ao Supabase.'
        return
    }
    if (-not $Window.Passphrase) { throw 'Digite a frase-senha de administrador e clique Usar.' }
    $apps = if ($developer.AllApps) { 'todos os apps' } else { @($developer.InboxApps) -join ', ' }
    $then = if ($developer.PublicKey) { "`n`nDepois, a próxima versão do registro com a chave dele é escrita e o console de assinatura abre (senha da raiz)." } else { '' }
    if (-not (Confirm-FixStep $Window "Adicionar $($developer.Name) <$($developer.Email)> como desenvolvedor ($apps), com o id $($developer.Id)?`n`nO Supabase cria a conta e manda o convite; se não puder mandar, você recebe o link para mandar.$then" 'Adicionar desenvolvedor')) {
        Write-FixWindowStatus $Window 'Nenhum desenvolvedor adicionado.'
        return
    }
    Write-FixWindowStatus $Window "Adicionando $($developer.Name)..."
    $result = Send-FixDevInvite $settings $Window.Passphrase $developer
    $Window.LastInvite = [pscustomobject]@{ developerId = $developer.Id; email = $developer.Email; userId = [string]$result.userId
        emailSent = [bool]$result.emailSent; outcome = [string]$result.outcome; grantError = $(if ($result.error -eq 'grant') { [string]$result.message } else { $null })
        linkShown = $false; registryDraft = $null }
    $outcomeText = Get-FixInviteOutcomeText $result
    Write-FixLog $Window @("desenvolvedor $($developer.Id) <$($developer.Email)>: conta $($result.userId); $outcomeText")
    if ($result.error -eq 'grant') { Write-FixLog $Window @("a conta foi criada, mas não virou desenvolvedor: $($result.message). Adicione de novo para concluir.") }
    if (-not $result.emailSent -and $result.link) {
        Show-FixInviteLink $Window $developer $result $outcomeText
        $Window.LastInvite.linkShown = $true
    }
    if ($developer.PublicKey) {
        $draft = Write-FixRegistryDraft $settings $developer
        $Window.LastInvite.registryDraft = $draft
        Write-FixLog $Window @("registro: versão nova com $($developer.Id) em $draft, sem assinatura.")
        $root = Get-FixRootIdentityPath $settings $Window.Form
        if (-not $root) { Write-FixLog $Window @('assinatura do registro adiada: nenhuma identidade raiz escolhida (use Assinar registro... depois).') }
        else {
            Open-FixRegistrySignConsole (Get-FixRegistrySignCommandLine $settings $draft $root)
            Write-FixLog $Window @('console aberto para registry-sign: digite a senha da raiz lá; depois clique Verificar registro.')
        }
    }
    $left = if ($developer.PublicKey) { ' Assine o registro no console que abriu.' } else { ' Quando a pessoa mandar a chave pública, adicione de novo com a chave para o registro.' }
    Write-FixWindowStatus $Window ("$($developer.Id): " + $(if ($result.emailSent) { 'convite enviado pelo Supabase.' } elseif ($result.link) { 'conta criada; mande o convite (janela aberta).' } else { 'feito.' }) + $left) ([bool]($result.error -eq 'grant'))
}

# The form: name, e-mail, id (follows the name until edited), the apps, and the public key when there is one.
function Read-FixDeveloperForm {
    param($Window)
    $layout = $UI.FixDevInvite
    $form = Build-FixForm 'Adicionar desenvolvedor' $layout -Fixed
    $boxes = @{}
    $y = 16
    foreach ($field in @(@('Name', 'Nome:'), @('Email', 'E-mail:'), @('Id', 'Id (contrib/<id>/):'))) {
        [void](Add-FixControl $form 'Label' $field[1] 16 $y 150 $UI.RowH)
        $boxes[$field[0]] = Add-FixControl $form 'TextBox' '' 170 $y ($layout.Width - 186) $UI.RowH
        $y += 40
    }
    $all = Add-FixControl $form 'CheckBox' 'Todos os apps (inclui o SuiteBUDA)' 170 $y 300 $UI.RowH
    $all.Checked = $true
    $y += 30
    $appBoxes = @{}
    $x = 170
    foreach ($app in $script:FixDevApps) { $appBoxes[$app] = Add-FixControl $form 'CheckBox' $app $x $y 150 $UI.RowH; $appBoxes[$app].Enabled = $false; $x += 160 }
    [void](Add-FixControl $form 'Label' 'Apps:' 16 ($y - 30) 150 $UI.RowH)
    $y += 44
    [void](Add-FixControl $form 'Label' 'Chave pública (opcional):' 16 $y 150 $UI.RowH)
    $boxes.PublicKey = Add-FixControl $form 'TextBox' '' 170 $y ($layout.Width - 186) $UI.RowH
    $y += 36
    $note = Add-FixControl $form 'Label' 'Com a chave (a linha ssh-ed25519 de Segurança do código ▸ Copiar chave pública), o cockpit também escreve a próxima versão do registro e abre a assinatura. Sem ela, a pessoa já pode enviar sugestões; o registro fica para quando a chave chegar.' 16 $y ($layout.Width - 32) 64
    $note.TextAlign = 'TopLeft'; $note.ForeColor = [System.Drawing.Color]::DimGray
    $ok = Add-FixControl $form 'Button' 'Adicionar' ($layout.Width - 224) ($layout.Height - 48) 100 $UI.BtnH
    $cancel = Add-FixControl $form 'Button' 'Cancelar' ($layout.Width - 116) ($layout.Height - 48) 100 $UI.BtnH
    $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'; $form.AcceptButton = $ok; $form.CancelButton = $cancel
    $edited = @{ Id = $false }
    $boxes.Name.Add_TextChanged({ if (-not $edited.Id) { $boxes.Id.Text = Get-FixDeveloperId $boxes.Name.Text } }.GetNewClosure())
    $boxes.Id.Add_KeyPress({ $edited.Id = $true }.GetNewClosure())
    $all.Add_CheckedChanged({ foreach ($b in $appBoxes.Values) { $b.Enabled = -not $all.Checked } }.GetNewClosure())
    try {
        if ($form.ShowDialog($Window.Form) -ne 'OK') { return $null }
        $apps = @($appBoxes.Keys | Where-Object { $appBoxes[$_].Checked })
        return (Build-FixDeveloperRequest $boxes.Name.Text $boxes.Email.Text $boxes.Id.Text $all.Checked $apps $boxes.PublicKey.Text)
    } finally { $form.Dispose() }
}

# The link to send, in a window of its own that does not block the cockpit (nor a CLI request).
function Show-FixInviteLink {
    param($Window, $Developer, $Result, [string]$Why)
    $layout = $UI.FixInviteLink
    $form = Build-FixForm "Convite para $($Developer.Name)" $layout -Fixed
    $reason = Add-FixControl $form 'Label' $Why 16 12 ($layout.Width - 32) 58
    $reason.TextAlign = 'TopLeft'; $reason.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    if (-not $Result.emailSent -and $Result.outcome -ne 'exists') { $reason.ForeColor = [System.Drawing.Color]::Firebrick }
    [void](Add-FixControl $form 'Label' 'Mensagem para mandar (e-mail, WhatsApp):' 16 78 ($layout.Width - 32) $UI.RowH)
    $message = Add-FixControl $form 'TextBox' (Get-FixInviteMessage $Developer $Result) 16 108 ($layout.Width - 32) 200
    $message.Multiline = $true; $message.ReadOnly = $true; $message.ScrollBars = 'Vertical'; $message.WordWrap = $true
    [void](Add-FixControl $form 'Label' 'Só o link:' 16 320 ($layout.Width - 32) $UI.RowH)
    $link = Add-FixControl $form 'TextBox' ([string]$Result.link) 16 350 ($layout.Width - 32) $UI.RowH
    $link.ReadOnly = $true
    $copyMessage = Add-FixControl $form 'Button' 'Copiar mensagem' 16 ($layout.Height - 48) 150 $UI.BtnH
    $copyLink = Add-FixControl $form 'Button' 'Copiar link' 174 ($layout.Height - 48) 120 $UI.BtnH
    $close = Add-FixControl $form 'Button' 'Fechar' ($layout.Width - 116) ($layout.Height - 48) 100 $UI.BtnH
    $form.CancelButton = $close
    $copyMessage.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($message.Text); $copyMessage.Text = 'Copiada' }.GetNewClosure())
    $copyLink.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($link.Text); $copyLink.Text = 'Copiado' }.GetNewClosure())
    $close.Add_Click({ $form.Close() }.GetNewClosure())
    $form.Add_FormClosed({ $form.Dispose() }.GetNewClosure())
    $Window.InviteForm = $form
    $form.Show($Window.Form)
}
