# ====================================================================
# SQL Server Reference
#
# A read-only "bible" of T-SQL statements and functions: pick one and see
# its syntax, an example and notes. No database connection is made.
#
# The content lives in SqlReference.txt (same folder). Add your own entries
# there - the format is explained at the top of that file - and use
# "Reload" in the app to pick them up.
#
# Shortcuts: Ctrl+F search | Esc clear search | Down jump to the list
#
# NOTE ON EVENT HANDLERS
# PowerShell event handlers do NOT see the local variables of a function that
# has already returned. Shared UI state lives in $script:UiRefs and per-control
# state in .Tag - never in captured locals.
# ====================================================================

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ====================================================================
# Configuration and state
# ====================================================================

$script:AppName = 'SQL Server Reference'
$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:DataPath = Join-Path $script:AppRoot 'SqlReference.txt'

$script:Entries = New-Object 'System.Collections.Generic.List[object]'
$script:Categories = @()
$script:SelectedKey = ''

# Shared references used by event handlers (see note at the top of the file).
$script:UiRefs = @{
    Form = $null
    Split = $null
    StatusBar = $null
    Search = $null
    CategoryBox = $null
    Tree = $null
    CountLabel = $null
    IsLoading = $false
    Detail = $null
}

# ====================================================================
# Layout Constants (Design Token System)
# ====================================================================

$script:UiLayout = [PSCustomObject]@{
    PaddingStandard = 16
    ControlSpacing = 8
    HeaderHeight = 72
    FilterRowHeight = 40
    ButtonHeightSmall = 32

    SplitterDefault = 380
    LeftMinWidth = 320
    RightMinWidth = 520

    TreeItemHeight = 26
    TreeIndent = 22
    TreeInnerPadding = 6
}

# ====================================================================
# UI Theme Configuration
# ====================================================================

$script:UiTheme = [PSCustomObject]@{
    Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
    FontStrong = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
    FontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 11, [System.Drawing.FontStyle]::Bold)
    FontHeading = New-Object System.Drawing.Font("Segoe UI Semibold", 18, [System.Drawing.FontStyle]::Regular)
    FontSummary = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Regular)
    FontCaption = New-Object System.Drawing.Font("Segoe UI Semibold", 8, [System.Drawing.FontStyle]::Regular)
    FontMono = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Regular)
    FontTreeCategory = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5, [System.Drawing.FontStyle]::Bold)

    Surface = [System.Drawing.Color]::White
    PageBackground = [System.Drawing.Color]::FromArgb(245, 247, 250)

    Accent = [System.Drawing.Color]::FromArgb(0, 120, 212)
    AccentHover = [System.Drawing.Color]::FromArgb(0, 99, 177)
    AccentLight = [System.Drawing.Color]::FromArgb(232, 243, 255)

    TextPrimary = [System.Drawing.Color]::FromArgb(40, 40, 40)
    TextMuted = [System.Drawing.Color]::FromArgb(90, 90, 90)
    TextDisabled = [System.Drawing.Color]::FromArgb(160, 160, 160)
    TextCategory = [System.Drawing.Color]::FromArgb(20, 20, 20)

    Border = [System.Drawing.Color]::FromArgb(216, 220, 227)
    DisabledBackground = [System.Drawing.Color]::FromArgb(238, 240, 243)
    CodeBackground = [System.Drawing.Color]::FromArgb(246, 248, 251)
    BadgeNeutral = [System.Drawing.Color]::FromArgb(238, 240, 243)
}

# ====================================================================
# Helper Functions - UI Element Creation
# ====================================================================

function New-UiPadding {
    param([int]$Left = 0, [int]$Top = 0, [int]$Right = 0, [int]$Bottom = 0)
    return New-Object System.Windows.Forms.Padding($Left, $Top, $Right, $Bottom)
}

function New-UiLabel {
    param(
        [string]$Text,
        [System.Drawing.Point]$Location,
        [int]$Width = 110,
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
        [string]$PlaceholderText = ""
    )

    $textBox = New-Object System.Windows.Forms.TextBox
    if ($PSBoundParameters.ContainsKey('Location')) { $textBox.Location = $Location }
    if ($PSBoundParameters.ContainsKey('Size')) { $textBox.Size = $Size }
    $textBox.Font = $script:UiTheme.Font

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

function Reset-SearchBox {
    <#
    .SYNOPSIS
        Empties the search box and shows the placeholder again (works whether or not it has focus).
    #>
    $box = $script:UiRefs.Search
    $box.Text = [string]$box.Tag
    $box.ForeColor = $script:UiTheme.TextMuted
}

function New-UiButton {
    param(
        [string]$Text,
        [System.Drawing.Point]$Location,
        [System.Drawing.Size]$Size,
        [switch]$Primary
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
        $button.ForeColor = $script:UiTheme.TextPrimary
        $button.FlatAppearance.BorderColor = $script:UiTheme.Border
        $button.Add_MouseEnter({ if ($this.Enabled) { $this.BackColor = $script:UiTheme.AccentLight } })
        $button.Add_MouseLeave({ if ($this.Enabled) { $this.BackColor = $script:UiTheme.Surface } })
    }

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

function Set-Status {
    param([string]$Message)
    if ($script:UiRefs.StatusBar) { $script:UiRefs.StatusBar.Text = $Message }
}

function Show-Failure {
    param([string]$Message, [string]$Title = 'Something went wrong')

    $owner = [System.Windows.Forms.Form]::ActiveForm
    if ($owner) {
        [void][System.Windows.Forms.MessageBox]::Show([System.Windows.Forms.IWin32Window]$owner, $Message, $Title, 'OK', 'Error')
    }
    else {
        [void][System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Error')
    }
}

function Invoke-SafeAction {
    param([scriptblock]$Action)

    try { & $Action }
    catch {
        Set-Status ("Failed: {0}" -f $_.Exception.Message)
        Show-Failure -Message $_.Exception.Message
    }
}

# ====================================================================
# Reference data
# ====================================================================

function Import-ReferenceData {
    <#
    .SYNOPSIS
        Parses SqlReference.txt (see the format description at the top of that file).
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "The reference file was not found:`n$Path" }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $current = $null
    $section = $null

    $finish = {
        param($item)
        if (-not $item) { return }

        # Trim blank lines at both ends of every section.
        $clean = @{}
        foreach ($name in 'Summary', 'Syntax', 'Example', 'Notes', 'SeeAlso') {
            $lines = New-Object 'System.Collections.Generic.List[string]'
            foreach ($l in $item[$name]) { $lines.Add($l) }
            while ($lines.Count -gt 0 -and -not $lines[0].Trim()) { $lines.RemoveAt(0) }
            while ($lines.Count -gt 0 -and -not $lines[$lines.Count - 1].Trim()) { $lines.RemoveAt($lines.Count - 1) }
            $clean[$name] = $lines.ToArray()
        }

        $seeAlso = @(($clean.SeeAlso -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $entries.Add([PSCustomObject]@{
            Key = ('{0}|{1}' -f $item.Category, $item.Name)
            Category = $item.Category
            Name = $item.Name
            Since = $item.Since
            Summary = ($clean.Summary -join ' ').Trim()
            Syntax = ($clean.Syntax -join "`r`n")
            Example = ($clean.Example -join "`r`n")
            Notes = ($clean.Notes -join ' ').Trim()
            SeeAlso = $seeAlso
        })
    }

    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^===\s*([^|]+?)\s*\|\s*([^|]+?)\s*(?:\|\s*(.*?))?\s*$') {
            & $finish $current
            $current = @{
                Category = $Matches[1]; Name = $Matches[2]; Since = [string]$Matches[3]
                Summary = @(); Syntax = @(); Example = @(); Notes = @(); SeeAlso = @()
            }
            $section = $null
            continue
        }

        if (-not $current) { continue }     # comment lines before the first entry

        if ($line -match '^(Summary|Syntax|Example|Notes|See also):\s?(.*)$') {
            $section = if ($Matches[1] -eq 'See also') { 'SeeAlso' } else { $Matches[1] }
            if ($Matches[2]) { $current[$section] += $Matches[2] }
            continue
        }

        if ($section) { $current[$section] += $line }
    }
    & $finish $current

    return , $entries
}

function Test-EntryMatch {
    param($Entry, [string]$Term)

    foreach ($field in 'Name', 'Summary', 'Category', 'Syntax', 'Notes') {
        $value = [string]$Entry.$field
        if ($value -and $value.IndexOf($Term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Find-Entry {
    <#
    .SYNOPSIS
        Resolves a "See also" name: exact name, then name starting with it, then name containing it.
    #>
    param([string]$Name)

    $entries = $script:Entries
    foreach ($e in $entries) { if ($e.Name -ieq $Name) { return $e } }
    foreach ($e in $entries) { if ($e.Name.StartsWith($Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $e } }
    foreach ($e in $entries) { if ($e.Name.IndexOf($Name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $e } }
    return $null
}

function Get-SelectedEntry {
    $tree = $script:UiRefs.Tree
    if (-not $tree -or -not $tree.SelectedNode) { return $null }
    $tag = $tree.SelectedNode.Tag
    if ($tag -is [PSCustomObject] -and $tag.PSObject.Properties['Syntax']) { return $tag }
    return $null
}

# ====================================================================
# Tree (categories and entries)
# ====================================================================

function Update-ReferenceTree {
    <#
    .SYNOPSIS
        Rebuilds the tree from the search text and category filter, keeping the open
        categories and the selected entry.
    #>
    $ui = $script:UiRefs
    if ($ui.IsLoading) { return }

    $tree = $ui.Tree
    $term = Get-FieldText $ui.Search
    $category = if ($ui.CategoryBox.SelectedIndex -gt 0) { [string]$ui.CategoryBox.SelectedItem } else { '' }
    $isFiltering = [bool]($term -or $category)

    $expanded = @{}
    foreach ($node in $tree.Nodes) { $expanded[$node.Name] = $node.IsExpanded }

    $visible = @($script:Entries | Where-Object {
            (-not $category -or $_.Category -eq $category) -and
            (-not $term -or (Test-EntryMatch -Entry $_ -Term $term))
        })

    $ui.IsLoading = $true
    $tree.BeginUpdate()
    try {
        $tree.Nodes.Clear()
        foreach ($name in $script:Categories) {
            $items = @($visible | Where-Object { $_.Category -eq $name })
            if ($items.Count -eq 0) { continue }

            $categoryNode = New-Object System.Windows.Forms.TreeNode
            $categoryNode.NodeFont = $script:UiTheme.FontTreeCategory
            $categoryNode.Text = '{0}  ({1})' -f $name, $items.Count
            $categoryNode.Name = "cat:$name"
            $categoryNode.Tag = $name
            $categoryNode.ForeColor = $script:UiTheme.TextCategory

            foreach ($entry in $items) {
                $entryNode = New-Object System.Windows.Forms.TreeNode
                $entryNode.NodeFont = $script:UiTheme.Font
                $entryNode.Text = $entry.Name
                $entryNode.Name = "entry:$($entry.Key)"
                $entryNode.Tag = $entry
                $entryNode.ToolTipText = $entry.Summary
                $entryNode.ForeColor = $script:UiTheme.TextPrimary
                [void]$categoryNode.Nodes.Add($entryNode)
            }

            [void]$tree.Nodes.Add($categoryNode)
            if ($isFiltering -or ($expanded.ContainsKey($categoryNode.Name) -and $expanded[$categoryNode.Name])) { $categoryNode.Expand() }
        }

        if ($script:SelectedKey) {
            $match = @($tree.Nodes.Find("entry:$($script:SelectedKey)", $true))
            if ($match.Count -gt 0) { $tree.SelectedNode = $match[0]; $match[0].EnsureVisible() }
        }
        if ($tree.Nodes.Count -gt 0) { $tree.TopNode = $tree.Nodes[0] }
    }
    finally {
        $tree.EndUpdate()
        $ui.IsLoading = $false
    }

    $total = $script:Entries.Count
    $ui.CountLabel.Text = if ($visible.Count -eq 0) { 'No entries match your search.' }
    elseif ($isFiltering) { "Showing $($visible.Count) of $total entries" }
    else { "$total entries in $($script:Categories.Count) categories" }

    Show-SelectedEntry
}

function Select-EntryByKey {
    <#
    .SYNOPSIS
        Clears the filters and selects an entry (used by "See also" links).
    #>
    param([string]$Key)

    $ui = $script:UiRefs
    $script:SelectedKey = $Key

    $ui.IsLoading = $true
    try {
        $ui.CategoryBox.SelectedIndex = 0
        Reset-SearchBox
    }
    finally { $ui.IsLoading = $false }

    Update-ReferenceTree
    $match = @($ui.Tree.Nodes.Find("entry:$Key", $true))
    if ($match.Count -gt 0) { $ui.Tree.SelectedNode = $match[0]; $match[0].EnsureVisible() }
}

# ====================================================================
# Details panel
# ====================================================================

function New-CaptionRow {
    <#
    .SYNOPSIS
        "SYNTAX" / "EXAMPLE" caption on the left and a Copy button on the right.
    #>
    param([string]$Text, [string]$CopyKind, [System.Windows.Forms.ToolTip]$ToolTip)

    $row = New-Object System.Windows.Forms.TableLayoutPanel
    $row.ColumnCount = 2
    $row.RowCount = 1
    $row.Height = 34
    $row.Dock = [System.Windows.Forms.DockStyle]::Fill
    $row.Margin = New-UiPadding 0 14 0 4
    [void]$row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$row.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $caption = New-UiLabel -Text $Text -Muted
    $caption.Font = $script:UiTheme.FontCaption
    $caption.AutoSize = $true
    $caption.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $caption.Margin = New-UiPadding 0 0 0 0
    $row.Controls.Add($caption, 0, 0)

    $button = New-UiButton -Text 'Copy' -Size (New-Object System.Drawing.Size(72, 26))
    $button.Tag = $CopyKind
    $button.Anchor = [System.Windows.Forms.AnchorStyles]::Right
    $button.Margin = New-UiPadding 0 0 0 0
    Add-UiTooltip -ToolTip $ToolTip -Control $button -Text "Copy the $($Text.ToLower()) to the clipboard"
    $button.Add_Click({ Invoke-SafeAction { Invoke-CopySection -Kind ([string]$this.Tag) } })
    $row.Controls.Add($button, 1, 0)

    return $row
}

function New-CodeBox {
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.WordWrap = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::None
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $box.BackColor = $script:UiTheme.CodeBackground
    $box.ForeColor = $script:UiTheme.TextPrimary
    $box.Font = $script:UiTheme.FontMono
    $box.Dock = [System.Windows.Forms.DockStyle]::Fill
    $box.Margin = New-UiPadding 0 0 0 0
    $box.TabStop = $false
    return $box
}

function Add-DetailRow {
    param([System.Windows.Forms.TableLayoutPanel]$Stack, [System.Windows.Forms.Control]$Control)

    $row = $Stack.RowStyles.Count
    [void]$Stack.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $Stack.RowCount = $row + 1
    $Stack.Controls.Add($Control, 0, $row)
}

function Create-DetailsPanel {
    <#
    .SYNOPSIS
        Right side: title, badges, summary, syntax, example, notes and see-also links.
        All controls are built once and filled by Show-SelectedEntry; hidden rows collapse.
    #>
    param([System.Windows.Forms.SplitContainer]$Split, [System.Windows.Forms.ToolTip]$ToolTip)

    $group = New-UiGroupBox -Text 'Reference' -Dock ([System.Windows.Forms.DockStyle]::Fill)
    $group.Padding = New-UiPadding $script:UiLayout.PaddingStandard 8 $script:UiLayout.PaddingStandard $script:UiLayout.PaddingStandard

    $host_ = New-BorderedHost
    $inner = $host_.Inner
    $inner.AutoScroll = $true
    $inner.Padding = New-UiPadding 24 20 24 20
    $group.Controls.Add($host_.Outer)

    $empty = New-UiLabel -Text '' -Muted
    $empty.AutoSize = $false
    $empty.Dock = [System.Windows.Forms.DockStyle]::Fill
    $empty.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $inner.Controls.Add($empty)

    $stack = New-Object System.Windows.Forms.TableLayoutPanel
    $stack.Dock = [System.Windows.Forms.DockStyle]::Top
    $stack.AutoSize = $true
    $stack.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $stack.ColumnCount = 1
    $stack.BackColor = [System.Drawing.Color]::Transparent
    [void]$stack.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $inner.Controls.Add($stack)

    $title = New-UiLabel -Text ''
    $title.Font = $script:UiTheme.FontHeading
    $title.AutoSize = $true
    $title.Margin = New-UiPadding 0 0 0 6
    Add-DetailRow -Stack $stack -Control $title

    $badges = New-Object System.Windows.Forms.FlowLayoutPanel
    $badges.AutoSize = $true
    $badges.WrapContents = $true
    $badges.Margin = New-UiPadding 0 0 0 10
    Add-DetailRow -Stack $stack -Control $badges

    $summary = New-UiLabel -Text ''
    $summary.Font = $script:UiTheme.FontSummary
    $summary.AutoSize = $true
    $summary.Margin = New-UiPadding 0 0 0 4
    Add-DetailRow -Stack $stack -Control $summary

    $syntaxRow = New-CaptionRow -Text 'SYNTAX' -CopyKind 'Syntax' -ToolTip $ToolTip
    $syntaxBox = New-CodeBox
    Add-DetailRow -Stack $stack -Control $syntaxRow
    Add-DetailRow -Stack $stack -Control $syntaxBox

    $exampleRow = New-CaptionRow -Text 'EXAMPLE' -CopyKind 'Example' -ToolTip $ToolTip
    $exampleBox = New-CodeBox
    Add-DetailRow -Stack $stack -Control $exampleRow
    Add-DetailRow -Stack $stack -Control $exampleBox

    $notesCaption = New-UiLabel -Text 'NOTES' -Muted
    $notesCaption.Font = $script:UiTheme.FontCaption
    $notesCaption.AutoSize = $true
    $notesCaption.Margin = New-UiPadding 0 16 0 4
    Add-DetailRow -Stack $stack -Control $notesCaption
    $notes = New-UiLabel -Text ''
    $notes.AutoSize = $true
    $notes.Margin = New-UiPadding 0 0 0 0
    Add-DetailRow -Stack $stack -Control $notes

    $seeCaption = New-UiLabel -Text 'SEE ALSO' -Muted
    $seeCaption.Font = $script:UiTheme.FontCaption
    $seeCaption.AutoSize = $true
    $seeCaption.Margin = New-UiPadding 0 16 0 4
    Add-DetailRow -Stack $stack -Control $seeCaption
    $seeAlso = New-Object System.Windows.Forms.FlowLayoutPanel
    $seeAlso.AutoSize = $true
    $seeAlso.WrapContents = $true
    $seeAlso.Margin = New-UiPadding 0 0 0 0
    Add-DetailRow -Stack $stack -Control $seeAlso

    $Split.Panel2.Controls.Add($group)

    $script:UiRefs.Detail = @{
        Inner = $inner; Empty = $empty; Stack = $stack
        Title = $title; Badges = $badges; Summary = $summary
        SyntaxRow = $syntaxRow; SyntaxBox = $syntaxBox
        ExampleRow = $exampleRow; ExampleBox = $exampleBox
        NotesCaption = $notesCaption; Notes = $notes
        SeeCaption = $seeCaption; SeeAlso = $seeAlso
    }

    $inner.Add_Resize({ Update-DetailLayout })
}

function Update-DetailLayout {
    <#
    .SYNOPSIS
        Wraps the text labels to the available width and sizes each code box to its text,
        so the whole page scrolls as one instead of showing inner scrollbars.
    #>
    $d = $script:UiRefs.Detail
    if (-not $d -or -not $d.Stack.Visible) { return }

    $available = $d.Stack.ClientSize.Width
    if ($available -le 40) { return }

    foreach ($label in @($d.Summary, $d.Notes)) {
        $label.MaximumSize = New-Object System.Drawing.Size(($available - 4), 0)
    }

    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::ExpandTabs
    foreach ($box in @($d.SyntaxBox, $d.ExampleBox)) {
        if (-not $box.Visible) { continue }
        $proposed = New-Object System.Drawing.Size(($available - 10), 0)
        $size = [System.Windows.Forms.TextRenderer]::MeasureText($box.Text, $box.Font, $proposed, $flags)
        # TextRenderer reports a slightly taller line (17px) than a TextBox actually draws (15px),
        # so count the lines first and multiply by the real line height.
        $measuredLine = [System.Windows.Forms.TextRenderer]::MeasureText('A', $box.Font, $proposed, $flags).Height
        $lines = [Math]::Max(1, [int][Math]::Round($size.Height / [double]$measuredLine))
        $box.Height = [int]([Math]::Floor($box.Font.GetHeight()) * $lines) + 12
    }
}

function Show-SelectedEntry {
    $d = $script:UiRefs.Detail
    if (-not $d) { return }

    $entry = Get-SelectedEntry
    if (-not $entry) {
        $node = $script:UiRefs.Tree.SelectedNode
        $d.Stack.Visible = $false
        $d.Empty.Visible = $true
        $d.Empty.Text = if ($node -and $node.Tag -is [string]) {
            "$($node.Tag)`n`nOpen the category and pick an entry."
        }
        else {
            "Pick a statement or function on the left`nto see its syntax and an example."
        }
        return
    }

    $script:SelectedKey = $entry.Key
    $d.Empty.Visible = $false
    $d.Stack.Visible = $true
    $d.Stack.SuspendLayout()

    $d.Title.Text = $entry.Name
    $d.Summary.Text = $entry.Summary

    $d.Badges.Controls.Clear()
    $badgeSpecs = @(@{ Text = $entry.Category; Back = $script:UiTheme.AccentLight; Fore = $script:UiTheme.Accent })
    if ($entry.Since) { $badgeSpecs += @{ Text = "SQL Server $($entry.Since)"; Back = $script:UiTheme.BadgeNeutral; Fore = $script:UiTheme.TextMuted } }
    foreach ($spec in $badgeSpecs) {
        $badge = New-UiLabel -Text $spec.Text
        $badge.AutoSize = $true
        $badge.Font = $script:UiTheme.FontStrong
        $badge.BackColor = $spec.Back
        $badge.ForeColor = $spec.Fore
        $badge.Padding = New-UiPadding 8 3 8 3
        $badge.Margin = New-UiPadding 0 0 8 0
        $d.Badges.Controls.Add($badge)
    }

    $hasSyntax = [bool]$entry.Syntax
    $d.SyntaxRow.Visible = $hasSyntax; $d.SyntaxBox.Visible = $hasSyntax
    $d.SyntaxBox.Text = $entry.Syntax

    $hasExample = [bool]$entry.Example
    $d.ExampleRow.Visible = $hasExample; $d.ExampleBox.Visible = $hasExample
    $d.ExampleBox.Text = $entry.Example

    $hasNotes = [bool]$entry.Notes
    $d.NotesCaption.Visible = $hasNotes; $d.Notes.Visible = $hasNotes
    $d.Notes.Text = $entry.Notes

    $d.SeeAlso.Controls.Clear()
    $hasLinks = $false
    foreach ($name in $entry.SeeAlso) {
        $target = Find-Entry -Name $name
        if ($target -and $target.Key -ne $entry.Key) {
            $link = New-Object System.Windows.Forms.LinkLabel
            $link.Text = $target.Name
            $link.Tag = $target.Key
            $link.AutoSize = $true
            $link.Font = $script:UiTheme.Font
            $link.LinkColor = $script:UiTheme.Accent
            $link.ActiveLinkColor = $script:UiTheme.AccentHover
            $link.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
            $link.Margin = New-UiPadding 0 0 14 4
            $link.Add_LinkClicked({ Invoke-SafeAction { Select-EntryByKey -Key ([string]$this.Tag) } })
            $d.SeeAlso.Controls.Add($link)
            $hasLinks = $true
        }
    }
    $d.SeeCaption.Visible = $hasLinks; $d.SeeAlso.Visible = $hasLinks

    $d.Stack.ResumeLayout($true)
    Update-DetailLayout
    $d.Inner.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)

    Set-Status ("{0} | {1}" -f $entry.Name, $entry.Summary)
}

function Invoke-CopySection {
    param([ValidateSet('Syntax', 'Example')][string]$Kind)

    $entry = Get-SelectedEntry
    if (-not $entry) { return }
    $text = [string]$entry.$Kind
    if (-not $text) { return }

    [System.Windows.Forms.Clipboard]::SetText($text)
    Set-Status ("Copied the {0} of {1} to the clipboard" -f $Kind.ToLower(), $entry.Name)
}

# ====================================================================
# UI Panel Creation Functions
# ====================================================================

function Create-HeaderPanel {
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
    $hint = New-UiLabel -Text 'Syntax and examples for T-SQL statements and functions (reference only, no database connection)' -Muted
    $hint.AutoSize = $true
    $hint.Margin = New-UiPadding 0 0 0 0
    $stack.Controls.Add($title)
    $stack.Controls.Add($hint)
    $layout.Controls.Add($stack, 0, 0)

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $buttons.WrapContents = $false
    $buttons.AutoSize = $true
    $buttons.Anchor = [System.Windows.Forms.AnchorStyles]::Right

    $btnEdit = New-UiButton -Text 'Edit data file' -Size (New-Object System.Drawing.Size(110, $script:UiLayout.ButtonHeightSmall))
    $btnEdit.Margin = New-UiPadding 0 0 8 0
    Add-UiTooltip -ToolTip $ToolTip -Control $btnEdit -Text 'Open SqlReference.txt to add or change entries'
    $btnEdit.Add_Click({ Invoke-SafeAction { Start-Process -FilePath $script:DataPath } })

    $btnReload = New-UiButton -Text 'Reload' -Size (New-Object System.Drawing.Size(80, $script:UiLayout.ButtonHeightSmall))
    $btnReload.Margin = New-UiPadding 0 0 0 0
    Add-UiTooltip -ToolTip $ToolTip -Control $btnReload -Text 'Read SqlReference.txt again'
    $btnReload.Add_Click({ Invoke-SafeAction { Invoke-ReloadData } })

    $buttons.Controls.AddRange(@($btnEdit, $btnReload))
    $layout.Controls.Add($buttons, 1, 0)

    $headerPanel.Controls.Add($layout)
    $ParentForm.Controls.Add($headerPanel)
    return $headerPanel
}

function Create-FilterBar {
    <#
    .SYNOPSIS
        Search box on the first line, category list below it.
    #>
    param([System.Windows.Forms.ToolTip]$ToolTip)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Top
    $panel.Height = 78
    $panel.Padding = New-UiPadding 0 0 0 $script:UiLayout.ControlSpacing

    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.Dock = [System.Windows.Forms.DockStyle]::Fill
    $table.ColumnCount = 1
    $table.RowCount = 2
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))

    $search = New-UiTextBox -Size (New-Object System.Drawing.Size(100, 24)) -PlaceholderText 'Search statements and functions...'
    $search.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $search.Margin = New-UiPadding 0 0 0 0
    Add-UiTooltip -ToolTip $ToolTip -Control $search -Text 'Matches the name, description and syntax (Ctrl+F)'
    $search.Add_TextChanged({ Invoke-SafeAction { Update-ReferenceTree } })
    $search.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $_.SuppressKeyPress = $true
            Invoke-SafeAction { Reset-SearchBox }
        }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Down) {
            $_.SuppressKeyPress = $true
            $script:UiRefs.Tree.Focus()
        }
    })
    $table.Controls.Add($search, 0, 0)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.Font = $script:UiTheme.Font
    $combo.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $combo.Margin = New-UiPadding 0 0 0 0
    Add-UiTooltip -ToolTip $ToolTip -Control $combo -Text 'Show only one category'
    $combo.Add_SelectedIndexChanged({ Invoke-SafeAction { Update-ReferenceTree } })
    $table.Controls.Add($combo, 0, 1)

    $panel.Controls.Add($table)
    return [PSCustomObject]@{ Panel = $panel; Search = $search; Combo = $combo }
}

function Create-ListPanel {
    <#
    .SYNOPSIS
        Left side: filters, the tree and a count line.

        DOCK ORDER MATTERS: WinForms lays out docked children from the HIGHEST child
        index down to 0, so the Fill tree host is added FIRST, then the Top controls.
        Adding the Fill control last makes it paint underneath the filter bar and count.
    #>
    param([System.Windows.Forms.SplitContainer]$Split, [System.Windows.Forms.ToolTip]$ToolTip)

    $group = New-UiGroupBox -Text 'Statements and functions' -Dock ([System.Windows.Forms.DockStyle]::Fill)
    $group.Padding = New-UiPadding $script:UiLayout.PaddingStandard 8 $script:UiLayout.PaddingStandard $script:UiLayout.PaddingStandard

    $treeHost = New-BorderedHost -InnerPadding $script:UiLayout.TreeInnerPadding

    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = [System.Windows.Forms.DockStyle]::Fill
    # The TreeView measures every label with ITS font, so it must be the widest one (bold
    # category); entries override it per node. A narrower control font would cut off the
    # bold category labels.
    $tree.Font = $script:UiTheme.FontTreeCategory
    $tree.ItemHeight = $script:UiLayout.TreeItemHeight
    $tree.Indent = $script:UiLayout.TreeIndent
    $tree.ShowNodeToolTips = $true
    $tree.HideSelection = $false
    $tree.ShowLines = $false
    $tree.FullRowSelect = $true
    $tree.ShowPlusMinus = $true
    $tree.ShowRootLines = $true
    $tree.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $tree.BackColor = $script:UiTheme.Surface
    $tree.Add_AfterSelect({
        if (-not $script:UiRefs.IsLoading) { Invoke-SafeAction { Show-SelectedEntry } }
    })
    $treeHost.Inner.Controls.Add($tree)

    $countLabel = New-UiLabel -Text '' -Muted
    $countLabel.AutoSize = $false
    $countLabel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $countLabel.Height = 28
    $countLabel.TextAlign = [System.Drawing.ContentAlignment]::BottomLeft

    $filter = Create-FilterBar -ToolTip $ToolTip

    # Order matters - see the DOCK ORDER note above.
    $group.Controls.Add($treeHost.Outer)      # Fill   (index 0)
    $group.Controls.Add($countLabel)          # Bottom
    $group.Controls.Add($filter.Panel)        # Top
    $Split.Panel1.Controls.Add($group)

    $script:UiRefs.Tree = $tree
    $script:UiRefs.CountLabel = $countLabel
    $script:UiRefs.Search = $filter.Search
    $script:UiRefs.CategoryBox = $filter.Combo
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
        FixedPanel = Panel1 keeps the list width and gives extra width to the reference page.
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
# Loading and main form
# ====================================================================

function Initialize-Data {
    <#
    .SYNOPSIS
        Reads the data file and refreshes the category list.
    #>
    $entries = Import-ReferenceData -Path $script:DataPath
    if ($entries.Count -eq 0) { throw "No entries were found in:`n$($script:DataPath)" }

    $script:Entries = $entries
    $script:Categories = @($entries | ForEach-Object { $_.Category } | Select-Object -Unique)

    $ui = $script:UiRefs
    if ($ui.CategoryBox) {
        $previous = if ($ui.CategoryBox.SelectedIndex -gt 0) { [string]$ui.CategoryBox.SelectedItem } else { '' }
        $ui.IsLoading = $true
        try {
            $ui.CategoryBox.Items.Clear()
            [void]$ui.CategoryBox.Items.Add('All categories')
            foreach ($name in $script:Categories) { [void]$ui.CategoryBox.Items.Add($name) }
            $index = if ($previous) { $ui.CategoryBox.Items.IndexOf($previous) } else { 0 }
            $ui.CategoryBox.SelectedIndex = [Math]::Max($index, 0)
        }
        finally { $ui.IsLoading = $false }
    }
}

function Invoke-ReloadData {
    Initialize-Data
    Update-ReferenceTree
    Set-Status ("Reloaded {0} entries from {1}" -f $script:Entries.Count, (Split-Path -Leaf $script:DataPath))
}

function Show-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $script:AppName
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size(1180, [Math]::Min(820, ($workArea.Height - 40)))
    $form.MinimumSize = New-Object System.Drawing.Size(940, 600)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $script:UiTheme.Font
    $form.BackColor = $script:UiTheme.PageBackground
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.KeyPreview = $true
    $script:UiRefs.Form = $form

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 9000
    $toolTip.InitialDelay = 300
    $toolTip.ReshowDelay = 100
    $toolTip.ShowAlways = $true

    # Form-level docking: the Fill panel is added FIRST so it is laid out LAST and only
    # receives the space left by the header and the status bar (see the DOCK ORDER notes).
    $mainPanel = New-Object System.Windows.Forms.Panel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.Padding = New-Object System.Windows.Forms.Padding(12)
    $form.Controls.Add($mainPanel)                                    # index 0 - Fill
    [void](Create-StatusBar -ParentForm $form)                        # index 1 - Bottom
    [void](Create-HeaderPanel -ParentForm $form -ToolTip $toolTip)    # index 2 - Top

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = [System.Windows.Forms.DockStyle]::Fill
    $split.BackColor = $script:UiTheme.PageBackground
    $split.Panel1.BackColor = $script:UiTheme.PageBackground
    $split.Panel2.BackColor = $script:UiTheme.PageBackground
    $mainPanel.Controls.Add($split)
    $script:UiRefs.Split = $split

    Create-DetailsPanel -Split $split -ToolTip $toolTip
    Create-ListPanel -Split $split -ToolTip $toolTip

    Initialize-Data
    Update-ReferenceTree
    Set-Status ("{0} entries loaded from {1}" -f $script:Entries.Count, $script:DataPath)

    $form.Add_KeyDown({
        if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::F) {
            $_.SuppressKeyPress = $true
            $script:UiRefs.Search.Focus()
            $script:UiRefs.Search.SelectAll()
        }
    })

    $form.Add_Shown({
        $this.Activate()
        Set-SplitLayout -Split $script:UiRefs.Split

        # Start on a useful page: SELECT.
        $first = $script:Entries | Where-Object { $_.Name -eq 'SELECT' } | Select-Object -First 1
        if ($first) { Select-EntryByKey -Key $first.Key }
        $script:UiRefs.Tree.Focus()
        Update-DetailLayout
    })

    [void]$form.ShowDialog()
}

# ====================================================================
# Entry Point
# ====================================================================

function Start-SqlReference {
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { Write-Verbose $_.Exception.Message }

    try { Show-MainForm }
    catch {
        Show-Failure -Message $_.Exception.Message -Title $script:AppName
    }
}

# Skipped when dot-sourced so the functions can be loaded without starting the UI.
if ($MyInvocation.InvocationName -ne '.') {
    Start-SqlReference
}
