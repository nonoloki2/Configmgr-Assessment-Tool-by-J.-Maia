# ConfigMgr Assessment Tool by J. Maia

Version: **1.0.0-alpha - Phase 1 Fixed MVP**

## Goal

PowerShell GUI tool for ConfigMgr/SCCM infrastructure assessment.

Phase 1 focuses only on **Discovery**:

- Validate Site Code and SMS Provider input
- Test DNS resolution
- Test ping
- Test WinRM
- Connect to SMS Provider WMI namespace
- Read site information
- Discover site system servers and roles
- Show results in the GUI
- Show topology tree
- Export CSV
- Save execution log

## How to run

Open PowerShell from the project folder and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ConfigMgrAssessmentTool.ps1
```

## Required fields

- **Site Code**: ConfigMgr site code, example: `PR1`
- **SMS Provider**: Server that hosts the SMS Provider, often the Primary Site Server, but not always.

## Output

CSV files are created in:

```text
Output\CSV
```

Execution logs are created in:

```text
Output\Logs
```

## Notes

This phase is read-only.
