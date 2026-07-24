MARCO 03.2 - Offline Error Knowledge Base

Run:
  powershell.exe -ExecutionPolicy Bypass -File .\SCCM_Monthly_Patch_Dashboard_Prototype_v2.4_Offline_AI.ps1

What changed:
- Local offline JSON knowledge base with 42 error codes.
- Error Detail is read from the local knowledge base first.
- New Recommended Actions column with 1 to 3 actions.
- New Import KB Update button in the existing PowerShell interface.
- Import validates the JSON and backs up the previous base.
- The dashboard never accesses the internet.

Keep the KnowledgeBase folder beside the PS1 file.
