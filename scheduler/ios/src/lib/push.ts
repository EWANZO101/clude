import Constants from 'expo-constants';
import * as Device from 'expo-device';
import * as Notifications from 'expo-notifications';
import { router } from 'expo-router';
import { useEffect } from 'react';
import { Platform } from 'react-native';

import type { ApiClient } from '@/lib/api';

export type PushState = 'enabled' | 'denied' | 'unsupported';

// Show banners even while the app is open — that's the "in-app" notification.
Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowBanner: true,
    shouldShowList: true,
    shouldPlaySound: true,
    shouldSetBadge: false,
  }),
});

let registeredToken: string | null = null;

/**
 * Asks for permission (the system prompt only appears the first time), then
 * registers this phone's Expo push token with the backend so new bookings
 * and customer cancellations are pushed here.
 */
export async function registerForPush(api: ApiClient): Promise<PushState> {
  // Simulators can't receive remote pushes.
  if (!Device.isDevice) return 'unsupported';

  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('default', {
      name: 'Bookings',
      importance: Notifications.AndroidImportance.HIGH,
    });
  }

  let { status } = await Notifications.getPermissionsAsync();
  if (status !== 'granted') ({ status } = await Notifications.requestPermissionsAsync());
  if (status !== 'granted') return 'denied';

  const projectId = Constants.expoConfig?.extra?.eas?.projectId ?? Constants.easConfig?.projectId;
  try {
    const { data } = await Notifications.getExpoPushTokenAsync({ projectId });
    await api.registerPush(data);
    registeredToken = data;
    return 'enabled';
  } catch {
    // e.g. Expo Go on Android, which has no remote push since SDK 53.
    return 'unsupported';
  }
}

/** Called on sign-out so this phone stops getting that account's notifications. */
export async function unregisterPush(api: ApiClient) {
  if (!registeredToken) return;
  await api.unregisterPush(registeredToken).catch(() => {});
  registeredToken = null;
}

/** Tapping a booking notification opens that booking. */
export function useNotificationTaps() {
  const response = Notifications.useLastNotificationResponse();
  useEffect(() => {
    const bookingId = response?.notification.request.content.data?.booking_id;
    if (typeof bookingId === 'number') router.push(`/booking/${bookingId}`);
  }, [response]);
}
