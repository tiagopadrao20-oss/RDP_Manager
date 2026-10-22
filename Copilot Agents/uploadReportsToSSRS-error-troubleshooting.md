# UploadReportsToSSRS – Troubleshooting Note

## Incident summary
During SSRS upload execution, folder creation completed successfully, then the script failed with:

- `-or : The term '-or' is not recognized as the name of a cmdlet...`
- Error location: `uploadReportsToSSRS.ps1` around line `573`

## What happened
The failure occurs in the file filter expression used to collect report/resource files.

Previous logic used a long `Where` expression split across multiple lines with PowerShell backtick line continuation (`` ` ``).
In Windows PowerShell 5.1, backtick continuation is fragile when:

- there are trailing spaces after a backtick,
- YAML/agent wrapping rewrites whitespace,
- or the script is copied through tooling that alters line endings/spacing.

When continuation breaks, a new line can start with `-or`, and PowerShell interprets it as a command name instead of a boolean operator.

## Root cause
A brittle multi-line predicate with backticks in this block:

- `Get-ChildItem ... | where { $_.Extension -like ... -or ... }`

This caused parser/runtime tokenization issues in the build agent context, producing the `CommandNotFoundException` for `-or`.

## Fix applied
The filter was refactored to remove backtick continuation entirely and use a robust predicate:

- Define allowed extensions in an array.
- Use `Where-Object` with explicit extension checks.
- Keep explicit file-name checks for `*.doc.xsl` and `*.doc.xslx`.

Updated block in `uploadReportsToSSRS.ps1`:

```powershell
$allowedExtensions = @('.xslx', '.xsl', '.rdl', '.docx', '.doc', '.xls', '.xlsx')
$files = Get-ChildItem -LiteralPath "$SourceDirectory" -Recurse -File | Where-Object {
    $extension = $_.Extension.ToLowerInvariant()
    ($allowedExtensions -contains $extension) -or
    ($_.Name -like '*.doc.xsl') -or
    ($_.Name -like '*.doc.xslx')
}
```

## Why this fix is safer
- No backtick continuation dependency.
- Works consistently in Windows PowerShell 5.1 and pipeline agents.
- Easier to maintain and extend with new file types.

## Validation checklist
1. Re-run the same pipeline/task with the updated script.
2. Confirm no `-or` command-not-found error appears.
3. Confirm logs proceed from folder creation to upload of `.rdl`/resource files.
4. Confirm reports are present in SSRS and data sources are updated.

## Optional hardening (recommended)
- Replace remaining `where` aliases with `Where-Object` for readability and lint compliance.
- Pipe `CreateFolder(...)` to `Out-Null` to avoid verbose object dump in logs.
- Add `Set-StrictMode -Version Latest` in non-prod tests to catch script fragility earlier.
