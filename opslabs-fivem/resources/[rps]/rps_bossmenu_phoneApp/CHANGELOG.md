# Changelog

## v1.0.1 - 2026-10-01

### Fixed
- The app's header ("Staff Roster" / "Hire Nearby") rendered underneath lb-phone's own status bar (clock/signal/battery), since nothing in the layout reserved space for it. Added top padding to `.app` so content starts below the status bar.
- The Manage modal's permission checkboxes were broken: `.field input`/`.field label` were descendant selectors, so they also matched the checkbox inputs/labels nested inside `.perm-list` — stretching every checkbox to full width and inheriting the section header's uppercase/gray/spacing styling. Scoped those rules to direct children only (`.field > input`, `.field > label`) and gave each permission row its own compact card style.

### Housekeeping
- Removed `ui/node_modules` from the resource folder (55+ MB of local build tooling that FXServer never reads — only `ui/dist` and the Lua files actually ship) and added `ui/.gitignore` so it doesn't creep back in.

## v1.0.0 - 2026-10-01

Initial release: Employee Management (roster, hire nearby, fire, manage rank/wage/permissions, bonuses) as an lb-phone app, mirroring the Billing Tablet's Employees feature in `rps_bossmenu`. No logic of its own — every action forwards to `rps_bossmenu`'s existing server events/callbacks.
