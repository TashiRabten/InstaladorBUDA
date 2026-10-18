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
    TopBarH      = 92     # build controls on row one and the session selector on row two
    SessionRowY  = 52
    SessionLabelW = 58
    SessionComboW = 400
    SessionNewW = 115
    SessionCloseW = 110
    HiddenTabHeader = 1
    SectionHeaderH = 26
    CollapsedSectionH = 34
    AgentConfig = @{
        Width = 720; Height = 390
        List = @{ X = 16; Y = 18; Width = 180; Height = 300 }
        LabelX = 214; LabelWidth = 470; LabelHeight = 22; FieldWidth = 470
        NameLabelY = 24; NameFieldY = 48
        CommandLabelY = 78; CommandFieldY = 102; CommandFieldWidth = 352
        ArgumentsLabelY = 132; ArgumentsFieldY = 156
        BrowseX = 580; BrowseY = 104; BrowseWidth = 104; BrowseHeight = 28
        ModeLabelX = 214; ModeY = 186; ModeLabelWidth = 112; ModeLabelHeight = 26; ModeX = 330; ModeWidth = 354
        HelpX = 214; HelpY = 222; HelpWidth = 470; HelpHeight = 44
        ButtonsY = 328; AddX = 16; AddWidth = 92; DeleteX = 112; DeleteWidth = 84
        HelpButtonX = 210; HelpButtonWidth = 92
        SaveX = 474; SaveWidth = 100; CancelX = 584; CancelWidth = 100; ButtonHeight = 32
    }
    AgentHelp = @{
        Width = 760; Height = 590
        TextX = 16; TextY = 16; TextWidth = 728; TextHeight = 506
        CloseX = 644; CloseY = 538; CloseWidth = 100; CloseHeight = 32
    }
    AgentChat = @{
        Width = 760; Height = 620; MinWidth = 700; MinHeight = 520
        ProjectX = 18; ProjectY = 10; ProjectWidth = 724; ProjectHeight = 28
        AgentLabelX = 18; AgentLabelY = 46; AgentLabelWidth = 65; AgentX = 86; AgentWidth = 420
        ConfigureX = 518; ConfigureY = 44; ConfigureWidth = 224; ConfigureHeight = 30
        ConversationLabelX = 18; ConversationLabelY = 84; ConversationLabelWidth = 88
        ConversationX = 108; ConversationWidth = 430; NewConversationX = 550; NewConversationWidth = 192
        RowY = 82; RowHeight = 30
        TranscriptX = 18; TranscriptY = 122; TranscriptWidth = 724; TranscriptHeight = 302
        PromptLabelX = 18; PromptLabelY = 432; PromptLabelWidth = 724; PromptLabelHeight = 24
        PromptX = 18; PromptY = 458; PromptWidth = 724; PromptHeight = 94
        SendX = 18; StopX = 160; ActionY = 570; SendWidth = 132; StopWidth = 100
        CloseX = 642; CloseWidth = 100; ActionHeight = 34
    }
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

# Turns each GroupBox into a compact, independently expandable section. The section
# heading stays visible while the section body is hidden, and later controls move with
# it so collapsing GitHub groups does not leave large blank areas in the scroll panel.
function Enable-CollapsibleSections {
    param(
        $Panel,
        $Sections,
        [string[]]$InitiallyExpanded = @()
    )

    foreach ($section in $Sections) {
        if (-not $section) { continue }
        $title = [string]$section.Text
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        $expandedHeight = $section.Height

        $header = New-Object System.Windows.Forms.Button
        $header.Text = "▼  $title"
        $header.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $header.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $header.ForeColor = $section.ForeColor
        $header.Cursor = [System.Windows.Forms.Cursors]::Hand
        $header.AccessibleName = $title
        $header.AccessibleDescription = 'Click to expand or collapse this section.'
        $header.AutoEllipsis = $true
        $header.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $header.FlatAppearance.BorderSize = 0
        $header.BackColor = $section.BackColor
        $header.UseVisualStyleBackColor = $false
        $header.SetBounds((Px 8), (Px 1), [Math]::Max((Px 100), $section.ClientSize.Width - (Px 16)), (Px $UI.SectionHeaderH))
        $header.Anchor = 'Top,Left,Right'

        # The button supplies the complete heading, so leave the GroupBox caption empty.
        $section.Text = ''
        $section.Controls.Add($header)
        $header.BringToFront()

        $state = [hashtable]::Synchronized(@{
            Expanded = $true
            ExpandedHeight = $expandedHeight
            CollapsedHeight = (Px $UI.CollapsedSectionH)
            Title = $title
            Section = $section
            Header = $header
            Panel = $Panel
        })

        $toggle = {
            $section = $state.Section
            $panel = $state.Panel
            $header = $state.Header
            $oldBottom = $section.Bottom
            if ($state.Expanded) {
                foreach ($child in @($section.Controls)) {
                    if ($child -ne $header) { $child.Visible = $false }
                }
                $section.Height = $state.CollapsedHeight
                $delta = $section.Height - $state.ExpandedHeight
                $state.Expanded = $false
                $header.Text = "▶  $($state.Title)"
            } else {
                foreach ($child in @($section.Controls)) {
                    if ($child -ne $header) { $child.Visible = $true }
                }
                $section.Height = $state.ExpandedHeight
                $delta = $section.Height - $state.CollapsedHeight
                $state.Expanded = $true
                $header.Text = "▼  $($state.Title)"
            }

            if ($delta -ne 0) {
                foreach ($sibling in @($panel.Controls)) {
                    if ($sibling -ne $section -and $sibling.Top -ge $oldBottom) {
                        $sibling.Top += $delta
                    }
                }
                $scrollSize = $panel.AutoScrollMinSize
                $newScrollHeight = [Math]::Max((Px $UI.CollapsedSectionH), $scrollSize.Height + $delta)
                $panel.AutoScrollMinSize = New-Object System.Drawing.Size($scrollSize.Width, $newScrollHeight)
            }
        }.GetNewClosure()

        # The header carries its section's state so Expand-CollapsibleSectionsFor can open it.
        $state.Toggle = $toggle
        $header.Tag = $state
        $header.Add_Click({ & $toggle }.GetNewClosure())
        if ($InitiallyExpanded -notcontains $title) { & $toggle }
    }
}

# Opens each collapsed section that holds $Control, so the control is shown and can be clicked.
function Expand-CollapsibleSectionsFor {
    param($Control)
    for ($parent = $Control.Parent; $parent; $parent = $parent.Parent) {
        if ($parent -isnot [System.Windows.Forms.GroupBox]) { continue }
        foreach ($child in @($parent.Controls)) {
            $sectionState = $child.Tag
            if ($sectionState -is [hashtable] -and $sectionState.ContainsKey('Toggle')) {
                if (-not $sectionState.Expanded) { & $sectionState.Toggle }
                break
            }
        }
    }
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
