# Shared command builders for workflow retries and ordinary pull requests.
function Assert-RecoveryRepo {
    param([string]$Repo)
    if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Select a valid owner/repository.' }
}

function Build-RerunCommands {
    param([string]$Repo, [string]$RunId, [bool]$FailedOnly = $false)
    Assert-RecoveryRepo $Repo
    if ($RunId -notmatch '^[1-9][0-9]*$') { throw 'Select a workflow run first.' }
    $r = Quote-PS $Repo; $id = Quote-PS $RunId
    $failed = if ($FailedOnly) { ' --failed' } else { '' }
    return @(
        "`$before = & gh api repos/$Repo/actions/runs/$RunId | ConvertFrom-Json",
        "if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; if (`$before.status -ne 'completed') { throw 'The run is still active. Wait for it to finish.' }",
        "& gh run rerun $id --repo $r$failed",
        'if ($LASTEXITCODE) { exit $LASTEXITCODE }',
        '`$deadline = [datetime]::UtcNow.AddSeconds(90)'.Replace('`$', '$'),
        "do { Start-Sleep -Seconds 2; `$next = & gh api repos/$Repo/actions/runs/$RunId | ConvertFrom-Json; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; if ([datetime]::UtcNow -gt `$deadline) { throw 'Retry accepted, but its new attempt did not appear within 90 seconds. Load runs to inspect it.' } } until (`$next.run_attempt -gt `$before.run_attempt)",
        "& gh run watch $id --repo $r --exit-status --interval 8"
    )
}

# "Create PR" opens a PR from a branch that is ALREADY pushed to GitHub (it does not commit or push):
#   Base  = the branch the PR goes into (normally: main)
#   Head  = the pushed branch with the changes (for example: contrib/tashi-rabten-tradutor/mcp-no-aplicativo-...)
# Suggestions from the inbox do not use this: "Abrir PR" in the suggestions window creates the branch, commits,
# pushes and opens the PR by itself.
function Build-CreatePrCommands {
    param([string]$Repo, [string]$Base, [string]$Head, [string]$Title, [string]$Body)
    Assert-RecoveryRepo $Repo
    $hints = @{ Base = 'a branch de destino, normalmente main'; Head = 'a branch com as mudanças, já enviada ao GitHub (git push)' }
    foreach ($pair in @(@('Base', $Base), @('Head', $Head))) {
        $field = $pair[0]; $value = [string]$pair[1]
        if ([string]::IsNullOrWhiteSpace($value)) { throw "Campo $field vazio: informe $($hints[$field]). (repositório: $Repo)" }
        if ($value -notmatch '^[A-Za-z0-9][A-Za-z0-9_./-]*$') { throw "Campo $field inválido ('$value'): use só letras, números e _ . / - , sem espaços. Informe $($hints[$field])." }
    }
    if ($Base -eq $Head) { throw "Base e Head são a mesma branch ('$Base'): Base é o destino (main) e Head é a branch com as mudanças." }
    if ([string]::IsNullOrWhiteSpace($Title)) { throw 'Campo Title vazio: informe o título do PR.' }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Body))
    $cmd = '& gh pr create --repo ' + (Quote-PS $Repo) + ' --base ' + (Quote-PS $Base) + ' --head ' + (Quote-PS $Head) + ' --title ' + (Quote-PS $Title) + ' --body-file $prBody'
    return @(
        '$prBody = Join-Path $env:TEMP ([guid]::NewGuid().ToString("N") + ".txt")',
        "[IO.File]::WriteAllText(`$prBody, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')), [Text.UTF8Encoding]::new(`$false))",
        "try { $cmd; `$prExit = `$LASTEXITCODE } finally { Remove-Item -LiteralPath `$prBody -ErrorAction SilentlyContinue }; if (`$prExit) { exit `$prExit }"
    )
}

function Build-MergePrCommands {
    param([string]$Repo, [string]$Number)
    Assert-RecoveryRepo $Repo
    if ($Number -notmatch '^[1-9][0-9]*$') { throw 'Enter a PR number.' }
    $prArgs = (Quote-PS $Number) + ' --repo ' + (Quote-PS $Repo)
    return @(
        "`$pr = & gh pr view $prArgs --json state,isDraft,headRefOid,url | ConvertFrom-Json",
        "if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; if (`$pr.state -ne 'OPEN' -or `$pr.isDraft) { throw 'Only an open, ready PR can be merged.' }",
        "Write-Host `$pr.url; & gh pr merge $prArgs --merge --match-head-commit `$pr.headRefOid"
    )
}

function Build-PullRequestSection {
    param($Font, [int]$Width, [int]$Y)
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = 'Pull requests (pushed branch -> create -> merge)'
    $controls = @{}; $row = $UI.BoxTop
    foreach ($field in @('Base','Head','Title','Body','Number')) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $field + ':'
        Set-Box $label $UI.BoxPad $row $UI.BoxLabelW $UI.RowH
        $fieldBox = New-Object System.Windows.Forms.TextBox
        Set-Field $fieldBox $Font ($UI.BoxPad + $UI.BoxLabelW + $UI.BtnGap) $row ($Width - 2*$UI.BoxPad - $UI.BoxLabelW - $UI.BtnGap)
        $fieldBox.Anchor = 'Top,Left,Right'; $fieldBox.MaxLength=0
        if ($field -eq 'Base') { $fieldBox.Text = 'main' }
        if ($field -eq 'Body') { $fieldBox.Multiline = $true; $fieldBox.ScrollBars = 'Vertical'; $fieldBox.Height = Px $UI.MessageH; $row += $UI.MessageH - $UI.RowH }
        $controls[$field] = $fieldBox
        $group.Controls.AddRange(@($label, $fieldBox)); $row += $UI.BoxRowPitch
    }
    $buttons = @{}
    foreach ($name in @('List','Create','Merge')) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = "$name PR"; $button.Font = $Font
        $buttons[$name] = $button
        $group.Controls.Add($button)
    }
    [void](Set-ButtonRow @($buttons.List, $buttons.Create, $buttons.Merge) $UI.BoxPad $row 110)
    $height = $row + $UI.BtnH + $UI.BoxPad
    Set-Box $group $UI.Pad $Y $Width $height; $group.Anchor = 'Top,Left,Right'
    return @{ Group = $group; Controls = $controls; Buttons = $buttons; Height = $height }
}

# What "List PR" tells the maintainer before the list: what each field of the section means, with a suggestion taken
# from the app's clone. A branch is only suggested as Head when it has commits that Base does not have (GitHub refuses
# a PR with "No commits between ..." otherwise): the current branch if it qualifies, or else the one local branch that
# has an upstream and commits beyond Base; the other candidates are listed. Empty fields are filled with the
# suggestion; a field the maintainer already typed is never changed. Local git only (the comparison is against the
# last fetched origin/<Base>), so the button stays fast.
function Get-PullRequestFieldHelp {
    param($App, [string]$Repo, $Controls)
    $root = [string]$App.repoRoot
    $base = $Controls.Base.Text.Trim()
    if ($base -notmatch '^[A-Za-z0-9][A-Za-z0-9_./-]*$') { $base = 'main' }
    $baseRef = "origin/$base"
    $branch = ''; $upstream = ''; $ahead = ''; $candidates = @()
    try {
        $branch = ([string](& git -C $root branch --show-current 2>$null)).Trim()
        if ($branch) {
            $upstream = ([string](& git -C $root rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)).Trim()
            if ($LASTEXITCODE) { $upstream = '' }
            $ahead = ([string](& git -C $root rev-list --count "$baseRef..HEAD" 2>$null)).Trim()
            if ($LASTEXITCODE) { $ahead = '' }
        }
        foreach ($row in @(& git -C $root for-each-ref '--format=%(refname:short)|%(upstream:short)' refs/heads 2>$null)) {
            $name, $up = ([string]$row).Split('|', 2)
            if (-not $name -or -not $up -or $name -eq $base) { continue }
            $n = ([string](& git -C $root rev-list --count "$baseRef..$name" 2>$null)).Trim()
            if ($LASTEXITCODE -eq 0 -and $n -match '^[1-9][0-9]*$') { $candidates += [pscustomobject]@{ Name = $name; Ahead = [int]$n } }
        }
    } catch { }
    $global:LASTEXITCODE = 0
    $onBase = (-not $branch) -or $branch -in @('main', 'master', $base)
    $hasWork = $ahead -match '^[1-9][0-9]*$'
    $others = @($candidates | Where-Object { $_.Name -ne $branch })
    $lines = @("Para criar um PR de $Repo com o botão Create PR, preencha:")
    if ([string]::IsNullOrWhiteSpace($Controls.Base.Text)) { $Controls.Base.Text = 'main' }
    $lines += "  Base  = $base  (a branch de destino; já vem preenchida)"
    $pick = ''
    if ($onBase) {
        $lines += "  Head  = a branch com as mudanças, já enviada ao GitHub. A branch atual do clone é '$(if ($branch) { $branch } else { 'desconhecida' })' (a de destino): crie uma branch, faça commit e git push -u origin <branch> antes."
    } elseif (-not $hasWork) {
        $lines += "  Head  = NÃO use '$branch': ela não tem commits além de $baseRef, e o GitHub recusa o PR ('No commits between')."
        $typed = $Controls.Head.Text.Trim()
        if ($typed -eq $branch) { $lines += "          O campo Head está com '$branch': troque por uma branch que tenha mudanças." }
    } elseif ($upstream) {
        $lines += "  Head  = $branch  (branch atual, já enviada para $upstream, com $ahead commit(s) além de $baseRef)"
        $pick = $branch
    } else {
        $lines += "  Head  = $branch  (branch atual, com $ahead commit(s), MAS ainda não foi enviada: rode git push -u origin $branch antes de criar o PR)"
        $pick = $branch
    }
    if ($others.Count) {
        $lines += "  Branches deste clone já enviadas e com commits além de ${baseRef}:"
        foreach ($o in ($others | Select-Object -First 10)) { $lines += "      $($o.Name)  ($($o.Ahead) commit(s))" }
        if (-not $pick -and $others.Count -eq 1) { $pick = $others[0].Name }
        $lines += '  (se a branch já aparece na lista de PRs abertos abaixo, ela já tem PR)'
    } elseif (-not $pick) {
        $lines += "  Nenhuma branch deste clone está enviada e com commits além de $baseRef."
    }
    if ($pick -and [string]::IsNullOrWhiteSpace($Controls.Head.Text)) { $Controls.Head.Text = $pick }
    $subject = ''
    if ($pick) {
        try { $subject = ([string](& git -C $root log -1 --format=%s $pick 2>$null)).Trim() } catch { }
        $global:LASTEXITCODE = 0
    }
    if ($subject) {
        $lines += "  Title = $subject  (sugestão: assunto do último commit de $pick)"
        if ([string]::IsNullOrWhiteSpace($Controls.Title.Text)) { $Controls.Title.Text = $subject }
    } else {
        $lines += '  Title = o título do PR (obrigatório)'
    }
    $lines += '  Body  = a descrição (opcional)'
    $lines += '  Number = só para Merge PR: o número do PR, na primeira coluna da lista abaixo'
    $lines += "As sugestões da caixa (pacotes .budafix) não usam estes campos: elas abrem o PR pelo botão 'Abrir PR' da janela de Sugestões."
    return $lines
}

function Connect-PullRequestSection {
    param($Section, $Target, $Run, $Log)
    $Section.Buttons.List.Add_Click({
        $app = Get-App $Target.SelectedItem; $repo = Resolve-AppRepo $app
        try {
            Assert-RecoveryRepo $repo
            foreach ($line in (Get-PullRequestFieldHelp $app $repo $Section.Controls)) { & $Log $line }
            & $Run @("& gh pr list --repo $(Quote-PS $repo) --state open") 'List open pull requests' $true $app.repoRoot
        }
        catch { & $Log $_.Exception.Message }
    }.GetNewClosure())
    $Section.Buttons.Create.Add_Click({
        $app = Get-App $Target.SelectedItem; $c = $Section.Controls
        try { $commands = Build-CreatePrCommands (Resolve-AppRepo $app) $c.Base.Text.Trim() $c.Head.Text.Trim() $c.Title.Text $c.Body.Text; & $Run $commands 'Create pull request from pushed branch' $true $app.repoRoot }
        catch { & $Log $_.Exception.Message }
    }.GetNewClosure())
    $Section.Buttons.Merge.Add_Click({
        $app = Get-App $Target.SelectedItem; $c = $Section.Controls
        try { $commands = Build-MergePrCommands (Resolve-AppRepo $app) $c.Number.Text.Trim(); & $Run $commands "Merge PR #$($c.Number.Text.Trim()) (repository checks apply)" $true $app.repoRoot }
        catch { & $Log $_.Exception.Message }
    }.GetNewClosure())
}
