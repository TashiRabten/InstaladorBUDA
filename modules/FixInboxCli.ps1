# ── The CLI side of suggested changes: every fix-* action clicks the same button as the mouse ────────
# The password is never accepted here: signing in happens only in the visible window, and the reply never
# carries the session token. Actions that send, build, push, merge or decline need confirm:true (a dry
# run only shows what they would do). fix-pr-installed (below) opens a PR from an installed app's own code.

function Get-FixCliActions {
    return @('fix-status', 'fix-settings', 'fix-suggest', 'fix-suggest-send', 'fix-suggest-refresh', 'fix-inbox', 'fix-inbox-refresh',
        'fix-inbox-verify', 'fix-inbox-open-pr', 'fix-inbox-decline', 'fix-inbox-merge', 'fix-inbox-register', 'fix-inbox-open',
        'fix-inbox-close', 'fix-inbox-forget', 'fix-inbox-add-developer', 'fix-inbox-new-keys', 'fix-registry-verify', 'fix-registry-sign',
        'fix-registry-publish', 'fix-sign-out', 'fix-pr-installed')
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
        'fix-inbox-register' = 1; 'fix-inbox-open' = 1; 'fix-inbox-close' = 1; 'fix-inbox-add-developer' = 1; 'fix-inbox-new-keys' = 1; 'fix-registry-publish' = 1
        'fix-pr-installed' = 1 }
    if ($needsConfirm.ContainsKey($Action) -and -not $confirmed -and -not ($dry -and $Action -ne 'fix-settings')) {
        throw "$Action requires confirm:true (or dryRun:true to see what it would do)."
    }
    switch ($Action) {
        'fix-status' { }
        'fix-settings' { Invoke-FixCliSettings $Request $TabState }
        'fix-registry-verify' { Invoke-FixCliTabButton $TabState 'RegistryVerify'; if ($TabState.FixRegistryError) { throw $TabState.FixRegistryError } }
        'fix-registry-sign' { Invoke-FixCliRegistrySign $Request $TabState $confirmed }
        'fix-sign-out' { Invoke-FixCliSignOut $TabState }
        'fix-pr-installed' {
            Invoke-FixInstalledPr $Request $TabState $confirmed
            return [pscustomobject]@{ ok = $true; command = 'action'; data = @{ tabId = $TabState.Id; action = $Action; running = [bool]$TabState.IsRunning
                    dryRun = $dry; lastInstalledPr = $TabState.LastInstalledPr } }
        }
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
        pendingStatus = @(Get-FixPendingStatuses); lastInstalledPr = $TabState.LastInstalledPr
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

# ── "PR do app instalado" (fix-pr-installed): the installed app's own code becomes a pull request, with no bundle ──
# Asked for by the developer on 13/11: the agents' changes to the three apps reach GitHub without him typing
# anything. The installed app's sources (<install>\source) are its release plus every local change, so copied over
# a worktree at that release's tag they make exactly those changes; the PR goes to main, where GitHub merges them
# with what main gained since the release (or shows the conflicts). It runs in this cockpit with the git and gh the
# maintainer is signed in with, as Abrir PR does: a new contrib/ branch in a worktree of its own (the clone's own
# checkout is not touched), Gitleaks on the commit and on the branch before the push, nothing forced. The signed
# bundle path (fix-suggest, fix-inbox-*) stays for other developers' suggestions.

function Resolve-FixInstall {
    param($Settings, [string]$Name)
    $candidates = @()
    if ($Settings.installs -and $Settings.installs.$Name) { $candidates += [string]$Settings.installs.$Name }
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $candidates += @((Join-Path $local $Name), (Join-Path $local "Programs\$Name"))
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'source') -PathType Container)) { return $c }
    }
    throw "O $Name instalado (com a pasta source) não foi achado em: $($candidates -join '; '). Diga onde com install."
}

# The installed version: jpackage's app\<name>.cfg, else the source stamp (ScanBUDA, TradutorBUDA).
function Get-FixInstalledVersion {
    param([string]$Install)
    foreach ($cfg in @(Get-ChildItem -LiteralPath (Join-Path $Install 'app') -Filter '*.cfg' -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match([IO.File]::ReadAllText($cfg.FullName), 'jpackage\.app-version=([0-9]+(\.[0-9]+){1,3})')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    $stamp = Join-Path $Install 'source\selfcode-sources.json'
    if (Test-Path -LiteralPath $stamp -PathType Leaf) {
        $v = [string](([IO.File]::ReadAllText($stamp) | ConvertFrom-Json).appVersion)
        if ($v) { return $v }
    }
    throw "A versão do app instalado em $Install não foi achada (app\*.cfg ou source\selfcode-sources.json). Diga com version."
}

# The release's commit in the clone: the tag, fetched from GitHub or restored from its build when missing.
function Resolve-FixInstalledBase {
    param($App, [string]$Version)
    $repo = [string]$App.repoRoot
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { throw "O repositório de $($App.name) não está em $repo." }
    $base = Get-FixReleaseBase $App $Version
    $note = ''
    $peeled = Invoke-FixGit @('-C', $repo, 'rev-parse', '--verify', '--quiet', "$($base.Reference)^{commit}")
    if ($peeled.ExitCode -ne 0 -and -not $base.ExpectedCommit) {
        $note = Restore-FixReleaseTag $App $repo $base.Label
        $peeled = Invoke-FixGit @('-C', $repo, 'rev-parse', '--verify', '--quiet', "$($base.Reference)^{commit}")
    }
    if ($peeled.ExitCode -ne 0) { throw "A base $($base.Label) não existe neste repositório nem no GitHub." }
    return [pscustomobject]@{ Reference = $base.Reference; Label = $base.Label; Note = $note }
}

# The job's lines: worktree on a new branch at the release, the installed .java copied over it, staged, then the
# same Gitleaks / commit / Gitleaks / push / gh pr create as Abrir PR (Build-FixPrPublishLines).
function Build-FixInstalledPrCommands {
    param([hashtable]$Plan)
    if (-not (Test-FixBranchName $Plan.Branch)) { throw "Branch inválida: $($Plan.Branch)" }
    $local = 'git -C $__repo rev-parse --verify --quiet "refs/heads/$__branch" *> $null; $__local = $LASTEXITCODE; $global:LASTEXITCODE = 0'
    $remote = 'git -C $__repo ls-remote --exit-code --heads origin "refs/heads/$__branch" *> $null; $__remote = $LASTEXITCODE; $global:LASTEXITCODE = 0'
    $eol = if ($Plan.BaseRef -notlike 'refs/tags/*') { 'core.autocrlf=false' } else { 'core.autocrlf=true' }
    $copy = 'robocopy $__from $__src *.java /S /NFL /NDL /NJH /NJS /NP | Out-Null; $__copied = $LASTEXITCODE; $global:LASTEXITCODE = 0'
    return @(
        "# PR do $($Plan.App) instalado ($($Plan.Version)): $($Plan.Branch) a partir de $($Plan.Tag)"
        "`$__repo = $(Quote-PS $Plan.RepoRoot); `$__wt = $(Quote-PS $Plan.Worktree); `$__branch = $(Quote-PS $Plan.Branch); `$__base = $(Quote-PS $Plan.BaseRef); `$__from = $(Quote-PS $Plan.From); `$__src = Join-Path `$__wt $(Quote-PS $Plan.SourceRoot)"
        (Get-FixStopLine '' '-not (Test-Path -LiteralPath $__from -PathType Container)' 'A pasta do código instalado não existe: nada foi feito.')
        (Get-FixStopLine $local '$__local -eq 0' 'A branch $__branch já existe neste clone: nada foi feito.')
        (Get-FixStopLine $remote '$__remote -eq 0' 'A branch $__branch já existe no GitHub: nada foi feito.')
        (Get-FixStopLine '' '$__remote -ne 2' 'O GitHub não respondeu ao git ls-remote: nada foi feito.')
        (Get-FixStopLine '' 'Test-Path -LiteralPath $__wt' 'A pasta $__wt já existe: nada foi feito.')
        "git -C `$__repo -c $eol worktree add -b `$__branch `$__wt `"`$__base`"; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
        (Get-FixStopLine $copy '$__copied -ge 8' 'A cópia do código instalado falhou (robocopy $__copied); a worktree fica para inspeção e nada foi enviado.')
        "git -C `$__wt -c core.autocrlf=true add -A -- $(Quote-PS $Plan.SourceRoot); if (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
        (Get-FixStopLine 'git -C $__wt diff --cached --quiet; $__same = ($LASTEXITCODE -eq 0); $global:LASTEXITCODE = 0' '$__same' 'O app instalado é igual à release: não há o que enviar.')
        'git -C $__wt -c core.quotepath=false diff --cached --stat'
    ) + @(Build-FixPrPublishLines $Plan)
}

# CLI fix-pr-installed: target SuiteBUDA, ScanBUDA or TradutorBUDA; optional title, body, version, install.
function Invoke-FixInstalledPr {
    param($Request, $TabState, [bool]$Confirmed)
    $name = [string]$Request.target
    if (-not (Get-FixAppTools)[$name]) { throw "fix-pr-installed: target é SuiteBUDA, ScanBUDA ou TradutorBUDA (veio '$name')." }
    $app = Get-App $name
    if (-not $app) { throw "O app '$name' não está em apps.json." }
    if ($TabState.IsRunning) { throw "A sessão $($TabState.Id) já tem um job rodando: use outra sessão ou espere." }
    $settings = Get-FixInboxSettings
    $install = if (Test-CliProperty $Request 'install') { [string]$Request.install } else { Resolve-FixInstall $settings $name }
    $version = if (Test-CliProperty $Request 'version') { [string]$Request.version } else { Get-FixInstalledVersion $install }
    $base = Resolve-FixInstalledBase $app $version
    $scanner = Resolve-GitBootstrapScanner $TabState.Controls.BootstrapScanner.Text.Trim() $AppDir
    if (-not $scanner) { throw 'O Gitleaks não foi encontrado, então nada foi feito.' }
    $repoSlug = Resolve-AppRepo $app
    if ($repoSlug -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "O repositório GitHub de $name não foi encontrado." }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $branch = "contrib/instalado/$($name.ToLowerInvariant())-$stamp"
    $title = if (Test-CliProperty $Request 'title') { ([string]$Request.title -replace '[\r\n]+', ' ').Trim() } else { "${name}: mudanças do app instalado sobre a $($base.Label)" }
    $body = if (Test-CliProperty $Request 'body') { [string]$Request.body } else { '' }
    $message = (@($title, '', $body, '', "Código do $name instalado nesta máquina ($install\source), versão $version, sobre a $($base.Label).",
        'Enviado pelo InstaladorBUDA (fix-pr-installed), sem pacote: Gitleaks no commit e na branch.')) -join "`n"
    $messageFile = Write-FixTempText 'commit' $message
    $bodyFile = Write-FixTempText 'pr' $message
    $resultFile = Join-Path $env:TEMP ('instaladorbuda-pr-' + [guid]::NewGuid().ToString('N') + '.txt')
    $plan = @{
        App = $name; Version = $version; RepoRoot = [string]$app.repoRoot; Branch = $branch; Tag = $base.Label; BaseRef = $base.Reference
        Worktree = Join-Path ([string]$settings.worktreeRoot) "$name\$($branch.Replace('/', '-'))"; From = Join-Path $install 'source'
        SourceRoot = (Get-FixSourceRoot $name); Scanner = $scanner; GitHubRepo = $repoSlug; Title = $title
        MessageFile = $messageFile; BodyFile = $bodyFile; ResultFile = $resultFile
    }
    $commands = Build-FixInstalledPrCommands $plan
    $log = $TabState.AppendLog
    if ($base.Note) { & $log "PR do instalado: $($base.Note)." }
    $temps = @($messageFile, $bodyFile)
    $tab = $TabState
    $onDone = {
        foreach ($f in $temps) { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
            $tab.LastInstalledPr = [IO.File]::ReadAllText($resultFile).Trim()
            Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue
            & $log "PR do $name instalado aberto: $($tab.LastInstalledPr)"
        } else {
            & $log "PR do $name instalado: o job não terminou (veja o log acima); nada mais foi feito."
        }
    }.GetNewClosure()
    $TabState.LastInstalledPr = ''
    $TabState.CliConfirmed = $Confirmed
    try { & $TabState.StartJob $commands "PR do $name instalado ($branch)" $true ([string]$app.repoRoot) $null $onDone }
    finally { $TabState.CliConfirmed = $false }
    if (-not $TabState.IsRunning) { foreach ($f in $temps) { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue } }
}
