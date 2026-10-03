# RDP Connection Manager

A small Windows tool to organize and launch RDP sessions.

## Run

Double-click `Launch-RDPManager.cmd` (or run `RDPManager.ps1` with Windows PowerShell 5.1+).

## Features

- Sign in with your Active Directory account (verified against the domain, remembered in Windows Credential Manager).
- Connections grouped by **Market > Environment > Server Type**.
- **Quick Connect** for one-off hosts, with an option to use different credentials.
- **Library** with search, favorites, edit, remove, and a right-click menu.
- Shortcuts: `Ctrl+F` search, `Enter` connect, `F2` edit, `Del` remove, `Esc` clear search.

## AD Toolkit

A second tool in the same style, for four everyday AD / network checks. Run it with `Launch-ADToolkit.cmd`.

| Option | Command |
| --- | --- |
| User details | `Get-ADUser -Filter ... -Properties *` |
| Group members | `Get-ADGroup` + `Get-ADGroupMember [-Recursive]` |
| Network test | `Test-NetConnection -ComputerName <host> [-Port <port>]` |
| Change password | `Set-ADAccountPassword -OldPassword ... -NewPassword ...` (uses the current password, no reset rights needed) |

- Needs the ActiveDirectory module (RSAT) for the AD options; Test-NetConnection works without it.
- Optional domain controller (`-Server`) and **Run as...** (`-Credential`); credentials are kept in memory only.
- Results can be filtered, copied or exported to CSV. The executed command is shown above the results; passwords are never shown.

## SQL Server Reference

A read-only "bible" of T-SQL: pick a statement or function and see its syntax, an example and notes. Run it with `Launch-SqlReference.cmd`.

- About 165 entries in 15 categories: queries, joins, data modification, tables and schema, aggregate / string / date / math functions, conversion and NULL handling, window functions, JSON, programming, transactions and errors, system views and administration.
- Search by name, description or syntax, filter by category, copy the syntax or the example, and follow "See also" links.
- Entries show the SQL Server version where a feature is not available everywhere (for example `STRING_AGG` 2017+).
- No database connection is made. The content is in `SqlReference.txt`: add your own entries there (the format is described at the top of the file) and press **Reload**.

## Files

| File | Purpose |
| --- | --- |
| `RDPManager.ps1` | RDP Connection Manager |
| `Launch-RDPManager.cmd` | Launcher for the RDP Connection Manager |
| `savedconnections.xml` | Your saved connections (CLIXML, schema v2) |
| `ADToolkit.ps1` | AD Toolkit |
| `Launch-ADToolkit.cmd` | Launcher for the AD Toolkit |
| `SqlReference.ps1` | SQL Server Reference |
| `SqlReference.txt` | The reference content (editable) |
| `Launch-SqlReference.cmd` | Launcher for the SQL Server Reference |

## Notes

- Sessions start through a temporary `.rdp` file and `mstsc.exe`; the file is deleted shortly after launch.
- The connection file is written atomically. When an older file is migrated, a `savedconnections.xml.backup_*` copy is kept (last 5).
- An unreadable connection file is moved to `savedconnections.xml.corrupt_*` instead of being overwritten.
