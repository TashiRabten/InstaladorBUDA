# ── "Abrir PR" and "Mesclar PR" as cockpit jobs ───────────────────────────────────────────────────
# Run through the session's job runner, so the maintainer sees every command in the confirmation (or in
# the log, for a dry run) and the output streams into the session log. The job never sees the Supabase
# token: the status goes back to the row from the cockpit, when the job has finished
# (Complete-FixPullRequest). Nothing in the job forces, deletes or rewrites a branch.

# $Plan: RepoRoot, Worktree, Branch, Tag, BundlePath, BundleSha, Tool (Java/Jar/MainClass), RegistryArgs,
# Scanner, GitHubRepo, Title, MessageFile, BodyFile, ResultFile.
function Build-FixPullRequestCommands {
    param([hashtable]$Plan)
    if (-not (Test-FixBranchName $Plan.Branch)) { throw "Branch inválida: $($Plan.Branch)" }
    return @(Build-FixPrPreflightLines $Plan) + @(Build-FixPrApplyLines $Plan) + @(Build-FixPrPublishLines $Plan)
}

# One job line that ends the job with $Message when $Condition holds (the braces stay in one literal).
function Get-FixStopLine {
    param([string]$Before, [string]$Condition, [string]$Message)
    $prefix = if ($Before) { "$Before; " } else { '' }
    return $prefix + 'if (' + $Condition + ') { Write-Host "' + $Message + '" -ForegroundColor Red; exit 1 }'
}

# Nothing exists yet: the bundle is the verified one, and the branch is new here and on GitHub.
function Build-FixPrPreflightLines {
    param([hashtable]$Plan)
    $sourceRoot = if ($Plan.SourceRoot) { $Plan.SourceRoot } else { 'src/main/java' }
    $baseRef = if ($Plan.BaseRef) { $Plan.BaseRef } else { "refs/tags/$($Plan.Tag)" }
    $sums = "(Get-FileHash -Algorithm SHA256 -LiteralPath $(Quote-PS $Plan.BundlePath)).Hash.ToLowerInvariant() -ne '$($Plan.BundleSha)'"
    $local = 'git -C $__repo rev-parse --verify --quiet "refs/heads/$__branch" *> $null; $__local = $LASTEXITCODE; $global:LASTEXITCODE = 0'
    $remote = 'git -C $__repo ls-remote --exit-code --heads origin "refs/heads/$__branch" *> $null; $__remote = $LASTEXITCODE; $global:LASTEXITCODE = 0'
    return @(
        "# PR: $($Plan.Branch) a partir de $($Plan.Tag)"
        "`$__repo = $(Quote-PS $Plan.RepoRoot); `$__wt = $(Quote-PS $Plan.Worktree); `$__branch = $(Quote-PS $Plan.Branch); `$__tag = $(Quote-PS $Plan.Tag); `$__base = $(Quote-PS $baseRef); `$__src = Join-Path `$__wt $(Quote-PS $sourceRoot)"
        (Get-FixStopLine '' $sums 'O pacote mudou depois da verificação: nada foi feito.')
        (Get-FixStopLine $local '$__local -eq 0' 'A branch $__branch já existe neste clone: nada foi feito.')
        (Get-FixStopLine $remote '$__remote -eq 0' 'A branch $__branch já existe no GitHub: nada foi feito.')
        (Get-FixStopLine '' '$__remote -ne 2' 'O GitHub não respondeu ao git ls-remote: nada foi feito.')
        (Get-FixStopLine '' 'Test-Path -LiteralPath $__wt' 'A pasta $__wt já existe: nada foi feito.')
    )
}

# The worktree on the new branch, the bundle applied by BundleTool (which verifies it again), staged.
function Build-FixPrApplyLines {
    param([hashtable]$Plan)
    $tool = $Plan.Tool
    $sourceRoot = if ($Plan.SourceRoot) { $Plan.SourceRoot } else { 'src/main/java' }
    # core.autocrlf=true, like the release worktree (Initialize-FixReleaseWorktree): the bundle's base hashes are of the
    # release's Windows checkout (CRLF), so the checkout the bundle is applied to must have the same bytes; the
    # `git add` below (autocrlf=true) turns the files back into LF for the commit. The one exception is a base that is
    # a bare commit and not a release tag (the SuiteBUDA seed, whose bases are LF).
    $eol = if ($Plan.BaseRef -and $Plan.BaseRef -notlike 'refs/tags/*') { 'core.autocrlf=false' } else { 'core.autocrlf=true' }
    $apply = @((Quote-PS $tool.Java), "'-Dstdout.encoding=UTF-8'", "'-Dfile.encoding=UTF-8'", '-cp', (Quote-PS $tool.Jar), $tool.MainClass) +
        @($tool.Arguments | Where-Object { $_ } | ForEach-Object { Quote-PS $_ }) + @('bundle-apply', '--bundle', (Quote-PS $Plan.BundlePath)) +
        @($Plan.RegistryArgs | ForEach-Object { Quote-PS $_ }) + @('--base', '$__src', '--into', '$__src')
    $applied = "`$__out = & $($apply -join ' ') | Out-String; `$__applied = `$LASTEXITCODE; Write-Host `$__out"
    return @(
        "git -C `$__repo -c $eol worktree add -b `$__branch `$__wt `"`$__base`"; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
        (Get-FixStopLine $applied '$__applied' 'bundle-apply recusou o pacote; a worktree fica para inspeção e nada foi enviado.')
        (Get-FixStopLine '$__json = $__out | ConvertFrom-Json' '-not $__json.valid -or $__json.branch -ne $__branch' 'O pacote aplicado não é o verificado, validade ou branch diferente: nada foi enviado.')
        "git -C `$__wt -c core.autocrlf=true add -A -- $(Quote-PS $sourceRoot); if (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
        (Get-FixStopLine 'git -C $__wt diff --cached --quiet; $__same = ($LASTEXITCODE -eq 0); $global:LASTEXITCODE = 0' '$__same' 'O pacote não muda nada nesta release: nada foi enviado.')
    )
}

# Gitleaks on what is staged, the commit as the maintainer, Gitleaks on what the branch adds, push, PR.
function Build-FixPrPublishLines {
    param([hashtable]$Plan)
    $create = "gh pr create --repo $(Quote-PS $Plan.GitHubRepo) --base main --head `$__branch --title $(Quote-PS $Plan.Title) --body-file $(Quote-PS $Plan.BodyFile)"
    return @(
        (Build-GitSecretScanCommand ([pscustomobject]@{ repoRoot = $Plan.Worktree }) $Plan.Scanner 'commit')
        "git -C `$__wt -c core.autocrlf=true -c core.quotepath=false commit -F $(Quote-PS $Plan.MessageFile); if (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
        (Build-FixBranchScanCommand $Plan.Scanner)
        'git -C $__wt push -u origin "$__branch"; if ($LASTEXITCODE) { exit $LASTEXITCODE }'
        "`$__pr = $create; `$__prCode = `$LASTEXITCODE; Write-Host `$__pr; if (`$__prCode) { exit `$__prCode }"
        "[IO.File]::WriteAllText($(Quote-PS $Plan.ResultFile), ([string](`$__pr | Select-Object -Last 1)).Trim())"
    )
}

# Gitleaks over the commits the branch adds to the release tag (the branch has no upstream yet, and the
# whole history is not this change's). A finding, a scanner error or a scanner that cannot start ends the job.
function Build-FixBranchScanCommand {
    param([string]$ScannerPath)
    $scanner = Quote-PS $ScannerPath
    return "try { & $scanner git `"--log-opts=`$__base..HEAD`" --redact --no-banner --no-color -v `$__wt } " +
        "catch { Write-Host `"Gitleaks could not run: `$(`$_.Exception.Message) nothing was pushed.`" -ForegroundColor Red; exit 1 }; " +
        "if (`$LASTEXITCODE) { Write-Host 'Gitleaks stopped this step (finding redacted above, or scanner error); nothing was pushed.' -ForegroundColor Red; exit `$LASTEXITCODE }"
}

function Build-FixMergeCommands {
    param([string]$GitHubRepo, [string]$PrUrl, [string]$ResultFile)
    if ($PrUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+$') { throw "Endereço de PR inválido: $PrUrl" }
    return @(
        "# Mesclar $PrUrl em main (merge commit; a branch contrib/ fica como registro)"
        "gh pr merge $(Quote-PS $PrUrl) --repo $(Quote-PS $GitHubRepo) --merge; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
        "[IO.File]::WriteAllText($(Quote-PS $ResultFile), 'merged')"
    )
}

# Declining a suggestion whose PR is open closes that PR too, so the row and GitHub agree.
function Build-FixCloseCommands {
    param([string]$GitHubRepo, [string]$PrUrl, [string]$ResultFile)
    if ($PrUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+$') { throw "Endereço de PR inválido: $PrUrl" }
    return @(
        "# Fechar $PrUrl sem mesclar (sugestão recusada; a branch contrib/ fica como registro)"
        "gh pr close $(Quote-PS $PrUrl) --repo $(Quote-PS $GitHubRepo); if (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
        "[IO.File]::WriteAllText($(Quote-PS $ResultFile), 'closed')"
    )
}

# The commit message and the PR body: the contributor's title and description, credited by name only.
function Get-FixCommitMessage {
    param($Result, $Summary, [string]$Tag, [long]$SubmissionId)
    $name = if ($Summary -and $Summary.developerName) { $Summary.developerName } else { $Result.developer }
    $origin = if ($SubmissionId -gt 0) { "sugestão nº $SubmissionId da caixa do InstaladorBUDA" } else { 'pacote recebido fora da caixa' }
    $lines = @(([string]$Result.title -replace '[\r\n]+', ' ').Trim(), '')
    if ($Result.description) { $lines += @([string]$Result.description, '') }
    $lines += "Sugerido por $name ($origin), sobre a release $Tag."
    $lines += "Pacote $($Summary.sha256.Substring(0, 12)), assinado pela chave $($Result.keyId), verificado pelo BundleTool."
    return ($lines -join "`n")
}

function Get-FixPullRequestBody {
    param($Result, [string]$Message)
    $caps = if (@($Result.capabilities).Count) { @($Result.capabilities) -join ', ' } else { 'nenhuma' }
    $over = if (@($Result.overCeiling).Count) { @($Result.overCeiling) -join ', ' } else { 'nenhuma' }
    $named = @($Result.protectedFiles | Where-Object { $_ })
    $guarded = if ($named.Count) { ($named | ForEach-Object { "``$_``" }) -join ', ' } else { 'nenhuma' }
    $files = @(); if ($Result.changes) { foreach ($c in $Result.changes.PSObject.Properties) { $files += "- $($c.Value): ``$($c.Name)``" } }
    return (@($Message, '', '### Verificação', "- Capacidades acrescentadas: $caps", "- Acima do teto do desenvolvedor: $over", "- Classes protegidas: $guarded", '', '### Arquivos') + $files) -join "`n"
}

function Write-FixTempText {
    param([string]$Prefix, [string]$Text)
    $path = Join-Path $env:TEMP ("instaladorbuda-$Prefix-" + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
    return $path
}

# Called on the UI thread when the PR or merge job has finished, whatever its exit code: the result file
# exists only when the last step succeeded. Then the status goes back to the row; when that cannot be done
# now (the window closed with the passphrase, the network), it waits on disk and the next Usar or Atualizar
# lista writes it. The window that started the job may have closed: the session's open one takes over.
function Complete-FixPullRequest {
    param($Window, [string]$Kind, [string]$ResultFile, [string[]]$TempFiles, [long]$SubmissionId, [hashtable]$Fields)
    foreach ($f in @($TempFiles)) { if ($f) { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue } }
    $open = $Window.TabState.FixInbox
    if ($open -and -not $open.Form.IsDisposed) { $Window = $open }
    $log = $Window.TabState.AppendLog
    if (-not (Test-Path -LiteralPath $ResultFile -PathType Leaf)) {
        & $log "Sugestões: o passo '$Kind' não terminou (veja o log acima); o status da sugestão não mudou."
        return
    }
    $text = [IO.File]::ReadAllText($ResultFile).Trim()
    Remove-Item -LiteralPath $ResultFile -ErrorAction SilentlyContinue
    $fields = $Fields
    if ($Kind -eq 'pr') {
        if ($text -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+$') { & $log "Sugestões: o gh não devolveu o endereço do PR ('$text')."; return }
        $Window.LastPrUrl = $text
        $fields = @{ status = 'pr-opened'; pr_url = $text }
        & $log "Sugestões: PR aberto: $text"
    } elseif ($Kind -eq 'merge') { & $log 'Sugestões: PR mesclado em main.' }
    else { & $log 'Sugestões: PR fechado sem mesclar.' }
    $Window.LastOutcome = $fields
    if ($SubmissionId -le 0) { & $log 'Sugestões: pacote local, sem linha na caixa para atualizar.'; return }
    Add-FixPendingStatus $SubmissionId $fields
    Send-FixPendingStatuses $Window
    if ($Window.Form.IsDisposed -or -not $Window.Passphrase) { return }
    try { Sync-FixInboxRow $Window (Get-FixInboxRowById $Window $SubmissionId) } catch { & $log "Sugestões: a lista não foi relida ($($_.Exception.Message)); clique Atualizar lista." }
}

# Everything that waits goes to its row with this window's passphrase; what fails stays for the next try.
function Send-FixPendingStatuses {
    param($Window)
    $log = $Window.TabState.AppendLog
    $waiting = @(Get-FixPendingStatuses)
    if ($waiting.Count -eq 0) { return }
    if (-not $Window.Passphrase) {
        foreach ($p in $waiting) { & $log "Sugestões: o status '$($p.fields.status)' da linha $($p.id) ficou guardado. Abra Sugestões recebidas e clique Usar: ele é gravado então." }
        return
    }
    $settings = Get-FixInboxSettings
    $left = @()
    foreach ($p in $waiting) {
        $fields = @{}
        foreach ($f in $p.fields.PSObject.Properties) { $fields[$f.Name] = $f.Value }
        try {
            [void](Send-FixSubmissionStatus $settings $Window.Passphrase ([long]$p.id) $fields)
            & $log "Sugestões: linha $($p.id) agora está '$($fields.status)'."
        } catch {
            $left += $p
            & $log "Sugestões: o status da linha $($p.id) não foi gravado ($($_.Exception.Message)). Ficou guardado para o próximo Atualizar lista."
        }
    }
    Save-FixPendingStatuses $left
}

# A row with no PR may have one all the same: the job's end was not seen (the cockpit closed), or an older
# version lost the status with its window. Abrir PR then refuses (the branch exists) and Mesclar PR stays off.
# The PR proves it is the row's by the package hash in its body (Get-FixCommitMessage) and its branch; a repeated
# slug shares the branch, not the hash. A fork could write both, so only branches of the repository itself count.
function Select-FixRowPullRequest {
    param($Row, $Pulls)
    $package = 'Pacote ' + ([string]$Row.bundle_sha256).Substring(0, 12)
    return ($Pulls | Where-Object {
        -not $_.isCrossRepository -and $_.state -in @('OPEN', 'MERGED') -and $_.headRefName -like "contrib/*/$($Row.slug)" -and ([string]$_.body).Contains($package)
    } | Select-Object -First 1)
}

function Get-FixRepoPullRequests {
    param([string]$Repo)
    $json = & gh pr list --repo $Repo --state all --limit 100 --json 'number,url,state,headRefName,isCrossRepository,body' 2>$null
    if ($LASTEXITCODE) { throw "gh pr list terminou com o código $LASTEXITCODE." }
    if (-not "$json".Trim()) { return @() }
    $pulls = ($json -join "`n") | ConvertFrom-Json
    return @($pulls | Where-Object { $_ })
}

# The rows that have a PR on GitHub and do not say so: @{ Id; Fields }, for Add-FixPendingStatus. A closed
# PR is left alone: declining takes a note only the maintainer can write. GitHub out of reach costs a log line.
function Find-FixLostPullRequests {
    param($Window, $Rows)
    $found = @()
    $lost = @($Rows | Where-Object { -not $_.pr_url -and $_.status -in @('received', 'reviewing') })
    foreach ($group in @($lost | Group-Object -Property app)) {
        $repo = Resolve-AppRepo (Get-App $group.Name)
        if (-not $repo) { continue }
        try { $pulls = @(Get-FixRepoPullRequests $repo) }
        catch { Write-FixLog $Window @("o GitHub não listou os PRs de ${repo} ($($_.Exception.Message))."); continue }
        foreach ($row in $group.Group) {
            $pull = Select-FixRowPullRequest $row $pulls
            if (-not $pull) { continue }
            $status = if ($pull.state -eq 'MERGED') { 'merged' } else { 'pr-opened' }
            Write-FixLog $Window @("linha $($row.id): o PR $($pull.number) já existe no GitHub ($($pull.url)).")
            $found += @{ Id = [long]$row.id; Fields = @{ status = $status; pr_url = [string]$pull.url } }
        }
    }
    return $found
}
