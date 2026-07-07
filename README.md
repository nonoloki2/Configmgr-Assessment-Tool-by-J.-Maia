# ConfigMgr Assessment Tool by J. Maia

Version **1.2.0-alpha** | Build **0009** | Release **1.2 - Core Health Assessment**

## What is included

- Professional GUI validated in Build 0008
- Discovery Engine
- Topology tree
- CSV export
- Execution log
- Open Output button
- New **Run Core Health** module

## Core Health checks in Build 0009

For every site system server discovered by Discovery:

- DNS resolution
- Ping
- WinRM
- Operating system caption/version/build
- Uptime and last boot time
- Fixed disk free space with warning/critical thresholds
- Basic Windows services
- Role-aware services such as IIS/W3SVC and WSUS service where applicable

## How to run

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ConfigMgrAssessmentTool.ps1
```

## Recommended test flow

1. Enter Site Code.
2. Enter SMS Provider.
3. Click **Run Discovery**.
4. Confirm Discovery completes.
5. Click **Run Core Health**.
6. Validate Results, Execution Log, CSV and Open Output.

## Acceptance check for Build 0009

- GUI opens without error.
- Discovery still works.
- Run Core Health becomes enabled only after Discovery.
- Core Health adds results to the grid.
- CSV exports CoreHealth rows.
- Open Output opens the CSV folder.
- Elapsed timer stops correctly after Core Health.
