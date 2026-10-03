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

## Files

| File | Purpose |
| --- | --- |
| `RDPManager.ps1` | The application |
| `Launch-RDPManager.cmd` | Launcher |
| `savedconnections.xml` | Your saved connections (CLIXML, schema v2) |

## Notes

- Sessions start through a temporary `.rdp` file and `mstsc.exe`; the file is deleted shortly after launch.
- The connection file is written atomically. When an older file is migrated, a `savedconnections.xml.backup_*` copy is kept (last 5).
- An unreadable connection file is moved to `savedconnections.xml.corrupt_*` instead of being overwritten.
