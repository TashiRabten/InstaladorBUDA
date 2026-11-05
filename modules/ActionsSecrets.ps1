# Actions secrets...: the masked manager behind the button of the bootstrap group and the actions-secrets action of
# the CLI. A value is typed in the window or read from a file, and reaches gh only through standard input
# (Invoke-ProcessStartWithoutInputBom, in GitBootstrap.ps1): never through CLI JSON, arguments, temporary files or logs.

function Test-GitHubActionsSecretName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z_][A-Za-z0-9_]*$' -and $Name -notmatch '^GITHUB_')
}

# A secret value read from a file as GitHub will store it: the exact UTF-8 text, line breaks kept, no BOM. The masked
# value box is one line, so a pasted multi-line value (the JSON of a release identity) would keep only its first line.
function Read-ActionsSecretValueFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Choose an existing file.' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $text = $null
    try {
        if ($bytes.Length - $start -gt 49152) { throw 'GitHub Actions secret values must be 48 KB or smaller.' }
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $start, $bytes.Length - $start)
    } catch [System.Text.DecoderFallbackException] {
        throw 'The file is not UTF-8 text; a secret value must be text.'
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'The file is empty.' }
    return $text
}

function Select-ActionsSecretValueFile {
    param([System.Windows.Forms.IWin32Window]$Owner)
    return (@(Invoke-BudaFilePicker -Key 'actions-secret-value' -Purpose File -Title 'Secret value from a file (sent as it is, line breaks kept)' -Owner $Owner) | Select-Object -First 1)
}

function Confirm-ActionsSecretSave {
    param([System.Windows.Forms.IWin32Window]$Owner, [string]$Name, [string]$RepositorySlug, [string]$Source)
    $answer = [System.Windows.Forms.MessageBox]::Show($Owner, "Add or replace '$Name' in $RepositorySlug with the value $Source? GitHub will encrypt it; the current value cannot be read back.", 'Confirm Actions secret', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
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
        if (-not (Invoke-ProcessStartWithoutInputBom $process)) { throw 'Could not start GitHub CLI.' }
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
    $fileButton = New-Object System.Windows.Forms.Button
    $valueFile = @{ Path = $null }
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
        $helpLabel.Text = 'Select a secret to replace or delete, or enter a new name. Values stay masked and are sent through standard input; a multi-line value, such as a key file, goes in with Value from file.'
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
        $fileButton.Text = 'Value from file...'
        $fileButton.SetBounds(290, 202, 150, 28)
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
        $form.Controls.AddRange(@($repoLabel, $helpLabel, $secretList, $nameLabel, $nameBox, $valueLabel, $valueBox, $fileButton, $statusLabel, $refreshButton, $saveButton, $deleteButton, $closeButton))
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
        $clearValueFile = {
            $valueFile.Path = $null
            $valueBox.Enabled = $true
            $fileButton.Text = 'Value from file...'
        }.GetNewClosure()
        $fileButton.Add_Click({
            if ($valueFile.Path) {
                & $clearValueFile
                $statusLabel.Text = 'File cleared: type the value instead.'
                return
            }
            $path = Select-ActionsSecretValueFile $form
            if (-not $path) { return }
            $text = $null
            try {
                $text = Read-ActionsSecretValueFile $path
                $valueFile.Path = $path
                $valueBox.Clear()
                $valueBox.Enabled = $false
                $fileButton.Text = 'Clear file'
                $statusLabel.Text = "The value will be read from $([IO.Path]::GetFileName($path)) ($([Text.Encoding]::UTF8.GetByteCount($text)) bytes) when you click Add / update."
            } catch {
                $statusLabel.Text = "File not used: $($_.Exception.Message)"
            } finally {
                $text = $null
            }
        }.GetNewClosure())
        $saveButton.Add_Click({
            $name = $nameBox.Text.Trim()
            $source = if ($valueFile.Path) { "from $([IO.Path]::GetFileName($valueFile.Path))" } else { 'typed in the box' }
            try {
                $value = if ($valueFile.Path) { Read-ActionsSecretValueFile $valueFile.Path } else { $valueBox.Text }
            } catch {
                $statusLabel.Text = "Not saved: $($_.Exception.Message)"
                return
            }
            if (-not (Test-GitHubActionsSecretName $name)) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'Use letters, digits, and underscores; start with a letter or underscore; do not use the reserved GITHUB_ prefix.', 'Invalid secret name', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            if ([string]::IsNullOrWhiteSpace($value)) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'Enter a secret value first.', 'Secret value required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            if (-not (Confirm-ActionsSecretSave $form $name $RepositorySlug $source)) { return }
            try {
                $exitCode = Invoke-GitHubActionsSecretSet -RepositorySlug $RepositorySlug -SecretName $name -SecretValue $value -GhPath $GhPath
                if ($exitCode -eq 0) {
                    $operations.Add([pscustomobject]@{ Action = 'set'; Name = $name })
                    & $loadNames   # before the message: the reload writes its own status line
                    $statusLabel.Text = "Saved '$name' in $RepositorySlug. The value was not logged."
                } else {
                    $statusLabel.Text = "GitHub CLI could not save '$name'. Check gh authentication and Actions-secrets permission."
                }
            } catch {
                $statusLabel.Text = "Could not save '$name'. Check gh authentication and Actions-secrets permission."
            } finally {
                $valueBox.Clear()
                $value = $null
                & $clearValueFile
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
                    $nameBox.Clear()
                    & $loadNames   # before the message: the reload writes its own status line
                    $statusLabel.Text = "Deleted '$name' from $RepositorySlug."
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
