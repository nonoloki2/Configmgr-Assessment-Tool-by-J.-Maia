# ConfigMgr Assessment Tool by J. Maia

Version: **1.1.0-alpha**  
Build: **0005**

## Scope of this build

Professional Foundation build:

- Redesigned WPF UI using Grid layout.
- Fixed Site Code and SMS Provider textbox clipping.
- Discovery Engine 2.0 base inventory.
- Topology TreeView.
- Discovery dashboard summary.
- Structured CSV export.
- Structured logging by date.
- Rule Engine and Knowledge Base folders prepared.
- Settings.json support.

## Run

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ConfigMgrAssessmentTool.ps1
```

## Required input

- Site Code
- SMS Provider server

The SMS Provider is often the Primary Site Server, but not always.

## Output

- CSV: `Output\CSV`
- Logs: `Output\Logs\yyyy\MM\dd`

## Notes

This build is still focused on Discovery/Foundation. Core Health, MP, DP, SUP, WSUS, SQL and Distribution Content assessments will be added in later builds.
