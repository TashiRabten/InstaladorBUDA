# A "Sugestões recebidas" window closed during a job must not cost the suggestion its PR.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\FixPrStatus.Tests.ps1
#
# What a job found out is written to the row with the admin passphrase, and the passphrase lives only in
# the open window. The test closes the window during a real job of the session, then checks that the
# status reaches the row at the next window that holds the passphrase, and that a row whose status was
# lost some other way finds its PR on GitHub. Real: the session tab, the windows, the job runner. Stand-ins:
# Supabase (tests\FixInboxFakes.ps1) and gh (a function below). Everything is written to a temporary folder.
param([switch]$Inner)

if (-not $Inner) {
    $self = $MyInvocation.MyCommand.Path
    $command = ". '{0}' -Inner" -f $self.Replace("'", "''")
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -Command $command
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $testRoot 'modules\AppRegistry.psm1'))))
$entrypoint = [IO.File]::ReadAllText((Join-Path $testRoot 'InstaladorBUDA.ps1'))
foreach ($moduleMatch in [regex]::Matches($entrypoint, "Join-Path \`$AppDir '(modules\\[^']+\.ps1)'")) { . (Join-Path $testRoot $moduleMatch.Groups[1].Value) }
. (Join-Path $PSScriptRoot 'FixInboxFakes.ps1')
function Get-App { param([string]$Name) $script:AppRegistry.Get($Name) }

$testPassed = 0
$testFailures = New-Object System.Collections.Generic.List[string]
function Assert-That { param([bool]$Condition, [string]$Name) if ($Condition) { $script:testPassed++; Write-Output "ok   $Name" } else { $script:testFailures.Add($Name); Write-Output "FAIL $Name" } }
function Assert-Equal { param($Actual, $Expected, [string]$Name) Assert-That ([string]$Actual -ceq [string]$Expected) "$Name (expected '$Expected', got '$Actual')" }
function Invoke-Cli { param([hashtable]$Request) return (Invoke-CockpitRequest $guiState ([pscustomobject]$Request)) }
function Wait-TestJob { param([int]$Seconds = 60) $end = [datetime]::UtcNow.AddSeconds($Seconds); while ($tab.IsRunning -and [datetime]::UtcNow -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }; [System.Windows.Forms.Application]::DoEvents() }
function Get-Row { param([int]$Id) return ($FakeInbox.Rows | Where-Object { $_.id -eq $Id } | Select-Object -First 1) }
function Get-RowState { param([int]$Id) $r = Get-Row $Id; return "$($r.status)|$($r.pr_url)" }
function Get-PrCell { param($Window, [long]$Id) foreach ($item in $Window.Controls.Rows.Items) { if ([long]$item.Tag.id -eq $Id) { return $item.SubItems[7].Text } }; return $null }
function Get-Waiting { if (Test-Path -LiteralPath $pendingFile) { return [IO.File]::ReadAllText($pendingFile) }; return '' }
function Close-Window { param($Window) $Window.Form.Close(); [System.Windows.Forms.Application]::DoEvents() }
function Add-Row {
    param([int]$Id, [string]$App, [string]$Slug, [string]$Status = 'received', [string]$PrUrl)
    $stamp = [datetime]::UtcNow.ToString('o')
    [void]$FakeInbox.Rows.Add([pscustomobject]@{
        id = $Id; user_id = 'teste'; app = $App; app_version = '1.0.0'; key_id = 'abc'; slug = $Slug; title = "Sugestão $Id"; description = ''
        bundle_b64 = ''; bundle_sha256 = (Get-Package $Id).PadRight(64, 'a'); bundle_size = 1; status = $Status; pr_url = $(if ($PrUrl) { $PrUrl } else { $null })
        released_in = $null; maintainer_note = $null; created_at = $stamp; updated_at = $stamp })
}
function Get-Package { param([int]$Id) return ([string]$Id).PadLeft(12, '0') }
function Get-PullBody { param([int]$Id) return "Título`n`nSugerido por Tenzin (sugestão nº $Id da caixa do InstaladorBUDA), sobre a release v1.`nPacote $(Get-Package $Id), assinado pela chave abc, verificado pelo BundleTool." }
function Open-Inbox {
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox'; session = '1' })
    $window = $tab.FixInbox
    $window.Controls.Passphrase.Text = $FakeInbox.Passphrase
    $window.Buttons.UsePassphrase.PerformClick()
    return $window
}
# A job of the session with the last line of Build-Fix*Commands; a dry confirmation, as the CLI gives it.
function Invoke-TestJob {
    param($Window, [string]$Kind, [string]$Result, [long]$Id, [hashtable]$Fields, [int]$Wait = 0)
    $resultFile = Join-Path $work ([guid]::NewGuid().ToString('N') + '.txt')
    $commands = @("Start-Sleep -Milliseconds $Wait", "[IO.File]::WriteAllText($(Quote-PS $resultFile), $(Quote-PS $Result))")
    $Window.CliConfirmed = $true
    try { Invoke-FixJob $Window $commands "Teste $Kind" $work $Kind $resultFile @() $Id $Fields } finally { $Window.CliConfirmed = $false }
    Assert-That ([bool]$tab.IsRunning) "job '$Kind' of row ${Id}: running"
}

# ── gh: answers the read-only calls; pull requests come from $ghPulls, by repository ──
$ghCalls = New-Object System.Collections.Generic.List[string]
$ghPulls = @{}
$ghState = @{ Fail = $false }
function gh {
    $line = $args -join ' '
    $ghCalls.Add($line); $global:LASTEXITCODE = 0
    if ($line -like 'repo view*') { return 'PRIVATE' }
    if ($line -match '^pr list --repo (\S+)') {
        if ($ghState.Fail) { $global:LASTEXITCODE = 1; return }
        return (ConvertTo-Json -InputObject @($ghPulls[$Matches[1]] | Where-Object { $_ }) -Depth 4 -Compress)
    }
    return ''
}
function Get-PullListCount { return @($ghCalls | Where-Object { $_ -like 'pr list*' }).Count }

# ── The inbox's stand-in, with a switch for a network that fails on the status write only ──
$inboxState = @{ StatusDown = $false }
$fakeHttp = ${function:Invoke-FixInboxHttp}
function Invoke-FixInboxHttp {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [byte[]]$Body, [string]$ContentType, [int]$TimeoutSec = 60)
    if ($inboxState.StatusDown -and $Uri -like '*fix_inbox_set_status') { throw 'Sem conexão com o Supabase (teste).' }
    return (& $fakeHttp @PSBoundParameters)
}

$work = Join-Path $env:TEMP ('instaladorbuda-fixprstatus-' + [guid]::NewGuid().ToString('N'))
$pendingFile = Join-Path $work 'fix-pending.json'
$repoA = 'TestOwner/TradutorBUDA'; $repoB = 'TestOwner/SuiteBUDA'
$form = $null
try {
    [void](New-Item -ItemType Directory -Path $work -Force)
    $settingsFile = Join-Path $work 'fix-inbox.json'; $sentFile = Join-Path $work 'fix-sent.json'
    function Get-FixInboxSettingsPath { return $settingsFile }
    function Get-FixInboxSentPath { return $sentFile }
    $apps = foreach ($name in 'TradutorBUDA', 'SuiteBUDA') {
        [ordered]@{ name = $name; repoRoot = $work; githubRepo = "TestOwner/$name"; releaseRepo = 'TestOwner/Releases'; manageVisibility = $false
            tagPrefix = "$name-v"; workflow = ''; releaseBranch = ''; versionFromGitTag = "$name-v*"; uploadScript = $null; models = @(); dispatchInputs = @() }
    }
    $cfg = Join-Path $work 'apps.json'
    [IO.File]::WriteAllText($cfg, (@{ apps = @($apps); tasks = @() } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $AppDir = $testRoot; $cfgFile = $cfg
    $script:AppRegistry = [BudaAppRegistry]::new($cfg); $script:Config = $script:AppRegistry.Config; $script:Tasks = @()
    $ReleaseRepo = 'TestOwner/Releases'; $ActionsUrl = 'https://github.com/TestOwner/TradutorBUDA/actions'
    $script:ReleaseVersionCache = @{}; $script:ControlPipeName = 'InstaladorBUDA.FixPrStatusTest'; $HasGit = $true; $HasGh = $true

    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false; $form.Location = New-Object System.Drawing.Point(-4000, -4000); $form.Size = New-Object System.Drawing.Size(900, 900)
    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'; $form.Controls.Add($tabs); [void]$tabs.Handle
    $guiState = [hashtable]::Synchronized(@{ Tabs = $tabs; Form = $form; JobCounter = 1; CliConfirmed = $false })
    $tabs.Tag = $guiState
    $tabs.TabPages.Add((New-JobTab -Tabs $tabs -Number 1))
    $form.Show(); [System.Windows.Forms.Application]::DoEvents()
    $tab = $tabs.TabPages[0].Tag
    $tab.Controls.DryRun.Checked = $false
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-settings'; session = '1'; confirm = $true; supabaseUrl = 'https://fake-project.supabase.co'; publishableKey = $FakeInbox.Key })

    # ── The window closes during Abrir PR: the status waits, and the next window writes it ──
    $url7 = "https://github.com/$repoA/pull/7"
    Add-Row 1 'TradutorBUDA' 'corrige'
    $w = Open-Inbox
    Assert-That ([bool]$w.Passphrase) 'first window: the passphrase is held'
    Assert-Equal (Get-PrCell $w 1) '' 'first window: no PR yet'
    Invoke-TestJob $w 'pr' $url7 1 $null
    Close-Window $w
    Assert-That (-not $w.Passphrase) 'closed window: the passphrase left with it'
    Wait-TestJob
    Assert-Equal (Get-RowState 1) 'received|' 'closed window: nothing reaches the row without the passphrase'
    Assert-That ((Get-Waiting).Contains($url7)) 'closed window: the status waits in a file'
    Assert-That (-not (Get-Waiting).Contains($FakeInbox.Passphrase)) 'closed window: no secret in that file'
    Assert-Equal (@((Invoke-Cli @{ command = 'action'; action = 'fix-status'; session = '1' }).data.pendingStatus | ForEach-Object { $_.id }) -join ',') '1' 'cli fix-status: says what waits, with no window open'
    $w = Open-Inbox
    Assert-Equal (Get-RowState 1) "pr-opened|$url7" 'next window: the status reaches the row'
    Assert-Equal (Get-PrCell $w 1) '7' 'next window: the list shows the PR number'
    [void](Select-FixInboxRow $w 1)
    Assert-That ($w.Buttons.Merge.Enabled) 'next window: Mesclar PR is on'
    Assert-Equal (Get-Waiting) '' 'next window: nothing left waiting'

    # ── The window is opened again before the job ends: the open window takes the result at once ──
    $url8 = "https://github.com/$repoA/pull/8"
    Add-Row 2 'TradutorBUDA' 'reaberta'
    Close-Window $w
    $w = Open-Inbox
    Invoke-TestJob $w 'pr' $url8 2 $null 1500
    Close-Window $w
    $w = Open-Inbox
    Wait-TestJob
    Assert-Equal (Get-RowState 2) "pr-opened|$url8" 'reopened window: the row is written when the job ends'
    Assert-Equal (Get-PrCell $w 2) '8' 'reopened window: the list shows the PR number'
    Assert-Equal $w.LastPrUrl $url8 'reopened window: it is the one that took the result'
    Assert-Equal (Get-Waiting) '' 'reopened window: nothing left waiting'

    # ── The same for the other two jobs: a merge and a decline with its note ──
    $note = 'Precisa de outro caminho: não é este.'
    Add-Row 3 'TradutorBUDA' 'junta' 'pr-opened' "https://github.com/$repoA/pull/9"
    Add-Row 4 'TradutorBUDA' 'recusa' 'pr-opened' "https://github.com/$repoA/pull/10"
    Invoke-TestJob $w 'merge' 'merged' 3 @{ status = 'merged' }
    Close-Window $w
    Wait-TestJob
    Assert-Equal (Get-Row 3).status 'pr-opened' 'closed window, merge: waits'
    $w = Open-Inbox
    Assert-Equal (Get-Row 3).status 'merged' 'next window, merge: the row says merged'
    Invoke-TestJob $w 'decline' 'closed' 4 @{ status = 'declined'; maintainer_note = $note }
    Close-Window $w
    Wait-TestJob
    $w = Open-Inbox
    Assert-Equal "$((Get-Row 4).status)|$((Get-Row 4).maintainer_note)" "declined|$note" 'next window, decline: status and note on the row'

    # ── The window stays open: a passphrase forgotten, then a status write that fails ──
    $url11 = "https://github.com/$repoA/pull/11"; $url12 = "https://github.com/$repoA/pull/12"
    Add-Row 5 'TradutorBUDA' 'esquecida'
    Add-Row 6 'TradutorBUDA' 'sem-rede'
    Invoke-TestJob $w 'pr' $url11 5 $null
    $w.Buttons.ForgetPassphrase.PerformClick()
    Wait-TestJob
    Assert-Equal (Get-RowState 5) 'received|' 'Esquecer: waits'
    $w.Controls.Passphrase.Text = $FakeInbox.Passphrase
    $w.Buttons.UsePassphrase.PerformClick()
    Assert-Equal (Get-RowState 5) "pr-opened|$url11" 'Usar: writes what waited'
    Assert-Equal (Get-PrCell $w 5) '11' 'Usar: the list shows it at once'
    $inboxState.StatusDown = $true
    Invoke-TestJob $w 'pr' $url12 6 $null
    Wait-TestJob
    Assert-Equal (Get-RowState 6) 'received|' 'write fails: the row is unchanged'
    Assert-That ((Get-Waiting).Contains($url12)) 'write fails: the status waits'
    Assert-That ($tab.Controls.Log.Text.Contains('Sem conexão')) 'write fails: the log says why'
    $inboxState.StatusDown = $false
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-refresh'; session = '1' })
    Assert-Equal (Get-RowState 6) "pr-opened|$url12" 'write fails: the next Atualizar lista writes it'
    Assert-Equal (Get-Waiting) '' 'write fails: nothing left waiting'

    # ── Every row has its PR: GitHub is not asked ──
    $before = Get-PullListCount
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-refresh'; session = '1' })
    Assert-Equal (Get-PullListCount) $before 'no row without a PR: GitHub is not asked'

    # ── A status lost with nothing waiting: the row finds its PR on GitHub ──
    function Build-Pull { param([int]$Number, [string]$Repo, [string]$State, [string]$Branch, [int]$Package, [bool]$Fork = $false) return [pscustomobject]@{ number = $Number; url = "https://github.com/$Repo/pull/$Number"; state = $State; headRefName = $Branch; isCrossRepository = $Fork; body = (Get-PullBody $Package) } }
    Add-Row 20 'TradutorBUDA' 'perdida'
    Add-Row 21 'TradutorBUDA' 'mesmo-nome'            # the branch of an older suggestion, another package
    Add-Row 22 'TradutorBUDA' 'de-fora'               # a fork claims this row's branch and package
    Add-Row 23 'TradutorBUDA' 'ja-mesclada'
    Add-Row 24 'TradutorBUDA' 'fechada'
    Add-Row 25 'SuiteBUDA' 'noutro-repositorio'
    Add-Row 26 'TradutorBUDA' 'sem-pr'
    $ghPulls[$repoA] = @(
        (Build-Pull 30 $repoA 'OPEN' 'contrib/tenzin/perdida' 20)
        (Build-Pull 31 $repoA 'MERGED' 'contrib/tenzin/mesmo-nome' 99)
        (Build-Pull 32 $repoA 'OPEN' 'contrib/tenzin/de-fora' 22 $true)
        (Build-Pull 33 $repoA 'MERGED' 'contrib/tenzin/ja-mesclada' 23)
        (Build-Pull 34 $repoA 'CLOSED' 'contrib/tenzin/fechada' 24)
        (Build-Pull 35 $repoA 'OPEN' 'main-work' 26))
    $ghPulls[$repoB] = @((Build-Pull 7 $repoB 'OPEN' 'contrib/tenzin-suite/noutro-repositorio' 25))
    $ghState.Fail = $true
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-refresh'; session = '1' })
    Assert-Equal (@($w.Rows).Count) 13 'gh fails: the list still shows'
    Assert-Equal (Get-RowState 20) 'received|' 'gh fails: no row changes'
    Assert-That ($tab.Controls.Log.Text -match 'GitHub') 'gh fails: the log says so'
    $ghState.Fail = $false
    $tab.Controls.DryRun.Checked = $true
    $before = Get-PullListCount
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-refresh'; session = '1' })
    $tab.Controls.DryRun.Checked = $false
    Assert-Equal "$(Get-PullListCount)|$(Get-RowState 20)" "$before|received|" 'dry run: GitHub is not asked, no row changes'
    $before = Get-PullListCount
    [void](Invoke-Cli @{ command = 'action'; action = 'fix-inbox-refresh'; session = '1' })
    Assert-Equal ((Get-PullListCount) - $before) 2 'lost rows: one question per repository'
    Assert-Equal (Get-RowState 20) "pr-opened|https://github.com/$repoA/pull/30" 'lost row: its open PR is on the row'
    Assert-Equal (Get-PrCell $w 20) '30' 'lost row: the list shows the PR number'
    [void](Select-FixInboxRow $w 20)
    Assert-That ($w.Buttons.Merge.Enabled) 'lost row: Mesclar PR is on'
    Assert-Equal (Get-RowState 21) 'received|' 'same branch, another package: not this row''s PR'
    Assert-Equal (Get-RowState 22) 'received|' 'a fork''s PR is never taken for the row''s'
    Assert-Equal (Get-RowState 23) "merged|https://github.com/$repoA/pull/33" 'lost row, PR already merged: the row says merged'
    Assert-Equal (Get-RowState 24) 'received|' 'a closed PR is left to the maintainer'
    Assert-Equal (Get-RowState 25) "pr-opened|https://github.com/$repoB/pull/7" 'lost row: looked up in its own app''s repository'
    Assert-Equal (Get-RowState 26) 'received|' 'a row with no PR stays as it was'
    Assert-Equal (Get-Waiting) '' 'lost rows: nothing left waiting'
    Assert-That (-not $tab.Controls.Log.Text.Contains($FakeInbox.Passphrase)) 'secrets: the passphrase never reaches the log'
} catch {
    $testFailures.Add("unexpected error: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)")
    Write-Output "FAIL unexpected error: $($_.Exception.Message)"
    Write-Output $_.InvocationInfo.PositionMessage
} finally {
    if ($form) { foreach ($t in @($tabs.TabPages)) { foreach ($k in @('FixSuggest', 'FixInbox')) { if ($t.Tag[$k]) { $t.Tag[$k].Form.Close() } } }; $form.Close(); $form.Dispose() }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("{0} passed, {1} failed" -f $testPassed, $testFailures.Count)
exit [int]($testFailures.Count -gt 0)
