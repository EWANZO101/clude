// The web preview can't receive Expo push notifications; these keep the same API as push.ts.
import type { ApiClient } from '@/lib/api';

export type PushState = 'enabled' | 'denied' | 'unsupported';

export async function registerForPush(_api: ApiClient): Promise<PushState> {
  return 'unsupported';
}

export async function unregisterPush(_api: ApiClient) {}

export function useNotificationTaps() {}
