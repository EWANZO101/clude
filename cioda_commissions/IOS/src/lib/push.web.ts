// The browser preview can't receive Expo push notifications.
export async function getPushToken(): Promise<string | null> {
  return null;
}

export function useLastNotificationResponse() {
  return null as null | { notification: { request: { content: { data: Record<string, unknown> } } } };
}
