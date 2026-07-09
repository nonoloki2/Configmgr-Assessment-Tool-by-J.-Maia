# Branching Strategy

## Branches

- `main`: stable builds only, validated in a real ConfigMgr environment.
- `develop`: active development builds and hotfixes before validation.

## Build flow

1. Create or switch to `develop`.
2. Apply code changes.
3. Test the standard workflow:
   - Discovery
   - CSV export
   - HTML Report
   - Open Output
4. Commit with the build number.
5. When approved, merge to `main` and tag the release.

## Example

```powershell
git checkout -b develop
git add .
git commit -m "Build 0018 - Workflow and UX refactoring"
git checkout main
git merge develop
git tag v2.0.5-alpha-build0018
git push origin main develop --tags
```
