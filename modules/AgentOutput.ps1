# Reads an agent's output while it runs, so the chat can show its steps instead of waiting for the end.
# The chat polls from its UI timer: Process output events fire on reader threads, where a script block
# has no PowerShell runspace. Each stream keeps one pending ReadAsync and hands back complete lines.
function New-CodeCliOutputPump {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory reader state; changes no system state.')]
    param([System.Diagnostics.Process]$Process)
    $streams = @()
    foreach ($source in 'out', 'err') {
        $reader = if ($source -eq 'out') { $Process.StandardOutput } else { $Process.StandardError }
        $streams += @{ Source = $source; Reader = $reader; Buffer = (New-Object char[] 8192); Task = $null
            Partial = (New-Object System.Text.StringBuilder); Done = $false }
    }
    return @{ Streams = $streams }
}

function Read-CodeCliOutputPump {
    param($Pump)
    $lines = New-Object System.Collections.ArrayList
    foreach ($stream in $Pump.Streams) {
        for ($reads = 0; -not $stream.Done -and $reads -lt 64; $reads++) {
            if (-not $stream.Task) { $stream.Task = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length) }
            if (-not $stream.Task.IsCompleted) { break }
            $count = 0
            # A read that fails (the process tree was stopped) ends the stream like end-of-output.
            try { $count = $stream.Task.Result } catch { $count = 0 }
            $stream.Task = $null
            if ($count -le 0) {
                $stream.Done = $true
                if ($stream.Partial.Length -gt 0) { [void]$lines.Add(@{ Source = $stream.Source; Text = $stream.Partial.ToString().TrimEnd("`r") }) }
                [void]$stream.Partial.Clear()
                break
            }
            [void]$stream.Partial.Append($stream.Buffer, 0, $count)
            $text = $stream.Partial.ToString()
            $cut = $text.LastIndexOf("`n")
            if ($cut -lt 0) { continue }
            foreach ($line in $text.Substring(0, $cut).Split("`n")) { [void]$lines.Add(@{ Source = $stream.Source; Text = $line.TrimEnd("`r") }) }
            [void]$stream.Partial.Clear()
            [void]$stream.Partial.Append($text.Substring($cut + 1))
        }
    }
    return @{ Lines = $lines.ToArray(); Done = (@($Pump.Streams | Where-Object { -not $_.Done }).Count -eq 0) }
}

# What one output line means for the chat. Kind 'answer': plain standard output, part of the reply.
# Kind 'step': progress to show while it works (standard error, stream-json steps). Kind 'result': the
# final reply carried by a stream-json "result" event. $null: nothing to show.
function ConvertFrom-CodeCliOutputLine {
    param([string]$Source, [string]$Text)
    if ($Source -eq 'err') {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        return @{ Kind = 'step'; Text = $Text }
    }
    $trimmed = $Text.Trim()
    if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) {
        $streamEvent = $null
        try { $streamEvent = ConvertFrom-Json -InputObject $trimmed } catch { $streamEvent = $null }
        if ($streamEvent -and $streamEvent.type) { return (ConvertFrom-CodeCliStreamEvent $streamEvent) }
    }
    return @{ Kind = 'answer'; Text = $Text }
}

# Events of --output-format stream-json: the agent's text and tool calls become steps; "result" holds the
# final reply and how the run ended.
function ConvertFrom-CodeCliStreamEvent {
    param($StreamEvent)
    switch ([string]$StreamEvent.type) {
        'system' {
            if ($StreamEvent.subtype -ne 'init') { return $null }
            $model = if ($StreamEvent.model) { " ($($StreamEvent.model))" } else { '' }
            return @{ Kind = 'step'; Text = "Started$model" }
        }
        'assistant' {
            $parts = @()
            foreach ($item in @($StreamEvent.message.content)) {
                if ($item.type -eq 'text' -and $item.text) { $parts += [string]$item.text }
                elseif ($item.type -eq 'tool_use') { $parts += ('-> ' + [string]$item.name + (Format-CodeCliToolInput $item.input)) }
            }
            if ($parts.Count -eq 0) { return $null }
            return @{ Kind = 'step'; Text = ($parts -join "`r`n") }
        }
        'user' {
            foreach ($item in @($StreamEvent.message.content)) {
                if ($item.type -eq 'tool_result' -and $item.is_error) { return @{ Kind = 'step'; Text = '   (that step failed)' } }
            }
            return $null
        }
        'result' {
            $ending = if ($StreamEvent.subtype -and $StreamEvent.subtype -ne 'success') { "Ended: $($StreamEvent.subtype)" } else { 'Finished' }
            if ($StreamEvent.num_turns) { $ending += " after $($StreamEvent.num_turns) turns" }
            return @{ Kind = 'result'; Text = [string]$StreamEvent.result; Step = $ending }
        }
        default { return $null }
    }
}

function Format-CodeCliToolInput {
    param($ToolInput)
    if (-not $ToolInput) { return '' }
    foreach ($name in 'command', 'file_path', 'path', 'pattern', 'url', 'query', 'description') {
        $value = [string]$ToolInput.$name
        if (-not $value) { continue }
        $value = ($value -replace '\s+', ' ').Trim()
        if ($value.Length -gt 140) { $value = $value.Substring(0, 137) + '...' }
        return ": $value"
    }
    return ''
}

# One agent run: its output readers, the steps shown so far, the plain reply text, and timing for the status.
function New-CodeCliRun {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory run state; changes no system state.')]
    param([System.Diagnostics.Process]$Process)
    $now = [datetime]::UtcNow
    return @{ Pump = (New-CodeCliOutputPump $Process); Activity = (New-Object System.Text.StringBuilder); Answer = (New-Object System.Text.StringBuilder)
        Result = $null; Ending = $null; StartedUtc = $now; LastOutputUtc = $now; LastStepStart = -1; LastStepText = '' }
}

# Takes the lines read since the last poll and returns the text to append to the live transcript.
function Add-CodeCliRunOutput {
    param($Run, $Lines)
    $shown = New-Object System.Text.StringBuilder
    foreach ($line in @($Lines)) {
        $Run.LastOutputUtc = [datetime]::UtcNow
        $item = ConvertFrom-CodeCliOutputLine $line.Source $line.Text
        if (-not $item) { continue }
        if ($item.Kind -eq 'answer') { [void]$Run.Answer.AppendLine($item.Text); [void]$shown.AppendLine($item.Text); continue }
        if ($item.Kind -eq 'result') {
            $Run.Result = $item.Text; $Run.Ending = $item.Step
            # The final text also arrived as the last step; keep it once, as the reply.
            if ($Run.LastStepStart -ge 0 -and $Run.LastStepText.Trim() -eq ([string]$item.Text).Trim()) {
                [void]$Run.Activity.Remove($Run.LastStepStart, $Run.Activity.Length - $Run.LastStepStart)
            }
            $item = @{ Text = $item.Step }
        }
        $step = Format-CodeCliStep $item.Text
        $Run.LastStepStart = $Run.Activity.Length; $Run.LastStepText = [string]$item.Text
        [void]$Run.Activity.Append($step)
        [void]$shown.Append($step)
    }
    return $shown.ToString()
}

function Get-CodeCliRunReply {
    param($Run, [int]$ExitCode, [bool]$Stopped)
    $reply = if ($Run.Result) { [string]$Run.Result } else { $Run.Answer.ToString().Trim() }
    if ($reply.Length -gt 20000) { $reply = $reply.Substring($reply.Length - 20000) }
    if ($Stopped) { if ($reply) { return "$reply`r`n`r`nStopped." } else { return 'Stopped.' } }
    if (-not $reply) { return "The command ended with exit code $ExitCode and no reply; its output is in the steps above." }
    if ($ExitCode -ne 0) { return "$reply`r`n`r`n(exit code $ExitCode)" }
    return $reply
}

# The steps kept with the reply, bounded so long runs do not swell the conversation file.
function Get-CodeCliRunActivity {
    param($Run)
    $text = $Run.Activity.ToString().TrimEnd()
    if ($text.Length -gt 8000) { $text = "  ...`r`n" + $text.Substring($text.Length - 8000) }
    return $text
}

function Get-CodeCliRunStatus {
    param($Run, [int]$ExitCode = 0, [switch]$Ended, [bool]$Stopped)
    $now = [datetime]::UtcNow
    $elapsed = Format-CodeCliDuration ($now - $Run.StartedUtc)
    if ($Ended) {
        if ($Stopped) { return "Stopped after $elapsed" }
        if ($ExitCode -ne 0) { return "Ended with exit code $ExitCode after $elapsed" }
        return "Finished in $elapsed"
    }
    $quiet = $now - $Run.LastOutputUtc
    if ($quiet.TotalSeconds -ge 10) { return "Working $elapsed - no new output for $(Format-CodeCliDuration $quiet)" }
    return "Working $elapsed"
}

# A step as it appears in the transcript: indented under "Agent", one line per line.
function Format-CodeCliStep {
    param([string]$Text)
    return ((@($Text -split "`r?`n") | ForEach-Object { "  $_" }) -join "`r`n") + "`r`n"
}

function Format-CodeCliDuration {
    param([TimeSpan]$Span)
    $minutes = [int][Math]::Floor($Span.TotalMinutes)
    return ('{0}:{1:00}' -f $minutes, $Span.Seconds)
}
