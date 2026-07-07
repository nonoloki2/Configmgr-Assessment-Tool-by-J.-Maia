# Changelog

## v1.4.1-alpha | Build 0012

- Fixed mojibake/encoding issue in server card titles by replacing the emoji server glyph with a CSS-rendered icon.
- Report remains self-contained and offline-friendly.


## v1.4.1-alpha | Build 0012

### Added
- HTML Encoding Fix.
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
- Tool version updated to 1.4.1-alpha Build 0012.

### Principle
- No unsupported compliance score is calculated. The tool reports facts, rule-based status and evidence.
