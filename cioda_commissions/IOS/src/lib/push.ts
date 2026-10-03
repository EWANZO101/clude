import Constants from 'expo-constants';
import * as Device from 'expo-device';
import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';

// Banners show while the app is open too.
Notifications.setNotificationHandler({
  handleNotification: async () => ({ shouldShowBanner: true, shouldShowList: true, shouldPlaySound: true, shouldSetBadge: false }),
});

let cached: Promise<string | null> | null = null;

/**
 * This phone's Expo push token, asking for permission the first time. Null when
 * the user says no or the device can't receive pushes (simulator, Android Expo Go).
 */
export function getPushToken(): Promise<string | null> {
  cached ??= (async () => {
    if (!Device.isDevice) return null;
    if (Platform.OS === 'android') {
      await Notifications.setNotificationChannelAsync('default', { name: 'Updates', importance: Notifications.AndroidImportance.HIGH });
    }
    let { status } = await Notifications.getPermissionsAsync();
    if (status !== 'granted') ({ status } = await Notifications.requestPermissionsAsync());
    if (status !== 'granted') return null;
    try {
      const projectId = Constants.expoConfig?.extra?.eas?.projectId ?? Constants.easConfig?.projectId;
      return (await Notifications.getExpoPushTokenAsync({ projectId })).data;
    } catch {
      return null;
    }
  })();
  const result = cached;
  // Let a later call ask again if this one came back empty (e.g. permission denied, then enabled in Settings).
  result.then((token) => {
    if (!token) cached = null;
  });
  return result;
}

export { useLastNotificationResponse } from 'expo-notifications';
