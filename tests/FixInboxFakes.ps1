# A local stand-in for the Supabase inbox, for tests/FixInbox.Tests.ps1: it replaces Invoke-FixInboxHttp
# (the cockpit's only HTTP call) and answers in memory as TradutorBUDA's dev/security/supabase-fix-inbox.sql
# (v2, applied) does: Auth for invited accounts; fix_submissions insert/select under its row rules and its
# before-insert trigger (inbox open, hourly cap, the bundle's bytes against bundle_sha256 / bundle_size);
# the maintainer's fix_inbox_* functions behind the admin passphrase. Nothing here touches the network.

$FakeInbox = @{
    Key = 'sb_publishable_fixinbox_test'
    Passphrase = 'frase de administrador do teste'
    Users = @{}          # email → @{ Id; Password; Email; DeveloperId; KeyId; PublicKey; Apps; Active } (KeyId empty: invited, not registered)
    Rows = New-Object System.Collections.ArrayList
    Calls = New-Object System.Collections.Generic.List[object]
    NextId = 1; Open = $true; MaxPerHour = 10
}

function Add-FakeInboxUser {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Test fixture: the fake Auth compares the text the cockpit sends with a made-up password.')]
    param([string]$Email, [string]$Password, [string]$Id)
    $FakeInbox.Users[$Email] = @{ Id = $Id; Password = $Password; Email = $Email; DeveloperId = ''; KeyId = ''; PublicKey = ''; Apps = @(); Active = $false }
}

function Build-FakeInboxReply {
    param([int]$Status, $Value, [string]$Text)
    if (-not $PSBoundParameters.ContainsKey('Text')) { $Text = if ($null -eq $Value) { '' } else { ConvertTo-Json -InputObject $Value -Depth 6 -Compress } }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return @{ Status = $Status; Bytes = $bytes; Text = $Text }
}

function Get-FakeInboxCaller {
    param([hashtable]$Headers)
    if ($Headers.apikey -ne $FakeInbox.Key) { return $null }
    foreach ($u in $FakeInbox.Users.Values) { if ([string]$Headers.Authorization -eq "Bearer tok-$($u.Id)") { return $u } }
    return $null
}

function Invoke-FixInboxHttp {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [byte[]]$Body, [string]$ContentType, [int]$TimeoutSec = 60)
    $text = if ($null -ne $Body) { [Text.Encoding]::UTF8.GetString($Body) } else { '' }
    $FakeInbox.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers.Clone(); Body = $text; ContentType = $ContentType })
    $u = [Uri]$Uri
    $path = $u.AbsolutePath
    if ($Headers.apikey -ne $FakeInbox.Key) { return (Build-FakeInboxReply 401 @{ message = 'Invalid API key' }) }
    if ($path -eq '/auth/v1/token') { return (Invoke-FakeInboxAuth $text) }
    if ($path -like '/rest/v1/rpc/*') { return (Invoke-FakeInboxRpc $path.Substring('/rest/v1/rpc/'.Length) ($text | ConvertFrom-Json)) }
    if ($path -ne '/rest/v1/fix_submissions') { return (Build-FakeInboxReply 404 @{ message = "no route $Method $path" }) }
    $caller = Get-FakeInboxCaller $Headers
    if (-not $caller) { return (Build-FakeInboxReply 401 @{ code = '42501'; message = 'permission denied for table fix_submissions' }) }
    $query = Get-FakeInboxQuery $u.Query
    if ($Method -eq 'GET') { return (Build-FakeInboxReply 200 @(Select-FakeInboxColumns @(Select-FakeInboxOwnRows $caller $query) $query.select)) }
    if ($Method -eq 'POST') { return (Invoke-FakeInboxInsert $caller ($text | ConvertFrom-Json) $query.select) }
    return (Build-FakeInboxReply 403 @{ code = '42501'; message = 'permission denied (no update or delete for clients)' })
}

function Invoke-FakeInboxAuth {
    param([string]$Text)
    $j = $Text | ConvertFrom-Json
    $u = $FakeInbox.Users[[string]$j.email]
    if (-not $u -or $u.Password -ne [string]$j.password) { return (Build-FakeInboxReply 400 @{ error = 'invalid_grant'; error_description = 'Invalid login credentials' }) }
    return (Build-FakeInboxReply 200 @{ access_token = "tok-$($u.Id)"; token_type = 'bearer'; expires_in = 3600; user = @{ id = $u.Id; email = $u.Email } })
}

function Get-FakeInboxQuery {
    param([string]$Query)
    $q = @{ select = '' }
    foreach ($pair in $Query.TrimStart('?').Split('&')) {
        if ($pair -match '^(id|app|bundle_sha256)=eq\.(.+)$') { $q[$Matches[1]] = [Uri]::UnescapeDataString($Matches[2]) }
        elseif ($pair -match '^select=(.+)$') { $q.select = [Uri]::UnescapeDataString($Matches[1]) }
    }
    return $q
}

function Select-FakeInboxColumns {
    param($Rows, [string]$Select)
    if (-not $Select -or $Select -eq '*') { return @($Rows) }
    $cols = $Select.Split(',')
    return @($Rows | ForEach-Object { $_ | Select-Object -Property $cols })
}

function Select-FakeInboxOwnRows {
    param($Caller, [hashtable]$Query)
    $rows = @($FakeInbox.Rows | Where-Object { $_.user_id -eq $Caller.Id })
    foreach ($k in @('id', 'app', 'bundle_sha256')) { if ($Query.ContainsKey($k)) { $rows = @($rows | Where-Object { [string]$_.$k -eq $Query[$k] }) } }
    return @($rows | Sort-Object { $_.id } -Descending)
}

# The before-insert trigger, then the insert policy (as in the schema: the trigger runs first).
function Invoke-FakeInboxInsert {
    param($Caller, $Row, [string]$Select)
    if (-not $FakeInbox.Open) { return (Build-FakeInboxReply 400 @{ code = 'P0001'; message = 'the suggestion inbox is closed' }) }
    $recent = @($FakeInbox.Rows | Where-Object { $_.user_id -eq $Caller.Id }).Count
    if ($recent -ge $FakeInbox.MaxPerHour) { return (Build-FakeInboxReply 400 @{ code = 'P0001'; message = 'too many suggestions in the last hour' }) }
    try { $bytes = [Convert]::FromBase64String([string]$Row.bundle_b64) } catch { return (Build-FakeInboxReply 400 @{ code = '22023'; message = 'the bundle is not base64' }) }
    if ($bytes.Length -ne [long]$Row.bundle_size -or (Get-FixSha256 $bytes) -ne [string]$Row.bundle_sha256) { return (Build-FakeInboxReply 400 @{ code = '22023'; message = 'the bundle does not match its size and SHA-256' }) }
    $userId = if ($Row.PSObject.Properties.Name -contains 'user_id') { $Row.user_id } else { $Caller.Id }   # default auth.uid()
    $allowed = $userId -eq $Caller.Id -and -not $Row.status -and -not $Row.pr_url -and -not $Row.maintainer_note -and
        $Caller.Active -and $Caller.KeyId -and $Caller.KeyId -eq $Row.key_id -and ($Caller.Apps -contains $Row.app)
    if (-not $allowed) { return (Build-FakeInboxReply 403 @{ code = '42501'; message = 'new row violates row-level security policy for table "fix_submissions"' }) }
    $now = [datetime]::UtcNow.ToString('o')
    $stored = [pscustomobject]@{
        id = $FakeInbox.NextId; user_id = $userId; app = $Row.app; app_version = $Row.app_version; key_id = $Row.key_id
        slug = $Row.slug; title = $Row.title; description = $Row.description; bundle_b64 = $Row.bundle_b64
        bundle_sha256 = $Row.bundle_sha256; bundle_size = $Row.bundle_size; status = 'received'; pr_url = $null
        released_in = $null; maintainer_note = $null; created_at = $now; updated_at = $now
    }
    $FakeInbox.NextId++
    [void]$FakeInbox.Rows.Add($stored)
    return (Build-FakeInboxReply 201 @(Select-FakeInboxColumns @($stored) $Select))
}

function Invoke-FakeInboxRpc {
    param([string]$Name, $Params)
    if ([string]$Params.p_passphrase -ne $FakeInbox.Passphrase) { return (Build-FakeInboxReply 400 @{ code = '28P01'; message = 'invalid admin passphrase' }) }
    switch ($Name) {
        'fix_inbox_list' {
            $rows = @($FakeInbox.Rows | Where-Object { -not $Params.p_status -or $_.status -eq $Params.p_status } | Sort-Object { $_.id } -Descending | ForEach-Object {
                $r = $_; $dev = $FakeInbox.Users.Values | Where-Object { $_.Id -eq $r.user_id } | Select-Object -First 1
                $r | Select-Object id, @{ n = 'developer_id'; e = { $dev.DeveloperId } }, app, app_version, key_id, slug, title, description, bundle_sha256, bundle_size, status, pr_url, released_in, maintainer_note, created_at, updated_at })
            return (Build-FakeInboxReply 200 @($rows))
        }
        'fix_inbox_bundle' {
            $row = $FakeInbox.Rows | Where-Object { [long]$_.id -eq [long]$Params.p_id } | Select-Object -First 1
            if (-not $row) { return (Build-FakeInboxReply 400 @{ code = 'P0002'; message = "no submission $($Params.p_id)" }) }
            return (Build-FakeInboxReply 200 $null ('"' + $row.bundle_b64 + '"'))
        }
        'fix_inbox_set_status' {
            $row = $FakeInbox.Rows | Where-Object { [long]$_.id -eq [long]$Params.p_id } | Select-Object -First 1
            if (-not $row) { return (Build-FakeInboxReply 400 @{ code = 'P0002'; message = "no submission $($Params.p_id)" }) }
            if ($Params.p_status -notin @('received', 'pr-opened', 'merged', 'declined')) { return (Build-FakeInboxReply 400 @{ code = '23514'; message = 'status check' }) }
            $row.status = $Params.p_status
            if ($null -ne $Params.p_pr_url) { $row.pr_url = $Params.p_pr_url }
            if ($null -ne $Params.p_released_in) { $row.released_in = $Params.p_released_in }
            if ($null -ne $Params.p_note) { $row.maintainer_note = $Params.p_note }
            $row.updated_at = [datetime]::UtcNow.ToString('o')
            return (Build-FakeInboxReply 204 $null '')
        }
        'fix_inbox_register_developer' {
            $u = $FakeInbox.Users[[string]$Params.p_email]
            if (-not $u) { return (Build-FakeInboxReply 400 @{ code = 'P0002'; message = 'no account with that e-mail: invite it first (Authentication > Users)' }) }
            $u.DeveloperId = [string]$Params.p_developer_id; $u.KeyId = [string]$Params.p_key_id; $u.PublicKey = [string]$Params.p_public_key
            $u.Apps = @($Params.p_apps); $u.Active = [bool]$Params.p_active
            return (Build-FakeInboxReply 200 $null ('"' + $u.Id + '"'))
        }
        'fix_inbox_set_open' {
            $FakeInbox.Open = [bool]$Params.p_open
            if ($null -ne $Params.p_max_per_hour) { $FakeInbox.MaxPerHour = [int]$Params.p_max_per_hour }
            return (Build-FakeInboxReply 204 $null '')
        }
    }
    return (Build-FakeInboxReply 404 @{ code = 'PGRST202'; message = "Could not find the function public.$Name" })
}
