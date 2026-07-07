# Changelog

## v1.3.0-alpha Build 0010

Release: Core Health Assessment Professional

### Added

- AssessmentPolicy.json for configurable thresholds.
- Rule Engine decisions for uptime, disk, memory, CPU and ping.
- Uptime rule: Healthy up to 37 days, Warning 38–59 days, Critical 60+ days.
- Disk assessment with total GB, used GB, free GB, used %, free %, file system and recommendation.
- Memory assessment with total, used, free and utilization percentage.
- CPU inventory and load assessment.
- Ping latency and packet loss assessment.
- WinRM elapsed time measurement.
- DNS reverse lookup evidence.
- Value, Impact and RuleId columns in the result object and grid.
- Initial Core Health Score.

### Changed

- Core Health now returns assessment-quality data instead of execution-only rows.
- CSV output is now better suited for Excel filtering and pivoting.

## v1.2.0-alpha Build 0009

- Added initial Core Health module.

## v1.1.3-alpha Build 0008

- Fixed stopwatch and success dialog issues.
