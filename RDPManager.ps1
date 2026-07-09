Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:SchemaVersion = 2
$script:DefaultMarkets = @("PT", "ES", "DE", "UK", "GR", "NL", "UNK")
$script:DefaultEnvironments = @("DEV", "REC", "INT", "CONS", "PROD", "OTHER")
$script:LegacyEnvironmentMap = @{
    "PRD" = "PROD"
    "PRE" = "REC"
    "UAT" = "INT"
    "TEST" = "INT"
}
$script:CurrentUsername = $null
$script:CurrentPassword = $null
$script:Connections = New-Object System.Collections.ArrayList
$script:TreeView = $null
$script:SearchBox = $null
$script:StatusLabel = $null

function Test-ADAuthentication {
    param(
        [string]$Username,
        [string]$Password
    )

    try {
        return $null -ne (New-Object DirectoryServices.DirectoryEntry "", $Username, $Password).psbase.name
    }
    catch {
        return $false
    }
}

function Save-Credential {
    param(
        [string]$Username,
        [string]$Password
    )

    cmdkey /generic:"RDPManager_ADCreds" /user:$Username /pass:$Password | Out-Null
}

function Get-SavedCredential {
    try {
        $cred = cmdkey /list:"RDPManager_ADCreds" 2>$null
        if ($cred) {
            $userLine = $cred | Where-Object { $_ -match "User:" }
            if ($userLine -match "User:\s*(.+)") {
                return $matches[1].Trim()
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Remove-SavedCredential {
    cmdkey /delete:"RDPManager_ADCreds" 2>$null | Out-Null
}

function Get-ConfigPath {
    $scriptPath = Split-Path -Parent $MyInvocation.ScriptName
    if (-not $scriptPath) {
        $scriptPath = $PSScriptRoot
    }
    if (-not $scriptPath) {
        $scriptPath = Get-Location
    }

    return Join-Path $scriptPath "savedconnections.xml"
}

function Get-ParsedDisplayName {
    param(
        [string]$DisplayName
    )

    $result = [PSCustomObject]@{
        Market = "UNK"
        Environment = "DEV"
        ServerType = "GENERAL"
    }

    if (-not $DisplayName) {
        return $result
    }

    $envMatch = [regex]::Match($DisplayName, '\b(DEV2|DEV|REC|INT|CONS|PROD|PRD|PRE|UAT|TEST)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($envMatch.Success) {
        $rawEnvironment = $envMatch.Groups[1].Value.ToUpperInvariant()
        if ($script:LegacyEnvironmentMap.ContainsKey($rawEnvironment)) {
            $result.Environment = $script:LegacyEnvironmentMap[$rawEnvironment]
        }
        else {
            $result.Environment = $rawEnvironment
        }

        $left = $DisplayName.Substring(0, $envMatch.Index).Trim(' ', '-')
        $right = $DisplayName.Substring($envMatch.Index + $envMatch.Length).Trim(' ', '-')

        if ($left) {
            $result.Market = $left.ToUpperInvariant()
        }

        if ($right) {
            $result.ServerType = ($right -replace '\s{2,}', ' ').Trim().ToUpperInvariant()
        }

        return $result
    }

    # Fallback parser for names that use custom environment labels like DEVCloud.
    $tokens = $DisplayName -split '\s+-\s+|\s+-\s*|\s*-\s+'
    $tokens = @($tokens | Where-Object { $_ -and $_.Trim() })
    if ($tokens.Count -ge 3) {
        $result.Market = $tokens[0].Trim().ToUpperInvariant()
        $envToken = $tokens[1].Trim().ToUpperInvariant()

        if ($envToken -match 'DEV') { $result.Environment = 'DEV' }
        elseif ($envToken -match 'REC|PRE') { $result.Environment = 'REC' }
        elseif ($envToken -match 'INT|UAT|TEST') { $result.Environment = 'INT' }
        elseif ($envToken -match 'CONS') { $result.Environment = 'CONS' }
        elseif ($envToken -match 'PROD|PRD') { $result.Environment = 'PROD' }
        else { $result.Environment = 'OTHER' }

        $result.ServerType = (($tokens[2..($tokens.Count - 1)] -join ' - ').Trim()).ToUpperInvariant()
        if (-not $result.ServerType) {
            $result.ServerType = 'GENERAL'
        }
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
        [string]$Notes,
        [bool]$Favorite,
        [string]$Id,
        [datetime]$LastUsedUtc
    )

    if (-not $Id) {
        $Id = [Guid]::NewGuid().ToString()
    }

    if (-not $DisplayName) {
        $DisplayName = $Computer
    }

    if (-not $Market) {
        $Market = "UNK"
    }

    if (-not $Environment) {
        $Environment = "DEV"
    }

    if ($script:LegacyEnvironmentMap.ContainsKey($Environment.ToUpperInvariant())) {
        $Environment = $script:LegacyEnvironmentMap[$Environment.ToUpperInvariant()]
    }

    if (-not $ServerType) {
        $ServerType = "GENERAL"
    }

    if ($null -eq $LastUsedUtc) {
        $LastUsedUtc = [datetime]::MinValue
    }

    return [PSCustomObject]@{
        SchemaVersion = $script:SchemaVersion
        Id = $Id
        DisplayName = $DisplayName
        Computer = $Computer
        Market = $Market.ToUpperInvariant()
        Environment = $Environment.ToUpperInvariant()
        ServerType = $ServerType.ToUpperInvariant()
        Notes = $Notes
        Favorite = [bool]$Favorite
        LastUsedUtc = $LastUsedUtc
    }
}

function Convert-ToConnectionObject {
    param(
        $Connection
    )

    if (-not $Connection -or -not $Connection.Computer) {
        return $null
    }

    $displayName = if ($Connection.DisplayName) { $Connection.DisplayName } elseif ($Connection.Name) { $Connection.Name } else { $Connection.Computer }
    $parsed = Get-ParsedDisplayName -DisplayName $displayName
    $market = if ($Connection.Market) { $Connection.Market } else { $parsed.Market }
    $environment = if ($Connection.Environment) { $Connection.Environment } else { $parsed.Environment }
    $serverType = if ($Connection.ServerType) { $Connection.ServerType } else { $parsed.ServerType }
    $notes = if ($Connection.Notes) { $Connection.Notes } else { "" }
    $favorite = $false
    if ($Connection.PSObject.Properties.Name -contains "Favorite") {
        $favorite = [bool]$Connection.Favorite
    }

    $lastUsedUtc = [datetime]::MinValue
    if ($Connection.PSObject.Properties.Name -contains "LastUsedUtc" -and $Connection.LastUsedUtc) {
        try {
            $lastUsedUtc = [datetime]$Connection.LastUsedUtc
        }
        catch {
            $lastUsedUtc = [datetime]::MinValue
        }
    }

    $id = $null
    if ($Connection.PSObject.Properties.Name -contains "Id" -and $Connection.Id) {
        $id = [string]$Connection.Id
    }

    return New-ConnectionObject -DisplayName $displayName -Computer $Connection.Computer -Market $market -Environment $environment -ServerType $serverType -Notes $notes -Favorite $favorite -Id $id -LastUsedUtc $lastUsedUtc
}

function Save-ConnectionsList {
    param(
        [System.Collections.ArrayList]$Connections
    )

    $configFile = Get-ConfigPath

    try {
        $exportList = @()
        foreach ($conn in $Connections) {
            $normalized = Convert-ToConnectionObject -Connection $conn
            if ($normalized) {
                $exportList += $normalized
            }
        }

        $exportList | Export-Clixml -Path $configFile -Force
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to save connections: $($_.Exception.Message)", "Save Error",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Load-ConnectionsList {
    $configFile = Get-ConfigPath
    $arrayList = New-Object System.Collections.ArrayList

    if (-not (Test-Path $configFile)) {
        return $arrayList
    }

    try {
        $imported = Import-Clixml -Path $configFile
        if ($null -eq $imported) {
            return $arrayList
        }

        $items = @($imported)
        $needsMigration = $false

        foreach ($item in $items) {
            $normalized = Convert-ToConnectionObject -Connection $item
            if ($normalized) {
                $arrayList.Add($normalized) | Out-Null

                if (-not $item.Market -or -not $item.Environment -or -not $item.Id -or -not $item.SchemaVersion) {
                    $needsMigration = $true
                }
            }
        }

        if ($needsMigration -and $arrayList.Count -gt 0) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $backupFile = "{0}.backup_{1}" -f $configFile, $timestamp
            Copy-Item -Path $configFile -Destination $backupFile -Force
            Save-ConnectionsList -Connections $arrayList
        }

        return $arrayList
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to load connections: $($_.Exception.Message)", "Load Error",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return (New-Object System.Collections.ArrayList)
    }
}

function Set-Status {
    param([string]$Message)

    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Message
    }
}

function Get-ConnectionNodeText {
    param($Connection)

    return "{0} [{1}]" -f $Connection.DisplayName, $Connection.Computer
}

function Refresh-ConnectionTree {
    param(
        [string]$FilterText
    )

    if (-not $script:TreeView) {
        return
    }

    $script:TreeView.BeginUpdate()
    $script:TreeView.Nodes.Clear()

    $term = ""
    if ($FilterText) {
        $term = $FilterText.Trim().ToLowerInvariant()
    }

    $grouped = $script:Connections |
        Sort-Object Market, Environment, ServerType, DisplayName |
        Group-Object Market

    foreach ($marketGroup in $grouped) {
        $marketNode = New-Object System.Windows.Forms.TreeNode($marketGroup.Name)
        $marketNode.NodeFont = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $envGroups = $marketGroup.Group | Group-Object Environment | Sort-Object Name

        foreach ($envGroup in $envGroups) {
            $envNode = New-Object System.Windows.Forms.TreeNode($envGroup.Name)

            $typeGroups = $envGroup.Group | Group-Object ServerType | Sort-Object Name
            foreach ($typeGroup in $typeGroups) {
                $typeName = if ($typeGroup.Name) { $typeGroup.Name } else { "GENERAL" }
                $typeNode = New-Object System.Windows.Forms.TreeNode($typeName)

                $matchedConnections = @($typeGroup.Group)
                if ($term) {
                    $matchedConnections = $matchedConnections | Where-Object {
                        $_.DisplayName.ToLowerInvariant().Contains($term) -or
                        $_.Computer.ToLowerInvariant().Contains($term) -or
                        $_.ServerType.ToLowerInvariant().Contains($term)
                    }
                }

                foreach ($conn in ($matchedConnections | Sort-Object DisplayName, Computer)) {
                    $connNode = New-Object System.Windows.Forms.TreeNode((Get-ConnectionNodeText -Connection $conn))
                    $connNode.Tag = $conn
                    $typeNode.Nodes.Add($connNode) | Out-Null
                }

                if ($typeNode.Nodes.Count -gt 0) {
                    $envNode.Nodes.Add($typeNode) | Out-Null
                }
            }

            if ($envNode.Nodes.Count -gt 0) {
                $marketNode.Nodes.Add($envNode) | Out-Null
            }
        }

        if ($marketNode.Nodes.Count -gt 0) {
            $script:TreeView.Nodes.Add($marketNode) | Out-Null
        }
    }

    $script:TreeView.ExpandAll()
    $script:TreeView.EndUpdate()

    Set-Status -Message ("Connections loaded: {0}" -f $script:Connections.Count)
}

function Get-SelectedConnection {
    if (-not $script:TreeView -or -not $script:TreeView.SelectedNode) {
        return $null
    }

    $node = $script:TreeView.SelectedNode
    if ($node.Tag -and $node.Tag.Computer) {
        return $node.Tag
    }

    return $null
}

function Connect-RDP {
    param(
        [string]$ComputerName,
        [string]$Username,
        [string]$Password,
        [switch]$UseCustomCredentials
    )

    $actualUsername = $Username
    $actualPassword = $Password

    if ($UseCustomCredentials) {
        $customCredForm = New-Object System.Windows.Forms.Form
        $customCredForm.Text = "Custom Credentials - $ComputerName"
        $customCredForm.Size = New-Object System.Drawing.Size(420, 210)
        $customCredForm.StartPosition = "CenterParent"
        $customCredForm.FormBorderStyle = "FixedDialog"
        $customCredForm.TopMost = $true
        $customCredForm.MaximizeBox = $false
        $customCredForm.MinimizeBox = $false
        $customCredForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        $lblCustomUser = New-Object System.Windows.Forms.Label
        $lblCustomUser.Text = "Username:"
        $lblCustomUser.Location = New-Object System.Drawing.Point(15, 25)
        $lblCustomUser.Size = New-Object System.Drawing.Size(90, 22)
        $customCredForm.Controls.Add($lblCustomUser)

        $txtCustomUser = New-Object System.Windows.Forms.TextBox
        $txtCustomUser.Location = New-Object System.Drawing.Point(115, 22)
        $txtCustomUser.Size = New-Object System.Drawing.Size(280, 24)
        $txtCustomUser.Text = $Username
        $customCredForm.Controls.Add($txtCustomUser)

        $lblCustomPwd = New-Object System.Windows.Forms.Label
        $lblCustomPwd.Text = "Password:"
        $lblCustomPwd.Location = New-Object System.Drawing.Point(15, 62)
        $lblCustomPwd.Size = New-Object System.Drawing.Size(90, 22)
        $customCredForm.Controls.Add($lblCustomPwd)

        $txtCustomPwd = New-Object System.Windows.Forms.TextBox
        $txtCustomPwd.Location = New-Object System.Drawing.Point(115, 59)
        $txtCustomPwd.Size = New-Object System.Drawing.Size(280, 24)
        $txtCustomPwd.UseSystemPasswordChar = $true
        $customCredForm.Controls.Add($txtCustomPwd)

        $btnCustomOK = New-Object System.Windows.Forms.Button
        $btnCustomOK.Text = "Connect"
        $btnCustomOK.Location = New-Object System.Drawing.Point(115, 112)
        $btnCustomOK.Size = New-Object System.Drawing.Size(120, 34)
        $btnCustomOK.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
        $btnCustomOK.ForeColor = [System.Drawing.Color]::White
        $btnCustomOK.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnCustomOK.Add_Click({
            if ($txtCustomUser.Text -and $txtCustomPwd.Text) {
                $customCredForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $customCredForm.Close()
            }
            else {
                [System.Windows.Forms.MessageBox]::Show("Please enter both username and password.", "Missing Information",
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        })
        $customCredForm.Controls.Add($btnCustomOK)

        $btnCustomCancel = New-Object System.Windows.Forms.Button
        $btnCustomCancel.Text = "Cancel"
        $btnCustomCancel.Location = New-Object System.Drawing.Point(245, 112)
        $btnCustomCancel.Size = New-Object System.Drawing.Size(120, 34)
        $btnCustomCancel.Add_Click({
            $customCredForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $customCredForm.Close()
        })
        $customCredForm.Controls.Add($btnCustomCancel)

        $customCredForm.AcceptButton = $btnCustomOK
        $customCredForm.CancelButton = $btnCustomCancel

        $result = $customCredForm.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
            return $false
        }

        $actualUsername = $txtCustomUser.Text
        $actualPassword = $txtCustomPwd.Text
    }

    $rdpFile = Join-Path $env:TEMP ("temp_{0}.rdp" -f [Guid]::NewGuid().ToString())
    $rdpContent = @"
screen mode id:i:1
full address:s:$ComputerName
username:s:$actualUsername
prompt for credentials:i:0
administrative session:i:1
desktopwidth:i:1440
desktopheight:i:900
smart sizing:i:1
"@

    try {
        $rdpContent | Set-Content -Path $rdpFile -Encoding ASCII
        cmdkey /generic:"TERMSRV/$ComputerName" /user:$actualUsername /pass:$actualPassword | Out-Null
        Start-Process "mstsc.exe" -ArgumentList $rdpFile
        Set-Status -Message ("Connection launched for {0}" -f $ComputerName)
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to launch RDP: $($_.Exception.Message)", "RDP Error",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return $false
    }
    finally {
        Remove-Item $rdpFile -ErrorAction SilentlyContinue
    }
}

function New-ConnectionDialog {
    param(
        [string]$Title,
        $ExistingConnection
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Size = New-Object System.Drawing.Size(460, 350)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblComputer = New-Object System.Windows.Forms.Label
    $lblComputer.Text = "Hostname/IP"
    $lblComputer.Location = New-Object System.Drawing.Point(20, 20)
    $lblComputer.Size = New-Object System.Drawing.Size(110, 22)
    $dialog.Controls.Add($lblComputer)

    $txtComputer = New-Object System.Windows.Forms.TextBox
    $txtComputer.Location = New-Object System.Drawing.Point(150, 18)
    $txtComputer.Size = New-Object System.Drawing.Size(280, 24)
    $txtComputer.Text = if ($ExistingConnection) { $ExistingConnection.Computer } else { "" }
    $dialog.Controls.Add($txtComputer)

    $lblDisplay = New-Object System.Windows.Forms.Label
    $lblDisplay.Text = "Display Name"
    $lblDisplay.Location = New-Object System.Drawing.Point(20, 56)
    $lblDisplay.Size = New-Object System.Drawing.Size(110, 22)
    $dialog.Controls.Add($lblDisplay)

    $txtDisplay = New-Object System.Windows.Forms.TextBox
    $txtDisplay.Location = New-Object System.Drawing.Point(150, 54)
    $txtDisplay.Size = New-Object System.Drawing.Size(280, 24)
    $txtDisplay.Text = if ($ExistingConnection) { $ExistingConnection.DisplayName } else { "" }
    $dialog.Controls.Add($txtDisplay)

    $lblMarket = New-Object System.Windows.Forms.Label
    $lblMarket.Text = "Market"
    $lblMarket.Location = New-Object System.Drawing.Point(20, 92)
    $lblMarket.Size = New-Object System.Drawing.Size(110, 22)
    $dialog.Controls.Add($lblMarket)

    $cmbMarket = New-Object System.Windows.Forms.ComboBox
    $cmbMarket.Location = New-Object System.Drawing.Point(150, 90)
    $cmbMarket.Size = New-Object System.Drawing.Size(130, 24)
    $cmbMarket.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbMarket.Items.AddRange($script:DefaultMarkets)
    $cmbMarket.SelectedItem = if ($ExistingConnection -and $ExistingConnection.Market) { $ExistingConnection.Market } else { "DE" }
    if (-not $cmbMarket.SelectedItem) { $cmbMarket.SelectedIndex = 0 }
    $dialog.Controls.Add($cmbMarket)

    $lblEnvironment = New-Object System.Windows.Forms.Label
    $lblEnvironment.Text = "Environment"
    $lblEnvironment.Location = New-Object System.Drawing.Point(20, 128)
    $lblEnvironment.Size = New-Object System.Drawing.Size(110, 22)
    $dialog.Controls.Add($lblEnvironment)

    $cmbEnvironment = New-Object System.Windows.Forms.ComboBox
    $cmbEnvironment.Location = New-Object System.Drawing.Point(150, 126)
    $cmbEnvironment.Size = New-Object System.Drawing.Size(130, 24)
    $cmbEnvironment.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbEnvironment.Items.AddRange($script:DefaultEnvironments)
    $cmbEnvironment.SelectedItem = if ($ExistingConnection -and $ExistingConnection.Environment) { $ExistingConnection.Environment } else { "DEV" }
    if (-not $cmbEnvironment.SelectedItem) { $cmbEnvironment.SelectedIndex = 0 }
    $dialog.Controls.Add($cmbEnvironment)

    $lblNotes = New-Object System.Windows.Forms.Label
    $lblNotes.Text = "Notes"
    $lblNotes.Location = New-Object System.Drawing.Point(20, 200)
    $lblNotes.Size = New-Object System.Drawing.Size(110, 22)
    $dialog.Controls.Add($lblNotes)

    $lblServerType = New-Object System.Windows.Forms.Label
    $lblServerType.Text = "Server Type"
    $lblServerType.Location = New-Object System.Drawing.Point(20, 164)
    $lblServerType.Size = New-Object System.Drawing.Size(110, 22)
    $dialog.Controls.Add($lblServerType)

    $txtServerType = New-Object System.Windows.Forms.TextBox
    $txtServerType.Location = New-Object System.Drawing.Point(150, 162)
    $txtServerType.Size = New-Object System.Drawing.Size(280, 24)
    $txtServerType.Text = if ($ExistingConnection -and $ExistingConnection.ServerType) { $ExistingConnection.ServerType } else { "GENERAL" }
    $dialog.Controls.Add($txtServerType)

    $txtNotes = New-Object System.Windows.Forms.TextBox
    $txtNotes.Location = New-Object System.Drawing.Point(150, 198)
    $txtNotes.Size = New-Object System.Drawing.Size(280, 60)
    $txtNotes.Multiline = $true
    $txtNotes.Text = if ($ExistingConnection -and $ExistingConnection.Notes) { $ExistingConnection.Notes } else { "" }
    $dialog.Controls.Add($txtNotes)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Location = New-Object System.Drawing.Point(150, 272)
    $btnSave.Size = New-Object System.Drawing.Size(120, 32)
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $dialog.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(280, 272)
    $btnCancel.Size = New-Object System.Drawing.Size(120, 32)
    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })
    $dialog.Controls.Add($btnCancel)

    $btnSave.Add_Click({
        if (-not $txtComputer.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Hostname/IP is required.", "Validation",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $dialog.Tag = [PSCustomObject]@{
            DisplayName = if ($txtDisplay.Text.Trim()) { $txtDisplay.Text.Trim() } else { $txtComputer.Text.Trim() }
            Computer = $txtComputer.Text.Trim()
            Market = $cmbMarket.SelectedItem.ToString()
            Environment = $cmbEnvironment.SelectedItem.ToString()
            ServerType = if ($txtServerType.Text.Trim()) { $txtServerType.Text.Trim().ToUpperInvariant() } else { "GENERAL" }
            Notes = $txtNotes.Text.Trim()
        }

        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $dialog.AcceptButton = $btnSave
    $dialog.CancelButton = $btnCancel

    $dialogResult = $dialog.ShowDialog()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.Tag
    }

    return $null
}

function Is-DuplicateConnection {
    param(
        [string]$Computer,
        [string]$Market,
        [string]$Environment,
        [string]$ServerType,
        [string]$ExcludeId
    )

    foreach ($conn in $script:Connections) {
        if ($ExcludeId -and $conn.Id -eq $ExcludeId) {
            continue
        }

        if ($conn.Computer -eq $Computer -and $conn.Market -eq $Market -and $conn.Environment -eq $Environment -and $conn.ServerType -eq $ServerType) {
            return $true
        }
    }

    return $false
}

function Show-CredentialValidationForm {
    $savedUser = Get-SavedCredential

    if ($savedUser) {
        $passwordForm = New-Object System.Windows.Forms.Form
        $passwordForm.Text = "Validate Credentials"
        $passwordForm.Size = New-Object System.Drawing.Size(390, 220)
        $passwordForm.StartPosition = "CenterScreen"
        $passwordForm.FormBorderStyle = "FixedDialog"
        $passwordForm.TopMost = $true
        $passwordForm.MaximizeBox = $false
        $passwordForm.MinimizeBox = $false
        $passwordForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        $labelUser = New-Object System.Windows.Forms.Label
        $labelUser.Text = "Username: $savedUser"
        $labelUser.Location = New-Object System.Drawing.Point(15, 25)
        $labelUser.Size = New-Object System.Drawing.Size(350, 22)
        $passwordForm.Controls.Add($labelUser)

        $labelPwd = New-Object System.Windows.Forms.Label
        $labelPwd.Text = "Password:"
        $labelPwd.Location = New-Object System.Drawing.Point(15, 60)
        $labelPwd.Size = New-Object System.Drawing.Size(80, 22)
        $passwordForm.Controls.Add($labelPwd)

        $textboxPwd = New-Object System.Windows.Forms.TextBox
        $textboxPwd.Location = New-Object System.Drawing.Point(110, 58)
        $textboxPwd.Size = New-Object System.Drawing.Size(250, 24)
        $textboxPwd.UseSystemPasswordChar = $true
        $passwordForm.Controls.Add($textboxPwd)

        $btnValidate = New-Object System.Windows.Forms.Button
        $btnValidate.Text = "Validate"
        $btnValidate.Location = New-Object System.Drawing.Point(110, 108)
        $btnValidate.Size = New-Object System.Drawing.Size(120, 34)
        $btnValidate.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
        $btnValidate.ForeColor = [System.Drawing.Color]::White
        $btnValidate.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnValidate.Add_Click({
            if (Test-ADAuthentication -Username $savedUser -Password $textboxPwd.Text) {
                $script:CurrentUsername = $savedUser
                $script:CurrentPassword = $textboxPwd.Text
                Save-Credential -Username $savedUser -Password $textboxPwd.Text
                $passwordForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $passwordForm.Close()
            }
            else {
                [System.Windows.Forms.MessageBox]::Show("Invalid credentials. Please try again.", "Authentication Failed",
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                Remove-SavedCredential
                $passwordForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                $passwordForm.Close()
            }
        })
        $passwordForm.Controls.Add($btnValidate)

        $passwordForm.AcceptButton = $btnValidate

        $result = $passwordForm.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            return $true
        }
    }

    $credForm = New-Object System.Windows.Forms.Form
    $credForm.Text = "Enter AD Credentials"
    $credForm.Size = New-Object System.Drawing.Size(390, 250)
    $credForm.StartPosition = "CenterScreen"
    $credForm.FormBorderStyle = "FixedDialog"
    $credForm.TopMost = $true
    $credForm.MaximizeBox = $false
    $credForm.MinimizeBox = $false
    $credForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $labelUser = New-Object System.Windows.Forms.Label
    $labelUser.Text = "Username:"
    $labelUser.Location = New-Object System.Drawing.Point(15, 28)
    $labelUser.Size = New-Object System.Drawing.Size(90, 22)
    $credForm.Controls.Add($labelUser)

    $textboxUser = New-Object System.Windows.Forms.TextBox
    $textboxUser.Location = New-Object System.Drawing.Point(110, 26)
    $textboxUser.Size = New-Object System.Drawing.Size(250, 24)
    $credForm.Controls.Add($textboxUser)

    $labelPwd = New-Object System.Windows.Forms.Label
    $labelPwd.Text = "Password:"
    $labelPwd.Location = New-Object System.Drawing.Point(15, 66)
    $labelPwd.Size = New-Object System.Drawing.Size(90, 22)
    $credForm.Controls.Add($labelPwd)

    $textboxPwd = New-Object System.Windows.Forms.TextBox
    $textboxPwd.Location = New-Object System.Drawing.Point(110, 64)
    $textboxPwd.Size = New-Object System.Drawing.Size(250, 24)
    $textboxPwd.UseSystemPasswordChar = $true
    $credForm.Controls.Add($textboxPwd)

    $btnLogin = New-Object System.Windows.Forms.Button
    $btnLogin.Text = "Login"
    $btnLogin.Location = New-Object System.Drawing.Point(110, 116)
    $btnLogin.Size = New-Object System.Drawing.Size(120, 34)
    $btnLogin.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnLogin.ForeColor = [System.Drawing.Color]::White
    $btnLogin.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnLogin.Add_Click({
        if (Test-ADAuthentication -Username $textboxUser.Text -Password $textboxPwd.Text) {
            $script:CurrentUsername = $textboxUser.Text
            $script:CurrentPassword = $textboxPwd.Text
            Save-Credential -Username $textboxUser.Text -Password $textboxPwd.Text
            $credForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $credForm.Close()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Invalid credentials. Please try again.", "Authentication Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })
    $credForm.Controls.Add($btnLogin)

    $credForm.AcceptButton = $btnLogin
    $result = $credForm.ShowDialog()

    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

if (-not (Show-CredentialValidationForm)) {
    exit
}

$script:Connections = Load-ConnectionsList
if (-not $script:Connections) {
    $script:Connections = New-Object System.Collections.ArrayList
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "RDP Connection Manager"
$form.Size = New-Object System.Drawing.Size(980, 680)
$form.MinimumSize = New-Object System.Drawing.Size(900, 620)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 56
$headerPanel.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($headerPanel)

$labelStatus = New-Object System.Windows.Forms.Label
$labelStatus.Text = "Logged in as: $script:CurrentUsername"
$labelStatus.Location = New-Object System.Drawing.Point(16, 18)
$labelStatus.AutoSize = $true
$labelStatus.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$headerPanel.Controls.Add($labelStatus)

$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainPanel.Padding = New-Object System.Windows.Forms.Padding(12)
$form.Controls.Add($mainPanel)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = [System.Windows.Forms.DockStyle]::Fill
$split.SplitterDistance = 360
$split.Panel1MinSize = 320
$split.Panel2MinSize = 420
$split.IsSplitterFixed = $false
$mainPanel.Controls.Add($split)

$groupQuick = New-Object System.Windows.Forms.GroupBox
$groupQuick.Text = "Quick Connect"
$groupQuick.Dock = [System.Windows.Forms.DockStyle]::Top
$groupQuick.Height = 290
$split.Panel1.Controls.Add($groupQuick)

$lblComputer = New-Object System.Windows.Forms.Label
$lblComputer.Text = "Hostname/IP"
$lblComputer.Location = New-Object System.Drawing.Point(16, 32)
$lblComputer.Size = New-Object System.Drawing.Size(95, 22)
$groupQuick.Controls.Add($lblComputer)

$txtComputer = New-Object System.Windows.Forms.TextBox
$txtComputer.Location = New-Object System.Drawing.Point(120, 30)
$txtComputer.Size = New-Object System.Drawing.Size(220, 24)
$txtComputer.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$groupQuick.Controls.Add($txtComputer)

$lblDisplay = New-Object System.Windows.Forms.Label
$lblDisplay.Text = "Display Name"
$lblDisplay.Location = New-Object System.Drawing.Point(16, 68)
$lblDisplay.Size = New-Object System.Drawing.Size(95, 22)
$groupQuick.Controls.Add($lblDisplay)

$txtDisplay = New-Object System.Windows.Forms.TextBox
$txtDisplay.Location = New-Object System.Drawing.Point(120, 66)
$txtDisplay.Size = New-Object System.Drawing.Size(220, 24)
$txtDisplay.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$groupQuick.Controls.Add($txtDisplay)

$lblMarket = New-Object System.Windows.Forms.Label
$lblMarket.Text = "Market"
$lblMarket.Location = New-Object System.Drawing.Point(16, 104)
$lblMarket.Size = New-Object System.Drawing.Size(95, 22)
$groupQuick.Controls.Add($lblMarket)

$cmbMarket = New-Object System.Windows.Forms.ComboBox
$cmbMarket.Location = New-Object System.Drawing.Point(120, 102)
$cmbMarket.Size = New-Object System.Drawing.Size(100, 24)
$cmbMarket.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbMarket.Items.AddRange($script:DefaultMarkets)
$cmbMarket.SelectedItem = "DE"
$groupQuick.Controls.Add($cmbMarket)

$lblEnvironment = New-Object System.Windows.Forms.Label
$lblEnvironment.Text = "Environment"
$lblEnvironment.Location = New-Object System.Drawing.Point(16, 140)
$lblEnvironment.Size = New-Object System.Drawing.Size(95, 22)
$groupQuick.Controls.Add($lblEnvironment)

$cmbEnvironment = New-Object System.Windows.Forms.ComboBox
$cmbEnvironment.Location = New-Object System.Drawing.Point(120, 138)
$cmbEnvironment.Size = New-Object System.Drawing.Size(100, 24)
$cmbEnvironment.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbEnvironment.Items.AddRange($script:DefaultEnvironments)
$cmbEnvironment.SelectedItem = "DEV"
$groupQuick.Controls.Add($cmbEnvironment)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Connect"
$btnConnect.Location = New-Object System.Drawing.Point(16, 188)
$btnConnect.Size = New-Object System.Drawing.Size(100, 34)
$btnConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnConnect.ForeColor = [System.Drawing.Color]::White
$btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$groupQuick.Controls.Add($btnConnect)

$btnConnectCustom = New-Object System.Windows.Forms.Button
$btnConnectCustom.Text = "Custom Creds"
$btnConnectCustom.Location = New-Object System.Drawing.Point(124, 188)
$btnConnectCustom.Size = New-Object System.Drawing.Size(108, 34)
$groupQuick.Controls.Add($btnConnectCustom)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Save"
$btnSave.Location = New-Object System.Drawing.Point(240, 188)
$btnSave.Size = New-Object System.Drawing.Size(100, 34)
$groupQuick.Controls.Add($btnSave)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = "Tip: organize by Market and Environment to speed up operations."
$hintLabel.Location = New-Object System.Drawing.Point(16, 236)
$hintLabel.Size = New-Object System.Drawing.Size(330, 22)
$hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$groupQuick.Controls.Add($hintLabel)

$groupSaved = New-Object System.Windows.Forms.GroupBox
$groupSaved.Text = "Saved Connections"
$groupSaved.Dock = [System.Windows.Forms.DockStyle]::Fill
$split.Panel2.Controls.Add($groupSaved)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "Search"
$lblSearch.Location = New-Object System.Drawing.Point(14, 30)
$lblSearch.Size = New-Object System.Drawing.Size(50, 22)
$groupSaved.Controls.Add($lblSearch)

$script:SearchBox = New-Object System.Windows.Forms.TextBox
$script:SearchBox.Location = New-Object System.Drawing.Point(70, 28)
$script:SearchBox.Size = New-Object System.Drawing.Size(370, 24)
$script:SearchBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$groupSaved.Controls.Add($script:SearchBox)

$btnClearSearch = New-Object System.Windows.Forms.Button
$btnClearSearch.Text = "Clear"
$btnClearSearch.Location = New-Object System.Drawing.Point(446, 27)
$btnClearSearch.Size = New-Object System.Drawing.Size(80, 26)
$btnClearSearch.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$groupSaved.Controls.Add($btnClearSearch)

$script:TreeView = New-Object System.Windows.Forms.TreeView
$script:TreeView.Location = New-Object System.Drawing.Point(14, 62)
$script:TreeView.Size = New-Object System.Drawing.Size(512, 440)
$script:TreeView.HideSelection = $false
$script:TreeView.FullRowSelect = $true
$script:TreeView.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$groupSaved.Controls.Add($script:TreeView)

$btnConnectSaved = New-Object System.Windows.Forms.Button
$btnConnectSaved.Text = "Connect"
$btnConnectSaved.Location = New-Object System.Drawing.Point(14, 514)
$btnConnectSaved.Size = New-Object System.Drawing.Size(88, 32)
$btnConnectSaved.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$groupSaved.Controls.Add($btnConnectSaved)

$btnCustomSaved = New-Object System.Windows.Forms.Button
$btnCustomSaved.Text = "Custom"
$btnCustomSaved.Location = New-Object System.Drawing.Point(108, 514)
$btnCustomSaved.Size = New-Object System.Drawing.Size(88, 32)
$btnCustomSaved.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$groupSaved.Controls.Add($btnCustomSaved)

$btnEdit = New-Object System.Windows.Forms.Button
$btnEdit.Text = "Edit"
$btnEdit.Location = New-Object System.Drawing.Point(202, 514)
$btnEdit.Size = New-Object System.Drawing.Size(88, 32)
$btnEdit.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$groupSaved.Controls.Add($btnEdit)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = "Remove"
$btnRemove.Location = New-Object System.Drawing.Point(296, 514)
$btnRemove.Size = New-Object System.Drawing.Size(88, 32)
$btnRemove.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$groupSaved.Controls.Add($btnRemove)

$btnChangeCredentials = New-Object System.Windows.Forms.Button
$btnChangeCredentials.Text = "Change Credentials"
$btnChangeCredentials.Location = New-Object System.Drawing.Point(390, 514)
$btnChangeCredentials.Size = New-Object System.Drawing.Size(136, 32)
$btnChangeCredentials.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$groupSaved.Controls.Add($btnChangeCredentials)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$script:StatusLabel.Text = "Ready"
$statusStrip.Items.Add($script:StatusLabel) | Out-Null
$form.Controls.Add($statusStrip)

$btnConnect.Add_Click({
    if (-not $txtComputer.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a hostname or IP address.", "Missing Information",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    Connect-RDP -ComputerName $txtComputer.Text.Trim() -Username $script:CurrentUsername -Password $script:CurrentPassword | Out-Null
})

$btnConnectCustom.Add_Click({
    if (-not $txtComputer.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a hostname or IP address.", "Missing Information",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    Connect-RDP -ComputerName $txtComputer.Text.Trim() -Username $script:CurrentUsername -Password $script:CurrentPassword -UseCustomCredentials | Out-Null
})

$btnSave.Add_Click({
    if (-not $txtComputer.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a hostname or IP address.", "Missing Information",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $market = $cmbMarket.SelectedItem.ToString()
    $environment = $cmbEnvironment.SelectedItem.ToString()
    $computer = $txtComputer.Text.Trim()
    $parsed = Get-ParsedDisplayName -DisplayName $txtDisplay.Text.Trim()
    $serverType = if ($parsed.ServerType -and $parsed.ServerType -ne "GENERAL") { $parsed.ServerType } else { "GENERAL" }

    if (Is-DuplicateConnection -Computer $computer -Market $market -Environment $environment -ServerType $serverType) {
        [System.Windows.Forms.MessageBox]::Show("A connection with the same host, market, environment and server type already exists.", "Duplicate",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $newConn = New-ConnectionObject -DisplayName $txtDisplay.Text.Trim() -Computer $computer -Market $market -Environment $environment -ServerType $serverType -Notes "" -Favorite $false -LastUsedUtc ([datetime]::MinValue)
    $script:Connections.Add($newConn) | Out-Null
    Save-ConnectionsList -Connections $script:Connections
    Refresh-ConnectionTree -FilterText $script:SearchBox.Text

    $txtComputer.Clear()
    $txtDisplay.Clear()
    Set-Status -Message "Connection saved successfully"
})

$script:SearchBox.Add_TextChanged({
    Refresh-ConnectionTree -FilterText $script:SearchBox.Text
})

$btnClearSearch.Add_Click({
    $script:SearchBox.Clear()
    Refresh-ConnectionTree -FilterText ""
})

$script:TreeView.Add_DoubleClick({
    $conn = Get-SelectedConnection
    if ($conn) {
        if (Connect-RDP -ComputerName $conn.Computer -Username $script:CurrentUsername -Password $script:CurrentPassword) {
            $conn.LastUsedUtc = [datetime]::UtcNow
            Save-ConnectionsList -Connections $script:Connections
        }
    }
})

$btnConnectSaved.Add_Click({
    $conn = Get-SelectedConnection
    if (-not $conn) {
        [System.Windows.Forms.MessageBox]::Show("Please select a connection.", "No Selection",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    if (Connect-RDP -ComputerName $conn.Computer -Username $script:CurrentUsername -Password $script:CurrentPassword) {
        $conn.LastUsedUtc = [datetime]::UtcNow
        Save-ConnectionsList -Connections $script:Connections
    }
})

$btnCustomSaved.Add_Click({
    $conn = Get-SelectedConnection
    if (-not $conn) {
        [System.Windows.Forms.MessageBox]::Show("Please select a connection.", "No Selection",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    if (Connect-RDP -ComputerName $conn.Computer -Username $script:CurrentUsername -Password $script:CurrentPassword -UseCustomCredentials) {
        $conn.LastUsedUtc = [datetime]::UtcNow
        Save-ConnectionsList -Connections $script:Connections
    }
})

$btnEdit.Add_Click({
    $conn = Get-SelectedConnection
    if (-not $conn) {
        [System.Windows.Forms.MessageBox]::Show("Please select a connection to edit.", "No Selection",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $edited = New-ConnectionDialog -Title "Edit Connection" -ExistingConnection $conn
    if (-not $edited) {
        return
    }

    if (Is-DuplicateConnection -Computer $edited.Computer -Market $edited.Market -Environment $edited.Environment -ServerType $edited.ServerType -ExcludeId $conn.Id) {
        [System.Windows.Forms.MessageBox]::Show("A connection with the same host, market, environment and server type already exists.", "Duplicate",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $conn.DisplayName = $edited.DisplayName
    $conn.Computer = $edited.Computer
    $conn.Market = $edited.Market
    $conn.Environment = $edited.Environment
    $conn.ServerType = $edited.ServerType
    $conn.Notes = $edited.Notes

    Save-ConnectionsList -Connections $script:Connections
    Refresh-ConnectionTree -FilterText $script:SearchBox.Text
    Set-Status -Message "Connection updated"
})

$btnRemove.Add_Click({
    $conn = Get-SelectedConnection
    if (-not $conn) {
        [System.Windows.Forms.MessageBox]::Show("Please select a connection to remove.", "No Selection",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $result = [System.Windows.Forms.MessageBox]::Show("Remove selected connection?", "Confirm Removal",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)

    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    $updated = New-Object System.Collections.ArrayList
    foreach ($item in $script:Connections) {
        if ($item.Id -ne $conn.Id) {
            $updated.Add($item) | Out-Null
        }
    }

    $script:Connections = $updated
    Save-ConnectionsList -Connections $script:Connections
    Refresh-ConnectionTree -FilterText $script:SearchBox.Text
    Set-Status -Message "Connection removed"
})

$btnChangeCredentials.Add_Click({
    Remove-SavedCredential
    [System.Windows.Forms.MessageBox]::Show("Credentials were cleared. Restart the app to sign in with a new account.", "Credentials Cleared",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    $form.Close()
})

$form.Add_Shown({
    Refresh-ConnectionTree -FilterText ""
    $txtComputer.Focus()
})

Set-Status -Message "Ready"
$form.ShowDialog() | Out-Null
