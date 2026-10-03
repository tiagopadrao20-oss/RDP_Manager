# ====================================================================
# RDP Connection Manager
#
# - Signs in against Active Directory and remembers the account in
#   Windows Credential Manager.
# - Stores connections in savedconnections.xml (CLIXML, schema v2),
#   grouped Market -> Environment -> Server Type.
# - Starts sessions through a temporary .rdp file and mstsc.exe.
#
# Shortcuts: Ctrl+F search | Enter connect | F2 edit | Del remove
#
# NOTE ON EVENT HANDLERS
# PowerShell event handlers (Add_Click, Add_TextChanged, ...) do NOT see the
# local variables/parameters of a function that has already returned.
# Shared UI state therefore lives in $script:UiRefs / $script:DialogState and
# per-control state in .Tag - never in captured locals.
# ====================================================================

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.DirectoryServices

# ====================================================================
# Native helpers (Windows Credential Manager)
# Writing credentials through the API keeps passwords off command lines
# (cmdkey /pass: is visible to other processes) and avoids parsing
# localized cmdkey output.
# ====================================================================

if (-not ('RdpManager.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace RdpManager
{
    public static class Native
    {
        private const uint CRED_TYPE_GENERIC = 1;
        private const uint CRED_PERSIST_LOCAL_MACHINE = 2;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public uint Flags;
            public uint Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, uint type, uint flags);

        [DllImport("advapi32.dll")]
        private static extern void CredFree(IntPtr buffer);

        public static void WriteCredential(string target, string userName, string password)
        {
            IntPtr blob = Marshal.StringToCoTaskMemUni(password);
            try
            {
                CREDENTIAL credential = new CREDENTIAL();
                credential.Type = CRED_TYPE_GENERIC;
                credential.TargetName = target;
                credential.UserName = userName;
                credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
                credential.CredentialBlobSize = (uint)(password.Length * 2);
                credential.CredentialBlob = blob;
                if (!CredWrite(ref credential, 0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                Marshal.ZeroFreeCoTaskMemUnicode(blob);
            }
        }

        public static string ReadUserName(string target)
        {
            IntPtr buffer;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out buffer))
            {
                return null;
            }

            try
            {
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(buffer, typeof(CREDENTIAL));
                return credential.UserName;
            }
            finally
            {
                CredFree(buffer);
            }
        }

        public static bool DeleteCredential(string target)
        {
            return CredDelete(target, CRED_TYPE_GENERIC, 0);
        }
    }
}
'@
}

# ====================================================================
# Configuration and state
# ====================================================================

$script:AppName = 'RDP Connection Manager'
$script:SchemaVersion = 2
$script:AdCredentialTarget = 'RDPManager_ADCreds'
$script:TempFileLifetimeMs = 30000
$script:BackupsToKeep = 5

$script:DefaultMarkets = @('PT', 'ES', 'DE', 'UK', 'GR', 'NL', 'UNK')
$script:DefaultEnvironments = @('DEV', 'REC', 'INT', 'CONS', 'PROD', 'OTHER')
$script:LegacyEnvironmentMap = @{ 'PRD' = 'PROD'; 'PRE' = 'REC'; 'UAT' = 'INT'; 'TEST' = 'INT' }

$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:StorePath = Join-Path $script:AppRoot 'savedconnections.xml'

$script:Connections = New-Object 'System.Collections.Generic.List[object]'
$script:FilteredConnections = @()
$script:TempFiles = New-Object 'System.Collections.Generic.List[string]'
$script:CurrentUsername = $null
$script:CurrentPassword = $null
$script:DialogState = $null

# Shared references used by event handlers (see note at the top of the file).
$script:UiRefs = @{
    Form = $null
    TreeView = $null
    SearchBox = $null
    Split = $null
    LeftScroll = $null
    StatusBar = $null
    UserLabel = $null
    HintLabel = $null
    QuickHost = $null
    AddFields = $null
    EditButton = $null
    RemoveButton = $null
    FavoriteButton = $null
}

# ====================================================================
# Layout Constants (Design Token System)
# ====================================================================

$script:UiLayout = [PSCustomObject]@{
    # Spacing & Padding (8px grid system)
    FieldRowHeight = 36            # Height of one label/input row
    NotesRowHeight = 72            # Multiline notes row
    PaddingStandard = 16           # Standard panel padding
    PaddingLarge = 24              # Large panel padding
    ControlSpacing = 8             # Space between related controls
    SectionGap = 12                # Vertical gap between left-column sections

    # Control Dimensions
    LabelWidth = 110               # Standard label column width
    ButtonHeightSmall = 32         # Secondary button height
    ButtonHeightLarge = 40         # Primary button height

    # Panels
    HeaderHeight = 72              # Header panel (two text lines + padding)
    FilterRowHeight = 40           # Library filter row (includes 8px breathing room below)

    # SplitContainer
    SplitterDefault = 420          # Initial width of the left column
    LeftMinWidth = 380             # Left column never collapses below this
    RightMinWidth = 420            # Connection Library never becomes unusably narrow

    # TreeView
    TreeItemHeight = 26            # Compact but comfortable rows
    TreeIndent = 22                # Clear indentation per level
    TreeInnerPadding = 6           # White space between tree border and first/last node
}

# ====================================================================
# UI Theme Configuration
# ====================================================================

$script:UiTheme = [PSCustomObject]@{
    # Typography (Segoe UI everywhere)
    Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
    FontStrong = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
    FontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 11, [System.Drawing.FontStyle]::Bold)
    FontTreeMarket = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)
    FontTreeEnvironment = New-Object System.Drawing.Font("Segoe UI Semibold", 9, [System.Drawing.FontStyle]::Regular)

    # Colors - Surface
    Surface = [System.Drawing.Color]::White
    PageBackground = [System.Drawing.Color]::FromArgb(245, 247, 250)

    # Colors - Interactive
    Accent = [System.Drawing.Color]::FromArgb(0, 120, 212)        # Microsoft Blue
    AccentHover = [System.Drawing.Color]::FromArgb(0, 99, 177)    # Darker on hover
    AccentLight = [System.Drawing.Color]::FromArgb(232, 243, 255) # Light blue background
    Danger = [System.Drawing.Color]::FromArgb(192, 40, 28)

    # Colors - Text
    TextPrimary = [System.Drawing.Color]::FromArgb(40, 40, 40)
    TextMuted = [System.Drawing.Color]::FromArgb(90, 90, 90)
    TextDisabled = [System.Drawing.Color]::FromArgb(160, 160, 160)
    TextMarket = [System.Drawing.Color]::FromArgb(20, 20, 20)     # Strongest level in the tree

    # Colors - States
    Border = [System.Drawing.Color]::FromArgb(216, 220, 227)
    DisabledBackground = [System.Drawing.Color]::FromArgb(238, 240, 243)

    # Tree symbols (ASCII-safe; indentation comes from TreeView.Indent, not from padding spaces)
    IconMarket = "[M]"
    IconEnvironment = ">"
    IconServerType = "-"
    IconConnection = [string][char]0x00B7   # middle dot, built from a code point to keep this file ASCII-only
    IconFavorite = "*"
}

# ====================================================================
# Helper Functions - UI Element Creation
# ====================================================================

function New-UiLabel {
    <#
    .SYNOPSIS
        Creates a standardized label with consistent styling.
    #>
    param(
        [string]$Text,
        [System.Drawing.Point]$Location,
        [int]$Width = $script:UiLayout.LabelWidth,
        [switch]$Strong,
        [switch]$Muted
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    # Location is optional: controls placed in a table/dock layout are positioned by their container.
    if ($PSBoundParameters.ContainsKey('Location')) { $label.Location = $Location }
    $label.Size = New-Object System.Drawing.Size($Width, 22)
    $label.Font = if ($Strong) { $script:UiTheme.FontStrong } else { $script:UiTheme.Font }
    $label.ForeColor = if ($Muted) { $script:UiTheme.TextMuted } else { $script:UiTheme.TextPrimary }
    return $label
}

function New-UiTextBox {
    <#
    .SYNOPSIS
        Creates a standardized textbox with optional placeholder text.
        The placeholder is kept in .Tag so the handlers do not depend on captured locals.
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

    if ($Multiline) {
        $textBox.Multiline = $true
    }
    if ($UsePasswordChar) {
        $textBox.UseSystemPasswordChar = $true
    }

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

function New-UiButton {
    <#
    .SYNOPSIS
        Creates a standardized button with hover effects and visual hierarchy.
    #>
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
    <#
    .SYNOPSIS
        Creates a standardized group box container.
    #>
    param(
        [string]$Text,
        [System.Windows.Forms.DockStyle]$Dock,
        [int]$Height = 0
    )

    $groupBox = New-Object System.Windows.Forms.GroupBox
    $groupBox.Text = $Text
    $groupBox.Dock = $Dock
    if ($Height -gt 0) {
        $groupBox.Height = $Height
    }
    $groupBox.Font = $script:UiTheme.FontStrong
    $groupBox.ForeColor = $script:UiTheme.TextPrimary
    return $groupBox
}

function Add-UiTooltip {
    <#
    .SYNOPSIS
        Adds a tooltip to a control.
    #>
    param(
        [System.Windows.Forms.ToolTip]$ToolTip,
        [System.Windows.Forms.Control]$Control,
        [string]$Text
    )

    if ($ToolTip -and $Control -and $Text) {
        $ToolTip.SetToolTip($Control, $Text)
    }
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
function Show-Failure { param([string]$Message, [string]$Title = 'Something went wrong') [void](Show-MessageBox -Message $Message -Title $Title -Icon Error) }

function Confirm-Action {
    param([string]$Message, [string]$Title = 'Please confirm')
    $answer = Show-MessageBox -Message $Message -Title $Title -Buttons YesNo -Icon Question -Default Button2
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Invoke-SafeAction {
    <#
    .SYNOPSIS
        Runs a UI action and reports unexpected errors instead of letting WinForms swallow them.
    #>
    param([scriptblock]$Action)

    try { & $Action }
    catch { Show-Failure -Message $_.Exception.Message -Title 'Unexpected error' }
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
        GroupBox for the left column. It sizes itself to its content (AutoSize) so
        no fixed height can clip a section.
        Padding.Top is small on purpose: a GroupBox already reserves room for its
        caption inside DisplayRectangle, so a large top padding would double-count it.
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
        Dock=Top + AutoSize lets the parent GroupBox grow to fit the rows.
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
        Adds "Label: [input]" to a field grid. The input stretches horizontally; without
        -Stretch it is vertically centered in its row (Anchor Left+Right only).
    #>
    param(
        [System.Windows.Forms.TableLayoutPanel]$Grid,
        [string]$LabelText,
        [System.Windows.Forms.Control]$Control,
        [int]$Height = $script:UiLayout.FieldRowHeight,
        [switch]$Stretch
    )

    $row = Add-GridRowStyle -Grid $Grid -Height $Height

    $label = New-UiLabel -Text $LabelText
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.Margin = New-UiPadding 0 0 0 0
    if ($Stretch) {
        $label.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
        $label.Padding = New-UiPadding 0 8 0 0
    }
    else {
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    }
    $Grid.Controls.Add($label, 0, $row)

    if ($Stretch) {
        $Control.Dock = [System.Windows.Forms.DockStyle]::Fill
        $Control.Margin = New-UiPadding 0 4 0 4
    }
    else {
        $Control.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $Control.Margin = New-UiPadding 0 0 0 0
    }
    $Grid.Controls.Add($Control, 1, $row)
}

function Add-FullWidthRow {
    <#
    .SYNOPSIS
        Adds a control that spans both grid columns (buttons, button rows, messages).
    #>
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
        [int]$Height = 32
    )

    $row = Add-GridRowStyle -Grid $Grid -Height $Height
    $Control.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $Control.Margin = New-UiPadding 0 0 0 0
    $Grid.Controls.Add($Control, 1, $row)
}

function New-ButtonRow {
    <#
    .SYNOPSIS
        Lays buttons out in equal-width columns that follow the container width.
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
    <#
    .SYNOPSIS
        Appends a section to the left column (single-column AutoSize table).
        A table keeps the order explicit, avoiding Dock z-order surprises.
    #>
    param([System.Windows.Forms.TableLayoutPanel]$Column, [System.Windows.Forms.Control]$Section)

    $row = $Column.RowStyles.Count
    [void]$Column.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $Column.RowCount = $row + 1
    $Column.Controls.Add($Section, 0, $row)
}

function New-LeftColumn {
    <#
    .SYNOPSIS
        Scrollable host for the left column. If the window is too short for all
        sections, a vertical scrollbar appears instead of clipping controls.
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
        1px bordered white surface with inner padding. Used around the TreeView so the
        first node has real white space above it and the border is drawn by the container
        (TreeView.BorderStyle = None), which keeps layout deterministic.
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
# Data model and persistence
# ====================================================================

function Get-OptionalProperty {
    param($InputObject, [string]$Name, $Default = $null)

    if ($null -ne $InputObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function Get-ParsedDisplayName {
    <#
    .SYNOPSIS
        Derives Market/Environment/ServerType from legacy "MARKET - ENV - TYPE" names.
        Only used to migrate records that lack those fields.
    #>
    param([string]$DisplayName)

    $result = [PSCustomObject]@{ Market = 'UNK'; Environment = 'DEV'; ServerType = 'GENERAL' }
    if (-not $DisplayName) { return $result }

    $match = [regex]::Match($DisplayName, '\b(DEV2|DEV|REC|INT|CONS|PROD|PRD|PRE|UAT|TEST)\b', 'IgnoreCase')
    if ($match.Success) {
        $raw = $match.Groups[1].Value.ToUpperInvariant()
        $result.Environment = if ($script:LegacyEnvironmentMap.ContainsKey($raw)) { $script:LegacyEnvironmentMap[$raw] } else { $raw }

        $left = $DisplayName.Substring(0, $match.Index).Trim(' ', '-')
        $right = $DisplayName.Substring($match.Index + $match.Length).Trim(' ', '-')
        if ($left) { $result.Market = $left.ToUpperInvariant() }
        if ($right) { $result.ServerType = ($right -replace '\s{2,}', ' ').Trim().ToUpperInvariant() }
        return $result
    }

    $tokens = @(($DisplayName -split '\s+-\s+|\s+-\s*|\s*-\s+') | Where-Object { $_ -and $_.Trim() })
    if ($tokens.Count -ge 3) {
        $result.Market = $tokens[0].Trim().ToUpperInvariant()
        $environment = $tokens[1].Trim().ToUpperInvariant()
        $result.Environment = switch -Regex ($environment) {
            'DEV' { 'DEV'; break }
            'REC|PRE' { 'REC'; break }
            'INT|UAT|TEST' { 'INT'; break }
            'CONS' { 'CONS'; break }
            'PROD|PRD' { 'PROD'; break }
            default { 'OTHER' }
        }
        $serverType = (($tokens[2..($tokens.Count - 1)] -join ' - ').Trim()).ToUpperInvariant()
        if ($serverType) { $result.ServerType = $serverType }
    }

    return $result
}

function New-ConnectionObject {
    param(
        [string]$DisplayName,
        [string]$Computer,
        [string]$Market,
        [string]$Environment,
        [string]$ServerType,
        [string]$Notes = '',
        [bool]$Favorite = $false,
        [string]$Id,
        [datetime]$LastUsedUtc = [datetime]::MinValue
    )

    if (-not $Id) { $Id = [Guid]::NewGuid().ToString() }
    if (-not $DisplayName) { $DisplayName = $Computer }
    if (-not $Market) { $Market = 'UNK' }
    if (-not $Environment) { $Environment = 'DEV' }
    if (-not $ServerType) { $ServerType = 'GENERAL' }

    $Environment = $Environment.ToUpperInvariant()
    if ($script:LegacyEnvironmentMap.ContainsKey($Environment)) { $Environment = $script:LegacyEnvironmentMap[$Environment] }

    return [PSCustomObject]@{
        SchemaVersion = $script:SchemaVersion
        Id            = $Id
        DisplayName   = $DisplayName
        Computer      = $Computer
        Market        = $Market.ToUpperInvariant()
        Environment   = $Environment
        ServerType    = $ServerType.ToUpperInvariant()
        Notes         = $Notes
        Favorite      = $Favorite
        LastUsedUtc   = $LastUsedUtc
    }
}

function ConvertTo-Connection {
    param($Source)

    $computer = Get-OptionalProperty $Source 'Computer'
    if (-not $computer) { return $null }

    $displayName = Get-OptionalProperty $Source 'DisplayName' (Get-OptionalProperty $Source 'Name' $computer)
    $parsed = Get-ParsedDisplayName -DisplayName $displayName

    $lastUsed = [datetime]::MinValue
    $rawLastUsed = Get-OptionalProperty $Source 'LastUsedUtc'
    if ($rawLastUsed) {
        try { $lastUsed = [datetime]$rawLastUsed } catch { $lastUsed = [datetime]::MinValue }
    }

    return New-ConnectionObject `
        -DisplayName $displayName `
        -Computer $computer `
        -Market (Get-OptionalProperty $Source 'Market' $parsed.Market) `
        -Environment (Get-OptionalProperty $Source 'Environment' $parsed.Environment) `
        -ServerType (Get-OptionalProperty $Source 'ServerType' $parsed.ServerType) `
        -Notes ([string](Get-OptionalProperty $Source 'Notes' '')) `
        -Favorite ([bool](Get-OptionalProperty $Source 'Favorite' $false)) `
        -Id ([string](Get-OptionalProperty $Source 'Id' '')) `
        -LastUsedUtc $lastUsed
}

function Remove-OldBackups {
    $pattern = '{0}.backup_*' -f (Split-Path -Leaf $script:StorePath)
    Get-ChildItem -Path $script:AppRoot -Filter $pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $script:BackupsToKeep |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Save-Connections {
    <#
    .SYNOPSIS
        Writes the store atomically (temp file + replace) so a crash cannot corrupt it.
    #>
    $temporary = '{0}.tmp' -f $script:StorePath
    try {
        $items = @($script:Connections | ForEach-Object { ConvertTo-Connection -Source $_ } | Where-Object { $_ })
        # One CLIXML object per connection (the long-standing file format).
        if ($items.Count -gt 0) {
            $items | Export-Clixml -Path $temporary -Depth 4 -Force
        }
        else {
            Export-Clixml -InputObject @() -Path $temporary -Force
        }

        if (Test-Path -LiteralPath $script:StorePath) {
            # [NullString]::Value: a plain $null would be marshalled as an empty path.
            [System.IO.File]::Replace($temporary, $script:StorePath, [NullString]::Value)
        }
        else {
            Move-Item -LiteralPath $temporary -Destination $script:StorePath -Force
        }
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Show-Failure -Message "Your connections could not be saved.`n`n$($_.Exception.Message)" -Title 'Save failed'
    }
}

function Import-Connections {
    <#
    .SYNOPSIS
        Loads savedconnections.xml. Older records are migrated (a backup is kept) and an
        unreadable file is set aside instead of being overwritten.
    #>
    # ",$list" keeps the List intact: a plain "return $list" would unroll it into a fixed-size array.
    $list = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $script:StorePath)) { return ,$list }

    try {
        # ForEach-Object { $_ } also flattens a file that stores the connections as one array.
        $imported = @(Import-Clixml -LiteralPath $script:StorePath | ForEach-Object { $_ })
    }
    catch {
        $quarantine = '{0}.corrupt_{1}' -f $script:StorePath, (Get-Date -Format 'yyyyMMdd_HHmmss')
        Move-Item -LiteralPath $script:StorePath -Destination $quarantine -Force
        Show-Failure -Message "The saved connections file could not be read and was moved to:`n$quarantine`n`nThe app will start with an empty list." -Title 'Load failed'
        return ,$list
    }

    $needsMigration = $false
    foreach ($item in $imported) {
        $connection = ConvertTo-Connection -Source $item
        if (-not $connection) { continue }
        $list.Add($connection)

        foreach ($required in 'Market', 'Environment', 'Id', 'SchemaVersion') {
            if (-not (Get-OptionalProperty $item $required)) { $needsMigration = $true }
        }
    }

    if ($needsMigration -and $list.Count -gt 0) {
        Copy-Item -LiteralPath $script:StorePath -Destination ('{0}.backup_{1}' -f $script:StorePath, (Get-Date -Format 'yyyyMMdd_HHmmss')) -Force
        $script:Connections = $list
        Save-Connections
        Remove-OldBackups
    }

    return ,$list
}

function Test-DuplicateConnection {
    param([string]$Computer, [string]$Market, [string]$Environment, [string]$ServerType, [string]$ExcludeId)

    foreach ($connection in $script:Connections) {
        if ($ExcludeId -and $connection.Id -eq $ExcludeId) { continue }
        if ($connection.Computer -eq $Computer -and
            $connection.Market -eq $Market -and
            $connection.Environment -eq $Environment -and
            $connection.ServerType -eq $ServerType) {
            return $true
        }
    }
    return $false
}

function Get-KnownValues {
    <#
    .SYNOPSIS
        Defaults plus every value already used, so editing never silently changes a record
        whose Market/Environment/ServerType is not one of the defaults.
    #>
    param([ValidateSet('Market', 'Environment', 'ServerType')][string]$Field)

    $defaults = switch ($Field) {
        'Market' { $script:DefaultMarkets }
        'Environment' { $script:DefaultEnvironments }
        default { @('GENERAL') }
    }
    $fromData = @($script:Connections | ForEach-Object { $_.$Field } | Where-Object { $_ } | Sort-Object -Unique)
    return @(@($defaults) + $fromData | Select-Object -Unique)
}

function Test-HostName {
    <#
    .SYNOPSIS
        Accepts hostnames, IPv4 and IPv6 (optionally with a port). Also blocks line breaks,
        which would otherwise let a value inject extra settings into the .rdp file.
    #>
    param([string]$Name)

    return ($Name -match '^[A-Za-z0-9._\-]{1,253}(:\d{1,5})?$') -or
           ($Name -match '^\[[0-9A-Fa-f:.]+\](:\d{1,5})?$') -or
           ($Name -match '^[0-9A-Fa-f:]{2,39}$')
}

function Format-RelativeTime {
    param([datetime]$Utc)

    if ($Utc.Year -lt 2000) { return 'Never' }
    $span = [datetime]::UtcNow - $Utc.ToUniversalTime()
    if ($span.TotalSeconds -lt 60) { return 'Just now' }
    if ($span.TotalMinutes -lt 60) { return ('{0} min ago' -f [int]$span.TotalMinutes) }
    if ($span.TotalHours -lt 24) { return ('{0} h ago' -f [int]$span.TotalHours) }
    if ($span.TotalDays -lt 30) { return ('{0} day(s) ago' -f [int]$span.TotalDays) }
    return $Utc.ToLocalTime().ToString('yyyy-MM-dd')
}

function Filter-Connections {
    <#
    .SYNOPSIS
        Filters connections based on search text across all fields.
    #>
    param([string]$SearchText)

    if ([string]::IsNullOrWhiteSpace($SearchText)) {
        # ToArray(): wrapping the List directly in @() throws "argument types do not match" on Windows PowerShell 5.1.
        $script:FilteredConnections = $script:Connections.ToArray()
        return
    }

    $searchLower = $SearchText.ToLower()

    $script:FilteredConnections = @($script:Connections | Where-Object {
        ($_.Computer -and $_.Computer.ToLower().Contains($searchLower)) -or
        ($_.DisplayName -and $_.DisplayName.ToLower().Contains($searchLower)) -or
        ($_.ServerType -and $_.ServerType.ToLower().Contains($searchLower)) -or
        ($_.Market -and $_.Market.ToLower().Contains($searchLower)) -or
        ($_.Environment -and $_.Environment.ToLower().Contains($searchLower)) -or
        ($_.Notes -and $_.Notes.ToLower().Contains($searchLower))
    })
}

# ====================================================================
# Credentials and Active Directory
# ====================================================================

# Self-contained so it can run in a background runspace (a domain bind can block for
# many seconds and would otherwise freeze the sign-in window).
$script:AdBindScript = {
    param([string]$Username, [string]$Password)

    $entry = $null
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry('', $Username, $Password)
        if ($null -ne $entry.psbase.Name) { return 'Valid' }
        return 'Unverified'
    }
    catch {
        $exception = $_.Exception
        while ($exception.InnerException -and $exception -isnot [System.Runtime.InteropServices.COMException]) {
            $exception = $exception.InnerException
        }
        # 0x8007052E = ERROR_LOGON_FAILURE
        if ($exception -is [System.Runtime.InteropServices.COMException] -and $exception.ErrorCode -eq -2147023570) { return 'BadCredentials' }
        return 'Unreachable'
    }
    finally {
        # The ADSI adapter may re-throw the bind error while resolving members; disposal is best effort.
        if ($entry) { try { $entry.psbase.Dispose() } catch { $null = $_ } }
    }
}

function Test-AdCredential {
    param([string]$Username, [string]$Password)

    # An empty password can make a bind succeed anonymously; never allow it.
    if (-not $Username -or -not $Password) {
        return [PSCustomObject]@{ Success = $false; Message = 'Enter both your username and password.' }
    }

    $worker = [powershell]::Create()
    try {
        [void]$worker.AddScript($script:AdBindScript.ToString()).AddArgument($Username).AddArgument($Password)
        $pending = $worker.BeginInvoke()
        while (-not $pending.AsyncWaitHandle.WaitOne(50)) { [System.Windows.Forms.Application]::DoEvents() }
        $outcome = [string]@($worker.EndInvoke($pending))[0]
    }
    finally {
        $worker.Dispose()
    }

    switch ($outcome) {
        'Valid' { return [PSCustomObject]@{ Success = $true; Message = '' } }
        'BadCredentials' { return [PSCustomObject]@{ Success = $false; Message = 'The username or password is incorrect.' } }
        default { return [PSCustomObject]@{ Success = $false; Message = 'Could not verify your credentials against the domain. Check your network or VPN connection and try again.' } }
    }
}

function Get-StoredUserName {
    try { return [RdpManager.Native]::ReadUserName($script:AdCredentialTarget) } catch { return $null }
}

function Save-StoredCredential {
    param([string]$Username, [string]$Password)
    [RdpManager.Native]::WriteCredential($script:AdCredentialTarget, $Username, $Password)
}

# ====================================================================
# RDP launching
# ====================================================================

function Remove-TempRdpFile {
    param([string]$Path)

    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    [void]$script:TempFiles.Remove($Path)
}

function Start-RdpSession {
    param([string]$ComputerName, [string]$Username, [string]$Password)

    if ($Username -match '[\r\n\0]') { throw 'The username contains invalid characters.' }

    $lines = @(
        'screen mode id:i:1'
        "full address:s:$ComputerName"
        "username:s:$Username"
        'prompt for credentials:i:0'
        'administrative session:i:1'
        'desktopwidth:i:1440'
        'desktopheight:i:900'
        'smart sizing:i:1'
    )

    $rdpFile = Join-Path ([System.IO.Path]::GetTempPath()) ('RDPManager_{0}.rdp' -f [Guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $rdpFile -Value $lines -Encoding Unicode
    $script:TempFiles.Add($rdpFile)

    try {
        [RdpManager.Native]::WriteCredential("TERMSRV/$ComputerName", $Username, $Password)
        # The path is quoted so profiles with spaces in their name still work.
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\mstsc.exe') -ArgumentList ('"{0}"' -f $rdpFile)
    }
    catch {
        Remove-TempRdpFile -Path $rdpFile
        throw
    }

    # mstsc reads the file asynchronously: remove it once it has certainly been consumed.
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $script:TempFileLifetimeMs
    $timer.Tag = $rdpFile
    $timer.Add_Tick({
        $path = [string]$this.Tag
        $this.Stop()
        $this.Dispose()
        Remove-TempRdpFile -Path $path
    })
    $timer.Start()
}

function Connect-Session {
    param([string]$ComputerName, $Connection, [switch]$UseOtherCredentials)

    $ComputerName = $ComputerName.Trim()
    if (-not $ComputerName) {
        Show-Warning -Message 'Type a hostname or IP address first.' -Title 'Missing host'
        return $false
    }
    if (-not (Test-HostName -Name $ComputerName)) {
        Show-Warning -Message "'$ComputerName' is not a valid hostname or IP address." -Title 'Invalid host'
        return $false
    }

    $username = $script:CurrentUsername
    $password = $script:CurrentPassword

    if ($UseOtherCredentials) {
        $other = Show-CustomCredentialDialog -ComputerName $ComputerName -DefaultUsername $username
        if (-not $other) { return $false }
        $username = $other.Username
        $password = $other.Password
    }

    $form = $script:UiRefs.Form
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Start-RdpSession -ComputerName $ComputerName -Username $username -Password $password
    }
    catch {
        Show-Failure -Message "Could not start the remote session.`n`n$($_.Exception.Message)" -Title 'Connection failed'
        return $false
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    if ($Connection) {
        $Connection.LastUsedUtc = [datetime]::UtcNow
        Save-Connections
    }

    Set-Status ("Session started for {0}" -f $ComputerName)
    return $true
}

# ====================================================================
# TreeView Management
# ====================================================================

function New-TreeLevelNode {
    <#
    .SYNOPSIS
        Creates a tree node with the visual style of its hierarchy level.
    #>
    param(
        [string]$Text,
        $Tag,
        [string]$Key,
        [System.Drawing.Font]$Font,
        [System.Drawing.Color]$ForeColor
    )

    $node = New-Object System.Windows.Forms.TreeNode
    if ($Font) { $node.NodeFont = $Font }
    $node.Text = $Text
    $node.Tag = $Tag
    if ($Key) { $node.Name = $Key }
    $node.ForeColor = $ForeColor
    return $node
}

function Get-NodeConnection {
    param([System.Windows.Forms.TreeNode]$Node)

    if ($Node -and $Node.Tag -is [PSCustomObject] -and $Node.Tag.PSObject.Properties['Computer']) { return $Node.Tag }
    return $null
}

function Get-SelectedConnection {
    $tree = $script:UiRefs.TreeView
    if (-not $tree) { return $null }
    return Get-NodeConnection -Node $tree.SelectedNode
}

function Refresh-ConnectionTree {
    <#
    .SYNOPSIS
        Rebuilds the TreeView from the filtered connections, keeping the expanded groups
        and the selection.
        Visual hierarchy: Market (bold) > Environment (semibold) > Server Type (muted) > Connection.
    #>
    param(
        [System.Windows.Forms.TreeView]$TreeView,
        [string]$SearchText = "",
        [string]$SelectId = ""
    )

    $theme = $script:UiTheme

    # Remember which groups were open, and what was selected.
    $expanded = @{}
    $pending = New-Object System.Collections.Stack
    foreach ($root in $TreeView.Nodes) { $pending.Push($root) }
    while ($pending.Count -gt 0) {
        $node = $pending.Pop()
        if ($node.Name) { $expanded[$node.Name] = $node.IsExpanded }
        foreach ($child in $node.Nodes) { $pending.Push($child) }
    }
    if (-not $SelectId) {
        $current = Get-NodeConnection -Node $TreeView.SelectedNode
        if ($current) { $SelectId = $current.Id }
    }

    $TreeView.BeginUpdate()
    $TreeView.Nodes.Clear()

    if ($script:FilteredConnections.Count -eq 0) {
        $message = if ($SearchText) { "No matches found for '$SearchText'" } else { "No connections yet - add one from the left panel" }
        $emptyNode = New-TreeLevelNode -Text $message -Tag $null -Font $theme.Font -ForeColor $theme.TextMuted
        $TreeView.Nodes.Add($emptyNode) | Out-Null
        $TreeView.EndUpdate()
        return
    }

    # Group by Market -> Environment -> ServerType -> Connection
    $grouped = $script:FilteredConnections | Group-Object -Property Market

    foreach ($marketGroup in $grouped | Sort-Object Name) {
        $marketKey = $marketGroup.Name
        $marketNode = New-TreeLevelNode -Text "$($theme.IconMarket) $($marketGroup.Name) ($($marketGroup.Count))" `
            -Tag "Market" -Key $marketKey -Font $theme.FontTreeMarket -ForeColor $theme.TextMarket

        $envGroups = $marketGroup.Group | Group-Object -Property Environment

        foreach ($envGroup in $envGroups | Sort-Object Name) {
            $envKey = "$marketKey|$($envGroup.Name)"
            $envNode = New-TreeLevelNode -Text "$($theme.IconEnvironment) $($envGroup.Name) ($($envGroup.Count))" `
                -Tag "Environment" -Key $envKey -Font $theme.FontTreeEnvironment -ForeColor $theme.TextPrimary

            $typeGroups = $envGroup.Group | Group-Object -Property ServerType

            foreach ($typeGroup in $typeGroups | Sort-Object Name) {
                $typeKey = "$envKey|$($typeGroup.Name)"
                $typeNode = New-TreeLevelNode -Text "$($theme.IconServerType) $($typeGroup.Name) ($($typeGroup.Count))" `
                    -Tag "ServerType" -Key $typeKey -Font $theme.Font -ForeColor $theme.TextMuted

                foreach ($conn in ($typeGroup.Group | Sort-Object DisplayName)) {
                    $connIcon = if ($conn.Favorite) { $theme.IconFavorite } else { $theme.IconConnection }
                    # Favorite connections stay accent colored
                    $connColor = if ($conn.Favorite) { $theme.Accent } else { $theme.TextPrimary }
                    $connNode = New-TreeLevelNode -Text "$connIcon $($conn.Computer)" -Tag $conn -Key "conn:$($conn.Id)" -Font $theme.Font -ForeColor $connColor

                    $tooltipLines = @(
                        "Display Name: $($conn.DisplayName)",
                        "Computer: $($conn.Computer)",
                        "Market: $($conn.Market)",
                        "Environment: $($conn.Environment)",
                        "Server Type: $($conn.ServerType)",
                        "Last used: $(Format-RelativeTime -Utc ([datetime]$conn.LastUsedUtc))"
                    )
                    if ($conn.Notes) {
                        $tooltipLines += "Notes: $($conn.Notes)"
                    }
                    $connNode.ToolTipText = $tooltipLines -join "`n"

                    $typeNode.Nodes.Add($connNode) | Out-Null
                }

                $envNode.Nodes.Add($typeNode) | Out-Null
            }

            $marketNode.Nodes.Add($envNode) | Out-Null
        }

        $TreeView.Nodes.Add($marketNode) | Out-Null

        # Searching opens everything; otherwise keep the user's open groups (Markets open by default).
        if ($SearchText) {
            $marketNode.ExpandAll()
        }
        else {
            $isNew = -not $expanded.ContainsKey($marketKey)
            if ($isNew -or $expanded[$marketKey]) { $marketNode.Expand() }
            $nested = New-Object System.Collections.Stack
            foreach ($child in $marketNode.Nodes) { $nested.Push($child) }
            while ($nested.Count -gt 0) {
                $node = $nested.Pop()
                if ($expanded.ContainsKey($node.Name) -and $expanded[$node.Name]) { $node.Expand() }
                foreach ($child in $node.Nodes) { $nested.Push($child) }
            }
        }
    }

    $TreeView.EndUpdate()

    # Always start at the top so the first Market is fully visible after a refresh.
    if ($TreeView.Nodes.Count -gt 0) {
        $TreeView.TopNode = $TreeView.Nodes[0]
    }

    if ($SelectId) {
        $match = @($TreeView.Nodes.Find("conn:$SelectId", $true))
        if ($match.Count -gt 0) {
            $TreeView.SelectedNode = $match[0]
            $match[0].EnsureVisible()
        }
    }
}

function Get-SearchTerm {
    $box = $script:UiRefs.SearchBox
    if ($box.Text -eq [string]$box.Tag) { return '' }
    return $box.Text.Trim()
}

function Set-Status {
    param([string]$Message)
    if ($script:UiRefs.StatusBar) { $script:UiRefs.StatusBar.Text = $Message }
}

function Update-ActionState {
    $hasSelection = [bool](Get-SelectedConnection)
    foreach ($name in 'EditButton', 'RemoveButton', 'FavoriteButton') {
        $script:UiRefs[$name].Enabled = $hasSelection
    }
}

function Update-ConnectionView {
    <#
    .SYNOPSIS
        Re-applies the filter, rebuilds the tree and refreshes dependent UI.
    #>
    param([string]$SelectId = "")

    $term = Get-SearchTerm
    Filter-Connections -SearchText $term
    Refresh-ConnectionTree -TreeView $script:UiRefs.TreeView -SearchText $term -SelectId $SelectId
    Update-ActionState

    $total = $script:Connections.Count
    $script:UiRefs.HintLabel.Text = "Connections grouped by Market -> Environment -> Server Type | $total saved"
    Set-Status ("{0} connection(s){1}" -f $total, $(if ($term) { " | showing $($script:FilteredConnections.Count)" } else { "" }))
}

# ====================================================================
# Dialogs
# ====================================================================

function New-DialogForm {
    param([string]$Title, [int]$Width = 440, [switch]$Standalone)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = [bool]$Standalone
    $form.StartPosition = if ($Standalone) { 'CenterScreen' } else { 'CenterParent' }
    $form.Font = $script:UiTheme.Font
    $form.BackColor = $script:UiTheme.PageBackground
    $form.Padding = New-UiPadding 24 20 24 20
    $form.ClientSize = New-Object System.Drawing.Size($Width, 200)
    return $form
}

function Complete-Dialog {
    <#
    .SYNOPSIS
        Sizes the dialog to its content once all rows have been added.
    #>
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
        Adds the inline error message and a right-aligned button bar. Returns the error label.
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

# ---- Sign in ---------------------------------------------------------------

function Invoke-LoginSubmit {
    $state = $script:DialogState
    $username = $state.User.Text.Trim()
    $state.Error.Text = ''

    if (-not $username -or -not $state.Password.Text) {
        $state.Error.Text = 'Enter both your username and password.'
        return
    }

    $state.Busy = $true
    $state.Form.UseWaitCursor = $true
    foreach ($control in $state.Controls) { $control.Enabled = $false }
    $state.Submit.Text = [string]::Format('Signing in{0}', [char]0x2026)
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $result = Test-AdCredential -Username $username -Password $state.Password.Text
        if ($result.Success) {
            Save-StoredCredential -Username $username -Password $state.Password.Text
            $script:CurrentUsername = $username
            $script:CurrentPassword = $state.Password.Text
            $state.Busy = $false            # allow the dialog to close
            $state.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            return
        }
        $state.Error.Text = $result.Message
    }
    finally {
        $state.Busy = $false
        $state.Form.UseWaitCursor = $false
        foreach ($control in $state.Controls) { $control.Enabled = $true }
        $state.Submit.Text = 'Sign in'
    }

    $state.Password.Clear()
    $state.Password.Focus()
}

function Show-LoginDialog {
    param([string]$DefaultUsername, [switch]$Standalone)

    $dialog = New-DialogForm -Title "$($script:AppName) - Sign in" -Width 440 -Standalone:$Standalone
    $grid = New-FieldGrid
    Add-DialogHeading -Grid $grid -Title 'Sign in' -Description 'Use your Active Directory account. It is verified against the domain and remembered in Windows Credential Manager.'

    $txtUser = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24))
    $txtUser.Text = $DefaultUsername
    $txtPassword = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -UsePasswordChar
    Add-FieldRow -Grid $grid -LabelText 'Username:' -Control $txtUser
    Add-FieldRow -Grid $grid -LabelText 'Password:' -Control $txtPassword

    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = 'Show password'
    $chkShow.Font = $script:UiTheme.Font
    $chkShow.AutoSize = $true
    $chkShow.ForeColor = $script:UiTheme.TextMuted
    $chkShow.Add_CheckedChanged({ $script:DialogState.Password.UseSystemPasswordChar = -not $this.Checked })
    Add-InputColumnRow -Grid $grid -Control $chkShow

    $btnSignIn = New-UiButton -Text 'Sign in' -Size (New-Object System.Drawing.Size(104, $script:UiLayout.ButtonHeightSmall)) -Primary
    $btnCancel = New-UiButton -Text 'Cancel' -Size (New-Object System.Drawing.Size(96, $script:UiLayout.ButtonHeightSmall))
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $errorLabel = Add-DialogFooter -Grid $grid -Buttons @($btnSignIn, $btnCancel)

    $script:DialogState = @{
        Form = $dialog; User = $txtUser; Password = $txtPassword; Error = $errorLabel
        Submit = $btnSignIn; Controls = @($txtUser, $txtPassword, $btnSignIn, $btnCancel, $chkShow); Busy = $false
    }

    $btnSignIn.Add_Click({ Invoke-SafeAction { Invoke-LoginSubmit } })
    $dialog.AcceptButton = $btnSignIn
    $dialog.CancelButton = $btnCancel
    $dialog.Add_FormClosing({ if ($script:DialogState.Busy) { $_.Cancel = $true } })
    $dialog.Add_Shown({
        $state = $script:DialogState
        if ($state.User.Text) { $state.Password.Focus() } else { $state.User.Focus() }
    })
    Complete-Dialog -Form $dialog -Grid $grid

    $owner = $script:UiRefs.Form
    $result = if ($owner -and -not $Standalone) { $dialog.ShowDialog($owner) } else { $dialog.ShowDialog() }
    $dialog.Dispose()
    $script:DialogState = $null
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

# ---- Other credentials -----------------------------------------------------

function Invoke-CustomCredentialSubmit {
    $state = $script:DialogState
    if (-not $state.User.Text.Trim() -or -not $state.Password.Text) {
        $state.Error.Text = 'Enter both a username and a password.'
        return
    }
    $state.Result = [PSCustomObject]@{ Username = $state.User.Text.Trim(); Password = $state.Password.Text }
    $state.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
}

function Show-CustomCredentialDialog {
    param([string]$ComputerName, [string]$DefaultUsername)

    $dialog = New-DialogForm -Title 'Other credentials' -Width 440
    $grid = New-FieldGrid
    Add-DialogHeading -Grid $grid -Title 'Other credentials' -Description ("Used only for this session to {0}." -f $ComputerName)

    $txtUser = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24))
    $txtUser.Text = $DefaultUsername
    $txtPassword = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -UsePasswordChar
    Add-FieldRow -Grid $grid -LabelText 'Username:' -Control $txtUser
    Add-FieldRow -Grid $grid -LabelText 'Password:' -Control $txtPassword

    $btnConnect = New-UiButton -Text 'Connect' -Size (New-Object System.Drawing.Size(104, $script:UiLayout.ButtonHeightSmall)) -Primary
    $btnCancel = New-UiButton -Text 'Cancel' -Size (New-Object System.Drawing.Size(96, $script:UiLayout.ButtonHeightSmall))
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $errorLabel = Add-DialogFooter -Grid $grid -Buttons @($btnConnect, $btnCancel)

    $script:DialogState = @{ Form = $dialog; User = $txtUser; Password = $txtPassword; Error = $errorLabel; Result = $null }

    $btnConnect.Add_Click({ Invoke-SafeAction { Invoke-CustomCredentialSubmit } })
    $dialog.AcceptButton = $btnConnect
    $dialog.CancelButton = $btnCancel
    $dialog.Add_Shown({ $script:DialogState.Password.Focus() })
    Complete-Dialog -Form $dialog -Grid $grid

    $result = $dialog.ShowDialog($script:UiRefs.Form)
    $credentials = if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $script:DialogState.Result } else { $null }
    $dialog.Dispose()
    $script:DialogState = $null
    return $credentials
}

# ---- Connection fields (shared by the Add panel and the Edit dialog) -----------

function Add-ConnectionFieldRows {
    <#
    .SYNOPSIS
        Adds the connection form rows to a field grid and returns the controls.
        Market/Environment/Server Type are editable lists so custom values survive editing.
    #>
    param([System.Windows.Forms.TableLayoutPanel]$Grid, [System.Windows.Forms.ToolTip]$ToolTip)

    $fieldSize = New-Object System.Drawing.Size(100, 24)

    $txtDisplay = New-UiTextBox -Size $fieldSize
    Add-UiTooltip -ToolTip $ToolTip -Control $txtDisplay -Text "Friendly name (defaults to the hostname)"
    Add-FieldRow -Grid $Grid -LabelText "Display Name:" -Control $txtDisplay

    $txtHost = New-UiTextBox -Size $fieldSize
    Add-UiTooltip -ToolTip $ToolTip -Control $txtHost -Text "Server hostname or IP address"
    Add-FieldRow -Grid $Grid -LabelText "Hostname/IP:" -Control $txtHost

    $combos = @{}
    foreach ($field in @(
        @{ Name = 'Market'; Label = 'Market:'; Tip = 'Geographic market' },
        @{ Name = 'Environment'; Label = 'Environment:'; Tip = 'Target environment' },
        @{ Name = 'ServerType'; Label = 'Server Type:'; Tip = 'Server type or role' })) {

        $combo = New-Object System.Windows.Forms.ComboBox
        $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
        $combo.Font = $script:UiTheme.Font
        $combo.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
        $combo.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
        [void]$combo.Items.AddRange([object[]]@(Get-KnownValues $field.Name))
        Add-UiTooltip -ToolTip $ToolTip -Control $combo -Text $field.Tip
        Add-FieldRow -Grid $Grid -LabelText $field.Label -Control $combo
        $combos[$field.Name] = $combo
    }

    $txtNotes = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 64)) -Multiline
    $txtNotes.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    Add-UiTooltip -ToolTip $ToolTip -Control $txtNotes -Text "Additional notes or documentation"
    Add-FieldRow -Grid $Grid -LabelText "Notes:" -Control $txtNotes -Height $script:UiLayout.NotesRowHeight -Stretch

    $chkFavorite = New-Object System.Windows.Forms.CheckBox
    $chkFavorite.Text = "Mark as Favorite"
    $chkFavorite.Font = $script:UiTheme.Font
    $chkFavorite.AutoSize = $true
    Add-UiTooltip -ToolTip $ToolTip -Control $chkFavorite -Text "Favorites are highlighted in the library"
    Add-InputColumnRow -Grid $Grid -Control $chkFavorite

    $fields = [PSCustomObject]@{
        Display = $txtDisplay; Host = $txtHost
        Market = $combos['Market']; Environment = $combos['Environment']; ServerType = $combos['ServerType']
        Notes = $txtNotes; Favorite = $chkFavorite
    }
    Set-ConnectionFormValues -Fields $fields
    return $fields
}

function Set-ConnectionFormValues {
    <#
    .SYNOPSIS
        Fills the form from a connection, or resets it to defaults when none is given.
    #>
    param($Fields, $Connection)

    if ($Connection) {
        $Fields.Display.Text = $Connection.DisplayName
        $Fields.Host.Text = $Connection.Computer
        $Fields.Market.Text = $Connection.Market
        $Fields.Environment.Text = $Connection.Environment
        $Fields.ServerType.Text = $Connection.ServerType
        $Fields.Notes.Text = $Connection.Notes
        $Fields.Favorite.Checked = [bool]$Connection.Favorite
        return
    }

    $Fields.Display.Clear()
    $Fields.Host.Clear()
    $Fields.Market.Text = 'DE'
    $Fields.Environment.Text = 'DEV'
    $Fields.ServerType.Text = 'GENERAL'
    $Fields.Notes.Clear()
    $Fields.Favorite.Checked = $false
}

function Get-ConnectionFormValues {
    <#
    .SYNOPSIS
        Validates the form. Returns the normalized values, or $null after telling the user what to fix.
    #>
    param($Fields, [string]$ExcludeId)

    $computer = $Fields.Host.Text.Trim()
    if (-not $computer) {
        Show-Warning -Message 'Hostname or IP is required.' -Title 'Missing host'
        [void]$Fields.Host.Focus()
        return $null
    }
    if (-not (Test-HostName -Name $computer)) {
        Show-Warning -Message 'Use a valid hostname or IP address (letters, digits, dots and dashes).' -Title 'Invalid host'
        [void]$Fields.Host.Focus()
        return $null
    }

    $market = $Fields.Market.Text.Trim().ToUpperInvariant()
    $environment = $Fields.Environment.Text.Trim().ToUpperInvariant()
    $serverType = $Fields.ServerType.Text.Trim().ToUpperInvariant()
    if (-not $market) { $market = 'UNK' }
    if (-not $environment) { $environment = 'DEV' }
    if (-not $serverType) { $serverType = 'GENERAL' }
    if ($script:LegacyEnvironmentMap.ContainsKey($environment)) { $environment = $script:LegacyEnvironmentMap[$environment] }

    if (Test-DuplicateConnection -Computer $computer -Market $market -Environment $environment -ServerType $serverType -ExcludeId $ExcludeId) {
        Show-Warning -Message 'A connection with the same host, market, environment and server type already exists.' -Title 'Duplicate connection'
        [void]$Fields.Host.Focus()
        return $null
    }

    $displayName = $Fields.Display.Text.Trim()
    return [PSCustomObject]@{
        Computer = $computer
        DisplayName = if ($displayName) { $displayName } else { $computer }
        Market = $market
        Environment = $environment
        ServerType = $serverType
        Notes = $Fields.Notes.Text.Trim()
        Favorite = [bool]$Fields.Favorite.Checked
    }
}

function Invoke-ConnectionDialogSave {
    $state = $script:DialogState
    $values = Get-ConnectionFormValues -Fields $state.Fields -ExcludeId $state.ExcludeId
    if (-not $values) { return }
    $state.Result = $values
    $state.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
}

function Show-ConnectionDialog {
    param($Existing)

    $dialog = New-DialogForm -Title 'Edit connection' -Width 500
    $grid = New-FieldGrid
    Add-DialogHeading -Grid $grid -Title 'Edit connection'

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $fields = Add-ConnectionFieldRows -Grid $grid -ToolTip $toolTip
    Set-ConnectionFormValues -Fields $fields -Connection $Existing

    $btnSave = New-UiButton -Text 'Save' -Size (New-Object System.Drawing.Size(104, $script:UiLayout.ButtonHeightSmall)) -Primary
    $btnCancel = New-UiButton -Text 'Cancel' -Size (New-Object System.Drawing.Size(96, $script:UiLayout.ButtonHeightSmall))
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    [void](Add-DialogFooter -Grid $grid -Buttons @($btnSave, $btnCancel))

    $script:DialogState = @{ Form = $dialog; Fields = $fields; ExcludeId = $Existing.Id; Result = $null }

    $btnSave.Add_Click({ Invoke-SafeAction { Invoke-ConnectionDialogSave } })
    $dialog.AcceptButton = $btnSave
    $dialog.CancelButton = $btnCancel
    $dialog.Add_Shown({ $script:DialogState.Fields.Display.Focus() })
    Complete-Dialog -Form $dialog -Grid $grid

    $result = $dialog.ShowDialog($script:UiRefs.Form)
    $values = if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $script:DialogState.Result } else { $null }
    $toolTip.Dispose()
    $dialog.Dispose()
    $script:DialogState = $null
    return $values
}

# ====================================================================
# Actions
# ====================================================================

function Invoke-ConnectSelected {
    param([switch]$UseOtherCredentials)

    $connection = Get-SelectedConnection
    if (-not $connection) { Set-Status 'Select a connection first.'; return }
    if (Connect-Session -ComputerName $connection.Computer -Connection $connection -UseOtherCredentials:$UseOtherCredentials) {
        Update-ConnectionView -SelectId $connection.Id
        Set-Status ("Session started for {0}" -f $connection.Computer)
    }
}

function Invoke-QuickConnect {
    param([switch]$UseOtherCredentials)
    [void](Connect-Session -ComputerName $script:UiRefs.QuickHost.Text -UseOtherCredentials:$UseOtherCredentials)
}

function Invoke-AddConnection {
    $fields = $script:UiRefs.AddFields
    $values = Get-ConnectionFormValues -Fields $fields
    if (-not $values) { return }

    $connection = New-ConnectionObject -DisplayName $values.DisplayName -Computer $values.Computer -Market $values.Market `
        -Environment $values.Environment -ServerType $values.ServerType -Notes $values.Notes -Favorite $values.Favorite
    $script:Connections.Add($connection)
    Save-Connections

    # A filter could hide the new entry, so clear it.
    $box = $script:UiRefs.SearchBox
    if ((Get-SearchTerm)) { $box.Focus(); $box.Text = ''; $script:UiRefs.TreeView.Focus() }

    Set-ConnectionFormValues -Fields $fields
    Update-ConnectionView -SelectId $connection.Id
    Set-Status ("Saved '{0}' to the library" -f $connection.DisplayName)
}

function Invoke-EditSelected {
    $connection = Get-SelectedConnection
    if (-not $connection) { Set-Status 'Select a connection to edit.'; return }

    $values = Show-ConnectionDialog -Existing $connection
    if (-not $values) { return }

    $connection.DisplayName = $values.DisplayName
    $connection.Computer = $values.Computer
    $connection.Market = $values.Market
    $connection.Environment = $values.Environment
    $connection.ServerType = $values.ServerType
    $connection.Notes = $values.Notes
    $connection.Favorite = $values.Favorite

    Save-Connections
    Update-ConnectionView -SelectId $connection.Id
    Set-Status ("Updated '{0}'" -f $connection.DisplayName)
}

function Invoke-RemoveSelected {
    $connection = Get-SelectedConnection
    if (-not $connection) { Set-Status 'Select a connection to remove.'; return }

    if (-not (Confirm-Action -Message ("Remove '{0}' ({1}) from your library?" -f $connection.DisplayName, $connection.Computer) -Title 'Remove connection')) { return }

    [void]$script:Connections.Remove($connection)
    Save-Connections
    Update-ConnectionView
    Set-Status ("Removed '{0}'" -f $connection.DisplayName)
}

function Invoke-ToggleFavorite {
    $connection = Get-SelectedConnection
    if (-not $connection) { Set-Status 'Select a connection first.'; return }

    $connection.Favorite = -not [bool]$connection.Favorite
    Save-Connections
    Update-ConnectionView -SelectId $connection.Id
    Set-Status $(if ($connection.Favorite) { "Added '$($connection.DisplayName)' to favorites" } else { "Removed '$($connection.DisplayName)' from favorites" })
}

function Invoke-CopyHost {
    $connection = Get-SelectedConnection
    if (-not $connection) { return }

    [System.Windows.Forms.Clipboard]::SetText($connection.Computer)
    Set-Status ("Copied {0} to the clipboard" -f $connection.Computer)
}

function Invoke-ClearFilter {
    $box = $script:UiRefs.SearchBox
    $box.Focus()
    $box.Text = ''           # TextChanged re-filters and rebuilds the tree
    $script:UiRefs.TreeView.Focus()
}

function Invoke-SwitchAccount {
    if (Show-LoginDialog -DefaultUsername $script:CurrentUsername) {
        $script:UiRefs.UserLabel.Text = "Signed in as: $($script:CurrentUsername)"
        Set-Status 'Account updated'
    }
}

# ====================================================================
# UI Panel Creation Functions (Modular Design)
# ====================================================================

function Create-HeaderPanel {
    <#
    .SYNOPSIS
        Header with the signed-in account, a short hint and the switch-account button.
    #>
    param([System.Windows.Forms.Form]$ParentForm)

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

    $labelStatus = New-UiLabel -Text "Signed in as: $($script:CurrentUsername)" -Strong
    $labelStatus.AutoSize = $true
    $labelStatus.Margin = New-UiPadding 0 0 0 2
    $labelHint = New-UiLabel -Text "Connections grouped by Market -> Environment -> Server Type" -Muted
    $labelHint.AutoSize = $true
    $labelHint.Margin = New-UiPadding 0 0 0 0
    $stack.Controls.Add($labelStatus)
    $stack.Controls.Add($labelHint)
    $layout.Controls.Add($stack, 0, 0)

    $btnSwitch = New-UiButton -Text "Switch account" -Size (New-Object System.Drawing.Size(130, $script:UiLayout.ButtonHeightSmall))
    $btnSwitch.Anchor = [System.Windows.Forms.AnchorStyles]::Right
    $btnSwitch.Margin = New-UiPadding 0 0 0 0
    $btnSwitch.Add_Click({ Invoke-SafeAction { Invoke-SwitchAccount } })
    $layout.Controls.Add($btnSwitch, 1, 0)

    $headerPanel.Controls.Add($layout)
    $ParentForm.Controls.Add($headerPanel)

    $script:UiRefs.UserLabel = $labelStatus
    $script:UiRefs.HintLabel = $labelHint
    return $headerPanel
}

function Create-QuickConnectPanel {
    <#
    .SYNOPSIS
        Quick Connect: one hostname field and two buttons.
    #>
    param(
        [System.Windows.Forms.TableLayoutPanel]$Column,
        [System.Windows.Forms.ToolTip]$ToolTip
    )

    $groupQuick = New-SectionGroup -Text "Quick Connect"
    $grid = New-FieldGrid

    $txtComputer = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24))
    Add-UiTooltip -ToolTip $ToolTip -Control $txtComputer -Text "Enter a hostname or IP address and press Enter"
    $txtComputer.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $_.SuppressKeyPress = $true
            Invoke-SafeAction { Invoke-QuickConnect }
        }
    })
    Add-FieldRow -Grid $grid -LabelText "Hostname/IP:" -Control $txtComputer

    $btnConnect = New-UiButton -Text "Connect" -Size (New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightLarge)) -Primary
    Add-UiTooltip -ToolTip $ToolTip -Control $btnConnect -Text "Connect with your signed-in account"
    $btnConnect.Add_Click({ Invoke-SafeAction { Invoke-QuickConnect } })

    $btnConnectOther = New-UiButton -Text "Other Credentials..." -Size (New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightLarge))
    Add-UiTooltip -ToolTip $ToolTip -Control $btnConnectOther -Text "Connect once with a different account"
    $btnConnectOther.Add_Click({ Invoke-SafeAction { Invoke-QuickConnect -UseOtherCredentials } })

    $buttons = New-ButtonRow -Buttons @($btnConnect, $btnConnectOther)
    Add-FullWidthRow -Grid $grid -Control $buttons -Height ($script:UiLayout.ButtonHeightLarge + $script:UiLayout.ControlSpacing)
    $buttons.Margin = New-UiPadding 0 $script:UiLayout.ControlSpacing 0 0

    $groupQuick.Controls.Add($grid)
    Add-StackSection -Column $Column -Section $groupQuick
    $script:UiRefs.QuickHost = $txtComputer
    return $groupQuick
}

function Create-AddToLibraryPanel {
    <#
    .SYNOPSIS
        "Add to Library" section with all connection metadata.
    #>
    param(
        [System.Windows.Forms.TableLayoutPanel]$Column,
        [System.Windows.Forms.ToolTip]$ToolTip
    )

    $groupAdd = New-SectionGroup -Text "Add to Library"
    $grid = New-FieldGrid
    $script:UiRefs.AddFields = Add-ConnectionFieldRows -Grid $grid -ToolTip $ToolTip

    $btnSave = New-UiButton -Text "Save to Library" -Size (New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightLarge)) -Primary
    $btnSave.Margin = New-UiPadding 0 $script:UiLayout.ControlSpacing 0 0
    Add-UiTooltip -ToolTip $ToolTip -Control $btnSave -Text "Save this connection to the library"
    $btnSave.Add_Click({ Invoke-SafeAction { Invoke-AddConnection } })
    Add-FullWidthRow -Grid $grid -Control $btnSave -Height ($script:UiLayout.ButtonHeightLarge + $script:UiLayout.ControlSpacing)

    $groupAdd.Controls.Add($grid)
    Add-StackSection -Column $Column -Section $groupAdd
    return $groupAdd
}

function Create-ActionsPanel {
    <#
    .SYNOPSIS
        Library actions (2 x 2 grid + refresh). Edit/Remove/Favorite follow the selection.
    #>
    param(
        [System.Windows.Forms.TableLayoutPanel]$Column,
        [System.Windows.Forms.ToolTip]$ToolTip
    )

    $groupActions = New-SectionGroup -Text "Library Actions"
    $groupActions.Margin = New-UiPadding 0 0 0 0
    $grid = New-FieldGrid
    $small = New-Object System.Drawing.Size(100, $script:UiLayout.ButtonHeightSmall)
    $rowHeight = $script:UiLayout.ButtonHeightSmall + $script:UiLayout.ControlSpacing

    $btnEdit = New-UiButton -Text "Edit Selected" -Size $small
    $btnEdit.Enabled = $false
    Add-UiTooltip -ToolTip $ToolTip -Control $btnEdit -Text "Edit the selected connection (F2)"
    $btnEdit.Add_Click({ Invoke-SafeAction { Invoke-EditSelected } })

    $btnRemove = New-UiButton -Text "Remove Selected" -Size $small -Danger
    $btnRemove.Enabled = $false
    Add-UiTooltip -ToolTip $ToolTip -Control $btnRemove -Text "Remove the selected connection (Del)"
    $btnRemove.Add_Click({ Invoke-SafeAction { Invoke-RemoveSelected } })

    $btnToggleFav = New-UiButton -Text "Toggle Favorite" -Size $small
    $btnToggleFav.Enabled = $false
    Add-UiTooltip -ToolTip $ToolTip -Control $btnToggleFav -Text "Mark or unmark as favorite"
    $btnToggleFav.Add_Click({ Invoke-SafeAction { Invoke-ToggleFavorite } })

    $btnClearSearch = New-UiButton -Text "Clear Filter" -Size $small
    Add-UiTooltip -ToolTip $ToolTip -Control $btnClearSearch -Text "Clear the search filter"
    $btnClearSearch.Add_Click({ Invoke-SafeAction { Invoke-ClearFilter } })

    $btnRefresh = New-UiButton -Text "Refresh View" -Size $small -Primary
    $btnRefresh.Margin = New-UiPadding 0 0 0 0
    Add-UiTooltip -ToolTip $ToolTip -Control $btnRefresh -Text "Reload the library from disk"
    $btnRefresh.Add_Click({
        Invoke-SafeAction {
            $script:Connections = Import-Connections
            Update-ConnectionView
        }
    })

    $rowOne = New-ButtonRow -Buttons @($btnEdit, $btnRemove)
    $rowTwo = New-ButtonRow -Buttons @($btnToggleFav, $btnClearSearch)
    $rowOne.Margin = New-UiPadding 0 0 0 $script:UiLayout.ControlSpacing
    $rowTwo.Margin = New-UiPadding 0 0 0 $script:UiLayout.ControlSpacing
    Add-FullWidthRow -Grid $grid -Control $rowOne -Height $rowHeight
    Add-FullWidthRow -Grid $grid -Control $rowTwo -Height $rowHeight
    Add-FullWidthRow -Grid $grid -Control $btnRefresh -Height $script:UiLayout.ButtonHeightSmall

    $groupActions.Controls.Add($grid)
    Add-StackSection -Column $Column -Section $groupActions

    $script:UiRefs.EditButton = $btnEdit
    $script:UiRefs.RemoveButton = $btnRemove
    $script:UiRefs.FavoriteButton = $btnToggleFav
    return $groupActions
}

function Create-FilterBar {
    <#
    .SYNOPSIS
        Filter row: "Filter:" label + search box that uses all remaining width.
        A 2-column table centers both controls vertically and lets the textbox stretch;
        Padding.Bottom gives the row breathing room before the tree.
    #>
    param([System.Windows.Forms.ToolTip]$ToolTip)

    $filterPanel = New-Object System.Windows.Forms.Panel
    $filterPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $filterPanel.Height = $script:UiLayout.FilterRowHeight
    $filterPanel.Padding = New-UiPadding 0 0 0 $script:UiLayout.ControlSpacing

    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.Dock = [System.Windows.Forms.DockStyle]::Fill
    $table.ColumnCount = 2
    $table.RowCount = 1
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 52)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $lblSearch = New-UiLabel -Text "Filter:" -Width 52
    $lblSearch.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lblSearch.Margin = New-UiPadding 0 0 0 0
    $lblSearch.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $table.Controls.Add($lblSearch, 0, 0)

    $txtSearch = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -PlaceholderText "Search connections..."
    $txtSearch.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $txtSearch.Margin = New-UiPadding 0 0 0 0
    Add-UiTooltip -ToolTip $ToolTip -Control $txtSearch -Text "Filter by hostname, name, type, market, environment or notes (Ctrl+F)"
    $table.Controls.Add($txtSearch, 1, 0)

    $filterPanel.Controls.Add($table)
    return [PSCustomObject]@{ Panel = $filterPanel; SearchBox = $txtSearch }
}

function New-LibraryContextMenu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Font = $script:UiTheme.Font

    $items = @(
        @{ Text = 'Connect'; Action = { Invoke-ConnectSelected }; Bold = $true },
        @{ Text = 'Connect with other credentials...'; Action = { Invoke-ConnectSelected -UseOtherCredentials } },
        @{ Separator = $true },
        @{ Text = 'Edit...'; Action = { Invoke-EditSelected } },
        @{ Text = 'Toggle favorite'; Action = { Invoke-ToggleFavorite } },
        @{ Text = 'Copy hostname'; Action = { Invoke-CopyHost } },
        @{ Separator = $true },
        @{ Text = 'Remove...'; Action = { Invoke-RemoveSelected }; Danger = $true }
    )

    foreach ($entry in $items) {
        if ($entry.Separator) { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($entry.Text)
        if ($entry.Bold) { $item.Font = $script:UiTheme.FontStrong }
        if ($entry.Danger) { $item.ForeColor = $script:UiTheme.Danger }
        $item.Tag = $entry.Action
        $item.Add_Click({ Invoke-SafeAction $this.Tag })
        [void]$menu.Items.Add($item)
    }

    # Only offer the menu on a connection, not on group nodes.
    $menu.Add_Opening({ if (-not (Get-SelectedConnection)) { $_.Cancel = $true } })
    return $menu
}

function Create-TreeViewPanel {
    <#
    .SYNOPSIS
        Creates the Connection Library (filter bar + TreeView).

        Layout (deterministic, no overlap):
            GroupBox
              +- treeHost   Dock=Fill   (bordered surface with inner padding)
              |    +- TreeView Dock=Fill
              +- filterBar  Dock=Top

        DOCK ORDER MATTERS: WinForms lays out docked children from the HIGHEST child
        index down to 0. The Fill control must therefore be added FIRST (index 0, laid
        out last, receives the space that is left) and the Top filter bar AFTER it
        (higher index, laid out first). Adding them the other way round makes the
        TreeView fill the whole group and the filter bar paint over its first rows.
    #>
    param(
        [System.Windows.Forms.SplitContainer]$SplitContainer,
        [System.Windows.Forms.ToolTip]$ToolTip
    )

    $groupSaved = New-UiGroupBox -Text "Connection Library" -Dock ([System.Windows.Forms.DockStyle]::Fill)
    $groupSaved.Padding = New-UiPadding $script:UiLayout.PaddingStandard 8 $script:UiLayout.PaddingStandard $script:UiLayout.PaddingStandard

    $treeHost = New-BorderedHost -InnerPadding $script:UiLayout.TreeInnerPadding

    $treeView = New-Object System.Windows.Forms.TreeView
    $treeView.Dock = [System.Windows.Forms.DockStyle]::Fill
    # The TreeView measures every label with ITS font, so it must be the widest one (bold
    # Market). Other levels override it per node (NodeFont); a narrower control font would
    # cut off the bold Market labels ("[M] DE (4" instead of "[M] DE (4)").
    $treeView.Font = $script:UiTheme.FontTreeMarket
    $treeView.ItemHeight = $script:UiLayout.TreeItemHeight
    $treeView.Indent = $script:UiLayout.TreeIndent
    $treeView.ShowNodeToolTips = $true
    $treeView.HideSelection = $false
    $treeView.ShowLines = $false          # cleaner; FullRowSelect needs ShowLines = $false
    $treeView.FullRowSelect = $true
    $treeView.ShowPlusMinus = $true
    $treeView.ShowRootLines = $true
    $treeView.BorderStyle = [System.Windows.Forms.BorderStyle]::None   # border is drawn by treeHost
    $treeView.BackColor = $script:UiTheme.Surface
    $treeView.ContextMenuStrip = New-LibraryContextMenu
    Add-UiTooltip -ToolTip $ToolTip -Control $treeView -Text "Double-click or press Enter to connect"
    $treeHost.Inner.Controls.Add($treeView)

    $treeView.Add_AfterSelect({ Update-ActionState })
    $treeView.Add_NodeMouseClick({
        # Right-click should select the node under the cursor before the menu opens.
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $this.SelectedNode = $_.Node }
    })
    $treeView.Add_NodeMouseDoubleClick({
        if (Get-NodeConnection -Node $_.Node) { Invoke-SafeAction { Invoke-ConnectSelected } }
    })
    $treeView.Add_KeyDown({
        if (-not (Get-SelectedConnection)) { return }
        $e = $_    # inside "switch", $_ is rebound to the switch value
        switch ($e.KeyCode) {
            'Return' { $e.SuppressKeyPress = $true; Invoke-SafeAction { Invoke-ConnectSelected } }
            'F2' { $e.SuppressKeyPress = $true; Invoke-SafeAction { Invoke-EditSelected } }
            'Delete' { $e.SuppressKeyPress = $true; Invoke-SafeAction { Invoke-RemoveSelected } }
        }
    })

    $filterBar = Create-FilterBar -ToolTip $ToolTip
    $txtSearch = $filterBar.SearchBox

    # Live filtering (placeholder text is stored in .Tag by New-UiTextBox)
    $txtSearch.Add_TextChanged({ Invoke-SafeAction { Update-ConnectionView } })
    $txtSearch.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $_.SuppressKeyPress = $true; Invoke-SafeAction { Invoke-ClearFilter } }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Down) { $_.SuppressKeyPress = $true; $script:UiRefs.TreeView.Focus() }
    })

    # Order matters - see the DOCK ORDER note above.
    $groupSaved.Controls.Add($treeHost.Outer)       # Fill  (index 0)
    $groupSaved.Controls.Add($filterBar.Panel)      # Top   (index 1)

    $SplitContainer.Panel2.Controls.Add($groupSaved)

    $script:UiRefs.TreeView = $treeView
    $script:UiRefs.SearchBox = $txtSearch
}

function Create-StatusBar {
    param([System.Windows.Forms.Form]$ParentForm)

    $statusBar = New-Object System.Windows.Forms.StatusBar
    $statusBar.Font = $script:UiTheme.Font
    $statusBar.Text = "Ready"
    $ParentForm.Controls.Add($statusBar)
    $script:UiRefs.StatusBar = $statusBar
    return $statusBar
}

function Set-SplitLayout {
    <#
    .SYNOPSIS
        Applies splitter limits once the control has its real size.
        Setting Panel*MinSize / SplitterDistance on a control that is still at its
        default 150px width can throw, so this runs from the form's Shown event.
        FixedPanel = Panel1 keeps the left column at its width and gives extra
        window width to the Connection Library.
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
# Main Form Construction
# ====================================================================

function Show-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $script:AppName
    # Prefer a height that shows every left-column section; fall back to the screen size
    # (the left column scrolls if the window is shorter).
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size(1100, [Math]::Min(860, ($workArea.Height - 40)))
    $form.MinimumSize = New-Object System.Drawing.Size(900, 620)
    $form.StartPosition = "CenterScreen"
    $form.Font = $script:UiTheme.Font
    $form.BackColor = $script:UiTheme.PageBackground
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.KeyPreview = $true
    $script:UiRefs.Form = $form

    $mainToolTip = New-Object System.Windows.Forms.ToolTip
    $mainToolTip.AutoPopDelay = 9000
    $mainToolTip.InitialDelay = 250
    $mainToolTip.ReshowDelay = 100
    $mainToolTip.ShowAlways = $true

    # ---- Form-level docking --------------------------------------------------
    # Docked controls are laid out from the highest child index to 0. The Fill panel
    # is added FIRST so it is laid out LAST and receives only the space left by the
    # header and status bar. (If it were added after the status bar, it would extend
    # underneath it and its bottom edge would be clipped.)
    $mainPanel = New-Object System.Windows.Forms.Panel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.Padding = New-Object System.Windows.Forms.Padding(12)
    $form.Controls.Add($mainPanel)                      # index 0 - Fill

    [void](Create-StatusBar -ParentForm $form)          # index 1 - Bottom
    [void](Create-HeaderPanel -ParentForm $form)        # index 2 - Top

    # ---- Split container -------------------------------------------------------
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = [System.Windows.Forms.DockStyle]::Fill
    $split.IsSplitterFixed = $false
    $split.BackColor = $script:UiTheme.PageBackground
    $split.Panel1.BackColor = $script:UiTheme.PageBackground
    $split.Panel2.BackColor = $script:UiTheme.PageBackground
    $mainPanel.Controls.Add($split)
    $script:UiRefs.Split = $split

    # Right: Connection Library
    Create-TreeViewPanel -SplitContainer $split -ToolTip $mainToolTip

    # Left: scrollable column with sections in visual order
    $leftColumn = New-LeftColumn
    $split.Panel1.Controls.Add($leftColumn.Scroll)
    $script:UiRefs.LeftScroll = $leftColumn.Scroll
    [void](Create-QuickConnectPanel -Column $leftColumn.Stack -ToolTip $mainToolTip)
    [void](Create-AddToLibraryPanel -Column $leftColumn.Stack -ToolTip $mainToolTip)
    [void](Create-ActionsPanel -Column $leftColumn.Stack -ToolTip $mainToolTip)

    $form.Add_KeyDown({
        if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::F) {
            $_.SuppressKeyPress = $true
            $script:UiRefs.SearchBox.Focus()
            $script:UiRefs.SearchBox.SelectAll()
        }
    })

    $form.Add_Shown({
        $this.Activate()
        Set-SplitLayout -Split $script:UiRefs.Split

        # The first focusable control would otherwise be a button at the bottom of the
        # left column, and AutoScroll would scroll it into view. Focus the quick-connect
        # field instead and reset the scroll position.
        $this.ActiveControl = $script:UiRefs.QuickHost
        $script:UiRefs.LeftScroll.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    })

    Update-ConnectionView
    Set-Status ("{0} connection(s) loaded" -f $script:Connections.Count)

    [void]$form.ShowDialog()
}

# ====================================================================
# Entry Point
# ====================================================================

function Start-RDPManager {
    try {
        [System.Windows.Forms.Application]::EnableVisualStyles()
    }
    catch {
        Write-Verbose $_.Exception.Message
    }

    if (-not (Show-LoginDialog -DefaultUsername (Get-StoredUserName) -Standalone)) { return }

    $script:Connections = Import-Connections
    try {
        Show-MainForm
    }
    finally {
        $script:CurrentPassword = $null
        foreach ($path in @($script:TempFiles)) { Remove-TempRdpFile -Path $path }
    }
}

# Skipped when dot-sourced so the functions can be loaded without starting the UI.
if ($MyInvocation.InvocationName -ne '.') {
    Start-RDPManager
}
