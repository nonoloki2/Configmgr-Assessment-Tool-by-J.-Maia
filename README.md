# ConfigMgr Assessment Tool by J. Maia

Version 2.0.3-alpha | Build 0016

## Recommended test flow

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ConfigMgrAssessmentTool.ps1
```

Inside the tool:

1. Run Discovery
2. Run Core Health
3. Run MP
4. HTML Report

## Build 0016 focus

This build improves the Management Point module with MPControl.log Evidence Mode. The report now shows the signals found in MPControl.log and explains whether the latest known signal is Healthy, Warning, Critical or informational.
