# ConfigMgr Assessment Tool by J. Maia

Version 2.0.1-alpha | Build 0014

## Current focus

Management Point Assessment - Connectivity, Services and IIS Prerequisites.

## Test flow

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ConfigMgrAssessmentTool.ps1
```

Then run:

1. Run Discovery
2. Run Core Health
3. Run MP
4. HTML Report

## Build 0014

This build adds the first evidence-based Management Point assessment layer and fixes HTML server matching between FQDN and short names.
