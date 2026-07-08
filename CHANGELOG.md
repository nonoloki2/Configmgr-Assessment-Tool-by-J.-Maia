# Changelog

## v2.0.3-alpha Build 0016

- Adds Management Point Evidence Mode for MPControl.log.
- Classifies latest MPControl.log signal as Healthy, Warning or Critical using known availability patterns.
- Adds MP Evidence section to the HTML report.
- Enhances service evidence with display name, startup mode and service account.
- Treats BITS stopped with manual/trigger-start semantics as healthy unless symptoms exist.

## v2.0.2-alpha Build 0015

- Blocks HTML generation with a clear message when MP assessment has not been executed.
- Keeps Build 0014 MP checks intact.
