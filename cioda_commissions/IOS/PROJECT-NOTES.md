# Cioda iPhone app: project notes

Last updated 26 September 2026. Kept out of git.

## What it is
One app, two modes:
- **Customers:** Home (open/closed, price list, gallery) · Request (queue → form → PIN) · My Orders (tracking, invoice, updates, finished art, support chat).
- **Cioda ("Studio"):** sign in with the website's admin login → dashboard (open/close commissions), orders (status, payment, ETA, price, updates with photos, finished art), tickets, invoices, requests.
- Push notifications: Cioda gets new requests, new tickets and customer replies; customers get status changes, replies and "payment received".

## Where things are
- App code: `/root/cioda_commissions/IOS` (Expo SDK 57). Expo project `@opslabs/cioda-commissions`. Bundle ID `space.ciodrawz.commissions`.
- API: `/root/cioda_commissions/cioda-commissions/mobile_api.py` (+ 3-line hook at the end of `app.py`), live at `https://order.ciodrawz.space/api/m/v1`.
- Backups from before the change: `/root/cioda-backup-before-app-20260926-191008.tar.gz`, `/root/cioda-db-before-app-20260926-191008.db`.

## Commands
Run in Expo Go (the Scheduler tunnel uses port 8081, so this uses 8082):
```
cd /root/cioda_commissions/IOS && npx expo start --tunnel --port 8082
```
Reload the live site after backend changes:
```
kill -HUP $(systemctl show -p MainPID --value cioda)
```
Checks before shipping app changes:
```
cd /root/cioda_commissions/IOS && npx tsc --noEmit && npx expo lint && npx expo-doctor
```

## Still to do for the App Store
Same path as Scheduler (see /root/scheduler/ios/PROJECT-NOTES.md): register the bundle ID with the Apple API key, create the App Store Connect listing, credentials + build via EAS, push key upload on expo.dev, demo login for reviewers, listing text/screenshots, privacy policy page.
