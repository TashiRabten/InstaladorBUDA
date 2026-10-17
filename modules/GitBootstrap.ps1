# Static worker sent to the background PowerShell process.
$script:GitBootstrapWorkerTemplate = @'
$ErrorActionPreference = 'Stop'
$root = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@ROOT@@'))
$githubRepo = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@GITHUB_REPO@@'))
$phase = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@PHASE@@'))
$commitMessage = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@COMMIT_MESSAGE@@'))
$scannerPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@SCANNER_PATH@@'))
$remote = "https://github.com/$githubRepo.git"

function Invoke-Tool {
    param([string]$Name, [string[]]$Arguments, [switch]$AllowFailure, [switch]$Quiet)
    $output = @(& $Name @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $Quiet) { foreach ($line in $output) { Write-Host $line } }
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "$Name failed with exit code $exitCode." }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Normalize-Remote {
    param([string]$Value)
    $normalized = $Value.Trim() -replace '^git@github\.com:', 'https://github.com/'
    $normalized = $normalized -replace '^ssh://git@github\.com/', 'https://github.com/'
    $normalized = $normalized -replace '\.git$', ''
    return $normalized.TrimEnd('/').ToLowerInvariant()
}

Write-Host "Repository folder: $root"
Write-Host "GitHub destination: $githubRepo"
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Repository folder does not exist: $root" }

$metadataResult = Invoke-Tool 'gh' @('repo', 'view', $githubRepo, '--json', 'nameWithOwner,isPrivate,defaultBranchRef')
$metadata = ($metadataResult.Output -join "`n") | ConvertFrom-Json
if ($metadata.nameWithOwner -and $metadata.nameWithOwner -ine $githubRepo) { throw "GitHub returned a different repository: $($metadata.nameWithOwner)" }
Write-Host ("Visibility: {0}" -f $(if ($metadata.isPrivate) { 'private' } else { 'public' }))

$remoteRefs = Invoke-Tool 'git' @('ls-remote', '--refs', $remote)
$remoteHasRefs = @($remoteRefs.Output | Where-Object { $_ }).Count -gt 0
Write-Host ("Remote refs: {0}" -f $(if ($remoteHasRefs) { 'present' } else { 'empty' }))

$topResult = Invoke-Tool 'git' @('-C', $root, 'rev-parse', '--show-toplevel') -AllowFailure -Quiet
$localRepo = $topResult.ExitCode -eq 0
$repoRootMatches = $false
$hasHead = $false
$branch = $null
$origin = $null
$bootstrapStatePath = $null
$preparedTree = $null
if ($localRepo) {
    $reportedRoot = [IO.Path]::GetFullPath(($topResult.Output | Select-Object -First 1).Trim()).TrimEnd('\', '/')
    $requestedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    $repoRootMatches = $reportedRoot -ieq $requestedRoot
    $headResult = Invoke-Tool 'git' @('-C', $root, 'rev-parse', '--verify', 'HEAD') -AllowFailure -Quiet
    $hasHead = $headResult.ExitCode -eq 0
    $branchResult = Invoke-Tool 'git' @('-C', $root, 'symbolic-ref', '--quiet', '--short', 'HEAD') -AllowFailure -Quiet
    if ($branchResult.ExitCode -eq 0) { $branch = ($branchResult.Output | Select-Object -First 1).Trim() }
    $originResult = Invoke-Tool 'git' @('-C', $root, 'config', '--get', 'remote.origin.url') -AllowFailure -Quiet
    if ($originResult.ExitCode -eq 0) { $origin = ($originResult.Output | Select-Object -First 1).Trim() }
    $statePathResult = Invoke-Tool 'git' @('-C', $root, 'rev-parse', '--git-path', 'instaladorbuda-bootstrap-tree') -AllowFailure -Quiet
    if ($statePathResult.ExitCode -eq 0) {
        $bootstrapStatePath = ($statePathResult.Output | Select-Object -First 1).Trim()
        if (-not [IO.Path]::IsPathRooted($bootstrapStatePath)) { $bootstrapStatePath = Join-Path $root $bootstrapStatePath }
        if (Test-Path -LiteralPath $bootstrapStatePath -PathType Leaf) {
            $preparedTree = [IO.File]::ReadAllText($bootstrapStatePath).Trim()
        }
    }
}

$resumeBootstrapCommit = $false
if ($phase -eq 'publish' -and $hasHead -and $preparedTree) {
    $headTreeResult = Invoke-Tool 'git' @('-C', $root, 'rev-parse', 'HEAD^{tree}') -AllowFailure -Quiet
    $headMessageResult = Invoke-Tool 'git' @('-C', $root, 'log', '-1', '--format=%B') -AllowFailure -Quiet
    $resumeBootstrapCommit = $headTreeResult.ExitCode -eq 0 -and
        (($headTreeResult.Output | Select-Object -First 1).Trim() -eq $preparedTree) -and
        (($headMessageResult.Output -join "`n").Trim() -eq $commitMessage.Trim())
}

$localDescription = if (-not $localRepo) { 'not initialized' }
    elseif (-not $repoRootMatches) { "nested under $($topResult.Output -join '')" }
    elseif ($hasHead) { 'already has a commit' }
    elseif ($branch) { "empty history on $branch" }
    else { 'empty history with no branch' }
Write-Host "Local state: $localDescription"
Write-Host ("Origin: {0}" -f $(if ($origin) { $origin } else { 'not set' }))

$identityName = (Invoke-Tool 'git' @('config', '--global', '--get', 'user.name') -AllowFailure -Quiet).Output -join ''
$identityEmail = (Invoke-Tool 'git' @('config', '--global', '--get', 'user.email') -AllowFailure -Quiet).Output -join ''
if ($localRepo) {
    if (-not $identityName) { $identityName = (Invoke-Tool 'git' @('-C', $root, 'config', '--local', '--get', 'user.name') -AllowFailure -Quiet).Output -join '' }
    if (-not $identityEmail) { $identityEmail = (Invoke-Tool 'git' @('-C', $root, 'config', '--local', '--get', 'user.email') -AllowFailure -Quiet).Output -join '' }
}
$identityReady = -not [string]::IsNullOrWhiteSpace($identityName) -and -not [string]::IsNullOrWhiteSpace($identityEmail)
Write-Host ("Commit identity: {0}" -f $(if ($identityReady) { "$identityName <$identityEmail>" } else { 'not configured' }))

$originMatches = -not $origin -or ((Normalize-Remote $origin) -eq (Normalize-Remote $remote))
$blockers = @()
if (-not $repoRootMatches -and $localRepo) { $blockers += 'The selected folder is inside a different Git repository.' }
if ($hasHead -and -not $resumeBootstrapCommit) { $blockers += 'This folder already has commit history; use the normal Git actions.' }
if ($remoteHasRefs) { $blockers += 'The GitHub repository already contains refs; bootstrap requires an empty remote.' }
if (-not $originMatches) { $blockers += "origin already points to a different repository: $origin" }
if ($phase -eq 'publish' -and -not $origin) { $blockers += 'origin is not configured; run bootstrap-prepare first.' }
if (-not $identityReady) { $blockers += 'Git commit identity is missing; configure user.name and user.email first.' }

if ($scannerPath -and (Test-Path -LiteralPath $scannerPath -PathType Leaf)) {
    $scan = Invoke-Tool $scannerPath @('detect', '--no-git', '--redact', '--source', $root) -AllowFailure
    if ($scan.ExitCode -eq 0) { Write-Host 'Secret scan: clean' }
    else { $blockers += "Secret scan found a problem or failed (exit $($scan.ExitCode)); inspect the redacted output." }
} elseif ($phase -eq 'plan') {
    Write-Host 'Secret scan: unavailable; install gitleaks or pass gitleaksPath before preparation.'
    $blockers += 'Secret scanner is unavailable.'
} else {
    $blockers += 'Secret scanner is unavailable; install gitleaks or pass gitleaksPath.'
}

if ($phase -eq 'plan') {
    if ($blockers.Count) { Write-Host 'Preflight blockers:'; $blockers | ForEach-Object { Write-Host "  - $_" } }
    else { Write-Host 'Preflight: ready to prepare the local repository.' }
} elseif ($blockers.Count) {
    throw ('Bootstrap stopped: ' + ($blockers -join ' '))
} elseif ($phase -eq 'prepare') {
    if (-not $localRepo) {
        Invoke-Tool 'git' @('-C', $root, 'init', '-b', 'main') | Out-Null
    } elseif ($branch -ne 'main') {
        Invoke-Tool 'git' @('-C', $root, 'symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
    }
    $statePathResult = Invoke-Tool 'git' @('-C', $root, 'rev-parse', '--git-path', 'instaladorbuda-bootstrap-tree') -Quiet
    $bootstrapStatePath = ($statePathResult.Output | Select-Object -First 1).Trim()
    if (-not [IO.Path]::IsPathRooted($bootstrapStatePath)) { $bootstrapStatePath = Join-Path $root $bootstrapStatePath }
    if (-not $origin) { Invoke-Tool 'git' @('-C', $root, 'remote', 'add', 'origin', $remote) | Out-Null }
    Invoke-Tool 'git' @('-C', $root, 'add', '--all') | Out-Null
    $staged = Invoke-Tool 'git' @('-C', $root, 'diff', '--cached', '--name-only')
    if (@($staged.Output | Where-Object { $_ }).Count -eq 0) { throw 'No files were staged. Check the folder and its .gitignore.' }
    $tree = Invoke-Tool 'git' @('-C', $root, 'write-tree') -Quiet
    if ($tree.ExitCode -ne 0) { throw 'Could not record the prepared Git index tree.' }
    [IO.File]::WriteAllText($bootstrapStatePath, ($tree.Output | Select-Object -First 1).Trim(), [Text.Encoding]::ASCII)
    Write-Host ("Prepared {0} staged path(s). Review this list before publishing:" -f @($staged.Output | Where-Object { $_ }).Count)
    Invoke-Tool 'git' @('-C', $root, '-c', 'core.quotepath=false', 'status', '--short', '--branch') | Out-Null
} elseif ($phase -eq 'publish') {
    if (-not $localRepo -or -not $repoRootMatches -or $branch -ne 'main' -or -not $bootstrapStatePath -or -not $preparedTree) { throw 'Local repository is not ready on main; run bootstrap-prepare first.' }
    if ((Normalize-Remote $origin) -ne (Normalize-Remote $remote)) { throw 'origin does not match the requested GitHub repository.' }
    $staged = Invoke-Tool 'git' @('-C', $root, 'diff', '--cached', '--name-only') -Quiet
    if (-not $resumeBootstrapCommit -and @($staged.Output | Where-Object { $_ }).Count -eq 0) { throw 'No staged files. Run bootstrap-prepare and review its status output first.' }
    $currentTree = Invoke-Tool 'git' @('-C', $root, 'write-tree') -Quiet
    if ($currentTree.ExitCode -ne 0 -or ($currentTree.Output | Select-Object -First 1).Trim() -ne $preparedTree) {
        throw 'The staged tree changed after preparation. Rerun bootstrap-prepare and review the staged list.'
    }
    if ($resumeBootstrapCommit) {
        $headTree = Invoke-Tool 'git' @('-C', $root, 'rev-parse', 'HEAD^{tree}') -Quiet
        if (($headTree.Output | Select-Object -First 1).Trim() -ne $preparedTree) { throw 'The existing commit does not match the prepared tree.' }
    }
    $unstaged = Invoke-Tool 'git' @('-C', $root, 'diff', '--quiet') -AllowFailure -Quiet
    if ($unstaged.ExitCode -ne 0) { throw 'Files changed after preparation. Rerun bootstrap-prepare and review the staged list.' }
    $untracked = Invoke-Tool 'git' @('-C', $root, 'ls-files', '--others', '--exclude-standard') -Quiet
    if (@($untracked.Output | Where-Object { $_ }).Count -gt 0) { throw 'New untracked files appeared after preparation. Rerun bootstrap-prepare and review the staged list.' }
    if ([string]::IsNullOrWhiteSpace($commitMessage)) { throw 'A commit message is required.' }

    if (-not $resumeBootstrapCommit) {
        $messageFile = Join-Path $env:TEMP ('instaladorbuda-bootstrap-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            [IO.File]::WriteAllText($messageFile, $commitMessage.Trim(), [Text.UTF8Encoding]::new($false))
            Invoke-Tool 'git' @('-C', $root, '-c', 'core.quotepath=false', 'commit', '-F', $messageFile) | Out-Null
        } finally { Remove-Item -LiteralPath $messageFile -ErrorAction SilentlyContinue }
    } else { Write-Host 'Resuming the previously created, prepared commit.' }

    Write-Host 'Pushing main and setting origin/main as upstream.'
    Invoke-Tool 'git' @('-C', $root, 'push', '--set-upstream', 'origin', 'main') | Out-Null
    Remove-Item -LiteralPath $bootstrapStatePath -ErrorAction SilentlyContinue
    Invoke-Tool 'git' @('-C', $root, '-c', 'core.quotepath=false', 'status', '--short', '--branch') | Out-Null
}
'@

# Focused helpers for creating the first local commit on an existing empty GitHub repo.
function Resolve-GitBootstrapScanner {
    param([string]$ExplicitPath, [string]$AppDir)

    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "Secret scanner not found: $ExplicitPath"
        }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    $command = Get-Command gitleaks, gitleaks.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    $appsRoot = Split-Path -Parent $AppDir
    if (Test-Path -LiteralPath $appsRoot -PathType Container) {
        $folders = Get-ChildItem -LiteralPath $appsRoot -Directory -Filter 'gitleaks_*_windows_*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach ($folder in $folders) {
            $candidate = Join-Path $folder.FullName 'gitleaks.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

function Build-GitBootstrapCommands {
    param(
        [string]$RepoRoot,
        [string]$GitHubRepo,
        [ValidateSet('plan', 'prepare', 'publish')][string]$Phase,
        [string]$CommitMessage,
        [string]$ScannerPath
    )

    $encode = { param([string]$value) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)) }
    $tokens = @{
        Root = & $encode $RepoRoot
        GitHubRepo = & $encode $GitHubRepo
        Phase = & $encode $Phase
        CommitMessage = & $encode $CommitMessage
        ScannerPath = & $encode $ScannerPath
    }

    $scriptText = $script:GitBootstrapWorkerTemplate

    foreach ($key in $tokens.Keys) { $scriptText = $scriptText.Replace('@@' + $key.ToUpperInvariant().Replace('GITHUBREPO', 'GITHUB_REPO').Replace('COMMITMESSAGE', 'COMMIT_MESSAGE').Replace('SCANNERPATH', 'SCANNER_PATH') + '@@', $tokens[$key]) }
    return ,@($scriptText)
}

function Build-GitHubRepoCreateCommands {
    param([string]$GitHubRepo)

    if ($GitHubRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'GitHub repository must be owner/name, for example TashiRabten/AI-config.'
    }
    $repoToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($GitHubRepo))
    $scriptText = @'
$ErrorActionPreference = 'Stop'
$repo = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@REPO@@'))
Write-Host "Creating an empty private GitHub repository: $repo"
$created = @(& gh repo create $repo --private 2>&1 | ForEach-Object { [string]$_ })
$createExit = $LASTEXITCODE
foreach ($line in $created) { Write-Host $line }
if ($createExit -ne 0) { throw "Could not create $repo. Check gh authentication, owner permissions, and whether the repository name is already taken." }
$details = @(& gh repo view $repo --json nameWithOwner,visibility,url 2>&1 | ForEach-Object { [string]$_ })
$viewExit = $LASTEXITCODE
foreach ($line in $details) { Write-Host $line }
if ($viewExit -ne 0) { throw "Repository was created but could not be verified: $repo" }
Write-Host 'Repository is ready for InstaladorBUDA bootstrap.'
'@
    return ,@($scriptText.Replace('@@REPO@@', $repoToken))
}

function Test-GitHubActionsSecretName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z_][A-Za-z0-9_]*$' -and $Name -notmatch '^GITHUB_')
}

function Invoke-GitHubActionsSecretProcess {
    param(
        [string]$Arguments,
        [string]$StandardInputText,
        [string]$GhPath
    )

    if (-not $GhPath) {
        $ghCommand = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ghCommand) { throw 'GitHub CLI (gh) is not installed.' }
        $GhPath = $ghCommand.Source
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GhPath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutTask = $null
    $stderrTask = $null
    $started = $false
    try {
        if (-not $process.Start()) { throw 'Could not start GitHub CLI.' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StandardInputText) {
            $inputBytes = [System.Text.Encoding]::UTF8.GetBytes($StandardInputText)
            try {
                $inputStream = $process.StandardInput.BaseStream
                $inputStream.Write($inputBytes, 0, $inputBytes.Length)
                $inputStream.Flush()
            } finally {
                if ($inputBytes) { [Array]::Clear($inputBytes, 0, $inputBytes.Length) }
                $inputBytes = $null
                $inputStream = $null
            }
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'GitHub CLI timed out while managing the Actions secret.'
        }
        $output = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = [string]$output }
    } finally {
        if ($started) {
            try {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            } catch { Write-Debug 'Could not stop the GitHub CLI process during cleanup.' }
        }
        $process.Dispose()
        $startInfo = $null
        $StandardInputText = $null
    }
}

function Get-GitHubActionsSecretNames {
    param([string]$RepositorySlug, [string]$GhPath)

    if ($RepositorySlug -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Choose a GitHub repository in owner/name format.'
    }
    $result = Invoke-GitHubActionsSecretProcess "secret list --app actions --repo $RepositorySlug --json name" $null $GhPath
    if ($result.ExitCode -ne 0) { throw 'GitHub CLI could not list Actions secrets for this repository.' }
    $items = @()
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) { $items = ConvertFrom-Json -InputObject $result.Output -ErrorAction Stop }
    return @($items | ForEach-Object { [string]$_.name } | Where-Object { $_ } | Sort-Object -Unique)
}

function Invoke-GitHubActionsSecretSet {
    param(
        [string]$RepositorySlug,
        [string]$SecretName,
        [string]$SecretValue,
        [string]$GhPath
    )

    if ($RepositorySlug -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Choose a GitHub repository in owner/name format.' }
    if (-not (Test-GitHubActionsSecretName $SecretName)) { throw 'Secret names may use letters, digits, and underscores, cannot start with a digit, and cannot start with GITHUB_.' }
    if ([string]::IsNullOrWhiteSpace($SecretValue)) { throw 'The secret value is empty.' }
    if ([Text.Encoding]::UTF8.GetByteCount($SecretValue) -gt 49152) { throw 'GitHub Actions secret values must be 48 KB or smaller.' }

    $arguments = "secret set $SecretName --app actions --repo $RepositorySlug"
    $result = Invoke-GitHubActionsSecretProcess $arguments $SecretValue $GhPath
    return [int]$result.ExitCode
}

function Invoke-GitHubActionsSecretDelete {
    param([string]$RepositorySlug, [string]$SecretName, [string]$GhPath)

    if ($RepositorySlug -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Choose a GitHub repository in owner/name format.' }
    if (-not (Test-GitHubActionsSecretName $SecretName)) { throw 'Select a valid Actions secret name.' }
    $arguments = "secret delete $SecretName --app actions --repo $RepositorySlug"
    $result = Invoke-GitHubActionsSecretProcess $arguments $null $GhPath
    return [int]$result.ExitCode
}

function Show-GitHubActionsSecretDialog {
    param([string]$RepositorySlug, [System.Windows.Forms.IWin32Window]$Owner, [string]$GhPath)

    $form = New-Object System.Windows.Forms.Form
    $repoLabel = New-Object System.Windows.Forms.Label
    $helpLabel = New-Object System.Windows.Forms.Label
    $secretList = New-Object System.Windows.Forms.ListBox
    $nameLabel = New-Object System.Windows.Forms.Label
    $nameBox = New-Object System.Windows.Forms.TextBox
    $valueLabel = New-Object System.Windows.Forms.Label
    $valueBox = New-Object System.Windows.Forms.TextBox
    $statusLabel = New-Object System.Windows.Forms.Label
    $refreshButton = New-Object System.Windows.Forms.Button
    $saveButton = New-Object System.Windows.Forms.Button
    $deleteButton = New-Object System.Windows.Forms.Button
    $closeButton = New-Object System.Windows.Forms.Button
    $operations = New-Object 'System.Collections.Generic.List[object]'
    $outcome = @{ Status = 'cancelled'; Operations = @() }
    try {
        $form.Text = 'GitHub Actions secrets'
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.StartPosition = 'CenterParent'
        $form.MinimizeBox = $false
        $form.MaximizeBox = $false
        $form.ShowInTaskbar = $false
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.ClientSize = [System.Drawing.Size]::new(720, 390)

        $repoLabel.Text = "Repository: $RepositorySlug"
        $repoLabel.AutoSize = $false
        $repoLabel.SetBounds(16, 12, 688, 24)
        $repoLabel.Font = [System.Drawing.Font]::new($form.Font, [System.Drawing.FontStyle]::Bold)
        $helpLabel.Text = 'Select a secret to replace or delete, or enter a new name. Values stay masked and are sent through standard input.'
        $helpLabel.AutoSize = $false
        $helpLabel.SetBounds(16, 38, 688, 36)
        $secretList.SetBounds(16, 82, 255, 232)
        $secretList.HorizontalScrollbar = $true
        $secretList.HorizontalExtent = 520
        $nameLabel.Text = 'Secret name:'
        $nameLabel.SetBounds(290, 82, 414, 20)
        $nameBox.SetBounds(290, 104, 414, 26)
        $nameBox.MaxLength = 100
        $valueLabel.Text = 'Secret value (masked):'
        $valueLabel.SetBounds(290, 144, 414, 20)
        $valueBox.SetBounds(290, 166, 414, 28)
        $valueBox.UseSystemPasswordChar = $true
        $valueBox.MaxLength = 49152
        $statusLabel.Text = 'Loading secret names...'
        $statusLabel.AutoSize = $false
        $statusLabel.SetBounds(16, 322, 688, 24)
        $refreshButton.Text = 'Refresh list'
        $refreshButton.SetBounds(16, 352, 110, 28)
        $saveButton.Text = 'Add / update'
        $saveButton.SetBounds(364, 352, 110, 28)
        $deleteButton.Text = 'Delete'
        $deleteButton.SetBounds(482, 352, 110, 28)
        $closeButton.Text = 'Close'
        $closeButton.SetBounds(600, 352, 104, 28)
        $form.Controls.AddRange(@($repoLabel, $helpLabel, $secretList, $nameLabel, $nameBox, $valueLabel, $valueBox, $statusLabel, $refreshButton, $saveButton, $deleteButton, $closeButton))
        $form.CancelButton = $closeButton

        $loadNames = {
            $secretList.Items.Clear()
            try {
                foreach ($name in @(Get-GitHubActionsSecretNames -RepositorySlug $RepositorySlug -GhPath $GhPath)) { [void]$secretList.Items.Add($name) }
                $statusLabel.Text = "Loaded $($secretList.Items.Count) Actions secret name(s). Values cannot be read back from GitHub."
            } catch {
                $statusLabel.Text = 'Could not load secret names. Check gh authentication and repository access.'
            }
        }.GetNewClosure()
        $form.Add_Shown({ & $loadNames }.GetNewClosure())
        $refreshButton.Add_Click({ & $loadNames }.GetNewClosure())
        $secretList.Add_SelectedIndexChanged({
            if ($null -ne $secretList.SelectedItem) { $nameBox.Text = [string]$secretList.SelectedItem }
        }.GetNewClosure())
        $saveButton.Add_Click({
            $name = $nameBox.Text.Trim()
            $value = $valueBox.Text
            if (-not (Test-GitHubActionsSecretName $name)) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'Use letters, digits, and underscores; start with a letter or underscore; do not use the reserved GITHUB_ prefix.', 'Invalid secret name', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            if ([string]::IsNullOrWhiteSpace($value)) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'Enter a secret value first.', 'Secret value required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            $answer = [System.Windows.Forms.MessageBox]::Show($form, "Add or replace '$name' in $RepositorySlug? GitHub will encrypt it; the current value cannot be read back.", 'Confirm Actions secret', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            try {
                $exitCode = Invoke-GitHubActionsSecretSet -RepositorySlug $RepositorySlug -SecretName $name -SecretValue $value -GhPath $GhPath
                if ($exitCode -eq 0) {
                    $operations.Add([pscustomobject]@{ Action = 'set'; Name = $name })
                    $statusLabel.Text = "Saved '$name' in $RepositorySlug. The value was not logged."
                    & $loadNames
                } else {
                    $statusLabel.Text = "GitHub CLI could not save '$name'. Check gh authentication and Actions-secrets permission."
                }
            } catch {
                $statusLabel.Text = "Could not save '$name'. Check gh authentication and Actions-secrets permission."
            } finally {
                $valueBox.Clear()
                $value = $null
            }
        }.GetNewClosure())
        $deleteButton.Add_Click({
            $name = [string]$secretList.SelectedItem
            if (-not (Test-GitHubActionsSecretName $name)) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'Select an Actions secret from the list first.', 'No secret selected', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            $answer = [System.Windows.Forms.MessageBox]::Show($form, "Delete '$name' from $RepositorySlug? Workflows using it may stop working.", 'Confirm secret deletion', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            try {
                $exitCode = Invoke-GitHubActionsSecretDelete -RepositorySlug $RepositorySlug -SecretName $name -GhPath $GhPath
                if ($exitCode -eq 0) {
                    $operations.Add([pscustomobject]@{ Action = 'delete'; Name = $name })
                    $statusLabel.Text = "Deleted '$name' from $RepositorySlug."
                    $nameBox.Clear()
                    & $loadNames
                } else {
                    $statusLabel.Text = "GitHub CLI could not delete '$name'. Check gh authentication and Actions-secrets permission."
                }
            } catch {
                $statusLabel.Text = "Could not delete '$name'. Check gh authentication and Actions-secrets permission."
            }
        }.GetNewClosure())
        $closeButton.Add_Click({ $form.Close() }.GetNewClosure())

        $dialogResult = if ($Owner) { $form.ShowDialog($Owner) } else { $form.ShowDialog() }
        if ($operations.Count -gt 0) { $outcome = @{ Status = 'configured'; Operations = @($operations.ToArray()) } }
        return $outcome
    } finally {
        $valueBox.Clear()
        $form.Dispose()
    }
}
