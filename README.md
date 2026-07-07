# ConfigMgr Assessment Tool by J. Maia

Version **1.4.0-alpha** | Build **0011** | Release **HTML Reporting Engine**

## What is included

- Discovery Engine validated against the SMS Provider.
- Core Health Assessment with DNS, Ping, WinRM, OS, Uptime, Storage, Memory, CPU and Services.
- Patch Evidence facts:
  - Last Installed KB
  - Installed On
  - Days Since Last Patch
  - Pending Reboot
  - Pending Reboot Reason when detected
- CSV export for Excel/table analysis.
- HTML Report export for operational review.
- Server cards with collapsible sections.
- Role badges, status color, filters and search.

## Run

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ConfigMgrAssessmentTool.ps1
```

Recommended flow:

1. Enter Site Code.
2. Enter SMS Provider.
3. Click **Run Discovery**.
4. Click **Run Core Health**.
5. Click **HTML Report**.
6. Click **Open Output** if you want to browse the output folder.

## Project principle

The tool follows the **Facts → Rules → Evidence** model. It does not claim patch compliance scores or unsupported percentages. It reports evidence and applies objective rules only when the data supports them.
