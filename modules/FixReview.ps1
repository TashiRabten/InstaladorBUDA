# ── Suggested changes, the maintainer's side: verify with the app's own BundleTool, read the release's ──
# sources from a worktree at the release tag, show what the bundle adds and its diff, then — only after
# the maintainer confirms — branch, apply, commit, push and open the PR (Build-FixPullRequestCommands,
# run as a cockpit job). The branch is the one the verifier returns (contrib/<id>/<slug>, from the
# root-signed registry), never one the bundle names.

# Runs a program without a shell; the arguments are quoted here (a path may not contain a double quote).
# -PumpUi keeps the window painting while a long call (a worktree checkout) runs.
function Invoke-FixProcess {
    param([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSec = 180, [switch]$PumpUi)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-FixProcessArgument $_ }) -join ' ')
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
        while (-not $process.WaitForExit(50)) {
            if ($PumpUi) { [System.Windows.Forms.Application]::DoEvents() }
            if ([datetime]::UtcNow -gt $deadline) { $process.Kill(); throw "$([IO.Path]::GetFileName($FileName)) passou de $TimeoutSec s e foi parado." }
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = $out.GetAwaiter().GetResult(); Error = $err.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function ConvertTo-FixProcessArgument {
    param([string]$Value)
    if ($Value.Contains('"')) { throw "Um argumento não pode conter aspas: $Value" }
    if ($Value -eq '' -or $Value -match '\s') { return '"' + $Value.TrimEnd('\') + '"' }
    return $Value
}

function Get-FixBundleToolCommand {
    param($Settings, [string]$App)
    $tool = (Get-FixAppTools)[$App]
    if (-not $tool) { throw "O cockpit não conhece o BundleTool de '$App'." }
    $install = [string]$Settings.installs.$App
    $java = Join-Path $install 'runtime\bin\java.exe'
    $jar = Join-Path $install $tool.Jar
    if (-not (Test-Path -LiteralPath $java -PathType Leaf) -or -not (Test-Path -LiteralPath $jar -PathType Leaf)) {
        throw "A instalação do $App não foi encontrada em '$install' (precisa de runtime\bin\java.exe e $($tool.Jar)). Ajuste a pasta em Configurar…"
    }
    return [pscustomobject]@{ Java = $java; Jar = $jar; MainClass = $tool.MainClass; Arguments = @($tool.Arguments | Where-Object { $_ }) }
}

# One BundleTool command with the installed runtime. Results are JSON on standard output; exit 0 valid,
# 1 not valid, 2 wrong use (BundleTool's contract).
function Invoke-FixBundleTool {
    param($Settings, [string]$App, [string[]]$Arguments, [switch]$PumpUi)
    $tool = Get-FixBundleToolCommand $Settings $App
    $all = @('-Dstdout.encoding=UTF-8', '-Dfile.encoding=UTF-8', '-cp', $tool.Jar, $tool.MainClass) + @($tool.Arguments | Where-Object { $_ }) + $Arguments
    $r = Invoke-FixProcess $tool.Java $all -TimeoutSec 180 -PumpUi:$PumpUi
    $json = $null
    try { if ($r.Output.Trim().StartsWith('{')) { $json = $r.Output | ConvertFrom-Json } } catch { $json = $null }
    if ($r.ExitCode -eq 2 -or ($r.ExitCode -gt 2) -or -not $json) {
        $detail = (($r.Output + ' ' + $r.Error) -replace '\s+', ' ').Trim()
        if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600) + '…' }
        throw "BundleTool $($Arguments[0]) não respondeu como esperado (exit $($r.ExitCode)): $detail"
    }
    return $json
}

function Get-FixRegistryArguments {
    param($Settings)
    foreach ($file in @($Settings.registryPath, $Settings.rootKeyPath)) {
        if (-not (Test-Path -LiteralPath ([string]$file) -PathType Leaf)) { throw "Arquivo não encontrado: $file (registro de desenvolvedores / chave pública raiz; veja Configurar…)." }
    }
    return @('--registry', [string]$Settings.registryPath, '--root', [string]$Settings.rootKeyPath, '--min-version', [string][long]$Settings.registrySeenVersion)
}

# Checks the developer registry against the root's public key. A newer version is remembered, so an
# older registry put back later is refused as a rollback (--min-version).
function Invoke-FixRegistryVerify {
    param($Settings, [string]$App = 'TradutorBUDA')
    $result = Invoke-FixBundleTool $Settings $App (@('registry-verify') + (Get-FixRegistryArguments $Settings))
    if ($result.valid -and [long]$result.version -gt [long]$Settings.registrySeenVersion) {
        $Settings.registrySeenVersion = [long]$result.version
        Save-FixInboxSettings $Settings
    }
    return $result
}

# The registry's developers with what the inbox needs (e-mail, public key, apps), read only from a file
# BundleTool has just verified against the root: the bytes read are the bytes it checked (same SHA-256).
function Get-FixRegistryDevelopers {
    param($Settings)
    $path = [string]$Settings.registryPath
    $before = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-FixSha256 ([IO.File]::ReadAllBytes($path)) } else { '' }
    $result = Invoke-FixRegistryVerify $Settings
    if (-not $result.valid) { throw ('O registro de desenvolvedores não confere: ' + (@($result.problems) -join '; ')) }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ((Get-FixSha256 $bytes) -ne $before) { throw 'O registro mudou durante a verificação; verifique de novo.' }
    $doc = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    $verified = @{}; foreach ($d in @($result.developers)) { $verified[[string]$d.id] = $d }
    foreach ($d in @($doc.developers)) {
        $v = $verified[[string]$d.id]
        if (-not $v) { continue }
        [pscustomobject]@{ id = [string]$d.id; name = [string]$d.name; email = [string]$d.email; keyId = [string]$v.keyId
            publicKey = [string]$d.publicKey; apps = @($d.apps | ForEach-Object { [string]$_ }); active = [bool]$v.active }
    }
}

function Format-FixRegistryReport {
    param($Result)
    if (-not $Result.valid) { return @('Registro de desenvolvedores NÃO confere: ' + (@($Result.problems) -join '; ')) }
    $lines = @("Registro de desenvolvedores confere com a chave raiz (versão $($Result.version)); $(@($Result.developers).Count) desenvolvedor(es):")
    foreach ($d in @($Result.developers)) {
        $state = if ($d.active) { 'ativo' } else { 'REVOGADO' }
        $lines += "  $($d.id)  $($d.name)  chave $($d.keyId)  branch $($d.branchPrefix)*  $state"
    }
    return $lines
}

# The console command that signs the registry with the offline root key. The root password is typed in
# that console (BundleTool reads it without echo); it never passes through the cockpit.
function Get-FixRegistrySignCommandLine {
    param($Settings, [string]$UnsignedPath, [string]$RootIdentityPath, [string]$App = 'TradutorBUDA')
    $tool = Get-FixBundleToolCommand $Settings $App
    foreach ($file in @($UnsignedPath, $RootIdentityPath)) { if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Arquivo não encontrado: $file" } }
    $parts = @($tool.Java, '-cp', $tool.Jar, $tool.MainClass) + @($tool.Arguments | Where-Object { $_ }) +
        @('registry-sign', '--in', $UnsignedPath, '--root-identity', $RootIdentityPath, '--out', [string]$Settings.registryPath)
    return (@($parts | ForEach-Object { '"' + ([string]$_).TrimEnd('\') + '"' }) -join ' ')
}

function Open-FixRegistrySignConsole {
    param([string]$CommandLine)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /v:off /s /k "' + $CommandLine + '"'
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
}

# ── The release's sources: a detached worktree at <tagPrefix><version>, made once per version ──
# core.autocrlf=true: the installed app's source zip is a Windows checkout (CRLF), and the bundle's base
# hashes are of those bytes; a checkout with LF endings would make every base look changed.

function Invoke-FixGit {
    param([string[]]$Arguments, [switch]$PumpUi)
    return (Invoke-FixProcess 'git' $Arguments -TimeoutSec 600 -PumpUi:$PumpUi)
}

function Get-FixReleaseTag {
    param($AppEntry, [string]$Version)
    if ($Version -notmatch '^[0-9]+(\.[0-9]+){1,3}$') { throw "Versão inválida no pacote: $Version" }
    if (-not $AppEntry.tagPrefix) { throw "O app $($AppEntry.name) não tem tagPrefix em apps.json." }
    return "$($AppEntry.tagPrefix)$Version"
}

function Get-FixReleaseBase {
    param($AppEntry, [string]$Version)
    if ($AppEntry.name -eq 'SuiteBUDA' -and $Version -eq '0.0.0') {
        $commit = [string]$AppEntry.suggestionBaseCommit
        if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
            throw 'SuiteBUDA 0.0.0 não tem uma release publicada. O mantenedor precisa configurar suggestionBaseCommit em apps.json com o commit exato da base inicial (40 caracteres); nenhuma branch será usada automaticamente.'
        }
        $commit = $commit.ToLowerInvariant()
        return [pscustomobject]@{ Reference = $commit; Label = $commit; ExpectedCommit = $commit }
    }
    $tag = Get-FixReleaseTag $AppEntry $Version
    return [pscustomobject]@{ Reference = "refs/tags/$tag"; Label = $tag; ExpectedCommit = '' }
}

# gh without a shell, through the same runner; its own function so the review can be tested with a fake.
function Invoke-FixGh {
    param([string[]]$Arguments)
    return (Invoke-FixProcess 'gh' $Arguments -TimeoutSec 120)
}

# gh's times are ISO strings in Windows PowerShell and DateTime values in PowerShell 7.
function ConvertTo-FixUtc {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

# Owner/name of the app's own repository on GitHub: githubRepo in apps.json, else the clone's origin.
function Get-FixGitHubRepo {
    param($AppEntry)
    if ($AppEntry.githubRepo) { return [string]$AppEntry.githubRepo }
    $origin = Invoke-FixGit @('-C', [string]$AppEntry.repoRoot, 'remote', 'get-url', 'origin')
    if ($origin.ExitCode -eq 0 -and $origin.Output.Trim() -match 'github\.com[:/]([^/\s]+/[^/\s]+?)(\.git)?$') { return $Matches[1] }
    throw "O repositório do $($AppEntry.name) no GitHub não está em apps.json (githubRepo) nem no origin do clone."
}

# The commit a release was built from, when its tag is not in the app's repository. Deploy pushes the tag here
# and the build runs on it; Trigger dispatches the workflow on main and the tag exists only in the release
# repository. The build is the run of the app's workflow that uploaded the release's Windows installer (each
# upload replaces the last, so its time is the last run's): exactly one run must have been running then.
function Find-FixReleaseBuildCommit {
    param($AppEntry, [string]$Tag)
    $releaseRepo = [string](Resolve-ReleaseRepo $AppEntry)
    $view = Invoke-FixGh @('release', 'view', $Tag, '--repo', $releaseRepo, '--json', 'assets')
    if ($view.ExitCode -ne 0) { throw "a release $Tag não foi achada em $releaseRepo ($(($view.Error -replace '\s+', ' ').Trim()))." }
    $installers = @(($view.Output | ConvertFrom-Json).assets | Where-Object { [string]$_.name -like '*.exe' })
    if (-not $installers) { throw "a release $Tag em $releaseRepo não tem instalador .exe para dizer qual build a gerou." }
    $repo = Get-FixGitHubRepo $AppEntry
    $list = Invoke-FixGh @('run', 'list', '--repo', $repo, '--workflow', [string]$AppEntry.workflow, '--limit', '100', '--json', 'databaseId,headSha,createdAt,updatedAt')
    if ($list.ExitCode -ne 0) { throw "os builds de $repo não foram lidos ($(($list.Error -replace '\s+', ' ').Trim()))." }
    $runs = $list.Output | ConvertFrom-Json   # Windows PowerShell hands the whole array as one object
    $runs = @($runs)
    $builds = @(foreach ($installer in $installers) {
        $at = ConvertTo-FixUtc $installer.updatedAt
        $during = @($runs | Where-Object { (ConvertTo-FixUtc $_.createdAt) -le $at -and $at -le (ConvertTo-FixUtc $_.updatedAt) })
        if ($during.Count -ne 1) { throw "$($during.Count) execuções de $($AppEntry.workflow) em $repo rodavam quando $($installer.name) foi enviado ($($at.ToString('u'))); é preciso exatamente uma." }
        $during[0]
    })
    $commits = @($builds | ForEach-Object { ([string]$_.headSha).ToLowerInvariant() } | Select-Object -Unique)
    if ($commits.Count -ne 1 -or $commits[0] -notmatch '^[0-9a-f]{40}$') { throw "os instaladores da $Tag não vêm de um único commit ($($commits -join ', '))." }
    return [pscustomobject]@{ Commit = $commits[0]; Run = [string]$builds[0].databaseId; Repo = $repo }
}

# The release tag missing from the clone: first the tag from GitHub (a Deploy made on another machine), else the
# commit its build ran on, tagged in this clone only. Nothing is pushed, so no build starts; the bundle's base hashes
# are then checked against that commit's files, as for any release. Returns what happened, for the log.
function Restore-FixReleaseTag {
    param($AppEntry, [string]$Repo, [string]$Tag)
    $fetched = Invoke-FixGit @('-C', $Repo, 'fetch', '--no-tags', 'origin', "+refs/tags/$Tag`:refs/tags/$Tag") -PumpUi
    if ($fetched.ExitCode -eq 0) { return "a tag $Tag veio do GitHub" }
    $build = Find-FixReleaseBuildCommit $AppEntry $Tag
    if ((Invoke-FixGit @('-C', $Repo, 'cat-file', '-e', "$($build.Commit)^{commit}")).ExitCode -ne 0) {
        $got = Invoke-FixGit @('-C', $Repo, 'fetch', '--no-tags', 'origin', $build.Commit) -PumpUi
        if ($got.ExitCode -ne 0) { throw "o commit $($build.Commit) não veio do GitHub ($(($got.Error -replace '\s+', ' ').Trim()))." }
    }
    $made = Invoke-FixGit @('-C', $Repo, 'tag', $Tag, $build.Commit)
    if ($made.ExitCode -ne 0) { throw "a tag $Tag não foi criada neste clone ($(($made.Error -replace '\s+', ' ').Trim()))." }
    return "a tag $Tag foi criada só neste clone, no commit $($build.Commit.Substring(0, 12)) do build $($build.Run) de $($build.Repo) (sem push)"
}

function Initialize-FixReleaseWorktree {
    param($Settings, $AppEntry, [string]$Version)
    $repo = [string]$AppEntry.repoRoot
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { throw "O repositório de $($AppEntry.name) não está em $repo." }
    $base = Get-FixReleaseBase $AppEntry $Version
    $tag = $base.Label
    $peeled = Invoke-FixGit @('-C', $repo, 'rev-parse', '--verify', '--quiet', "$($base.Reference)^{commit}")
    $tagNote = ''
    if ($peeled.ExitCode -ne 0 -and -not $base.ExpectedCommit) {
        try { $tagNote = Restore-FixReleaseTag $AppEntry $repo $tag }
        catch { throw "A base $tag não existe neste repositório nem no GitHub, e o commit do build dela não foi achado: $($_.Exception.Message)" }
        $peeled = Invoke-FixGit @('-C', $repo, 'rev-parse', '--verify', '--quiet', "$($base.Reference)^{commit}")
    }
    if ($peeled.ExitCode -ne 0) { throw "A base $tag não existe neste repositório: o pacote foi feito para uma release ou commit que este clone não tem (git fetch --tags)." }
    $commit = $peeled.Output.Trim()
    if ($base.ExpectedCommit -and $commit -cne $base.ExpectedCommit) { throw 'O commit resolvido não é a base inicial configurada: nada foi feito.' }
    $path = Join-Path ([string]$Settings.worktreeRoot) "$($AppEntry.name)\release-$Version"
    if (Test-Path -LiteralPath $path) {
        $head = Invoke-FixGit @('-C', $path, 'rev-parse', 'HEAD')
        $dirty = Invoke-FixGit @('-C', $path, 'status', '--porcelain')
        if ($head.ExitCode -ne 0 -or $head.Output.Trim() -ne $commit -or $dirty.Output.Trim()) {
            throw "A árvore da release em $path não é mais a tag $tag (outro commit ou arquivos alterados). Remova-a com git worktree remove e verifique de novo."
        }
    } else {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        $eol = if ($AppEntry.name -eq 'SuiteBUDA' -and $Version -eq '0.0.0') { 'core.autocrlf=false' } else { 'core.autocrlf=true' }  # SuiteBUDA 0.0.0: a seed e as bases do pacote estao em LF
        $add = Invoke-FixGit @('-C', $repo, '-c', $eol, 'worktree', 'add', '--detach', $path, $commit) -PumpUi
        if ($add.ExitCode -ne 0) { throw "git worktree add falhou para $tag`: $(($add.Error -replace '\s+', ' ').Trim())" }
    }
    return [pscustomobject]@{ Path = $path; SourceRoot = (Join-Path $path (Get-FixSourceRoot $AppEntry.name)); Tag = $tag; BaseRef = $base.Reference; Commit = $commit; TagNote = $tagNote }
}

function Invoke-FixBundleVerify {
    param($Settings, [string]$App, [string]$BundlePath, [string]$BaseRoot)
    $arguments = @('bundle-verify', '--bundle', $BundlePath) + (Get-FixRegistryArguments $Settings)
    if ($BaseRoot) { $arguments += @('--base', $BaseRoot) }
    return (Invoke-FixBundleTool $Settings $App $arguments -PumpUi)
}

# The unified diff of every file the bundle changes, against the release's sources. Read-only: the new
# contents go to a temporary folder that is removed afterwards.
function Get-FixBundleDiff {
    param([string]$BundlePath, [string]$BaseRoot, $Changes, [int]$MaxChars = 400000)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temp = Join-Path $env:TEMP ('instaladorbuda-diff-' + [guid]::NewGuid().ToString('N'))
    $text = New-Object System.Text.StringBuilder
    $zip = [IO.Compression.ZipFile]::OpenRead($BundlePath)
    try {
        foreach ($change in @($Changes.PSObject.Properties)) {
            $relative = [string]$change.Name
            if ($relative -notmatch '^[A-Za-z0-9_$/.-]+\.java$' -or $relative.Contains('..')) { continue }
            $left = if ($change.Value -eq 'new') { '/dev/null' } else { Join-Path $BaseRoot $relative }
            $right = '/dev/null'
            if ($change.Value -ne 'deleted') {
                $right = Join-Path $temp $relative
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $right) -Force)
                [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry("files/$relative"), $right, $true)
            }
            $d = Invoke-FixGit @('diff', '--no-index', '--no-color', '--text', '--', $left, $right)
            $section = $d.Output.Replace($right.Replace('\', '/'), "b/$relative").Replace($left.Replace('\', '/'), "a/$relative")
            [void]$text.AppendLine("=== $($change.Value): $relative ===").AppendLine($section)
            if ($text.Length -gt $MaxChars) { [void]$text.AppendLine("… diff cortado em $MaxChars caracteres; leia o resto na worktree depois de abrir o PR."); break }
        }
    } finally {
        $zip.Dispose()
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $text.ToString()
}

# The report, in the order the maintainer must read it: verdict and problems, what the change adds and
# what goes beyond the developer's ceiling, who and where, then the files. The diff follows it.
function Format-FixVerification {
    param($Result, $Summary, [string]$Tag)
    $lines = @()
    if ($Result.valid) { $lines += 'VEREDITO: o pacote confere (assinatura, registro, caminhos, conteúdo e base da release).' }
    else { $lines += 'VEREDITO: o pacote NÃO confere; nenhum PR pode ser aberto.' }
    foreach ($p in @($Result.problems)) { if ($p) { $lines += "  PROBLEMA: $p" } }
    $caps = if (@($Result.capabilities).Count) { @($Result.capabilities) -join ', ' } else { 'nenhuma' }
    $lines += "CAPACIDADES que a mudança acrescenta: $caps"
    if (@($Result.overCeiling).Count) { $lines += "  ACIMA DO TETO do desenvolvedor: $(@($Result.overCeiling) -join ', ') — abrir o PR exige a sua decisão explícita." }
    if ($Summary) { foreach ($l in @($Summary.capabilityLines)) { $lines += "  $l" } }
    $guarded = @($Result.protectedFiles | Where-Object { $_ })
    if ($guarded.Count) { $lines += "CLASSES PROTEGIDAS (segurança ou troca de código; desenvolvedor sênior): $($guarded -join ', ') — revise estes arquivos primeiro; só entram no app por versão nova." }
    $lines += "Desenvolvedor: $($Result.developer)   chave $($Result.keyId)   branch: $($Result.branch)"
    $lines += "App: $($Result.app) $($Result.appVersion)   release: $Tag"
    $lines += "Título: $($Result.title)"
    if ($Result.description) { $lines += "Descrição: $($Result.description)" }
    $lines += 'Arquivos:'
    if ($Result.changes) { foreach ($c in $Result.changes.PSObject.Properties) { $lines += "  $(([string]$c.Value).PadRight(8)) $($c.Name)" } }
    return $lines
}

function Test-FixBranchName {
    param([string]$Branch)
    return ($Branch -match '^contrib/[a-z0-9][a-z0-9-]{0,39}/[a-z0-9][a-z0-9-]{0,59}$')
}
