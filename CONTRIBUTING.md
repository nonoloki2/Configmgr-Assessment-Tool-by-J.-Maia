# Contributing

This project follows an evidence-based assessment model.

Every check should return structured data with:

- Assessment ID
- Module
- Category
- Check
- Target
- Role
- Value
- Status
- Severity
- Impact
- Finding
- Recommendation
- Evidence
- Rule ID

Do not add unsupported compliance percentages or assumptions unless the tool collects enough evidence to justify them.

## Release rule

A build is not stable until it passes:

- Tool opens without parser errors
- Discovery completes
- Core Health completes
- Role modules complete when enabled
- CSV export works
- HTML report works
- Open Output works
- No regression from the previous approved build
