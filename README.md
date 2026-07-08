# ConfigMgr Assessment Tool by J. Maia

Version 2.0.0-alpha | Build 0013

## Flow

1. Run Discovery
2. Run Core Health
3. Run MP
4. Generate HTML Report

## Build 0013

This build introduces the first ConfigMgr role-specific assessment module: Management Point Assessment.

The MP module collects evidence from connectivity checks, Windows services, IIS configuration, certificate store, MPControl.log and MPList URL live tests.

All findings are exported to CSV and included in the HTML report under the Management Point tab for each MP server.
