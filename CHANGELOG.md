# Changelog

## v1.4.0-alpha | Build 0011

### Added
- HTML Reporting Engine.
- **HTML Report** button in the GUI.
- Collapsible server cards.
- Dashboard summary with server/status counts.
- Search by server and filters by status/role.
- Role badges per server.
- Tabbed sections inside each server card: Overview, Operating System, Storage and Services.
- Storage cards with free-space bars.
- Patch Evidence section:
  - Last Installed KB
  - Installed On
  - Days Since Last Patch
  - Pending Reboot
  - Pending Reboot Reason
- ADR documentation folder.

### Changed
- Disk assessment now prioritizes free percentage and ignores small FAT/FAT32/system-reserved style volumes as NotApplicable.
- Tool version updated to 1.4.0-alpha Build 0011.

### Principle
- No unsupported compliance score is calculated. The tool reports facts, rule-based status and evidence.
