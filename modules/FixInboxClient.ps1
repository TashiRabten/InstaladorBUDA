# ── The Supabase inbox over HTTPS (TradutorBUDA dev/security/supabase-fix-inbox.sql, v2, applied) ───
# Contributor: an invited Auth account (e-mail + password) inserts into fix_submissions with the bundle in
# the row (bundle_b64; the database recomputes its SHA-256 and size) and reads only its own rows.
# Maintainer: no account — the admin passphrase, sent with the publishable key to the fix_inbox_* functions
# (list, bundle, set status, register developer, open/close). The passphrase and the password are held as
# SecureString and read only into one request body, which is cleared; neither is stored, logged, nor taken
# from the CLI. Only the contributor's access token is kept, in memory. In a dry run nothing is sent.

$script:FixInboxMaxInboxBytes = 4194304
$script:FixInboxRowColumns = 'id,app,app_version,key_id,slug,title,description,bundle_sha256,bundle_size,status,pr_url,released_in,maintainer_note,created_at,updated_at'

function Invoke-FixInboxHttp {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [byte[]]$Body, [string]$ContentType, [int]$TimeoutSec = 60)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.AllowAutoRedirect = $false
    foreach ($h in $Headers.GetEnumerator()) {
        if ($h.Key -eq 'Accept') { $request.Accept = [string]$h.Value } else { $request.Headers[[string]$h.Key] = [string]$h.Value }
    }
    if ($ContentType) { $request.ContentType = $ContentType }
    if ($null -ne $Body) {
        $request.ContentLength = $Body.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($Body, 0, $Body.Length) } finally { $stream.Dispose() }
    }
    $response = $null
    try { $response = $request.GetResponse() }
    catch {
        $ex = $_.Exception
        while ($ex -and $ex -isnot [Net.WebException]) { $ex = $ex.InnerException }
        if (-not $ex -or -not $ex.Response) { throw "Sem conexão com o Supabase ($Method $(Get-FixInboxSafeUri $Uri)): $($_.Exception.Message)" }
        $response = $ex.Response
    }
    try {
        $buffer = New-Object IO.MemoryStream
        $stream = $response.GetResponseStream()
        try { $stream.CopyTo($buffer) } finally { $stream.Dispose() }
        $bytes = $buffer.ToArray()
        return @{ Status = [int]$response.StatusCode; Bytes = $bytes; Text = [Text.Encoding]::UTF8.GetString($bytes) }
    } finally { $response.Dispose() }
}

function Get-FixInboxSafeUri { param([string]$Uri) return ($Uri -split '\?')[0] }

# Supabase's error text, whatever shape it came in (Auth: error_description / msg; PostgREST: message).
function Get-FixInboxError {
    param($Response)
    $why = ''
    try {
        $j = $Response.Text | ConvertFrom-Json
        foreach ($field in @('error_description', 'msg', 'message', 'error')) { if ($j.$field) { $why = [string]$j.$field; break } }
        if ($j.code -and $why) { $why = "$why (código $($j.code))" }
    } catch { $why = '' }
    if (-not $why) { $why = ($Response.Text -replace '\s+', ' ').Trim() }
    if ($why.Length -gt 300) { $why = $why.Substring(0, 300) + '…' }
    return "HTTP $($Response.Status): $why"
}

function Get-FixInboxHeaders {
    param($Settings, $Session)
    $bearer = if ($Session) { $Session.AccessToken } else { $Settings.publishableKey }
    return @{ apikey = [string]$Settings.publishableKey; Authorization = "Bearer $bearer" }
}

function Get-FixInboxBaseUrl { param($Settings) return ([string]$Settings.supabaseUrl).TrimEnd('/') }

function Assert-FixInboxSession {
    param($Session)
    if (-not $Session -or -not $Session.AccessToken) { throw 'Entre com a sua conta do Supabase primeiro (e-mail e senha).' }
    if ([datetime]::UtcNow -ge $Session.ExpiresAt) { throw 'A sessão do Supabase expirou: entre de novo.' }
}

# A SecureString built from a text box's characters (the box is cleared by the caller).
function ConvertTo-FixSecureText {
    param([string]$Text)
    $secure = New-Object Security.SecureString
    foreach ($ch in $Text.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

# Sends $Fields as a JSON body with the SecureString added under $SecretName, then clears the body bytes.
function Invoke-FixInboxSecretPost {
    param([string]$Uri, [hashtable]$Headers, [hashtable]$Fields, [string]$SecretName, [Security.SecureString]$Secret)
    $plain = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    $body = $null
    try {
        $all = @{}; foreach ($k in $Fields.Keys) { $all[$k] = $Fields[$k] }
        $all[$SecretName] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($plain)
        $body = [Text.Encoding]::UTF8.GetBytes(($all | ConvertTo-Json -Compress -Depth 4))
        $all = $null
        return (Invoke-FixInboxHttp 'POST' $Uri $Headers $body 'application/json')
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($plain)
        if ($body) { [Array]::Clear($body, 0, $body.Length) }
    }
}

# ── Contributor ─────────────────────────────────────────────────────────────────────────────────

# Signs in with e-mail and password (Supabase Auth, grant_type=password): the access token, the user id
# and when it expires.
function Connect-FixInbox {
    param($Settings, [string]$Email, [Security.SecureString]$Password, [switch]$DryRun)
    Assert-FixInboxConfigured $Settings
    if ($Email -notmatch '^[^@\s]+@[^@\s]+$') { throw 'Escreva o e-mail da sua conta.' }
    $uri = (Get-FixInboxBaseUrl $Settings) + '/auth/v1/token?grant_type=password'
    if ($DryRun) { return [pscustomobject]@{ DryRun = $true; Requests = @("POST $uri  (e-mail $Email; num dry run a senha não é enviada)") } }
    if (-not $Password -or $Password.Length -eq 0) { throw 'Escreva a senha.' }
    $r = Invoke-FixInboxSecretPost $uri @{ apikey = [string]$Settings.publishableKey } @{ email = $Email } 'password' $Password
    if ($r.Status -ne 200) {
        if ($r.Status -eq 400) { throw "Não foi possível entrar: e-mail ou senha incorretos, ou conta não confirmada ($(Get-FixInboxError $r))." }
        throw "Não foi possível entrar: $(Get-FixInboxError $r)"
    }
    $j = $r.Text | ConvertFrom-Json
    if (-not $j.access_token -or -not $j.user.id) { throw 'O Supabase respondeu sem sessão.' }
    $seconds = if ($j.expires_in) { [int]$j.expires_in } else { 3600 }
    return [pscustomobject]@{ AccessToken = [string]$j.access_token; UserId = [string]$j.user.id; Email = [string]$j.user.email; ExpiresAt = [datetime]::UtcNow.AddSeconds($seconds - 30) }
}

# This account's rows (row-level security returns only its own), without the bundle itself.
function Get-FixOwnSubmissions {
    param($Settings, $Session, [string]$Sha256, [switch]$DryRun)
    $filters = @("select=$($script:FixInboxRowColumns)", 'order=created_at.desc', 'limit=200')
    if ($Sha256) { $filters += 'bundle_sha256=eq.' + [Uri]::EscapeDataString($Sha256) }
    $uri = (Get-FixInboxBaseUrl $Settings) + '/rest/v1/fix_submissions?' + ($filters -join '&')
    if ($DryRun) { return [pscustomobject]@{ DryRun = $true; Requests = @("GET $uri") } }
    Assert-FixInboxConfigured $Settings
    Assert-FixInboxSession $Session
    $r = Invoke-FixInboxHttp 'GET' $uri (Get-FixInboxHeaders $Settings $Session) $null $null
    if ($r.Status -ne 200) { throw "A caixa de sugestões não respondeu: $(Get-FixInboxError $r)" }
    $rows = $r.Text | ConvertFrom-Json
    return @($rows | Where-Object { $_ })
}

# Inserts the submission with the bundle in it (bundle_b64). The database checks the SHA-256 and size against
# the bytes, the sender's registered key and app, the open switch and the hourly cap. A bundle already in the
# inbox (same SHA-256) is not sent twice.
function Send-FixBundleToInbox {
    param($Settings, $Session, $Summary, [switch]$DryRun)
    Assert-FixSubmissionFields $Summary
    if ([long]$Summary.size -gt $script:FixInboxMaxInboxBytes) { throw 'A caixa aceita pacotes de até 4 MiB; este é maior.' }
    $base = Get-FixInboxBaseUrl $Settings
    $insertUri = "$base/rest/v1/fix_submissions?select=$($script:FixInboxRowColumns)"
    $row = [ordered]@{
        app = $Summary.app; app_version = $Summary.appVersion; key_id = $Summary.keyId; slug = $Summary.slug
        title = $Summary.title; description = $Summary.description
        bundle_sha256 = $Summary.sha256; bundle_size = [long]$Summary.size
    }
    if ($DryRun) {
        return [pscustomobject]@{ DryRun = $true; Requests = @(
            "GET $base/rest/v1/fix_submissions?bundle_sha256=eq.$($Summary.sha256)  (já enviado?)",
            "POST $insertUri  $(($row | ConvertTo-Json -Compress)) + bundle_b64 ($($Summary.size) bytes em base64)") }
    }
    Assert-FixInboxConfigured $Settings
    Assert-FixInboxSession $Session
    $existing = @(Get-FixOwnSubmissions $Settings $Session -Sha256 $Summary.sha256)
    if ($existing.Count -gt 0) { return [pscustomobject]@{ AlreadySent = $true; Row = $existing[0] } }
    $bytes = [IO.File]::ReadAllBytes($Summary.path)
    if ((Get-FixSha256 $bytes) -ne $Summary.sha256) { throw 'O pacote mudou depois de aberto aqui; escolha-o de novo.' }
    # Spliced in rather than serialized: base64 needs no JSON escaping, and Windows PowerShell's JSON
    # serializer is not meant for a 5 MB string.
    $json = ($row | ConvertTo-Json -Compress)
    $json = $json.Substring(0, $json.Length - 1) + ',"bundle_b64":"' + [Convert]::ToBase64String($bytes) + '"}'
    $headers = Get-FixInboxHeaders $Settings $Session
    $headers['Prefer'] = 'return=representation'
    $ins = Invoke-FixInboxHttp 'POST' $insertUri $headers ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json'
    if ($ins.Status -ne 201) {
        if ($ins.Status -in @(401, 403) -or $ins.Text -match '42501') {
            throw "A caixa recusou a sugestão: a conta não está registrada como desenvolvedor deste app ou a chave do pacote não é a registrada ($(Get-FixInboxError $ins))."
        }
        throw "A caixa recusou a sugestão: $(Get-FixInboxError $ins)"
    }
    $rows = $ins.Text | ConvertFrom-Json
    return [pscustomobject]@{ AlreadySent = $false; Row = @($rows)[0] }
}

function Get-FixSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# ── Maintainer: the fix_inbox_* functions, with the admin passphrase ────────────────────────────────

# -Raw returns the response text unparsed (fix_inbox_bundle: a JSON string of up to 5.6 MB, more than
# Windows PowerShell's ConvertFrom-Json is meant to take).
function Invoke-FixInboxRpc {
    param($Settings, [string]$Function, [hashtable]$Params, [Security.SecureString]$Passphrase, [switch]$DryRun, [switch]$Raw)
    $uri = (Get-FixInboxBaseUrl $Settings) + "/rest/v1/rpc/$Function"
    if ($DryRun) { return [pscustomobject]@{ DryRun = $true; Requests = @("POST $uri  $(($Params | ConvertTo-Json -Compress -Depth 4)) + p_passphrase (não mostrada)") } }
    Assert-FixInboxConfigured $Settings
    if (-not $Passphrase -or $Passphrase.Length -eq 0) { throw 'Digite a frase-senha de administrador na janela Sugestões recebidas.' }
    $r = Invoke-FixInboxSecretPost $uri (Get-FixInboxHeaders $Settings $null) $Params 'p_passphrase' $Passphrase
    if ($r.Status -notin @(200, 204)) {
        if ($r.Text -match '(?i)passphrase|frase|not authori[sz]ed|permission') { throw "A caixa recusou a frase-senha de administrador ($(Get-FixInboxError $r))." }
        throw "$Function falhou: $(Get-FixInboxError $r)"
    }
    if ($Raw) { return $r.Text }
    if (-not $r.Text.Trim()) { return $null }
    return ($r.Text | ConvertFrom-Json)
}

function Get-FixInboxList {
    param($Settings, [Security.SecureString]$Passphrase, [string]$Status, [switch]$DryRun)
    $params = @{ p_status = $(if ($Status) { $Status } else { $null }) }
    $rows = Invoke-FixInboxRpc $Settings 'fix_inbox_list' $params $Passphrase -DryRun:$DryRun
    if ($DryRun) { return $rows }
    return @($rows | Where-Object { $_ })
}

# Fetches a submission's bundle (base64 from fix_inbox_bundle) into $Folder and checks its size and SHA-256
# against the listed row before anything opens it.
function Save-FixBundleFromInbox {
    param($Settings, [Security.SecureString]$Passphrase, $Row, [string]$Folder, [switch]$DryRun)
    $result = Invoke-FixInboxRpc $Settings 'fix_inbox_bundle' @{ p_id = [long]$Row.id } $Passphrase -DryRun:$DryRun -Raw
    if ($DryRun) { return $result }
    $text = ([string]$result).Trim()
    if ($text -notmatch '^"[A-Za-z0-9+/=\\rn]*"$') { throw "A sugestão $($Row.id) não veio como texto base64." }
    $text = $text.Substring(1, $text.Length - 2).Replace('\/', '/').Replace('\n', '').Replace('\r', '')
    try { $bytes = [Convert]::FromBase64String($text) } catch { throw "A sugestão $($Row.id) não veio em base64." }
    $sha = Get-FixSha256 $bytes
    if ($bytes.Length -ne [long]$Row.bundle_size -or $sha -ne [string]$Row.bundle_sha256) {
        throw "O pacote recebido não é o que a linha $($Row.id) registra (tamanho ou SHA-256 diferente); nada foi aberto."
    }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $Folder -Force) }
    $target = Join-Path $Folder ("{0}-{1}.budafix" -f $Row.id, $sha.Substring(0, 12))
    [IO.File]::WriteAllBytes("$target.part", $bytes)
    Move-Item -LiteralPath "$target.part" -Destination $target -Force
    return $target
}

# $Fields: status (required), pr_url, released_in, maintainer_note. A field left out keeps its value.
function Send-FixSubmissionStatus {
    param($Settings, [Security.SecureString]$Passphrase, [long]$Id, [hashtable]$Fields, [switch]$DryRun)
    if (-not $Fields.status) { throw 'O status é obrigatório.' }
    $params = @{ p_id = $Id; p_status = [string]$Fields.status; p_pr_url = $Fields.pr_url; p_released_in = $Fields.released_in; p_note = $Fields.maintainer_note }
    return (Invoke-FixInboxRpc $Settings 'fix_inbox_set_status' $params $Passphrase -DryRun:$DryRun)
}

function Register-FixInboxDeveloper {
    param($Settings, [Security.SecureString]$Passphrase, $Developer, [switch]$DryRun)
    $params = @{ p_email = [string]$Developer.email; p_developer_id = [string]$Developer.id; p_key_id = [string]$Developer.keyId
        p_public_key = [string]$Developer.publicKey; p_apps = @($Developer.apps | ForEach-Object { [string]$_ }); p_active = [bool]$Developer.active }
    return (Invoke-FixInboxRpc $Settings 'fix_inbox_register_developer' $params $Passphrase -DryRun:$DryRun)
}

function Send-FixInboxOpen {
    param($Settings, [Security.SecureString]$Passphrase, [bool]$Open, $MaxPerHour, [switch]$DryRun)
    $cap = if ($null -ne $MaxPerHour -and "$MaxPerHour" -ne '') { [int]$MaxPerHour } else { $null }
    if ($null -ne $cap -and ($cap -lt 0 -or $cap -gt 100)) { throw 'O limite por hora vai de 0 a 100.' }
    return (Invoke-FixInboxRpc $Settings 'fix_inbox_set_open' @{ p_open = $Open; p_max_per_hour = $cap } $Passphrase -DryRun:$DryRun)
}

# ── The contributor's own record of what was sent (no secret in it), shown before signing in ──

function Get-FixSentRecords {
    $path = Get-FixInboxSentPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try { $records = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return @() }
    return @($records | Where-Object { $_ })
}

function Save-FixSentRecord {
    param($Row, [string]$BundlePath)
    $records = @(Get-FixSentRecords | Where-Object { [string]$_.sha256 -ne [string]$Row.bundle_sha256 })
    $records = @([pscustomobject]@{
        id = $Row.id; sha256 = [string]$Row.bundle_sha256; title = [string]$Row.title; app = [string]$Row.app
        appVersion = [string]$Row.app_version; status = [string]$Row.status; prUrl = [string]$Row.pr_url
        note = [string]$Row.maintainer_note; createdAt = [string]$Row.created_at; updatedAt = [string]$Row.updated_at; bundle = $BundlePath
    }) + $records
    $records = @($records | Sort-Object -Property @{ Expression = { [long]$_.id }; Descending = $true })
    $path = Get-FixInboxSentPath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject @($records | Select-Object -First 200) -Depth 4), [Text.UTF8Encoding]::new($false))
}

# ── What a job found out and the row does not say yet (no secret in it) ──
# The status goes to the row with the admin passphrase, which lives only in the open window: a window closed
# during Abrir PR left the row with no PR, and Mesclar PR off for good. It waits here until a window holds the
# passphrase (Send-FixPendingStatuses); one record per row, id and the fields of fix_inbox_set_status.

function Get-FixPendingStatuses {
    $path = Get-FixInboxPendingPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try { $records = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return @() }
    return @($records | Where-Object { $_ })
}

function Save-FixPendingStatuses {
    param([object[]]$Records)
    $path = Get-FixInboxPendingPath
    if (@($Records).Count -eq 0) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue; return }
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject @($Records) -Depth 4), [Text.UTF8Encoding]::new($false))
}

function Add-FixPendingStatus {
    param([long]$Id, [hashtable]$Fields)
    Save-FixPendingStatuses (@(Get-FixPendingStatuses | Where-Object { [long]$_.id -ne $Id }) + @([pscustomobject]@{ id = $Id; fields = $Fields }))
}
