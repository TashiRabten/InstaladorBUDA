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
# ── Suggested changes: settings, the bundle's manifest, and the Supabase inbox ─────────────────
# A contributor has no access to the repository: their app writes a signed .budafix, this cockpit
# sends it to the private Supabase inbox (FixInboxClient.ps1), and the maintainer's cockpit verifies it
# and opens the PR (FixReview.ps1, FixPullRequest.ps1). The schema is TradutorBUDA's
# dev/security/supabase-fix-inbox.sql (v2). Every HTTP call goes through Invoke-FixInboxHttp (tests replace it).

$script:FixInboxMaxBundleBytes = 8388608   # BundleTool's own cap; the inbox takes 4 MiB

function Get-FixInboxSettingsPath {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    return (Join-Path $localData 'InstaladorBUDA\fix-inbox.json')
}

function Get-FixInboxSentPath {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    return (Join-Path $localData 'InstaladorBUDA\fix-sent.json')
}

function Get-FixInboxPendingPath { return (Join-Path (Split-Path -Parent (Get-FixInboxSentPath)) 'fix-pending.json') }

# The apps whose BundleTool the cockpit knows: the jar inside the install and the class.
function Get-FixAppTools {
    return @{
        TradutorBUDA = @{ Jar = 'app\TradutorBUDA.jar'; MainClass = 'com.example.glossariobuda.selfcode.BundleTool'; DefaultInstall = 'TradutorBUDA' }
        ScanBUDA     = @{ Jar = 'app\ScanBUDA.jar';     MainClass = 'com.example.scanbuda.selfcode.BundleTool';       DefaultInstall = 'ScanBUDA' }
        SuiteBUDA    = @{ Jar = 'app\SuiteBUDA.jar';    MainClass = 'org.budasuite.SuiteBUDA'; Arguments = @('--bundle-tool'); DefaultInstall = 'SuiteBUDA'; SourceRoot = 'app/src/main/java' }
    }
}

function Get-FixSourceRoot {
    param([string]$App)
    $tool = (Get-FixAppTools)[$App]
    if (-not $tool) { throw "O cockpit não conhece os fontes de '$App'." }
    if ($tool.SourceRoot) { return [string]$tool.SourceRoot }
    return 'src/main/java'
}

function Get-FixInboxDefaults {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $profileDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $installs = [ordered]@{}
    foreach ($entry in (Get-FixAppTools).GetEnumerator()) { $installs[$entry.Key] = Join-Path $localData $entry.Value.DefaultInstall }
    return [ordered]@{
        supabaseUrl = ''; publishableKey = ''; email = ''
        suggestionsFolder = Join-Path $profileDir '.tradutorbuda\sugestoes'
        installs = $installs
        registryPath = Join-Path $localData 'InstaladorBUDA\registry\developers.json'
        rootKeyPath = Join-Path $localData 'InstaladorBUDA\registry\root.pub'
        inboxFolder = Join-Path $localData 'InstaladorBUDA\fix-inbox'
        worktreeRoot = Join-Path $localData 'InstaladorBUDA\worktrees'
        registrySeenVersion = 0
    }
}

function Get-FixInboxSettings {
    $settings = Get-FixInboxDefaults
    $path = Get-FixInboxSettingsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]$settings }
    try { $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return [pscustomobject]$settings }
    foreach ($name in @($settings.Keys)) {
        if ($name -eq 'installs' -or -not ($saved.PSObject.Properties.Name -contains $name)) { continue }
        $settings[$name] = $saved.$name
    }
    if ($saved.installs) { foreach ($p in $saved.installs.PSObject.Properties) { $settings.installs[$p.Name] = [string]$p.Value } }
    $settings.registrySeenVersion = [long]$settings.registrySeenVersion
    return [pscustomobject]$settings
}

function Save-FixInboxSettings {
    param($Settings)
    $path = Get-FixInboxSettingsPath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    [IO.File]::WriteAllText($path, ($Settings | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}

# Null when $Key may go in a client; otherwise why not. A secret key (sb_secret_…, or a JWT whose role is
# not anon) would let anyone holding the cockpit bypass row-level security, so it is refused outright.
function Test-FixInboxPublishableKey {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return 'Falta a chave publicável do projeto (Supabase ▸ Settings ▸ API Keys).' }
    if ($Key -match '^sb_secret_') { return 'Esta é uma chave secreta (sb_secret_…), que nunca vai num cliente. Use a publicável (sb_publishable_…).' }
    if ($Key -match '^eyJ[A-Za-z0-9_-]*\.([A-Za-z0-9_-]+)\.') {
        $payload = $Matches[1].Replace('-', '+').Replace('_', '/')
        $payload += '=' * ((4 - $payload.Length % 4) % 4)
        try { $role = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json).role } catch { $role = '' }
        if ($role -ne 'anon') { return "Esta chave JWT tem o papel '$role'; use a chave anon ou a publicável." }
        return $null
    }
    if ($Key -notmatch '^sb_publishable_[A-Za-z0-9_-]+$') { return 'Formato de chave desconhecido: use sb_publishable_… (ou a chave anon).' }
    return $null
}

function Test-FixInboxUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return 'Falta a URL do projeto Supabase (https://<ref>.supabase.co).' }
    if ($Url -match '^https://[A-Za-z0-9.-]+(:\d+)?/?$' -or $Url -match '^http://(127\.0\.0\.1|localhost)(:\d+)?/?$') { return $null }
    return 'A URL do Supabase deve ser https://<ref>.supabase.co (http só em 127.0.0.1 / localhost).'
}

function Assert-FixInboxConfigured {
    param($Settings)
    foreach ($problem in @((Test-FixInboxUrl $Settings.supabaseUrl), (Test-FixInboxPublishableKey $Settings.publishableKey))) {
        if ($problem) { throw "$problem Abra Configurar… na seção Sugestões de mudança." }
    }
}

# ── The bundle as its own manifest describes it (unverified: the maintainer's BundleTool decides) ──

function Read-FixBundleManifest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Pacote não encontrado: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1 -or $item.Length -gt $script:FixInboxMaxBundleBytes) { throw 'Um pacote tem de 1 byte a 8 MB.' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $text = $null; $names = @()
    $zip = [IO.Compression.ZipFile]::OpenRead($item.FullName)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $entry = $zip.GetEntry('manifest.json')
        if (-not $entry -or $entry.Length -gt 1048576) { throw 'Não é um pacote de sugestão: falta manifest.json.' }
        $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    $m = $text | ConvertFrom-Json
    if ($m.format -ne 'budafix') { throw 'Não é um pacote de sugestão (format diferente de budafix).' }
    return (ConvertTo-FixBundleSummary $m $item $names)
}

function ConvertTo-FixBundleSummary {
    param($Manifest, $Item, [string[]]$EntryNames)
    $files = @()
    if ($Manifest.files) {
        foreach ($p in $Manifest.files.PSObject.Properties) {
            $kind = if (-not $p.Value.sha256) { 'deleted' } elseif (-not $p.Value.base) { 'new' } else { 'changed' }
            $files += [pscustomobject]@{ path = $p.Name; kind = $kind }
        }
    }
    return [pscustomobject]@{
        path = $Item.FullName; size = [long]$Item.Length
        sha256 = (Get-Sha256File $Item.FullName)
        app = [string]$Manifest.app; appVersion = [string]$Manifest.appVersion
        title = [string]$Manifest.title; description = [string]$Manifest.description; slug = [string]$Manifest.slug
        created = [string]$Manifest.created
        developerName = [string]$Manifest.developer.name; developerEmail = [string]$Manifest.developer.email
        keyId = [string]$Manifest.signature.keyId
        files = $files
        capabilities = @($Manifest.capabilities | ForEach-Object { [string]$_ })
        capabilityLines = @($Manifest.capabilityLines | ForEach-Object { [string]$_ })
        entries = @($EntryNames).Count
    }
}

function Format-FixBundleSummary {
    param($Summary)
    $lines = @(
        "Título: $($Summary.title)"
        "App: $($Summary.app) $($Summary.appVersion)   slug: $($Summary.slug)"
        "Desenvolvedor: $($Summary.developerName) <$($Summary.developerEmail)>   chave: $($Summary.keyId)"
        "Pacote: $($Summary.size) bytes   SHA-256 $($Summary.sha256)"
    )
    if ($Summary.description) { $lines += "Descrição: $($Summary.description)" }
    $lines += "Arquivos ($(@($Summary.files).Count)):"
    $lines += @($Summary.files | ForEach-Object { "  $($_.kind.PadRight(8)) $($_.path)" })
    $caps = if (@($Summary.capabilities).Count) { $Summary.capabilities -join ', ' } else { 'nenhuma' }
    $lines += "Capacidades que a mudança acrescenta: $caps"
    $lines += @($Summary.capabilityLines | ForEach-Object { "  $_" })
    $lines += '(Lido do próprio pacote. A assinatura, o registro e a release são conferidos pelo mantenedor.)'
    return ($lines -join [Environment]::NewLine)
}

# The row's checks from the schema, before anything is sent, so a refusal names the field.
function Assert-FixSubmissionFields {
    param($Summary)
    $problems = @()
    if (-not (Get-FixAppTools).ContainsKey([string]$Summary.app)) { $problems += "app desconhecido: $($Summary.app)" }
    if ($Summary.appVersion -notmatch '^[0-9]+(\.[0-9]+){1,3}$') { $problems += "versão inválida: $($Summary.appVersion)" }
    if ($Summary.keyId -notmatch '^[0-9a-f]{16}$') { $problems += 'o pacote não está assinado (sem keyId)' }
    if ($Summary.slug -notmatch '^[a-z0-9][a-z0-9-]{0,59}$') { $problems += "slug inválido: $($Summary.slug)" }
    if ($Summary.title.Length -lt 1 -or $Summary.title.Length -gt 200) { $problems += 'o título deve ter de 1 a 200 caracteres' }
    if ($Summary.description.Length -gt 4000) { $problems += 'a descrição passa de 4000 caracteres' }
    if ($problems.Count) { throw ('O pacote não pode ser enviado: ' + ($problems -join '; ') + '.') }
}
