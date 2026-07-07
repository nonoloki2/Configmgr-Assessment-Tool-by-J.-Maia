# ConfigMgr Assessment Tool by J. Maia

Version: **1.3.0-alpha**  
Build: **0010**  
Release: **Core Health Assessment Professional**

## What is included

- Professional WPF interface
- Discovery Engine
- Topology tree
- CSV export
- Execution logging
- Open Output button
- Core Health module
- Assessment Policy Engine
- Rule Engine for Core Health thresholds
- Rich CSV values for uptime, disk, memory, CPU, ping, DNS and WinRM
- Initial Health Score calculation

## Core Health checks

Run Discovery first, then run Core Health.

Core Health collects:

- DNS forward and reverse information
- Ping average, min, max and packet loss
- WinRM response time
- OS caption, version, build, architecture and install date
- Last boot time and uptime days
- Disk total, used, free, used %, free % and file system
- Physical memory total, used, free, used % and free %
- CPU sockets, cores, logical processors and current load
- Core services depending on role

## Assessment policy

Thresholds are stored in:

```text
Config\AssessmentPolicy.json
```

Default uptime policy:

- Healthy: 0–37 days
- Warning: 38–59 days
- Critical: 60+ days

Disk policy defaults:

- Healthy: 20%+ free and at least 20 GB free
- Warning: below 20% or below 20 GB free
- Critical: below 10% or below 10 GB free

## How to run

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ConfigMgrAssessmentTool.ps1
```

Recommended flow:

1. Enter Site Code.
2. Enter SMS Provider.
3. Run Discovery.
4. Run Core Health.
5. Export CSV.
6. Open Output.
