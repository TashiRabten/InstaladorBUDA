<#
.SYNOPSIS
    Compile InstaladorBUDA.ps1 into a standalone InstaladorBUDA.exe using ps2exe.

.DESCRIPTION
    Produces a single Windows .exe that embeds the script. The .exe is self-contained
    except for apps.json, which must sit next to it (it is read at runtime so you can
    add/edit apps without recompiling).

    ps2exe is installed from the PowerShell Gallery on first run if missing. If a previous
    InstaladorBUDA.exe is still running, this script stops it first (ps2exe cannot
    overwrite a locked/running .exe — that is the "Access to the path is denied" error).

.PARAMETER Icon
    Optional path to a .ico for the exe. Defaults to the app icon if present.

.EXAMPLE
    .\build-exe.ps1
#>
[CmdletBinding()]
param(
    [string]$Icon
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here 'InstaladorBUDA.ps1'
$bootstrapModule = Join-Path $here 'modules\GitBootstrap.ps1'
$out  = Join-Path $here 'InstaladorBUDA.exe'

if (-not (Test-Path $src)) { throw "InstaladorBUDA.ps1 not found next to this script ($src)." }
if (-not (Test-Path $bootstrapModule)) { throw "Git bootstrap module not found: $bootstrapModule" }

# The source stays split for editing. Compile one temporary script so the shipped EXE
# still needs only apps.json beside it.
$sourceText = [IO.File]::ReadAllText($src)
$marker = '#__GIT_BOOTSTRAP_MODULE__'
if ([regex]::Matches($sourceText, [regex]::Escape($marker)).Count -ne 1) {
    throw "Expected exactly one $marker marker in InstaladorBUDA.ps1."
}
$moduleText = [IO.File]::ReadAllText($bootstrapModule)
$bundledSource = $sourceText.Replace($marker, $moduleText)
$bundledInput = Join-Path $env:TEMP ("InstaladorBUDA-bundle-" + [guid]::NewGuid().ToString('N') + '.ps1')

# Default icon: the app icon in the resources folder, if present.
if (-not $Icon) {
    $guess = Join-Path $here 'resources\pramana.ico'
    if (Test-Path $guess) { $Icon = (Resolve-Path $guess).Path }
}

# Free the output path: a running instance locks the .exe so ps2exe's delete-then-write
# fails with "Access to the path is denied". Stop it, then remove the stale file.
function Clear-Output {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $full = (Resolve-Path $Path).Path
    foreach ($attempt in 1..3) {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop; return } catch { }
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and ($_.Path -ieq $full) } catch { $false }
        } | ForEach-Object {
            Write-Host "Stopping running instance (PID $($_.Id)) ..." -ForegroundColor Yellow
            try { $_.CloseMainWindow() | Out-Null } catch { }
            Start-Sleep -Milliseconds 300
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { }
        }
        Start-Sleep -Milliseconds 300
    }
    if (Test-Path $Path) {
        throw "Cannot overwrite $Path — it is in use. Close InstaladorBUDA.exe (taskbar / Task Manager) and re-run build-exe.ps1."
    }
}
Clear-Output $out

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe (CurrentUser scope) from PSGallery ..." -ForegroundColor Cyan
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

[IO.File]::WriteAllText($bundledInput, $bundledSource, [System.Text.UTF8Encoding]::new($false))

$opts = @{
    InputFile   = $bundledInput
    OutputFile  = $out
    noConsole   = $false         # CLI output needs inherited standard handles; the GUI hides its console at startup
    STA         = $true          # WinForms needs a single-threaded apartment
    DPIAware    = $true          # sharp text on a scaled display (125% / 150%). The GUI sizes
                                 # itself for the real DPI (Px in InstaladorBUDA.ps1), so
                                 # Windows must not bitmap-stretch the window as well.
    title       = 'InstaladorBUDA'
    product     = 'InstaladorBUDA'
    company     = 'Glossario BUDA'
    description = 'BUDA app deployment cockpit'
    version     = '1.0.0.0'
}
if ($Icon -and (Test-Path $Icon)) { $opts.iconFile = $Icon; Write-Host "Icon: $Icon" -ForegroundColor DarkGray }

$start = Get-Date
Write-Host "Compiling -> $out" -ForegroundColor Cyan
try {
    Invoke-ps2exe @opts
} finally {
    Remove-Item -LiteralPath $bundledInput -ErrorAction SilentlyContinue
}

# Verify a FRESH exe was actually produced — ps2exe prints a success banner even when the
# delete-then-write failed and only a stale exe remains, so check the write time.
if ((Test-Path $out) -and ((Get-Item $out).LastWriteTime -ge $start)) {
    $mb = [math]::Round((Get-Item $out).Length / 1MB, 2)
    Write-Host ""
    Write-Host "Built InstaladorBUDA.exe ($mb MB)." -ForegroundColor Green
    Write-Host "Ship it together with apps.json (same folder). Double-click to run." -ForegroundColor Green
} else {
    throw "ps2exe did not produce a fresh $out (see the errors above). If it said 'Access to the path is denied', the exe was running — close it and retry."
}
