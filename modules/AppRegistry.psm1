class BudaAppRegistry {
    [string]$Path
    [object]$Config
    [object[]]$Apps

    BudaAppRegistry([string]$path) {
        $this.Path = $path
        $this.Load()
    }

    [void] Load() {
        if (-not (Test-Path -LiteralPath $this.Path -PathType Leaf)) {
            throw "App registry not found: $($this.Path)"
        }
        $this.Config = [System.IO.File]::ReadAllText($this.Path) | ConvertFrom-Json
        $this.Apps = @($this.Config.apps)
    }

    [object] Get([string]$name) {
        foreach ($app in $this.Apps) {
            if ($app.name -eq $name) { return $app }
        }
        return $null
    }

    [object] Add([object]$app) {
        if (-not $app -or [string]::IsNullOrWhiteSpace([string]$app.name)) { throw 'App name is required.' }
        if ($this.Get([string]$app.name)) { throw "An app named '$($app.name)' is already registered." }
        if (-not (Test-Path -LiteralPath $this.Path -PathType Leaf)) { throw "App registry not found: $($this.Path)" }

        # Insert only the new object into the apps array. Serializing the whole config would
        # rewrite unrelated user formatting and comments whenever an app is registered.
        $raw = [System.IO.File]::ReadAllText($this.Path)
        $appsMatch = [regex]::Match($raw, '"apps"\s*:\s*\[')
        if (-not $appsMatch.Success) { throw "Could not find the apps array in $($this.Path)" }
        $openIndex = $appsMatch.Index + $appsMatch.Length - 1
        $depth = 1; $inString = $false; $escaped = $false; $closeIndex = -1
        for ($i = $openIndex + 1; $i -lt $raw.Length; $i++) {
            $ch = $raw[$i]
            if ($inString) {
                if ($escaped) { $escaped = $false }
                elseif ($ch -eq '\') { $escaped = $true }
                elseif ($ch -eq '"') { $inString = $false }
                continue
            }
            if ($ch -eq '"') { $inString = $true; continue }
            if ($ch -eq '[' -or $ch -eq '{') { $depth++ }
            elseif ($ch -eq ']' -or $ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $closeIndex = $i; break }
            }
        }
        if ($closeIndex -lt 0) { throw "Could not find the end of the apps array in $($this.Path)" }

        $body = $raw.Substring($openIndex + 1, $closeIndex - $openIndex - 1)
        $appJson = ConvertTo-Json -InputObject $app -Depth 20
        $indentedApp = ($appJson -split "`r?`n" | ForEach-Object { "    $_" }) -join "`r`n"
        if ([string]::IsNullOrWhiteSpace($body)) {
            $newBody = "`r`n$indentedApp`r`n  "
        } else {
            $bodyEnd = $body.Length
            while ($bodyEnd -gt 0 -and [char]::IsWhiteSpace($body[$bodyEnd - 1])) { $bodyEnd-- }
            if ($bodyEnd -eq 0) { throw 'Could not determine the end of the last app entry.' }
            $newBody = $body.Substring(0, $bodyEnd) + ",`r`n" + $indentedApp + $body.Substring($bodyEnd)
        }
        $updated = $raw.Substring(0, $openIndex + 1) + $newBody + $raw.Substring($closeIndex)
        $validated = ConvertFrom-Json -InputObject $updated -ErrorAction Stop
        if (@($validated.apps).Count -ne (@($this.Config.apps).Count + 1)) {
            throw 'The updated app registry did not validate with the new entry.'
        }

        $fileToken = [guid]::NewGuid().ToString('N')
        $registryDir = Split-Path -Parent $this.Path
        $tempPath = Join-Path $registryDir ('.apps.json.' + $fileToken + '.tmp')
        $backupPath = Join-Path $registryDir ('.apps.json.' + $fileToken + '.bak')
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        try {
            [System.IO.File]::WriteAllText($tempPath, $updated, $utf8)
            # .NET Framework rejects a null backup filename; provide a same-directory
            # backup so Replace remains atomic on the packaged EXE's runtime.
            [System.IO.File]::Replace($tempPath, $this.Path, $backupPath)
        } finally {
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        }
        $this.Load()
        return $this.Get([string]$app.name)
    }
}
