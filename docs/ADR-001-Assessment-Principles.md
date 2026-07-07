# ADR-001 - Assessment Principles

## Decision

ConfigMgr Assessment Tool by J. Maia follows the model:

**Facts → Rules → Evidence**

## Consequences

- The tool reports only facts it collected.
- Rules are applied only when objective thresholds exist.
- Every Warning/Critical finding should include evidence.
- The tool must not invent compliance scores when the required baseline is unknown.

## Example

Allowed:

- Pending Reboot = Yes
- Last Installed KB = KB5066783
- Days Since Last Patch = 3

Not allowed:

- Patch Compliance = 98% without knowing all required updates in the baseline.
