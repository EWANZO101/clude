import * as SecureStore from 'expo-secure-store';
import * as WebBrowser from 'expo-web-browser';

import { WEBSITE_SETTINGS_URL } from '@/lib/links';

const KEY = 'scheduler.first-launch-done';

/**
 * On the very first launch, opens the website's Settings page (via its
 * sign-in) in an in-app Safari sheet, so setup can be finished there. Marked
 * done before opening, so it never auto-opens again even if the app is
 * killed while the sheet is up.
 */
export async function openSettingsOnFirstLaunch() {
  if (await SecureStore.getItemAsync(KEY)) return;
  await SecureStore.setItemAsync(KEY, '1');
  await WebBrowser.openBrowserAsync(WEBSITE_SETTINGS_URL);
}
