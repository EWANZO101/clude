# rps_bossmenu_phone

An [lb-phone](https://docs.lbphone.com/) custom app that gives bosses/owners the
same Employee Management screen the physical boss tablet (`rps_bossmenu`) has —
roster, hire, fire, rank/wage/permissions, and bonuses — from their phone.

This resource has **no business logic of its own**. Every action in
`client/nui.lua` forwards straight to `rps_bossmenu`'s existing server events
and callbacks, so the phone app and the tablet always show identical data and
enforce identical permissions (boss/owner only — see
`server/billing.lua`'s `getEmployeesCallback` in `rps_bossmenu`).

## Requirements

- [lb-phone](https://lbscripts.com/) installed and started
- `rps_lib` and `rps_bossmenu` started before this resource

## Setting up the UI

The UI is a Vite + React + TypeScript project under `ui/`, same layout as
[lbphone/lb-phone-app-template](https://github.com/lbphone/lb-phone-app-template).

1. Install [Node.js](https://nodejs.org/en/download)
2. `cd ui && npm i`

### Developing

1. `npm run dev` (opens `http://localhost:3000`, with fake data so you can see
   the UI without a running server — see the `devMode` block in `ui/src/index.tsx`)
2. In `fxmanifest.lua`, comment out the production `ui_page` line and
   uncomment the `http://localhost:3000/` one
3. Restart the resource

### Building for production

1. `cd ui && npm run build` — output goes to `ui/dist`
2. In `fxmanifest.lua`, swap the `ui_page` lines back
3. Restart the resource

## Notes

- `Config.Identifier` (`config.lua`) must be unique across every custom app
  installed on the server.
- `Config.DefaultApp = false` means players have to download the app from the
  phone's App Store rather than having it pre-installed — flip it to `true` if
  you'd rather every business owner/boss already has it.
