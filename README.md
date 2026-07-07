# ConfigMgr Assessment Tool by J. Maia

Version: **1.1.1-alpha**  
Build: **0006**

## Scope of this build

Completion UX Fixes build:

- Makes Discovery completion unmistakable.
- Shows a success popup when Discovery finishes.
- Adds a clear completion summary: servers, roles, CSV and elapsed time.
- Disables Run Discovery while the operation is running.
- Re-enables buttons safely after completion or failure.
- Adds **Open Output** button.
- Prevents the Current task text from looking truncated without a tooltip.
- Keeps the Professional Foundation UI, dashboard, topology tree, logging and CSV export.

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

## Acceptance check for Build 0007

After clicking **Run Discovery**, the tool should end with:

- Header status: `Completed`
- Progress: 100%
- Completion summary visible under the buttons
- Success popup displayed
- CSV path shown in the status bar
- **Open Output** enabled
