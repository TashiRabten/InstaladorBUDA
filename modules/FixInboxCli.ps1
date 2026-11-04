# ── The CLI side of suggested changes: every fix-* action clicks the same button as the mouse ────────
# The password is never accepted here: signing in happens only in the visible window, and the reply never
# carries the session token. Actions that send, build, push, merge or decline need confirm:true (a dry
# run only shows what they would do).

function Get-FixCliActions {
    return @('fix-status', 'fix-settings', 'fix-suggest', 'fix-suggest-send', 'fix-suggest-refresh', 'fix-inbox', 'fix-inbox-refresh',
        'fix-inbox-verify', 'fix-inbox-open-pr', 'fix-inbox-decline', 'fix-inbox-merge', 'fix-inbox-register', 'fix-inbox-open',
        'fix-inbox-close', 'fix-inbox-forget', 'fix-inbox-add-developer', 'fix-inbox-new-keys', 'fix-registry-verify', 'fix-registry-sign',
        'fix-registry-publish', 'fix-sign-out')
}

function Assert-FixCliRequest {
    param($Request)
    foreach ($field in @('password', 'senha', 'passphrase', 'adminPassphrase', 'p_passphrase', 'fraseSenha', 'token', 'accessToken', 'access_token', 'refreshToken', 'secret', 'secretKey', 'serviceKey', 'apiKey', 'value')) {
        if (Test-CliProperty $Request $field) { throw "Do not put a credential in CLI JSON ('$field'). The password and the admin passphrase are typed only in the visible window; only the contributor's session token and the passphrase, as a SecureString, are kept, in memory." }
    }
}

function Invoke-FixInboxCliRequest {
    param($GuiState, $Request, $TabState, [string]$Action)
    Assert-FixCliRequest $Request
    if ($Action -notin (Get-FixCliActions)) { throw "Unknown action '$Action'. Use help for available actions." }
    if (-not $TabState.FixButtons) { throw 'This cockpit session has no suggestions section.' }
    $dry = [bool]$TabState.Controls.DryRun.Checked
    $confirmed = [bool]$Request.confirm
    $needsConfirm = @{ 'fix-settings' = 1; 'fix-suggest-send' = 1; 'fix-inbox-open-pr' = 1; 'fix-inbox-decline' = 1; 'fix-inbox-merge' = 1; 'fix-registry-sign' = 1
        'fix-inbox-register' = 1; 'fix-inbox-open' = 1; 'fix-inbox-close' = 1; 'fix-inbox-add-developer' = 1; 'fix-inbox-new-keys' = 1; 'fix-registry-publish' = 1 }
    if ($needsConfirm.ContainsKey($Action) -and -not $confirmed -and -not ($dry -and $Action -ne 'fix-settings')) {
        throw "$Action requires confirm:true (or dryRun:true to see what it would do)."
    }
    switch ($Action) {
        'fix-status' { }
        'fix-settings' { Invoke-FixCliSettings $Request $TabState }
        'fix-registry-verify' { Invoke-FixCliTabButton $TabState 'RegistryVerify'; if ($TabState.FixRegistryError) { throw $TabState.FixRegistryError } }
        'fix-registry-sign' { Invoke-FixCliRegistrySign $Request $TabState $confirmed }
        'fix-sign-out' { Invoke-FixCliSignOut $TabState }
        default { Invoke-FixCliWindowAction $Request $TabState $Action $confirmed }
    }
    return [pscustomobject]@{ ok = $true; command = 'action'; data = (Get-FixCliStatus $TabState $Action) }
}

function Invoke-FixCliTabButton {
    param($TabState, [string]$Name)
    $button = $TabState.FixButtons[$Name]
    Assert-CockpitButtonReady $button "The '$($button.Text)' control is unavailable."
    $button.PerformClick()
}

function Invoke-FixCliSettings {
    param($Request, $TabState)
    $values = @{}
    foreach ($field in @(Get-FixSettingsFields | ForEach-Object { $_[0] })) {
        if (Test-CliProperty $Request $field) { $values[$field] = [string]$Request.$field }
    }
    if ($values.Count -eq 0) { throw "fix-settings needs at least one of: $((Get-FixSettingsFields | ForEach-Object { $_[0] }) -join ', ')." }
    [void](Save-FixInboxSettingsFrom $values)
    & $TabState.AppendLog "Sugestões: configuração salva pela CLI ($(@($values.Keys | Sort-Object) -join ', '))."
    foreach ($w in @($TabState.FixSuggest, $TabState.FixInbox)) { if ($w -and -not $w.Form.IsDisposed) { Show-FixSessionLabel $w } }
}

function Invoke-FixCliRegistrySign {
    param($Request, $TabState, [bool]$Confirmed)
    foreach ($field in @('in', 'rootIdentity')) { if (-not (Test-CliProperty $Request $field)) { throw "fix-registry-sign requires $field (a file path)." } }
    $TabState.FixPendingSign = @{ In = [string]$Request.in; RootIdentity = [string]$Request.rootIdentity }
    $TabState.CliConfirmed = $Confirmed
    try { Invoke-FixCliTabButton $TabState 'RegistrySign' } finally { $TabState.CliConfirmed = $false; $TabState.FixPendingSign = $null }
    if ($TabState.FixRegistrySignError) { throw $TabState.FixRegistrySignError }
}

function Invoke-FixCliSignOut {
    param($TabState)
    $TabState.FixShared.Session = $null
    foreach ($w in @($TabState.FixSuggest, $TabState.FixInbox)) {
        if ($w -and -not $w.Form.IsDisposed) { Show-FixSessionLabel $w; Sync-FixWindowButtons $w }
    }
    & $TabState.AppendLog 'Sugestões: saiu da conta (CLI); o token foi descartado.'
}

# Opens (or finds) the window an action belongs to and clicks its button.
function Invoke-FixCliWindowAction {
    param($Request, $TabState, [string]$Action, [bool]$Confirmed)
    $kind = if ($Action -like 'fix-suggest*') { 'suggest' } else { 'inbox' }
    $key = if ($kind -eq 'suggest') { 'FixSuggest' } else { 'FixInbox' }
    $window = $TabState[$key]
    if ($Action -in @('fix-suggest', 'fix-inbox')) {
        Invoke-FixCliTabButton $TabState $(if ($kind -eq 'suggest') { 'Suggest' } else { 'Inbox' })
        $window = $TabState[$key]
        if (-not $window) { throw 'The window did not open; see the session log.' }
        if ($kind -eq 'inbox') { $window.Controls.Passphrase.Focus() | Out-Null; return }
        if (Test-CliProperty $Request 'email') { $window.Controls.Email.Text = [string]$Request.email }
        if (Test-CliProperty $Request 'bundle') {
            $window.Controls.Bundle.Text = [string]$Request.bundle
            Invoke-FixWindowStep $window 'suggest-load'
            if ($window.LastError) { throw $window.LastError }
        }
        if (-not $window.Shared.Session) { $window.Controls.Password.Focus() | Out-Null }
        return
    }
    if (-not $window -or $window.Form.IsDisposed) { throw "Open the window first ($(if ($kind -eq 'suggest') { 'fix-suggest' } else { 'fix-inbox' }))." }
    $button = Select-FixCliTarget $Request $window $Action
    Invoke-FixCliClick $window $button $Confirmed $Request
}

function Select-FixCliTarget {
    param($Request, $Window, [string]$Action)
    switch ($Action) {
        'fix-suggest-send' { return 'Send' }
        'fix-suggest-refresh' { return 'Refresh' }
        'fix-inbox-refresh' { return 'Refresh' }
        'fix-inbox-open-pr' { return 'OpenPr' }
        'fix-inbox-register' { return 'Register' }
        'fix-inbox-new-keys' { return 'NewKeys' }
        'fix-registry-publish' { return 'PublishRegistry' }
        'fix-inbox-forget' { return 'ForgetPassphrase' }
        'fix-inbox-add-developer' {
            # apps: "all" (the default) or a list of TradutorBUDA / ScanBUDA. The link, when there is one, opens in
            # the window only; the reply says whether it was shown, never the link.
            foreach ($field in @('name', 'email')) { if (-not (Test-CliProperty $Request $field)) { throw "fix-inbox-add-developer needs $field." } }
            $apps = if (Test-CliProperty $Request 'apps') { @($Request.apps | ForEach-Object { [string]$_ }) } else { @('all') }
            $id = if (Test-CliProperty $Request 'developerId') { [string]$Request.developerId } else { '' }
            $key = if (Test-CliProperty $Request 'publicKey') { [string]$Request.publicKey } else { '' }
            $senior = (Test-CliProperty $Request 'senior') -and [bool]$Request.senior
            $Window.CliDeveloper = Build-FixDeveloperRequest ([string]$Request.name) ([string]$Request.email) $id ($apps -contains 'all') $apps $key $senior
            return 'AddDeveloper'
        }
        { $_ -in @('fix-inbox-open', 'fix-inbox-close') } {
            if (Test-CliProperty $Request 'maxPerHour') { $Window.CliMaxPerHour = [int]$Request.maxPerHour }
            if ($Action -eq 'fix-inbox-open') { return 'OpenInbox' } else { return 'CloseInbox' }
        }
        'fix-inbox-verify' {
            if (Test-CliProperty $Request 'bundle') { $Window.CliBundle = [string]$Request.bundle; return 'VerifyFile' }
            if (-not (Test-CliProperty $Request 'id')) { throw 'fix-inbox-verify needs id (an inbox row) or bundle (a local .budafix).' }
            [void](Select-FixInboxRow $Window ([long]$Request.id))
            return 'Verify'
        }
        default {
            if (-not (Test-CliProperty $Request 'id')) { throw "$Action needs id (the inbox row)." }
            [void](Select-FixInboxRow $Window ([long]$Request.id))
            if ($Action -eq 'fix-inbox-decline') {
                if (-not (Test-CliProperty $Request 'note')) { throw 'fix-inbox-decline needs note (the developer reads it).' }
                $Window.CliNote = [string]$Request.note
                return 'Decline'
            }
            return 'Merge'
        }
    }
}

function Invoke-FixCliClick {
    param($Window, [string]$Name, [bool]$Confirmed, $Request)
    $button = $Window.Buttons[$Name]
    if ($Window.Busy) { throw 'The window is busy with another step; try again when it finishes.' }
    Sync-FixWindowButtons $Window
    if (-not $button.Enabled) {
        $Window.CliBundle = $null; $Window.CliNote = $null; $Window.CliMaxPerHour = $null; $Window.CliDeveloper = $null
        throw "'$($button.Text)' is not available now (sign in, pick or verify a bundle, or select a row with the right status first)."
    }
    Assert-CockpitButtonReady $button "The '$($button.Text)' control is unavailable."
    $Window.CliConfirmed = $Confirmed
    $Window.CliOverrideCeiling = [bool]$Request.overrideCeiling
    try { $button.PerformClick() }
    finally { $Window.CliConfirmed = $false; $Window.CliNote = $null; $Window.CliOverrideCeiling = $false; $Window.CliBundle = $null; $Window.CliMaxPerHour = $null; $Window.CliDeveloper = $null }
    if ($Window.LastError) { throw $Window.LastError }
}

function Get-FixCliStatus {
    param($TabState, [string]$Action)
    $settings = Get-FixInboxSettings
    $s = $TabState.FixShared.Session
    $session = if ($s) { @{ signedIn = $true; email = $s.Email; userId = $s.UserId; expiresAt = $s.ExpiresAt.ToString('o') } } else { @{ signedIn = $false } }
    return @{
        tabId = $TabState.Id; action = $Action; dryRun = [bool]$TabState.Controls.DryRun.Checked; running = [bool]$TabState.IsRunning
        settings = @{
            supabaseUrl = $settings.supabaseUrl; publishableKeySet = [bool]$settings.publishableKey; email = $settings.email
            suggestionsFolder = $settings.suggestionsFolder; installs = $settings.installs; registryPath = $settings.registryPath
            rootKeyPath = $settings.rootKeyPath; inboxFolder = $settings.inboxFolder; worktreeRoot = $settings.worktreeRoot
            registrySeenVersion = $settings.registrySeenVersion
        }
        session = $session; registry = $TabState.FixShared.Registry; registryError = $TabState.FixRegistryError
        suggest = (Get-FixCliWindowStatus $TabState.FixSuggest); inbox = (Get-FixCliWindowStatus $TabState.FixInbox)
        pendingStatus = @(Get-FixPendingStatuses)
    }
}

function Get-FixCliWindowStatus {
    param($Window)
    if (-not $Window -or $Window.Form.IsDisposed) { return @{ open = $false } }
    $v = $Window.Verification
    $verification = $null
    if ($v) {
        $r = $v.Result
        $verification = @{ valid = [bool]$r.valid; problems = @($r.problems); capabilities = @($r.capabilities); overCeiling = @($r.overCeiling)
            branch = $r.branch; developer = $r.developer; keyId = $r.keyId; app = $r.app; appVersion = $r.appVersion; title = $r.title
            changes = $r.changes; tag = $v.Release.Tag; worktree = $v.Release.Path; bundle = $v.BundlePath; submissionId = $v.SubmissionId; diffChars = $v.DiffChars }
    }
    $summary = $Window.Summary
    return @{
        open = $true; busy = [bool]$Window.Busy; status = $Window.LastStatus; lastError = $Window.LastError
        passphraseSet = [bool]$Window.Passphrase; lastRegistered = $Window.LastRegistered; lastInvite = $Window.LastInvite; lastNewKeys = $Window.LastNewKeys; lastPublished = $Window.LastPublished
        bundle = if ($summary) { @{ path = $summary.path; title = $summary.title; app = $summary.app; appVersion = $summary.appVersion; sha256 = $summary.sha256; keyId = $summary.keyId; files = @($summary.files); capabilities = @($summary.capabilities) } } else { $null }
        rows = @($Window.Rows); lastSent = $Window.LastSent; verification = $verification
        lastPrUrl = $Window.LastPrUrl; lastOutcome = $Window.LastOutcome
    }
}
