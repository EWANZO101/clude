import { API_URL } from '@/lib/api';

/** The scheduler website the API belongs to, e.g. https://scheduler.opslabsystems.cloud */
export const WEBSITE_URL = API_URL.replace(/\/api\/v1\/?$/, '');

/** The website's sign-in, continuing to the admin Settings page. */
export const WEBSITE_SETTINGS_URL = `${WEBSITE_URL}/auth/login?next=${encodeURIComponent('/admin/settings')}`;
