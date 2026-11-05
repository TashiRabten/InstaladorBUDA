# Actions secrets: a value taken from a file reaches GitHub exactly as the file holds it, line breaks included. The masked
# value box is a single-line field, where a pasted multi-line value (a release identity's JSON) would keep only its
# first line. The checks read files with Read-ActionsSecretValueFile and drive the visible window: Value from file...,
# Clear file, Add / update, with the secret call answered in the test.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\ActionsSecretFile.Tests.ps1 [-WithFakeGh]
#
# The script reruns itself dot-sourced in a fresh STA Windows PowerShell 5.1, the runtime of the exe. Nothing reaches
# GitHub. -WithFakeGh also sends a value through the real transport to a stand-in gh compiled into the temporary folder,
# which records its standard input; it is off by default because AVG sandboxes a freshly compiled program and starts
# extra copies of it (measured 2026-11-04: three copies for one call, one crashing with a Windows error dialog).
param([switch]$Inner, [switch]$WithFakeGh)

if (-not $Inner) {
    $self = $MyInvocation.MyCommand.Path
    $command = ". '{0}' -Inner{1}" -f $self.Replace("'", "''"), $(if ($WithFakeGh) { ' -WithFakeGh' } else { '' })
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -Command $command
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $testRoot 'modules\AppRegistry.psm1'))))
$entrypoint = [IO.File]::ReadAllText((Join-Path $testRoot 'InstaladorBUDA.ps1'))
foreach ($moduleMatch in [regex]::Matches($entrypoint, "Join-Path \`$AppDir '(modules\\[^']+\.ps1)'")) {
    . (Join-Path $testRoot $moduleMatch.Groups[1].Value)
}

$testPassed = 0
$testFailures = New-Object System.Collections.Generic.List[string]
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:testPassed++; Write-Output "ok   $Name" }
    else { $script:testFailures.Add($Name); Write-Output "FAIL $Name" }
}
function Get-Refusal {
    param([scriptblock]$Action)
    try { & $Action; return '' } catch { return $_.Exception.Message }
}
function Get-Hex { param([byte[]]$Bytes) return [BitConverter]::ToString($Bytes) }

$work = Join-Path ([IO.Path]::GetTempPath()) ('instaladorbuda-secretfile-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # Files: a pretty-printed identity-like JSON with CRLF and with LF, one with a BOM, an empty one, a binary one, a big one.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $jsonLf = "{`n  `"format`": `"buda-identity-1`",`n  `"name`": `"ScanBUDA release`",`n  `"sealed`": `"QUJDREVGR0g=`"`n}"
    $jsonCrlf = $jsonLf.Replace("`n", "`r`n")
    $lfFile = Join-Path $work 'identity-lf.json'; [IO.File]::WriteAllText($lfFile, $jsonLf, $utf8)
    $crlfFile = Join-Path $work 'identity-crlf.json'; [IO.File]::WriteAllText($crlfFile, $jsonCrlf, $utf8)
    $bomFile = Join-Path $work 'identity-bom.json'; [IO.File]::WriteAllBytes($bomFile, [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes($jsonLf))
    $emptyFile = Join-Path $work 'empty.txt'; [IO.File]::WriteAllText($emptyFile, "  `r`n ", $utf8)
    $binaryFile = Join-Path $work 'binary.bin'; [IO.File]::WriteAllBytes($binaryFile, [byte[]](0x50, 0xC3, 0x28, 0xFF, 0xFE))
    $bigFile = Join-Path $work 'big.txt'; [IO.File]::WriteAllText($bigFile, ('x' * 49153), $utf8)

    # Reading a file.
    Assert-That ((Read-ActionsSecretValueFile $lfFile) -ceq $jsonLf) 'read: LF lines come back exactly'
    Assert-That ((Read-ActionsSecretValueFile $crlfFile) -ceq $jsonCrlf) 'read: CRLF lines come back exactly'
    Assert-That ((Read-ActionsSecretValueFile $bomFile) -ceq $jsonLf) 'read: a UTF-8 BOM is dropped, the rest kept'
    Assert-That ((Get-Refusal { Read-ActionsSecretValueFile $emptyFile }) -match 'empty') 'read: a blank file is refused'
    Assert-That ((Get-Refusal { Read-ActionsSecretValueFile $binaryFile }) -match 'not UTF-8') 'read: a file that is not UTF-8 text is refused'
    Assert-That ((Get-Refusal { Read-ActionsSecretValueFile $bigFile }) -match '48 KB') 'read: more than 48 KB is refused'
    Assert-That ((Get-Refusal { Read-ActionsSecretValueFile (Join-Path $work 'missing.json') }) -match 'existing file') 'read: a missing file is refused'

    if ($WithFakeGh) {
        # The transport: what gh receives on standard input is the file's text, line breaks and all, with no BOM in front.
        $fakeGh = Join-Path $work 'gh.exe'
        $fakeSource = @'
using System;
using System.IO;
public static class FakeGh {
    public static int Main(string[] args) {
        string dir = Environment.GetEnvironmentVariable("FAKE_GH_DIR");
        string line = string.Join(" ", args);
        File.AppendAllText(Path.Combine(dir, "args.txt"), line + "\n");
        if (line.StartsWith("secret list")) { Console.Out.Write("[]"); return 0; }
        if (line.StartsWith("secret set")) {
            using (Stream input = Console.OpenStandardInput())
            using (FileStream output = File.Create(Path.Combine(dir, "stdin.bin"))) { input.CopyTo(output); }
            return 0;
        }
        return 1;
    }
}
'@
        Add-Type -TypeDefinition $fakeSource -OutputAssembly $fakeGh -OutputType ConsoleApplication
        $env:FAKE_GH_DIR = $work
        $stdinFile = Join-Path $work 'stdin.bin'
        $exit = Invoke-GitHubActionsSecretSet -RepositorySlug 'owner/repo' -SecretName 'RELEASE_SIGNING_IDENTITY' -SecretValue (Read-ActionsSecretValueFile $crlfFile) -GhPath $fakeGh
        Assert-That ($exit -eq 0) 'transport: gh secret set exits 0'
        Assert-That ((Get-Hex ([IO.File]::ReadAllBytes($stdinFile))) -ceq (Get-Hex $utf8.GetBytes($jsonCrlf))) 'transport: stdin holds the file bytes exactly'
        Assert-That (([IO.File]::ReadAllText((Join-Path $work 'args.txt'))) -match 'secret set RELEASE_SIGNING_IDENTITY --app actions --repo owner/repo') 'transport: the name and repository are the arguments, the value is not'
    }

    # The window. The picker, the confirmation and the two gh calls are what a test cannot click or must not send;
    # they answer here, in this process.
    $calls = @{ Picked = $lfFile; Source = ''; Sent = $null }
    Set-Item -Path function:global:Select-ActionsSecretValueFile -Value ({ param($Owner) return $calls.Picked }.GetNewClosure())
    Set-Item -Path function:global:Confirm-ActionsSecretSave -Value ({ param($Owner, $Name, $RepositorySlug, $Source) $calls.Source = $Source; return $true }.GetNewClosure())
    Set-Item -Path function:global:Get-GitHubActionsSecretNames -Value ({ param($RepositorySlug, $GhPath) return @('RELEASE_SIGNING_IDENTITY') })
    Set-Item -Path function:global:Invoke-GitHubActionsSecretSet -Value ({
        param($RepositorySlug, $SecretName, $SecretValue, $GhPath)
        $calls.Sent = @{ Repository = $RepositorySlug; Name = $SecretName; Value = $SecretValue }
        return 0
    }.GetNewClosure())
    $seen = @{ Steps = New-Object System.Collections.Generic.List[string] }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $state = @{ Step = 0; Ticks = 0 }
    $timer.Add_Tick({
        $state.Ticks++
        $window = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq 'GitHub Actions secrets' }) | Select-Object -First 1
        if (-not $window) { if ($state.Ticks -gt 40) { $seen.Steps.Add('no window'); $timer.Stop() }; return }
        $window.Location = New-Object System.Drawing.Point(-4000, -4000)
        $controls = @($window.Controls)
        $file = $controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -in @('Value from file...', 'Clear file') } | Select-Object -First 1
        $save = $controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Add / update' } | Select-Object -First 1
        $value = $controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] -and $_.UseSystemPasswordChar } | Select-Object -First 1
        $name = $controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] -and -not $_.UseSystemPasswordChar } | Select-Object -First 1
        $status = ($controls | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text -match 'will be read|cleared|Saved|Loaded|Not saved|not used' } | ForEach-Object { $_.Text }) -join ' | '
        switch ($state.Step) {
            0 { $seen.Steps.Add("button:$([bool]$file):$($file.Enabled)"); $file.PerformClick(); $state.Step = 1 }
            1 { $seen.Steps.Add("chosen:$($value.Enabled):$($file.Text):$status"); $file.PerformClick(); $state.Step = 2 }
            2 { $seen.Steps.Add("cleared:$($value.Enabled):$($file.Text):$status"); $file.PerformClick(); $state.Step = 3 }
            3 { $name.Text = 'RELEASE_SIGNING_IDENTITY'; $save.PerformClick(); $state.Step = 4 }
            4 { $seen.Steps.Add("saved:$($value.Enabled):$($file.Text):$status"); $timer.Stop(); $window.Close() }
        }
    }.GetNewClosure())
    $timer.Start()
    $outcome = Show-GitHubActionsSecretDialog -RepositorySlug 'owner/repo'
    $timer.Stop(); $timer.Dispose()
    $steps = @($seen.Steps)
    Assert-That ($steps.Count -eq 4) "window: every step ran ($($steps -join ' / '))"
    Assert-That ($steps[0] -eq 'button:True:True') 'window: Value from file... is there and enabled'
    Assert-That ($steps[1] -match '^chosen:False:Clear file:.*identity-lf\.json') 'window: a chosen file disables the box and names the file'
    Assert-That ($steps[2] -match '^cleared:True:Value from file\.\.\.:.*File cleared') 'window: Clear file gives the box back'
    Assert-That ($steps[3] -match '^saved:True:Value from file\.\.\.:Saved .RELEASE_SIGNING_IDENTITY.') 'window: Add / update says Saved and forgets the file'
    Assert-That ($calls.Source -eq 'from identity-lf.json') 'window: the confirmation names the file'
    Assert-That ($null -ne $calls.Sent -and $calls.Sent.Value -ceq $jsonLf) 'window: the value sent is the whole multi-line file'
    Assert-That ($null -ne $calls.Sent -and $calls.Sent.Name -eq 'RELEASE_SIGNING_IDENTITY' -and $calls.Sent.Repository -eq 'owner/repo') 'window: to the named secret of this repository'
    Assert-That ($outcome.Status -eq 'configured' -and @($outcome.Operations).Count -eq 1 -and $outcome.Operations[0].Name -eq 'RELEASE_SIGNING_IDENTITY') 'window: the outcome lists the one secret set'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "Secret file checks: $testPassed passed, $($testFailures.Count) failed"
if ($testFailures.Count) { exit 1 }
exit 0
