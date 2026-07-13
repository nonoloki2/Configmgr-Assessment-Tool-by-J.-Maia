# Changelog

## v2.0.6-alpha Build 0019 - Distribution Point Assessment

- Added a dedicated `DistributionPointEngine.psm1` module.
- Integrated Distribution Point assessment as step 4/4 of the existing workflow.
- Added read-only checks for DNS, ping, CIM, W3SVC, SMS_EXECUTIVE, DP shares, Content Library location, free space, drive exclusion markers and SMS Provider DP configuration.
- Added Distribution Point results to CSV and HTML reports.
- Preserved the exact stable WPF window dimensions and native minimize, maximize and close behavior from Build 0018.
- No remediation or environment modification actions are performed.


## v2.0.5-alpha Build 0018 - Workflow and UX Refactoring

- Restored standard Windows window controls through explicit WindowStyle and ResizeMode.
- Removed the Exit button from the UI.
- Consolidated Run Discovery, Run Core Health and Run MP into a single **Discovery** workflow button.
- Added clean run reset logic so the full assessment can be executed again in the same application session.
- Reorganized toolbar buttons to avoid Open Output truncation and provide room for future modules.
- Discovery now orchestrates: Discovery Engine, Core Health Engine, Management Point Engine and CSV export.

## v2.0.4-alpha Build 0017
- Hotfix release: restores the stable Management Point engine after rejected Build 0016 parser error.
- Uses the last validated MP implementation from Build 0015 as the baseline.
- Keeps Run MP output working in the HTML report: Connectivity, Services and IIS sections.
- Keeps the HTML guard that warns if MP roles exist but Run MP was not executed before report generation.
- No new MPControl.log Evidence Mode changes are included in this hotfix; that feature will return in a later build after validation.
