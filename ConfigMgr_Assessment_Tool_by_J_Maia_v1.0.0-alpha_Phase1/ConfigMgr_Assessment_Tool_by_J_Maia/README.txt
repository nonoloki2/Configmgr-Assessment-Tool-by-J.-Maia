ConfigMgr Assessment Tool by J. Maia
Version: 1.0.0-alpha - Phase 1

PHASE 1 FEATURES
- WPF graphical interface
- Site Code and SMS Provider fields
- Run Discovery button
- Input validation
- Ping test
- WinRM test
- SMS Provider WMI/CIM namespace test: root\SMS\site_<SiteCode>
- Basic ConfigMgr site information collection via SMS_Site
- Site system role discovery via SMS_SystemResourceList
- Standardized assessment result object
- Execution log file per run
- CSV export with Assessment ID

HOW TO RUN
1. Copy the full folder to a Windows machine with network access to the ConfigMgr SMS Provider.
2. Open PowerShell as a user with permissions in ConfigMgr.
3. Run:
   powershell.exe -ExecutionPolicy Bypass -File .\ConfigMgrAssessmentTool.ps1

FIELDS
- Site Code: example PR1
- SMS Provider: server hosting the SMS Provider role. Often the Primary Site Server, but not always.

OUTPUT
- CSV files: .\Output\CSV
- Log files: .\Output\Logs

NOTES
- This phase is read-only.
- SQL Assessment is intentionally separated for future phases due to permission requirements.
- Future modules are visible as placeholders but not enabled yet.
