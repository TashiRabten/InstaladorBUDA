# ── GUI layout ───────────────────────────────────────────────────────────────
# Every position and size in the GUI is in design pixels — pixels at 100% Windows
# scaling — and goes through Px, which scales it to the screen's real DPI once. The exe
# is DPI-aware so its text is sharp, which means Windows no longer enlarges the window
# for it: at 150% the 9 pt font is drawn 1.5x larger, and positions left at their 100%
# values crowd the rows together and clip the labels. Change spacing here, not in
# New-JobTab.
$UI = @{
    Pad          = 20     # outer margin of a tab's content
    ContentWidth = 720    # a tab's content width; boxes run from Pad to ContentWidth - Pad
    LabelWidth   = 100    # row labels ("Target app:", "Version:")
    FieldX       = 130    # where a row's input starts
    RowH         = 26     # a label, text box, combo box or check box
    RowPitch     = 42     # top of one field row to the top of the next
    CheckPitch   = 32     # between the two stacked check boxes
    BoxGap       = 18     # between one group box and the next
    BoxTop       = 30     # first row inside a group box, below its caption
    BoxPad       = 16     # a group box's inner left / right / bottom padding
    BoxRowPitch  = 46     # top of one row inside a group box to the next
    BoxLabelW    = 72     # "Workflow:" / "Run:" inside a group box
    BootstrapLabelW = 104 # bootstrap labels, including "Commit message:"
    BootstrapButtonMinW = 125 # enough room for the three bootstrap phase captions
    BtnH         = 34     # button height
    BtnGap       = 16     # between buttons in a row
    BtnTextPad   = 32     # caption-to-edge padding inside a button
    NotesH       = 80     # release-notes text box
    MessageH     = 56     # the Git group's commit-message box (two lines and a bit)
    LogH         = 150    # log box
    StatusH      = 30     # git / gh status line
    TopBarH      = 50     # the strip above the tabs holding Update (a button and its margin)
    WindowWidth  = 780    # main window, before it is capped to the screen
    WindowHeight = 1150
}

# Screen DPI / 96, read once: 1.5 at 150% in the DPI-aware exe; 1.0 for a .ps1 under
# pwsh, which is not DPI-aware (Windows stretches that whole window instead).
function Get-UiScale {
    if (-not $script:UiScale) {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try { $script:UiScale = $g.DpiX / 96.0 } finally { $g.Dispose() }
    }
    return $script:UiScale
}

function Px([double]$Value) { [int][Math]::Round($Value * (Get-UiScale)) }

# Places a control, in design pixels.
function Set-Box {
    param($Control, [double]$X, [double]$Y, [double]$Width, [double]$Height)
    $Control.SetBounds((Px $X), (Px $Y), (Px $Width), (Px $Height))
}

# Places a single-line text box or combo box centred in a RowH-high row at $Y, level
# with that row's MiddleLeft label. Its height is decided by its font, not by us, so the
# font is set first (a control not yet on the form has the default font).
function Set-Field {
    param($Control, $Font, [double]$X, [double]$Y, [double]$Width)
    $Control.Font = $Font
    Set-Box $Control $X $Y $Width $UI.RowH
    $Control.Top = (Px $Y) + [int][Math]::Floor(((Px $UI.RowH) - $Control.Height) / 2)
}

# The width a button needs for its caption, in design pixels, never below $MinWidth.
# Measured with TextRenderer (the GDI path Button itself draws with) at the real DPI, then
# converted back to design pixels so Set-Box scales it like everything else. $Caption
# measures a different text than the one the button shows now.
function Get-ButtonWidth {
    param([System.Windows.Forms.Button]$Button, [double]$MinWidth = 110, [string]$Caption)
    $text = if ($Caption) { $Caption } else { $Button.Text }
    $px = [System.Windows.Forms.TextRenderer]::MeasureText($text, $Button.Font).Width
    return [Math]::Max($MinWidth, [Math]::Ceiling($px / (Get-UiScale)) + $UI.BtnTextPad)
}

# Lays buttons left to right from $X on row $Y, each as wide as its caption needs.
# Returns the X just past the last one, so a later row can line up under this one.
function Set-ButtonRow {
    param([System.Windows.Forms.Button[]]$Buttons, [double]$X, [double]$Y, [double]$MinWidth = 110)
    foreach ($b in $Buttons) {
        $w = Get-ButtonWidth $b $MinWidth
        Set-Box $b $X $Y $w $UI.BtnH
        $X += $w + $UI.BtnGap
    }
    return $X
}

function Convert-CliList {
    param($Value)
    if ($null -eq $Value) { return ,@() }
    if ($Value -is [string]) { return ,@($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return ,@($Value | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ })
}

function Test-CliProperty {
    param($Object, [string]$Name)
    return ($Object -and ($Object.PSObject.Properties.Name -contains $Name))
}
