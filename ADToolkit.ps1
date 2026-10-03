# ====================================================================
# AD Toolkit
#
# Four everyday commands behind one window:
#   1. Get-ADUser -Properties *      all properties of an account
#   2. Get-ADGroupMember             accounts that belong to an AD group
#   3. Test-NetConnection            ping / TCP port test
#   4. Set-ADAccountPassword         change a password using the current one
#
# Requirements: Windows PowerShell 5.1 and, for the AD commands, the
# ActiveDirectory module (RSAT). Commands run as the current Windows user
# unless "Run as" credentials are set.
#
# NOTE ON EVENT HANDLERS
# PowerShell event handlers do NOT see the local variables of a function that
# has already returned. Shared UI state lives in $script:UiRefs and per-control
# state in .Tag - never in captured locals.
# ====================================================================

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data

# ====================================================================
# Configuration and state
# ====================================================================

$script:AppName = 'AD Toolkit'
$script:Credential = $null            # PSCredential used for the AD commands (null = current user)
$script:HasAdModule = $false
$script:RunspacePrelude = ''          # Text prepended to every background script (used by tests)
$script:DialogState = $null

# Attributes stored as 64-bit FILETIME values; shown with a readable date next to the raw value.
$script:FileTimeAttributes = @('lastLogon', 'lastLogonTimestamp', 'pwdLastSet', 'accountExpires', 'badPasswordTime', 'lockoutTime')

# Shared references used by event handlers (see note at the top of the file).
$script:UiRefs = @{
    Form = $null
    Split = $null
    LeftScroll = $null
    StatusBar = $null
    ServerBox = $null
    RunAsLabel = $null
    Grid = $null
    GridMessage = $null
    FilterBox = $null
    CommandBox = $null
    Columns = @()
    View = $null
    RunButtons = @()
    Fields = @{}
}

# ====================================================================
# Layout Constants (Design Token System)
# ====================================================================

$script:UiLayout = [PSCustomObject]@{
    FieldRowHeight = 34
    PaddingStandard = 16
    ControlSpacing = 8
    SectionGap = 10

    LabelWidth = 110
    ButtonHeightSmall = 32
    ButtonHeightLarge = 38

    HeaderHeight = 72
    ToolbarHeight = 40

    SplitterDefault = 400
    LeftMinWidth = 380
    RightMinWidth = 420
}

# ====================================================================
# UI Theme Configuration
# ====================================================================

$script:UiTheme = [PSCustomObject]@{
    Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
    FontStrong = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
    FontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 11, [System.Drawing.FontStyle]::Bold)
    FontMono = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Regular)

    Surface = [System.Drawing.Color]::White
    PageBackground = [System.Drawing.Color]::FromArgb(245, 247, 250)

    Accent = [System.Drawing.Color]::FromArgb(0, 120, 212)
    AccentHover = [System.Drawing.Color]::FromArgb(0, 99, 177)
    AccentLight = [System.Drawing.Color]::FromArgb(232, 243, 255)
    Danger = [System.Drawing.Color]::FromArgb(192, 40, 28)
    Success = [System.Drawing.Color]::FromArgb(22, 130, 58)

    TextPrimary = [System.Drawing.Color]::FromArgb(40, 40, 40)
    TextMuted = [System.Drawing.Color]::FromArgb(90, 90, 90)
    TextDisabled = [System.Drawing.Color]::FromArgb(160, 160, 160)

    Border = [System.Drawing.Color]::FromArgb(216, 220, 227)
    DisabledBackground = [System.Drawing.Color]::FromArgb(238, 240, 243)
    GridHeader = [System.Drawing.Color]::FromArgb(240, 243, 248)
    GridAlternate = [System.Drawing.Color]::FromArgb(250, 251, 253)
}

# ====================================================================
# Helper Functions - UI Element Creation
# ====================================================================

function New-UiLabel {
    param(
        [string]$Text,
        [System.Drawing.Point]$Location,
        [int]$Width = $script:UiLayout.LabelWidth,
        [switch]$Strong,
        [switch]$Muted
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    if ($PSBoundParameters.ContainsKey('Location')) { $label.Location = $Location }
    $label.Size = New-Object System.Drawing.Size($Width, 22)
    $label.Font = if ($Strong) { $script:UiTheme.FontStrong } else { $script:UiTheme.Font }
    $label.ForeColor = if ($Muted) { $script:UiTheme.TextMuted } else { $script:UiTheme.TextPrimary }
    return $label
}

function New-UiTextBox {
    <#
    .SYNOPSIS
        Standard textbox with optional placeholder (kept in .Tag so handlers need no captured locals).
    #>
    param(
        [System.Drawing.Point]$Location,
        [System.Drawing.Size]$Size,
        [switch]$Multiline,
        [switch]$UsePasswordChar,
        [string]$PlaceholderText = ""
    )

    $textBox = New-Object System.Windows.Forms.TextBox
    if ($PSBoundParameters.ContainsKey('Location')) { $textBox.Location = $Location }
    if ($PSBoundParameters.ContainsKey('Size')) { $textBox.Size = $Size }
    $textBox.Font = $script:UiTheme.Font

    if ($Multiline) { $textBox.Multiline = $true }
    if ($UsePasswordChar) { $textBox.UseSystemPasswordChar = $true }

    if ($PlaceholderText) {
        $textBox.Tag = $PlaceholderText
        $textBox.ForeColor = $script:UiTheme.TextMuted
        $textBox.Text = $PlaceholderText
        $textBox.Add_GotFocus({
            if ($this.Text -eq $this.Tag) {
                $this.Text = ""
                $this.ForeColor = $script:UiTheme.TextPrimary
            }
        })
        $textBox.Add_LostFocus({
            if ([string]::IsNullOrWhiteSpace($this.Text)) {
                $this.Text = [string]$this.Tag
                $this.ForeColor = $script:UiTheme.TextMuted
            }
        })
    }

    return $textBox
}

function Get-FieldText {
    <#
    .SYNOPSIS
        Trimmed textbox value, treating an untouched placeholder as empty.
    #>
    param([System.Windows.Forms.TextBox]$TextBox)

    if ($TextBox.Tag -is [string] -and $TextBox.Text -eq $TextBox.Tag) { return '' }
    return $TextBox.Text.Trim()
}

function New-UiButton {
    param(
        [string]$Text,
        [System.Drawing.Point]$Location,
        [System.Drawing.Size]$Size,
        [switch]$Primary,
        [switch]$Danger
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    if ($PSBoundParameters.ContainsKey('Location')) { $button.Location = $Location }
    if ($PSBoundParameters.ContainsKey('Size')) { $button.Size = $Size }
    $button.Font = $script:UiTheme.Font
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.FlatAppearance.BorderSize = 1

    if ($Primary) {
        $button.BackColor = $script:UiTheme.Accent
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderColor = $script:UiTheme.Accent
        $button.Add_MouseEnter({ if ($this.Enabled) { $this.BackColor = $script:UiTheme.AccentHover } })
        $button.Add_MouseLeave({ if ($this.Enabled) { $this.BackColor = $script:UiTheme.Accent } })
    }
    else {
        $button.BackColor = $script:UiTheme.Surface
        $button.ForeColor = if ($Danger) { $script:UiTheme.Danger } else { $script:UiTheme.TextPrimary }
        $button.FlatAppearance.BorderColor = $script:UiTheme.Border
        $button.Add_MouseEnter({ if ($this.Enabled) { $this.BackColor = $script:UiTheme.AccentLight } })
        $button.Add_MouseLeave({ if ($this.Enabled) { $this.BackColor = $script:UiTheme.Surface } })
    }

    # Flat buttons ignore the system disabled look, so draw it explicitly.
    $button.Add_EnabledChanged({
        if (-not $this.Enabled) {
            $this.BackColor = $script:UiTheme.DisabledBackground
            $this.ForeColor = $script:UiTheme.TextDisabled
        }
        elseif ($this.Tag -eq 'primary') {
            $this.BackColor = $script:UiTheme.Accent
            $this.ForeColor = [System.Drawing.Color]::White
        }
        else {
            $this.BackColor = $script:UiTheme.Surface
            $this.ForeColor = if ($this.Tag -eq 'danger') { $script:UiTheme.Danger } else { $script:UiTheme.TextPrimary }
        }
    })
    $button.Tag = if ($Primary) { 'primary' } elseif ($Danger) { 'danger' } else { 'secondary' }

    return $button
}

function New-UiGroupBox {
    param(
        [string]$Text,
        [System.Windows.Forms.DockStyle]$Dock,
        [int]$Height = 0
    )

    $groupBox = New-Object System.Windows.Forms.GroupBox
    $groupBox.Text = $Text
    $groupBox.Dock = $Dock
    if ($Height -gt 0) { $groupBox.Height = $Height }
    $groupBox.Font = $script:UiTheme.FontStrong
    $groupBox.ForeColor = $script:UiTheme.TextPrimary
    return $groupBox
}

function Add-UiTooltip {
    param(
        [System.Windows.Forms.ToolTip]$ToolTip,
        [System.Windows.Forms.Control]$Control,
        [string]$Text
    )

    if ($ToolTip -and $Control -and $Text) { $ToolTip.SetToolTip($Control, $Text) }
}

# ====================================================================
# Helper Functions - Messages
# ====================================================================

function Show-MessageBox {
    param(
        [string]$Message,
        [string]$Title,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = 'OK',
        [System.Windows.Forms.MessageBoxIcon]$Icon = 'Information',
        [System.Windows.Forms.MessageBoxDefaultButton]$Default = 'Button1'
    )

    $owner = [System.Windows.Forms.Form]::ActiveForm
    if ($owner) {
        return [System.Windows.Forms.MessageBox]::Show([System.Windows.Forms.IWin32Window]$owner, $Message, $Title, $Buttons, $Icon, $Default)
    }
    return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon, $Default)
}

function Show-Info { param([string]$Message, [string]$Title = $script:AppName) [void](Show-MessageBox -Message $Message -Title $Title -Icon Information) }
function Show-Warning { param([string]$Message, [string]$Title = 'Check your input') [void](Show-MessageBox -Message $Message -Title $Title -Icon Warning) }
function Show-Failure { param([string]$Message, [string]$Title = 'Command failed') [void](Show-MessageBox -Message $Message -Title $Title -Icon Error) }

function Confirm-Action {
    param([string]$Message, [string]$Title = 'Please confirm')
    $answer = Show-MessageBox -Message $Message -Title $Title -Buttons YesNo -Icon Question -Default Button2
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Invoke-SafeAction {
    <#
    .SYNOPSIS
        Runs a UI action and reports errors instead of letting WinForms swallow them.
    #>
    param([scriptblock]$Action)

    try { & $Action }
    catch {
        Set-Status ("Failed: {0}" -f $_.Exception.Message)
        Show-Failure -Message $_.Exception.Message
    }
}

# ====================================================================
# Helper Functions - Layout (docked/table based, no hard-coded widths)
# ====================================================================

function New-UiPadding {
    param([int]$Left = 0, [int]$Top = 0, [int]$Right = 0, [int]$Bottom = 0)
    return New-Object System.Windows.Forms.Padding($Left, $Top, $Right, $Bottom)
}

function New-SectionGroup {
    <#
    .SYNOPSIS
        GroupBox that sizes itself to its content so no fixed height can clip a section.
        Padding.Top is small: a GroupBox already reserves room for its caption.
    #>
    param([string]$Text)

    $group = New-UiGroupBox -Text $Text -Dock ([System.Windows.Forms.DockStyle]::Fill)
    $group.AutoSize = $true
    $group.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $group.Padding = New-UiPadding $script:UiLayout.PaddingStandard 8 $script:UiLayout.PaddingStandard $script:UiLayout.PaddingStandard
    $group.Margin = New-UiPadding 0 0 0 $script:UiLayout.SectionGap
    return $group
}

function New-FieldGrid {
    <#
    .SYNOPSIS
        Two-column grid: fixed label column + stretching input column.
    #>
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock = [System.Windows.Forms.DockStyle]::Top
    $grid.AutoSize = $true
    $grid.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $grid.ColumnCount = 2
    $grid.BackColor = [System.Drawing.Color]::Transparent
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $script:UiLayout.LabelWidth)))
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    return $grid
}

function Add-GridRowStyle {
    param([System.Windows.Forms.TableLayoutPanel]$Grid, [int]$Height)

    $index = $Grid.RowStyles.Count
    [void]$Grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $Height)))
    $Grid.RowCount = $index + 1
    return $index
}

function Add-FieldRow {
    <#
    .SYNOPSIS
        "Label: [input]" row. The input stretches horizontally and is vertically centered.
    #>
    param(
        [System.Windows.Forms.TableLayoutPanel]$Grid,
        [string]$LabelText,
        [System.Windows.Forms.Control]$Control,
        [int]$Height = $script:UiLayout.FieldRowHeight
    )

    $row = Add-GridRowStyle -Grid $Grid -Height $Height

    $label = New-UiLabel -Text $LabelText
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.Margin = New-UiPadding 0 0 0 0
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $Grid.Controls.Add($label, 0, $row)

    $Control.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $Control.Margin = New-UiPadding 0 0 0 0
    $Grid.Controls.Add($Control, 1, $row)
}

function Add-FullWidthRow {
    param(
        [System.Windows.Forms.TableLayoutPanel]$Grid,
        [System.Windows.Forms.Control]$Control,
        [int]$Height
    )

    $row = Add-GridRowStyle -Grid $Grid -Height $Height
    $Control.Dock = [System.Windows.Forms.DockStyle]::Fill
    $Grid.Controls.Add($Control, 0, $row)
    $Grid.SetColumnSpan($Control, 2)
}

function Add-InputColumnRow {
    <#
    .SYNOPSIS
        Adds a control aligned with the inputs (second column), e.g. a checkbox.
    #>
    param(
        [System.Windows.Forms.TableLayoutPanel]$Grid,
        [System.Windows.Forms.Control]$Control,
        [int]$Height = 28
    )

    $row = Add-GridRowStyle -Grid $Grid -Height $Height
    $Control.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $Control.Margin = New-UiPadding 0 0 0 0
    $Grid.Controls.Add($Control, 1, $row)
}

function New-ButtonRow {
    <#
    .SYNOPSIS
        Equal-width buttons that follow the container width.
    #>
    param([System.Windows.Forms.Button[]]$Buttons)

    $row = New-Object System.Windows.Forms.TableLayoutPanel
    $row.ColumnCount = $Buttons.Count
    $row.RowCount = 1
    $row.BackColor = [System.Drawing.Color]::Transparent
    [void]$row.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    for ($i = 0; $i -lt $Buttons.Count; $i++) {
        [void]$row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, (100 / $Buttons.Count))))
        $gap = if ($i -lt ($Buttons.Count - 1)) { $script:UiLayout.ControlSpacing } else { 0 }
        $Buttons[$i].Dock = [System.Windows.Forms.DockStyle]::Fill
        $Buttons[$i].Margin = New-UiPadding 0 0 $gap 0
        $row.Controls.Add($Buttons[$i], $i, 0)
    }

    return $row
}

function Add-StackSection {
    param([System.Windows.Forms.TableLayoutPanel]$Column, [System.Windows.Forms.Control]$Section)

    $row = $Column.RowStyles.Count
    [void]$Column.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $Column.RowCount = $row + 1
    $Column.Controls.Add($Section, 0, $row)
}

function New-LeftColumn {
    <#
    .SYNOPSIS
        Scrollable host for the left column: a short window gets a scrollbar instead of clipped controls.
    #>
    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = [System.Windows.Forms.DockStyle]::Fill
    $scroll.AutoScroll = $true
    $scroll.Padding = New-UiPadding 0 0 $script:UiLayout.ControlSpacing 0

    $stack = New-Object System.Windows.Forms.TableLayoutPanel
    $stack.Dock = [System.Windows.Forms.DockStyle]::Top
    $stack.AutoSize = $true
    $stack.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $stack.ColumnCount = 1
    $stack.BackColor = [System.Drawing.Color]::Transparent
    [void]$stack.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $scroll.Controls.Add($stack)

    return [PSCustomObject]@{ Scroll = $scroll; Stack = $stack }
}

function New-BorderedHost {
    <#
    .SYNOPSIS
        1px bordered white surface; the border is drawn by the container so layout stays deterministic.
    #>
    param([int]$InnerPadding = 0)

    $outer = New-Object System.Windows.Forms.Panel
    $outer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $outer.BackColor = $script:UiTheme.Border
    $outer.Padding = New-UiPadding 1 1 1 1

    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $inner.BackColor = $script:UiTheme.Surface
    $inner.Padding = New-UiPadding $InnerPadding $InnerPadding $InnerPadding $InnerPadding
    $outer.Controls.Add($inner)

    return [PSCustomObject]@{ Outer = $outer; Inner = $inner }
}

# ====================================================================
# Dialog scaffolding
# ====================================================================

function New-DialogForm {
    param([string]$Title, [int]$Width = 440)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'CenterParent'
    $form.Font = $script:UiTheme.Font
    $form.BackColor = $script:UiTheme.PageBackground
    $form.Padding = New-UiPadding 24 20 24 20
    $form.ClientSize = New-Object System.Drawing.Size($Width, 200)
    return $form
}

function Complete-Dialog {
    param([System.Windows.Forms.Form]$Form, [System.Windows.Forms.TableLayoutPanel]$Grid)

    $Grid.Dock = [System.Windows.Forms.DockStyle]::Top
    $Form.Controls.Add($Grid)
    $Form.ClientSize = New-Object System.Drawing.Size($Form.ClientSize.Width, ($Grid.PreferredSize.Height + $Form.Padding.Vertical))
}

function Add-DialogHeading {
    param([System.Windows.Forms.TableLayoutPanel]$Grid, [string]$Title, [string]$Description)

    $heading = New-UiLabel -Text $Title
    $heading.Font = $script:UiTheme.FontTitle
    $heading.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    Add-FullWidthRow -Grid $Grid -Control $heading -Height 32

    if ($Description) {
        $intro = New-UiLabel -Text $Description -Muted
        $intro.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
        Add-FullWidthRow -Grid $Grid -Control $intro -Height 44
    }
}

function Add-DialogFooter {
    <#
    .SYNOPSIS
        Inline error message + right-aligned buttons. Returns the error label.
    #>
    param([System.Windows.Forms.TableLayoutPanel]$Grid, [System.Windows.Forms.Button[]]$Buttons)

    $errorLabel = New-UiLabel -Text ""
    $errorLabel.ForeColor = $script:UiTheme.Danger
    $errorLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    Add-FullWidthRow -Grid $Grid -Control $errorLabel -Height 28

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $bar.WrapContents = $false
    foreach ($button in $Buttons) {
        $button.Margin = New-UiPadding $script:UiLayout.ControlSpacing 0 0 0
        $bar.Controls.Add($button)
    }
    Add-FullWidthRow -Grid $Grid -Control $bar -Height ($script:UiLayout.ButtonHeightSmall + 8)

    return $errorLabel
}

# ====================================================================
# Validation, formatting and background execution
# ====================================================================

function Test-HostName {
    <#
    .SYNOPSIS
        Hostnames, IPv4 and IPv6. Rejects spaces and control characters.
    #>
    param([string]$Name)

    return ($Name -match '^[A-Za-z0-9._\-]{1,253}$') -or
           ($Name -match '^\[?[0-9A-Fa-f:.]{2,45}\]?$')
}

function Test-AdModule {
    return [bool](Get-Module -ListAvailable -Name ActiveDirectory)
}

function Format-AdValue {
    <#
    .SYNOPSIS
        Turns any AD attribute value into display text (collections joined, binary summarized).
    #>
    param($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) { return "<binary, $($Value.Length) bytes>" }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        return (@($Value | ForEach-Object { Format-AdValue $_ }) -join '; ')
    }
    return [string]$Value
}

function Format-FileTimeValue {
    <#
    .SYNOPSIS
        Appends a readable date to raw FILETIME numbers (lastLogon, pwdLastSet, ...).
    #>
    param([string]$Name, $Value)

    $text = Format-AdValue $Value
    if ($script:FileTimeAttributes -notcontains $Name) { return $text }

    $number = 0L
    if (-not [long]::TryParse($text, [ref]$number)) { return $text }
    if ($number -le 0) { return "$text (not set)" }
    if ($number -ge 9223372036854775807) { return "$text (never)" }
    try { return ('{0} ({1})' -f $text, [datetime]::FromFileTimeUtc($number).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')) }
    catch { return $text }
}

function Invoke-BackgroundScript {
    <#
    .SYNOPSIS
        Runs a script in its own runspace while the window keeps repainting, so slow AD or
        network calls never freeze the UI. Errors are rethrown with a clean message.
    #>
    param([scriptblock]$Script, [object[]]$Arguments = @())

    $worker = [powershell]::Create()
    try {
        # The prelude is its own statement so the script's param() block stays the first thing in its statement.
        if ($script:RunspacePrelude) { [void]$worker.AddScript($script:RunspacePrelude, $false).AddStatement() }
        [void]$worker.AddScript($Script.ToString())
        foreach ($argument in $Arguments) { [void]$worker.AddArgument($argument) }

        $pending = $worker.BeginInvoke()
        while (-not $pending.AsyncWaitHandle.WaitOne(50)) { [System.Windows.Forms.Application]::DoEvents() }

        try {
            # "," keeps the outputs together as ONE array (a single result must still be indexable).
            return , @($worker.EndInvoke($pending))
        }
        catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            throw $inner.Message
        }
    }
    finally {
        $worker.Dispose()
    }
}

function Set-Status {
    param([string]$Message)
    if ($script:UiRefs.StatusBar) { $script:UiRefs.StatusBar.Text = $Message }
}

function Set-Busy {
    param([bool]$Busy)

    $script:UiRefs.Form.UseWaitCursor = $Busy
    foreach ($button in $script:UiRefs.RunButtons) { $button.Enabled = (-not $Busy) -and ($button.Name -ne 'ad' -or $script:HasAdModule) }
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-ToolCommand {
    <#
    .SYNOPSIS
        Shared runner: busy state, command echo, timing and error reporting.
        The command text is only a display string; the real call is $Script.
    #>
    param(
        [string]$Title,
        [string]$CommandText,
        [scriptblock]$Script,
        [object[]]$Arguments
    )

    $script:UiRefs.CommandBox.Text = $CommandText
    Set-Status "Running $Title..."
    Set-Busy $true
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = Invoke-BackgroundScript -Script $Script -Arguments $Arguments
        Set-Status ("{0} finished in {1:N1}s" -f $Title, $watch.Elapsed.TotalSeconds)
        return , $result
    }
    finally {
        Set-Busy $false
    }
}

function Get-CommonAdArguments {
    <#
    .SYNOPSIS
        Optional domain controller and credential shared by every AD command.
    #>
    return @((Get-FieldText $script:UiRefs.ServerBox), $script:Credential)
}

# ====================================================================
# Results grid
# ====================================================================

function Escape-LikeValue {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Text.ToCharArray()) {
        switch ($char) {
            "'" { [void]$builder.Append("''") }
            '[' { [void]$builder.Append('[[]') }
            ']' { [void]$builder.Append('[]]') }
            '%' { [void]$builder.Append('[%]') }
            '*' { [void]$builder.Append('[*]') }
            default { [void]$builder.Append($char) }
        }
    }
    return $builder.ToString()
}

function Show-GridMessage {
    <#
    .SYNOPSIS
        Shows a centered message instead of the grid (empty state, missing RSAT, ...).
    #>
    param([string]$Message)

    $script:UiRefs.Grid.Visible = $false
    $script:UiRefs.GridMessage.Text = $Message
    $script:UiRefs.GridMessage.Visible = $true
}

function Show-Results {
    <#
    .SYNOPSIS
        Binds rows to the grid. Rows are objects with one property per column plus an optional
        State ('ok' / 'fail') used to color the Value column.
    #>
    param(
        [object[]]$Rows,
        [string[]]$Columns,
        [hashtable]$Widths = @{}
    )

    $grid = $script:UiRefs.Grid
    $table = New-Object System.Data.DataTable
    foreach ($name in $Columns) { [void]$table.Columns.Add($name, [string]) }
    [void]$table.Columns.Add('State', [string])

    foreach ($item in $Rows) {
        $row = $table.NewRow()
        foreach ($name in $Columns) { $row[$name] = [string]$item.$name }
        $row['State'] = [string]$item.State
        $table.Rows.Add($row)
    }

    $view = New-Object System.Data.DataView($table)
    $grid.DataSource = $view
    $grid.Columns['State'].Visible = $false

    foreach ($name in $Columns) {
        $column = $grid.Columns[$name]
        if ($Widths.ContainsKey($name)) {
            $column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
            $column.Width = $Widths[$name]
        }
        else {
            $column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
        }
    }

    $script:UiRefs.Columns = $Columns
    $script:UiRefs.View = $view
    $script:UiRefs.GridMessage.Visible = $false
    $grid.Visible = $true
    Apply-ResultFilter
}

function Apply-ResultFilter {
    $view = $script:UiRefs.View
    # "$null -eq" on purpose: an empty DataView is falsy in PowerShell, which would skip clearing the filter.
    if ($null -eq $view) { return }

    $term = Get-FieldText $script:UiRefs.FilterBox
    if (-not $term) {
        $view.RowFilter = ''
        return
    }

    $escaped = Escape-LikeValue $term
    $clauses = foreach ($name in $script:UiRefs.Columns) { "[$name] LIKE '%$escaped%'" }
    $view.RowFilter = ($clauses -join ' OR ')
}

function Get-ResultText {
    <#
    .SYNOPSIS
        Visible rows as tab-separated text (header included) for the clipboard.
    #>
    $view = $script:UiRefs.View
    if ($null -eq $view) { return '' }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($script:UiRefs.Columns -join "`t"))
    foreach ($rowView in $view) {
        $lines.Add((($script:UiRefs.Columns | ForEach-Object { [string]$rowView[$_] }) -join "`t"))
    }
    return ($lines -join "`r`n")
}

function Invoke-CopyResults {
    $text = Get-ResultText
    if (-not $text) { Set-Status 'Nothing to copy.'; return }
    [System.Windows.Forms.Clipboard]::SetText($text)
    Set-Status ("Copied {0} row(s) to the clipboard" -f $script:UiRefs.View.Count)
}

function Invoke-ExportResults {
    $view = $script:UiRefs.View
    if ($null -eq $view -or $view.Count -eq 0) { Set-Status 'Nothing to export.'; return }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV file (*.csv)|*.csv'
    $dialog.FileName = 'ADToolkit_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    try {
        if ($dialog.ShowDialog($script:UiRefs.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $view.ToTable() | Select-Object -Property $script:UiRefs.Columns | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8
        Set-Status ("Exported {0} row(s) to {1}" -f $view.Count, $dialog.FileName)
    }
    finally {
        $dialog.Dispose()
    }
}

# ====================================================================
# Command 1 - Get-ADUser (all properties)
# ====================================================================

$script:GetAdUserScript = {
    param([string]$Value, [string]$Server, $Credential)

    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory

    $common = @{}
    if ($Server) { $common.Server = $Server }
    if ($Credential) { $common.Credential = $Credential }

    # Single quotes are doubled so the value cannot break out of the filter string.
    $v = $Value.Replace("'", "''")
    $filter = "SamAccountName -eq '$v' -or UserPrincipalName -eq '$v' -or mail -eq '$v' -or DistinguishedName -eq '$v'"
    $users = @(Get-ADUser @common -Filter $filter -Properties *)
    if ($users.Count -eq 0) { throw "No user found for '$Value'." }
    , $users
}

function Invoke-GetAdUser {
    $value = Get-FieldText $script:UiRefs.Fields.UserIdentity
    if (-not $value) { Show-Warning -Message 'Enter a username, UPN or e-mail address.' -Title 'Missing user'; return }

    $arguments = @($value) + (Get-CommonAdArguments)
    $result = Invoke-ToolCommand -Title 'Get-ADUser' -Script $script:GetAdUserScript -Arguments $arguments `
        -CommandText ("Get-ADUser -Filter ""SamAccountName -eq '{0}' -or UserPrincipalName -eq '{0}' -or mail -eq '{0}'"" -Properties *" -f $value.Replace("'", "''"))

    $users = @($result[0])
    $user = $users[0]

    $names = if ($user.PSObject.Properties['PropertyNames']) { @($user.PropertyNames) } else { @($user.PSObject.Properties.Name) }
    $rows = foreach ($name in ($names | Sort-Object -Unique)) {
        $raw = try { $user.$name } catch { $null }
        [PSCustomObject]@{ Property = $name; Value = (Format-FileTimeValue -Name $name -Value $raw) }
    }

    Show-Results -Rows @($rows) -Columns @('Property', 'Value') -Widths @{ Property = 230 }
    $suffix = if ($users.Count -gt 1) { " ($($users.Count) accounts matched; showing the first)" } else { '' }
    Set-Status ("Get-ADUser: {0} properties for {1}{2}" -f @($rows).Count, $user.SamAccountName, $suffix)
}

# ====================================================================
# Command 2 - Get-ADGroupMember
# ====================================================================

$script:GetGroupMembersScript = {
    param([string]$Group, [bool]$Recursive, [string]$Server, $Credential)

    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory

    $common = @{}
    if ($Server) { $common.Server = $Server }
    if ($Credential) { $common.Credential = $Credential }

    # Resolve by name or sAMAccountName first, then query members by the unambiguous DN.
    $g = $Group.Replace("'", "''")
    $found = @(Get-ADGroup @common -Filter "SamAccountName -eq '$g' -or Name -eq '$g' -or DistinguishedName -eq '$g'")
    if ($found.Count -eq 0) { throw "No group found for '$Group'." }
    if ($found.Count -gt 1) { throw "'$Group' matches $($found.Count) groups; use the exact sAMAccountName." }

    $members = @(Get-ADGroupMember @common -Identity $found[0].DistinguishedName -Recursive:$Recursive)
    , @($found[0].Name, $members)
}

function Invoke-GroupMembers {
    $group = Get-FieldText $script:UiRefs.Fields.GroupName
    if (-not $group) { Show-Warning -Message 'Enter a group name.' -Title 'Missing group'; return }
    $recursive = [bool]$script:UiRefs.Fields.Recursive.Checked

    $arguments = @($group, $recursive) + (Get-CommonAdArguments)
    $result = Invoke-ToolCommand -Title 'Get-ADGroupMember' -Script $script:GetGroupMembersScript -Arguments $arguments `
        -CommandText ("Get-ADGroupMember -Identity '{0}'{1}" -f $group.Replace("'", "''"), $(if ($recursive) { ' -Recursive' } else { '' }))

    $groupName = $result[0][0]
    $members = @($result[0][1])
    $rows = foreach ($member in ($members | Sort-Object ObjectClass, Name)) {
        [PSCustomObject]@{
            Name = $member.Name
            SamAccountName = $member.SamAccountName
            ObjectClass = $member.objectClass
            DistinguishedName = $member.distinguishedName
        }
    }

    if ($members.Count -eq 0) {
        Show-GridMessage "Group '$groupName' has no members."
        $script:UiRefs.View = $null
    }
    else {
        Show-Results -Rows @($rows) -Columns @('Name', 'SamAccountName', 'ObjectClass', 'DistinguishedName') `
            -Widths @{ Name = 220; SamAccountName = 160; ObjectClass = 90 }
    }
    Set-Status ("Get-ADGroupMember: {0} member(s) in '{1}'" -f $members.Count, $groupName)
}

# ====================================================================
# Command 3 - Test-NetConnection
# ====================================================================

$script:TestNetScript = {
    param([string]$Computer, [string]$Port)

    $ErrorActionPreference = 'Stop'
    $arguments = @{ ComputerName = $Computer; InformationLevel = 'Detailed'; WarningAction = 'SilentlyContinue' }
    if ($Port) { $arguments.Port = [int]$Port }
    Test-NetConnection @arguments
}

function Invoke-NetTest {
    $computer = Get-FieldText $script:UiRefs.Fields.NetHost
    $port = Get-FieldText $script:UiRefs.Fields.NetPort

    if (-not $computer) { Show-Warning -Message 'Enter a hostname or IP address.' -Title 'Missing host'; return }
    if (-not (Test-HostName -Name $computer)) { Show-Warning -Message "'$computer' is not a valid hostname or IP address." -Title 'Invalid host'; return }
    if ($port -and (($port -notmatch '^\d{1,5}$') -or [int]$port -lt 1 -or [int]$port -gt 65535)) {
        Show-Warning -Message 'The port must be a number between 1 and 65535.' -Title 'Invalid port'; return
    }

    $result = Invoke-ToolCommand -Title 'Test-NetConnection' -Script $script:TestNetScript -Arguments @($computer, $port) `
        -CommandText ("Test-NetConnection -ComputerName {0}{1} -InformationLevel Detailed" -f $computer, $(if ($port) { " -Port $port" } else { '' }))
    $r = $result[0]

    $source = $r.SourceAddress
    $sourceText = if ($source -and $source.PSObject.Properties['IPAddress']) { [string]$source.IPAddress } else { Format-AdValue $source }

    $pingOk = [bool]$r.PingSucceeded
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add([PSCustomObject]@{ Property = 'ComputerName'; Value = $r.ComputerName })
    $rows.Add([PSCustomObject]@{ Property = 'RemoteAddress'; Value = (Format-AdValue $r.RemoteAddress) })
    $rows.Add([PSCustomObject]@{ Property = 'NameResolutionResults'; Value = (Format-AdValue $r.NameResolutionResults) })
    $rows.Add([PSCustomObject]@{ Property = 'InterfaceAlias'; Value = (Format-AdValue $r.InterfaceAlias) })
    $rows.Add([PSCustomObject]@{ Property = 'SourceAddress'; Value = $sourceText })
    $rows.Add([PSCustomObject]@{ Property = 'PingSucceeded'; Value = $pingOk; State = $(if ($pingOk) { 'ok' } else { 'fail' }) })
    if ($r.PingReplyDetails) {
        $rows.Add([PSCustomObject]@{ Property = 'PingRoundTrip (ms)'; Value = $r.PingReplyDetails.RoundtripTime })
    }
    if ($port) {
        $tcpOk = [bool]$r.TcpTestSucceeded
        $rows.Add([PSCustomObject]@{ Property = 'RemotePort'; Value = $r.RemotePort })
        $rows.Add([PSCustomObject]@{ Property = 'TcpTestSucceeded'; Value = $tcpOk; State = $(if ($tcpOk) { 'ok' } else { 'fail' }) })
    }

    Show-Results -Rows $rows.ToArray() -Columns @('Property', 'Value') -Widths @{ Property = 230 }
    $summary = if ($port) { "TCP $port " + $(if ([bool]$r.TcpTestSucceeded) { 'reachable' } else { 'NOT reachable' }) } else { 'ping ' + $(if ($pingOk) { 'succeeded' } else { 'failed' }) }
    Set-Status ("Test-NetConnection {0}: {1}" -f $computer, $summary)
}

# ====================================================================
# Command 4 - Set-ADAccountPassword (change using the CURRENT password)
# No -Reset: the domain policy here requires the old password, so this is a normal
# password change and needs no "Reset Password" permission.
# ====================================================================

$script:ResolveUserScript = {
    param([string]$Value, [string]$Server, $Credential)

    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory

    $common = @{}
    if ($Server) { $common.Server = $Server }
    if ($Credential) { $common.Credential = $Credential }

    $v = $Value.Replace("'", "''")
    $users = @(Get-ADUser @common -Filter "SamAccountName -eq '$v' -or UserPrincipalName -eq '$v' -or mail -eq '$v'" -Properties DisplayName, Enabled)
    if ($users.Count -eq 0) { throw "No user found for '$Value'." }
    if ($users.Count -gt 1) { throw "'$Value' matches $($users.Count) accounts; use the exact sAMAccountName." }

    $u = $users[0]
    [PSCustomObject]@{ DistinguishedName = $u.DistinguishedName; SamAccountName = $u.SamAccountName; DisplayName = $u.DisplayName; Enabled = $u.Enabled }
}

$script:ChangePasswordScript = {
    param([string]$DistinguishedName, [securestring]$OldPassword, [securestring]$NewPassword, [string]$Server, $Credential)

    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory

    $common = @{}
    if ($Server) { $common.Server = $Server }
    if ($Credential) { $common.Credential = $Credential }

    Set-ADAccountPassword @common -Identity $DistinguishedName -OldPassword $OldPassword -NewPassword $NewPassword
    'done'
}

function New-SecureStringFromText {
    param([string]$Text)

    $secure = New-Object System.Security.SecureString
    foreach ($char in $Text.ToCharArray()) { $secure.AppendChar($char) }
    $secure.MakeReadOnly()
    return $secure
}

function New-RandomPassword {
    <#
    .SYNOPSIS
        16-character password with upper, lower, digit and symbol, from a cryptographic RNG.
    #>
    param([int]$Length = 16)

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%&*?+-=')
    $all = ($sets -join '')
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = {
            param([string]$Pool)
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $Pool[[int]([BitConverter]::ToUInt32($bytes, 0) % $Pool.Length)]
        }
        $chars = New-Object System.Collections.Generic.List[char]
        foreach ($set in $sets) { $chars.Add((& $pick $set)) }
        while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }

        # Fisher-Yates shuffle so the guaranteed characters are not always first.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $j = [int]([BitConverter]::ToUInt32($bytes, 0) % ($i + 1))
            $swap = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $swap
        }
        return (-join $chars)
    }
    finally {
        $rng.Dispose()
    }
}

function Invoke-GeneratePassword {
    $fields = $script:UiRefs.Fields
    $password = New-RandomPassword
    $fields.NewPassword.Text = $password
    $fields.ConfirmPassword.Text = $password
    # Only the NEW password is revealed (so it can be copied); the current password stays hidden.
    $fields.NewPassword.UseSystemPasswordChar = $false
    $fields.ConfirmPassword.UseSystemPasswordChar = $false
    Set-Status 'Generated a password - copy it before you change.'
}

function Invoke-PasswordChange {
    $fields = $script:UiRefs.Fields
    $identity = Get-FieldText $fields.ChangeUser
    $oldPassword = $fields.OldPassword.Text
    $newPassword = $fields.NewPassword.Text
    $confirm = $fields.ConfirmPassword.Text

    if (-not $identity) { Show-Warning -Message 'Enter the account.' -Title 'Missing account'; return }
    if (-not $oldPassword) { Show-Warning -Message 'Enter the current password.' -Title 'Missing current password'; return }
    if (-not $newPassword) { Show-Warning -Message 'Enter the new password.' -Title 'Missing password'; return }
    if ($newPassword -cne $confirm) { Show-Warning -Message 'The two new passwords do not match.' -Title 'Passwords differ'; return }
    if ($newPassword -ceq $oldPassword) { Show-Warning -Message 'The new password must be different from the current one.' -Title 'Same password'; return }

    # Step 1: resolve the account so the operator confirms WHO is about to be changed.
    $common = Get-CommonAdArguments
    $resolved = (Invoke-ToolCommand -Title 'Get-ADUser (lookup)' -Script $script:ResolveUserScript -Arguments (@($identity) + $common) `
        -CommandText ("Get-ADUser -Filter ""SamAccountName -eq '{0}' ..."" -Properties DisplayName, Enabled" -f $identity.Replace("'", "''")))[0]

    $details = "Account:  {0}`nName:     {1}`nEnabled:  {2}`nDN:       {3}" -f $resolved.SamAccountName, $resolved.DisplayName, $resolved.Enabled, $resolved.DistinguishedName
    if (-not (Confirm-Action -Message "Change the password of this account?`n`n$details" -Title 'Change password')) {
        Set-Status 'Password change cancelled.'
        return
    }

    # Step 2: change. Both passwords only travel as SecureStrings and are never shown in the command line.
    $oldSecure = New-SecureStringFromText -Text $oldPassword
    $newSecure = New-SecureStringFromText -Text $newPassword
    try {
        [void](Invoke-ToolCommand -Title 'Set-ADAccountPassword' -Script $script:ChangePasswordScript `
            -Arguments (@($resolved.DistinguishedName, $oldSecure, $newSecure) + $common) `
            -CommandText ("Set-ADAccountPassword -Identity '{0}' -OldPassword (hidden) -NewPassword (hidden)" -f $resolved.SamAccountName))
    }
    finally {
        $oldSecure.Dispose()
        $newSecure.Dispose()
        foreach ($name in 'OldPassword', 'NewPassword', 'ConfirmPassword') {
            $fields[$name].Clear()
            $fields[$name].UseSystemPasswordChar = $true
        }
        $fields.ShowPasswords.Checked = $false
    }

    $rows = @(
        [PSCustomObject]@{ Property = 'Account'; Value = $resolved.SamAccountName },
        [PSCustomObject]@{ Property = 'Name'; Value = $resolved.DisplayName },
        [PSCustomObject]@{ Property = 'Result'; Value = 'Password changed'; State = 'ok' },
        [PSCustomObject]@{ Property = 'Time'; Value = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    )
    Show-Results -Rows $rows -Columns @('Property', 'Value') -Widths @{ Property = 230 }
    Set-Status ("Password changed for {0}" -f $resolved.SamAccountName)
}

# ====================================================================
# Run as (credentials) dialog
# ====================================================================

function Update-RunAsLabel {
    $text = if ($script:Credential) { $script:Credential.UserName } else { '{0}\{1} (current user)' -f $env:USERDOMAIN, $env:USERNAME }
    $script:UiRefs.RunAsLabel.Text = "Running as: $text"
}

function Invoke-RunAsSubmit {
    $state = $script:DialogState
    $user = $state.User.Text.Trim()
    if (-not $user -or -not $state.Password.Text) {
        $state.Error.Text = 'Enter both a username and a password.'
        return
    }
    $state.Result = New-Object System.Management.Automation.PSCredential($user, (New-SecureStringFromText -Text $state.Password.Text))
    $state.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
}

function Invoke-RunAs {
    $dialog = New-DialogForm -Title 'Run as' -Width 440
    $grid = New-FieldGrid
    Add-DialogHeading -Grid $grid -Title 'Run AD commands as' -Description 'Credentials are kept in memory only for this session and are passed to the AD cmdlets as -Credential.'

    $txtUser = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24))
    if ($script:Credential) { $txtUser.Text = $script:Credential.UserName }
    $txtPassword = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -UsePasswordChar
    Add-FieldRow -Grid $grid -LabelText 'Username:' -Control $txtUser
    Add-FieldRow -Grid $grid -LabelText 'Password:' -Control $txtPassword

    $btnUse = New-UiButton -Text 'Use' -Size (New-Object System.Drawing.Size(88, $script:UiLayout.ButtonHeightSmall)) -Primary
    $btnCancel = New-UiButton -Text 'Cancel' -Size (New-Object System.Drawing.Size(88, $script:UiLayout.ButtonHeightSmall))
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCurrent = New-UiButton -Text 'Current user' -Size (New-Object System.Drawing.Size(110, $script:UiLayout.ButtonHeightSmall))
    $btnCurrent.DialogResult = [System.Windows.Forms.DialogResult]::Retry
    $errorLabel = Add-DialogFooter -Grid $grid -Buttons @($btnUse, $btnCancel, $btnCurrent)

    $script:DialogState = @{ Form = $dialog; User = $txtUser; Password = $txtPassword; Error = $errorLabel; Result = $null }
    $btnUse.Add_Click({ Invoke-SafeAction { Invoke-RunAsSubmit } })
    $dialog.AcceptButton = $btnUse
    $dialog.CancelButton = $btnCancel
    $dialog.Add_Shown({ $state = $script:DialogState; if ($state.User.Text) { $state.Password.Focus() } else { $state.User.Focus() } })
    Complete-Dialog -Form $dialog -Grid $grid

    $result = $dialog.ShowDialog($script:UiRefs.Form)
    $credential = $script:DialogState.Result
    $dialog.Dispose()
    $script:DialogState = $null

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $script:Credential = $credential; Set-Status 'Running AD commands with the supplied account.' }
    elseif ($result -eq [System.Windows.Forms.DialogResult]::Retry) { $script:Credential = $null; Set-Status 'Running AD commands as the current user.' }
    Update-RunAsLabel
}

# ====================================================================
# UI Panel Creation Functions
# ====================================================================

function Create-HeaderPanel {
    <#
    .SYNOPSIS
        Title on the left; domain controller and "Run as" on the right.
    #>
    param([System.Windows.Forms.Form]$ParentForm, [System.Windows.Forms.ToolTip]$ToolTip)

    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headerPanel.Height = $script:UiLayout.HeaderHeight
    $headerPanel.BackColor = $script:UiTheme.Surface
    $headerPanel.Padding = New-UiPadding $script:UiLayout.PaddingStandard 10 $script:UiLayout.PaddingStandard 10

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 2
    $layout.RowCount = 1
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $stack = New-Object System.Windows.Forms.FlowLayoutPanel
    $stack.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $stack.WrapContents = $false
    $stack.AutoSize = $true
    $stack.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $title = New-UiLabel -Text $script:AppName -Strong
    $title.AutoSize = $true
    $title.Margin = New-UiPadding 0 0 0 2
    $hint = New-UiLabel -Text 'User lookup, group members, network test and password reset' -Muted
    $hint.AutoSize = $true
    $hint.Margin = New-UiPadding 0 0 0 0
    $stack.Controls.Add($title)
    $stack.Controls.Add($hint)
    $layout.Controls.Add($stack, 0, 0)

    $right = New-Object System.Windows.Forms.FlowLayoutPanel
    $right.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $right.WrapContents = $false
    $right.AutoSize = $true
    $right.Anchor = [System.Windows.Forms.AnchorStyles]::Right

    $lblServer = New-UiLabel -Text 'Domain controller:' -Muted -Width 110
    $lblServer.AutoSize = $true
    $lblServer.Margin = New-UiPadding 0 7 6 0
    $txtServer = New-UiTextBox -Size (New-Object System.Drawing.Size(170, 24)) -PlaceholderText 'auto-detect'
    $txtServer.Margin = New-UiPadding 0 3 16 0
    Add-UiTooltip -ToolTip $ToolTip -Control $txtServer -Text 'Optional: a specific domain controller (-Server) for the AD commands'

    $runAs = New-UiLabel -Text '' -Muted
    $runAs.AutoSize = $true
    $runAs.Margin = New-UiPadding 0 7 10 0
    $btnRunAs = New-UiButton -Text 'Run as...' -Size (New-Object System.Drawing.Size(96, $script:UiLayout.ButtonHeightSmall))
    $btnRunAs.Margin = New-UiPadding 0 0 0 0
    Add-UiTooltip -ToolTip $ToolTip -Control $btnRunAs -Text 'Run the AD commands with a different account (for example an admin account)'
    $btnRunAs.Add_Click({ Invoke-SafeAction { Invoke-RunAs } })

    $right.Controls.AddRange(@($lblServer, $txtServer, $runAs, $btnRunAs))
    $layout.Controls.Add($right, 1, 0)

    $headerPanel.Controls.Add($layout)
    $ParentForm.Controls.Add($headerPanel)

    $script:UiRefs.ServerBox = $txtServer
    $script:UiRefs.RunAsLabel = $runAs
    Update-RunAsLabel
    return $headerPanel
}

function Add-RunButton {
    <#
    .SYNOPSIS
        Registers a Run button; AD buttons are tagged so they can be disabled when RSAT is missing.
    #>
    param([System.Windows.Forms.Button]$Button, [bool]$RequiresAd)

    $Button.Name = if ($RequiresAd) { 'ad' } else { 'net' }
    $script:UiRefs.RunButtons += $Button
}

function Add-EnterKey {
    <#
    .SYNOPSIS
        Pressing Enter in a field runs that command.
    #>
    param([System.Windows.Forms.TextBox]$TextBox, [System.Windows.Forms.Button]$Button)

    $script:EnterButtons[$TextBox.GetHashCode()] = $Button
    $TextBox.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $_.SuppressKeyPress = $true
            $target = $script:EnterButtons[$this.GetHashCode()]
            if ($target -and $target.Enabled) { $target.PerformClick() }
        }
    })
}

function Create-UserPanel {
    param([System.Windows.Forms.TableLayoutPanel]$Column, [System.Windows.Forms.ToolTip]$ToolTip)

    $group = New-SectionGroup -Text 'User details (Get-ADUser)'
    $grid = New-FieldGrid

    $txtUser = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24))
    Add-UiTooltip -ToolTip $ToolTip -Control $txtUser -Text 'sAMAccountName, UPN, e-mail or distinguished name'
    Add-FieldRow -Grid $grid -LabelText 'User:' -Control $txtUser

    $btn = New-UiButton -Text 'Get all properties' -Size (New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightLarge)) -Primary
    $btn.Margin = New-UiPadding 0 $script:UiLayout.ControlSpacing 0 0
    $btn.Add_Click({ Invoke-SafeAction { Invoke-GetAdUser } })
    Add-FullWidthRow -Grid $grid -Control $btn -Height ($script:UiLayout.ButtonHeightLarge + $script:UiLayout.ControlSpacing)

    $group.Controls.Add($grid)
    Add-StackSection -Column $Column -Section $group
    $script:UiRefs.Fields.UserIdentity = $txtUser
    Add-RunButton -Button $btn -RequiresAd $true
    Add-EnterKey -TextBox $txtUser -Button $btn
}

function Create-GroupPanel {
    param([System.Windows.Forms.TableLayoutPanel]$Column, [System.Windows.Forms.ToolTip]$ToolTip)

    $group = New-SectionGroup -Text 'Group members (Get-ADGroupMember)'
    $grid = New-FieldGrid

    $txtGroup = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24))
    Add-UiTooltip -ToolTip $ToolTip -Control $txtGroup -Text 'Group name or sAMAccountName'
    Add-FieldRow -Grid $grid -LabelText 'Group:' -Control $txtGroup

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = 'Include nested groups (-Recursive)'
    $chk.Font = $script:UiTheme.Font
    $chk.AutoSize = $true
    Add-UiTooltip -ToolTip $ToolTip -Control $chk -Text 'Also list members of groups inside this group'
    Add-InputColumnRow -Grid $grid -Control $chk

    $btn = New-UiButton -Text 'List members' -Size (New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightLarge)) -Primary
    $btn.Margin = New-UiPadding 0 $script:UiLayout.ControlSpacing 0 0
    $btn.Add_Click({ Invoke-SafeAction { Invoke-GroupMembers } })
    Add-FullWidthRow -Grid $grid -Control $btn -Height ($script:UiLayout.ButtonHeightLarge + $script:UiLayout.ControlSpacing)

    $group.Controls.Add($grid)
    Add-StackSection -Column $Column -Section $group
    $script:UiRefs.Fields.GroupName = $txtGroup
    $script:UiRefs.Fields.Recursive = $chk
    Add-RunButton -Button $btn -RequiresAd $true
    Add-EnterKey -TextBox $txtGroup -Button $btn
}

function Create-NetPanel {
    param([System.Windows.Forms.TableLayoutPanel]$Column, [System.Windows.Forms.ToolTip]$ToolTip)

    $group = New-SectionGroup -Text 'Network test (Test-NetConnection)'
    $grid = New-FieldGrid

    $txtHost = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24))
    Add-UiTooltip -ToolTip $ToolTip -Control $txtHost -Text 'Hostname or IP address'
    Add-FieldRow -Grid $grid -LabelText 'Host:' -Control $txtHost

    $txtPort = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -PlaceholderText 'optional, e.g. 3389'
    Add-UiTooltip -ToolTip $ToolTip -Control $txtPort -Text 'Leave empty for a ping only; enter a port for a TCP test'
    Add-FieldRow -Grid $grid -LabelText 'Port:' -Control $txtPort

    $btn = New-UiButton -Text 'Test connection' -Size (New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightLarge)) -Primary
    $btn.Margin = New-UiPadding 0 $script:UiLayout.ControlSpacing 0 0
    $btn.Add_Click({ Invoke-SafeAction { Invoke-NetTest } })
    Add-FullWidthRow -Grid $grid -Control $btn -Height ($script:UiLayout.ButtonHeightLarge + $script:UiLayout.ControlSpacing)

    $group.Controls.Add($grid)
    Add-StackSection -Column $Column -Section $group
    $script:UiRefs.Fields.NetHost = $txtHost
    $script:UiRefs.Fields.NetPort = $txtPort
    Add-RunButton -Button $btn -RequiresAd $false
    Add-EnterKey -TextBox $txtHost -Button $btn
    Add-EnterKey -TextBox $txtPort -Button $btn
}

function Create-PasswordPanel {
    param([System.Windows.Forms.TableLayoutPanel]$Column, [System.Windows.Forms.ToolTip]$ToolTip)

    $group = New-SectionGroup -Text 'Change password (Set-ADAccountPassword)'
    $group.Margin = New-UiPadding 0 0 0 0
    $grid = New-FieldGrid

    $txtUser = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24))
    Add-UiTooltip -ToolTip $ToolTip -Control $txtUser -Text 'sAMAccountName, UPN or e-mail of the account'
    Add-FieldRow -Grid $grid -LabelText 'Account:' -Control $txtUser

    $txtOld = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -UsePasswordChar
    Add-UiTooltip -ToolTip $ToolTip -Control $txtOld -Text 'The password the account has now (required by the domain)'
    $txtNew = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -UsePasswordChar
    $txtConfirm = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -UsePasswordChar
    Add-FieldRow -Grid $grid -LabelText 'Current password:' -Control $txtOld
    Add-FieldRow -Grid $grid -LabelText 'New password:' -Control $txtNew
    Add-FieldRow -Grid $grid -LabelText 'Confirm new:' -Control $txtConfirm

    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = 'Show passwords'
    $chkShow.Font = $script:UiTheme.Font
    $chkShow.AutoSize = $true
    $chkShow.Add_CheckedChanged({
        $hide = -not $this.Checked
        foreach ($name in 'OldPassword', 'NewPassword', 'ConfirmPassword') { $script:UiRefs.Fields[$name].UseSystemPasswordChar = $hide }
    })
    Add-InputColumnRow -Grid $grid -Control $chkShow

    $btnGenerate = New-UiButton -Text 'Generate new' -Size (New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightLarge))
    Add-UiTooltip -ToolTip $ToolTip -Control $btnGenerate -Text 'Fill the new-password fields with a random 16-character password'
    $btnGenerate.Add_Click({ Invoke-SafeAction { Invoke-GeneratePassword } })
    $btnChange = New-UiButton -Text 'Change password' -Size (New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightLarge)) -Primary
    Add-UiTooltip -ToolTip $ToolTip -Control $btnChange -Text 'Look up the account, ask for confirmation, then change the password'
    $btnChange.Add_Click({ Invoke-SafeAction { Invoke-PasswordChange } })
    $buttons = New-ButtonRow -Buttons @($btnGenerate, $btnChange)
    $buttons.Margin = New-UiPadding 0 $script:UiLayout.ControlSpacing 0 0
    Add-FullWidthRow -Grid $grid -Control $buttons -Height ($script:UiLayout.ButtonHeightLarge + $script:UiLayout.ControlSpacing)

    $group.Controls.Add($grid)
    Add-StackSection -Column $Column -Section $group
    $script:UiRefs.Fields.ChangeUser = $txtUser
    $script:UiRefs.Fields.OldPassword = $txtOld
    $script:UiRefs.Fields.NewPassword = $txtNew
    $script:UiRefs.Fields.ConfirmPassword = $txtConfirm
    $script:UiRefs.Fields.ShowPasswords = $chkShow
    Add-RunButton -Button $btnChange -RequiresAd $true
}

function Create-ResultsPanel {
    <#
    .SYNOPSIS
        Results card: command echo, filter + copy/export toolbar, and the grid.

        DOCK ORDER MATTERS: WinForms lays out docked children from the HIGHEST child
        index down to 0, so the Fill grid host is added FIRST, then the toolbar, then the
        command bar (docked first = top-most). Reversing it makes the grid paint under the bars.
    #>
    param([System.Windows.Forms.SplitContainer]$Split, [System.Windows.Forms.ToolTip]$ToolTip)

    $group = New-UiGroupBox -Text 'Results' -Dock ([System.Windows.Forms.DockStyle]::Fill)
    $group.Padding = New-UiPadding $script:UiLayout.PaddingStandard 8 $script:UiLayout.PaddingStandard $script:UiLayout.PaddingStandard

    # ---- Grid host ----
    $gridHost = New-BorderedHost
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.Font = $script:UiTheme.Font
    $grid.BackgroundColor = $script:UiTheme.Surface
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $grid.GridColor = $script:UiTheme.Border
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $script:UiTheme.GridHeader
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:UiTheme.TextPrimary
    $grid.ColumnHeadersDefaultCellStyle.Font = $script:UiTheme.FontStrong
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:UiTheme.GridHeader
    $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $script:UiTheme.TextPrimary
    $grid.ColumnHeadersHeight = 30
    $grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
    $grid.RowHeadersVisible = $false
    $grid.RowTemplate.Height = 26
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.MultiSelect = $true
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $script:UiTheme.GridAlternate
    $grid.DefaultCellStyle.SelectionBackColor = $script:UiTheme.AccentLight
    $grid.DefaultCellStyle.SelectionForeColor = $script:UiTheme.TextPrimary
    $grid.Visible = $false
    $grid.Add_CellFormatting({
        # Color the Value cell of rows flagged ok / fail (ping and TCP results, reset result).
        if ($_.RowIndex -lt 0) { return }
        $g = $this
        if ($g.Columns[$_.ColumnIndex].Name -ne 'Value') { return }
        $state = [string]$g.Rows[$_.RowIndex].Cells['State'].Value
        if ($state -eq 'ok') { $_.CellStyle.ForeColor = $script:UiTheme.Success; $_.CellStyle.Font = $script:UiTheme.FontStrong }
        elseif ($state -eq 'fail') { $_.CellStyle.ForeColor = $script:UiTheme.Danger; $_.CellStyle.Font = $script:UiTheme.FontStrong }
    })
    $gridHost.Inner.Controls.Add($grid)

    $message = New-UiLabel -Text '' -Muted
    $message.AutoSize = $false
    $message.Dock = [System.Windows.Forms.DockStyle]::Fill
    $message.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $gridHost.Inner.Controls.Add($message)

    # ---- Toolbar: Filter [........] [Copy] [Export CSV] ----
    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Top
    $toolbar.Height = $script:UiLayout.ToolbarHeight
    $toolbar.Padding = New-UiPadding 0 0 0 $script:UiLayout.ControlSpacing

    $bar = New-Object System.Windows.Forms.TableLayoutPanel
    $bar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bar.ColumnCount = 4
    $bar.RowCount = 1
    [void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 52)))
    [void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$bar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$bar.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $lblFilter = New-UiLabel -Text 'Filter:' -Width 52
    $lblFilter.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblFilter.Margin = New-UiPadding 0 0 0 0
    $lblFilter.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $bar.Controls.Add($lblFilter, 0, 0)

    $txtFilter = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -PlaceholderText 'Filter results...'
    $txtFilter.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $txtFilter.Margin = New-UiPadding 0 0 8 0
    Add-UiTooltip -ToolTip $ToolTip -Control $txtFilter -Text 'Show only rows containing this text (Ctrl+F)'
    $txtFilter.Add_TextChanged({ Invoke-SafeAction { Apply-ResultFilter } })
    $txtFilter.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $_.SuppressKeyPress = $true; $this.Text = '' }
    })
    $bar.Controls.Add($txtFilter, 1, 0)

    $btnCopy = New-UiButton -Text 'Copy' -Size (New-Object System.Drawing.Size(80, $script:UiLayout.ButtonHeightSmall))
    $btnCopy.Margin = New-UiPadding 0 0 8 0
    $btnCopy.Anchor = [System.Windows.Forms.AnchorStyles]::None
    Add-UiTooltip -ToolTip $ToolTip -Control $btnCopy -Text 'Copy the visible rows (tab-separated) to the clipboard'
    $btnCopy.Add_Click({ Invoke-SafeAction { Invoke-CopyResults } })
    $bar.Controls.Add($btnCopy, 2, 0)

    $btnExport = New-UiButton -Text 'Export CSV' -Size (New-Object System.Drawing.Size(96, $script:UiLayout.ButtonHeightSmall))
    $btnExport.Margin = New-UiPadding 0 0 0 0
    $btnExport.Anchor = [System.Windows.Forms.AnchorStyles]::None
    Add-UiTooltip -ToolTip $ToolTip -Control $btnExport -Text 'Save the visible rows to a CSV file'
    $btnExport.Add_Click({ Invoke-SafeAction { Invoke-ExportResults } })
    $bar.Controls.Add($btnExport, 3, 0)
    $toolbar.Controls.Add($bar)

    # ---- Command bar (echo of the executed command) ----
    $commandBar = New-Object System.Windows.Forms.Panel
    $commandBar.Dock = [System.Windows.Forms.DockStyle]::Top
    $commandBar.Height = 38
    $commandBar.Padding = New-UiPadding 0 0 0 $script:UiLayout.ControlSpacing

    $txtCommand = New-Object System.Windows.Forms.TextBox
    $txtCommand.Dock = [System.Windows.Forms.DockStyle]::Fill
    $txtCommand.Font = $script:UiTheme.FontMono
    $txtCommand.ReadOnly = $true
    $txtCommand.BackColor = $script:UiTheme.GridHeader
    $txtCommand.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $txtCommand.Text = 'PS> '
    Add-UiTooltip -ToolTip $ToolTip -Control $txtCommand -Text 'The PowerShell command that produced the results below'
    $commandBar.Controls.Add($txtCommand)

    # Order matters - see the DOCK ORDER note above.
    $group.Controls.Add($gridHost.Outer)    # Fill (index 0)
    $group.Controls.Add($toolbar)           # Top
    $group.Controls.Add($commandBar)        # Top (docked first, top-most)
    $Split.Panel2.Controls.Add($group)

    $script:UiRefs.Grid = $grid
    $script:UiRefs.GridMessage = $message
    $script:UiRefs.FilterBox = $txtFilter
    $script:UiRefs.CommandBox = $txtCommand
}

function Create-StatusBar {
    param([System.Windows.Forms.Form]$ParentForm)

    $statusBar = New-Object System.Windows.Forms.StatusBar
    $statusBar.Font = $script:UiTheme.Font
    $statusBar.Text = 'Ready'
    $ParentForm.Controls.Add($statusBar)
    $script:UiRefs.StatusBar = $statusBar
    return $statusBar
}

function Set-SplitLayout {
    <#
    .SYNOPSIS
        Applies splitter limits once the control has its real size (setting them earlier can throw).
        FixedPanel = Panel1 keeps the left column width and gives extra width to the results.
    #>
    param([System.Windows.Forms.SplitContainer]$Split)

    $Split.Panel1MinSize = $script:UiLayout.LeftMinWidth
    $Split.Panel2MinSize = $script:UiLayout.RightMinWidth

    $maxDistance = $Split.Width - $Split.Panel2MinSize - $Split.SplitterWidth
    $distance = [Math]::Min($script:UiLayout.SplitterDefault, $maxDistance)
    $Split.SplitterDistance = [Math]::Max($script:UiLayout.LeftMinWidth, $distance)
    $Split.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel1
}

# ====================================================================
# Main Form
# ====================================================================

function Show-MainForm {
    $script:HasAdModule = Test-AdModule
    $script:EnterButtons = @{}

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $script:AppName
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size(1180, [Math]::Min(900, ($workArea.Height - 40)))
    $form.MinimumSize = New-Object System.Drawing.Size(940, 640)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $script:UiTheme.Font
    $form.BackColor = $script:UiTheme.PageBackground
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.KeyPreview = $true
    $script:UiRefs.Form = $form

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 9000
    $toolTip.InitialDelay = 250
    $toolTip.ReshowDelay = 100
    $toolTip.ShowAlways = $true

    # Form-level docking: the Fill panel is added FIRST so it is laid out LAST and only
    # receives the space left by the header and status bar (see DOCK ORDER notes).
    $mainPanel = New-Object System.Windows.Forms.Panel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.Padding = New-Object System.Windows.Forms.Padding(12)
    $form.Controls.Add($mainPanel)                       # index 0 - Fill
    [void](Create-StatusBar -ParentForm $form)           # index 1 - Bottom
    [void](Create-HeaderPanel -ParentForm $form -ToolTip $toolTip)   # index 2 - Top

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = [System.Windows.Forms.DockStyle]::Fill
    $split.BackColor = $script:UiTheme.PageBackground
    $split.Panel1.BackColor = $script:UiTheme.PageBackground
    $split.Panel2.BackColor = $script:UiTheme.PageBackground
    $mainPanel.Controls.Add($split)
    $script:UiRefs.Split = $split

    Create-ResultsPanel -Split $split -ToolTip $toolTip

    $left = New-LeftColumn
    $split.Panel1.Controls.Add($left.Scroll)
    $script:UiRefs.LeftScroll = $left.Scroll
    Create-UserPanel -Column $left.Stack -ToolTip $toolTip
    Create-GroupPanel -Column $left.Stack -ToolTip $toolTip
    Create-NetPanel -Column $left.Stack -ToolTip $toolTip
    Create-PasswordPanel -Column $left.Stack -ToolTip $toolTip

    if ($script:HasAdModule) {
        Show-GridMessage "Run a command from the left.`nThe result appears here and can be filtered, copied or exported."
    }
    else {
        foreach ($button in $script:UiRefs.RunButtons) { if ($button.Name -eq 'ad') { $button.Enabled = $false } }
        Show-GridMessage ("The ActiveDirectory PowerShell module (RSAT) was not found, so the AD commands are disabled.`n`n" +
            "Install it from an elevated PowerShell:`nAdd-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`n`n" +
            "Test-NetConnection is still available.")
        Set-Status 'ActiveDirectory module not found - only Test-NetConnection is available.'
    }

    $form.Add_KeyDown({
        if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::F) {
            $_.SuppressKeyPress = $true
            $script:UiRefs.FilterBox.Focus()
            $script:UiRefs.FilterBox.SelectAll()
        }
    })

    $form.Add_Shown({
        $this.Activate()
        Set-SplitLayout -Split $script:UiRefs.Split
        # Avoid AutoScroll jumping to a focused control at the bottom of the left column.
        $this.ActiveControl = $script:UiRefs.Fields.UserIdentity
        $script:UiRefs.LeftScroll.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    })

    [void]$form.ShowDialog()
}

# ====================================================================
# Entry Point
# ====================================================================

function Start-ADToolkit {
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { Write-Verbose $_.Exception.Message }
    try { Show-MainForm }
    finally { $script:Credential = $null }
}

# Skipped when dot-sourced so the functions can be loaded without starting the UI.
if ($MyInvocation.InvocationName -ne '.') {
    Start-ADToolkit
}
