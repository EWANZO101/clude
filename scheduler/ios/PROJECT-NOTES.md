# Scheduler iPhone app: project notes

Last updated: 26 September 2026. Kept out of git on purpose (contains the demo login).

## Status right now

| Item | State |
|---|---|
| App built and uploaded to App Store Connect | ✅ Version 1.0.0, build 2, processed by Apple ("VALID") |
| App Store listing (text, screenshots, build, review info, categories, age rating) | ✅ Filled in via the API |
| Push notifications in Expo Go | ✅ Working |
| **Push notifications in the TestFlight / App Store app** | ❌ **APNs push key not uploaded yet** (see To do #1) |
| App Privacy section in App Store Connect | ⏳ You fill it in (API can't) |
| Submitted for App Review | ⏳ Not yet |

## To do

1. **Upload the push key** (without it, notifications don't reach the App Store/TestFlight app):
   1. https://developer.apple.com/account/resources/authkeys/add → name `Scheduler Push`, tick
      **Apple Push Notifications service (APNs)** → Configure → **Sandbox & Production** → Save → Continue → Register.
   2. **Download** the `AuthKey_XXXXXXXXXX.p8` (one download only) and note the **Key ID**.
   3. https://expo.dev/accounts/opslabs/projects/scheduler/credentials → iOS identifier **opslabs-scheduler** →
      **Push Key** → **Add a Push Key** → upload the .p8, enter the Key ID and Team ID `8937GN7874`.
   4. No rebuild needed. Test with "Send test notification" on the Today screen.
2. **In the TestFlight app, sign in with your real admin account**, not the demo one. Website bookings belong to
   your main account, so only phones signed in as that account get notified about them.
3. **App Store Connect → App Privacy → Get Started**: no tracking; data used for App Functionality only:
   email address, name, phone number, other user content (booking notes). Then **Publish**.
4. Version page → **Add for Review** → **Submit for Review**. Review usually takes 1–3 days.

## Accounts and IDs

| What | Value |
|---|---|
| Expo account / project | `opslabs` / `@opslabs/scheduler` (project ID 39e245e2-2b57-4cc2-be1b-e5256098cee0) |
| Apple Team ID | `8937GN7874` (Individual: Ewan Campbell) |
| Bundle ID | `opslabs-scheduler` |
| App Store Connect app | **OpsLab Scheduler**, Apple ID `6816490382` |
| App Review demo login | `appreview@opslabsystems.cloud` / `SchedulerDemo5244` |
| App Store Connect API key | Key ID `5CSC5GB633`, Issuer `3bbfb750-b3a3-4b40-97e1-34f92c356c2f`, file `/root/.appstore-key.p8` |
| EAS environment for the key | `/root/.appstore-eas.env` (root-only) |

The API key has Admin access to your Apple account. Revoke it any time at
https://appstoreconnect.apple.com/access/integrations/api.

## Where things are

- **App code:** `/root/scheduler/ios` (git, branch `mobile-app`; `master` is the original template).
  Merge when ready: `git checkout master && git merge mobile-app`
- **App Store listing text:** `store/listing.md`; screenshots: `store/screenshots/`
- **Backend (Flask, live on port 5076, NOT in git):** `/root/scheduler`
  - `app/routes/api.py`: the `/api/v1` JSON API the app uses
  - `app/services/push.py`: sends notifications through Expo's push service
  - `app/models/push_device.py` + migration `c3d4e5f6a7b8`: registered phones
  - `app/templates/public/privacy.html`: https://scheduler.opslabsystems.cloud/privacy
  - `flask seed-review-account`: creates/refreshes the demo account (in `app/__init__.py`)
  - `tests/test_api.py`: run with `python3 -m pytest tests/ -q`
- **Backups taken before changes:** `/root/scheduler-backup-before-api-20260926-164826.tar.gz`,
  `/root/scheduler-db-before-push-20260926-172935.db`, `/root/scheduler-db-before-review-account-20260926-174339.db`

## Common commands

Reload the live backend gracefully (after backend code changes):
```
kill -HUP $(systemctl show -p MainPID --value scheduler)
```

Run the app on your phone in Expo Go (needs `npx expo login` as opslabs, and Expo Go signed in as opslabs):
```
cd /root/scheduler/ios && npx expo start --tunnel
```

New App Store build and upload (free tier: 15 iOS builds/month):
```
cd /root/scheduler/ios && set -a && . /root/.appstore-eas.env && set +a
npx eas-cli@latest build -p ios --profile production --auto-submit --non-interactive
```

Refresh the demo account's bookings before a (re)submission:
```
cd /root/scheduler && set -a && . ./.env && set +a && python3 -m flask --app run.py seed-review-account --email appreview@opslabsystems.cloud --password 'SchedulerDemo5244'
```

Checks before shipping app changes:
```
cd /root/scheduler/ios && npx tsc --noEmit && npx expo lint && npx expo-doctor
```

## Known issues and gotchas

- The iPhone turns `--` into a long dash when typing, which is why the demo password has no dashes.
- The server's apt is in a broken state (mysql-server version mismatch). `apt --fix-broken` would upgrade and
  restart MySQL, so it was left alone. Fix it at a quiet time.
- Port 5099 is used by another app on this server.
- Apple may reject a public listing under guideline 4.2 (app only usable by one business). Fallback: an
  **Unlisted** App Store app, which reuses everything above.
- The app can't create bookings yet (view/manage only). That needs a new API endpoint plus a screen.
- App Store screenshots were captured from the web preview; the tab bar looks slightly different from iOS.
