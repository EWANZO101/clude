// Client for the Flask backend's /api/v1 (see app/routes/api.py in the
// scheduler repo). All datetimes are naive local time in the owner's
// timezone, formatted "YYYY-MM-DDTHH:MM" — see lib/format.ts.

export const API_URL = process.env.EXPO_PUBLIC_API_URL ?? 'https://scheduler.opslabsystems.cloud/api/v1';

export type ManualStatus = 'available' | 'busy' | 'unavailable' | 'away';
export type StatusName = ManualStatus | 'offline';
export type BookingStatus = 'pending' | 'confirmed' | 'cancelled' | 'completed' | 'no_show';
export type BookingFilter = 'upcoming' | 'past' | 'cancelled' | 'all';

export type User = { id: number; name: string; email: string; timezone: string };

export type CurrentStatus = {
  status: StatusName;
  message: string | null;
  is_manual: boolean;
  next_available: string | null;
};

export type Booking = {
  id: number;
  name: string;
  email: string;
  phone: string | null;
  notes: string | null;
  start: string;
  end: string;
  status: BookingStatus;
  booking_type: string | null;
  is_out_of_hours: boolean;
  out_of_hours_fee_shown: string | null;
};

export type TimeOff = { id: number; start: string; end: string; all_day: boolean; reason: string | null };

export type Dashboard = {
  user: User;
  now: string;
  status: CurrentStatus;
  manual_statuses: ManualStatus[];
  current_task: string | null;
  stats: { todays_bookings: number; week_bookings: number };
  todays_bookings: Booking[];
  next_booking: Booking | null;
};

export type CalendarDay = {
  date: string;
  is_working_day: boolean;
  working_hours: { start: string; end: string } | null;
  breaks: { label: string; start: string; end: string }[];
  time_offs: TimeOff[];
  bookings: Booking[];
};

export type CalendarMonth = {
  year: number;
  month: number;
  month_label: string;
  today: string;
  days: CalendarDay[];
};

export type NewTimeOff = {
  start_date: string;
  end_date: string;
  all_day: boolean;
  start_time?: string;
  end_time?: string;
  reason?: string;
};

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
  }
}

type RequestOptions = { method?: 'GET' | 'POST' | 'DELETE'; body?: unknown; token?: string | null };

async function request<T>(path: string, { method = 'GET', body, token }: RequestOptions = {}): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${API_URL}${path}`, {
      method,
      headers: {
        Accept: 'application/json',
        ...(body !== undefined && { 'Content-Type': 'application/json' }),
        ...(token && { Authorization: `Bearer ${token}` }),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError("Can't reach the server. Check your connection and try again.", 0);
  }

  if (res.status === 204) return undefined as T;
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(data?.error ?? `Something went wrong (${res.status}).`, res.status);
  return data as T;
}

export function login(email: string, password: string) {
  return request<{ token: string; user: User }>('/auth/login', { method: 'POST', body: { email, password } });
}

// Everything past sign-in needs the token; screens get this bound client from useAuth().
export function createClient(token: string) {
  return {
    me: () => request<{ user: User }>('/me', { token }),
    dashboard: () => request<Dashboard>('/dashboard', { token }),
    setStatus: (status: ManualStatus | null, message?: string) =>
      request<{ status: CurrentStatus }>('/status', { method: 'POST', body: { status, message }, token }),
    setCurrentTask: (current_task: string) =>
      request<{ current_task: string | null }>('/current-task', { method: 'POST', body: { current_task }, token }),
    bookings: (filter: BookingFilter) => request<{ bookings: Booking[] }>(`/bookings?filter=${filter}`, { token }),
    booking: (id: number) => request<{ booking: Booking }>(`/bookings/${id}`, { token }),
    bookingAction: (id: number, action: 'cancel' | 'complete' | 'no-show') =>
      request<{ booking: Booking }>(`/bookings/${id}/${action}`, { method: 'POST', token }),
    calendar: (year: number, month: number) =>
      request<CalendarMonth>(`/calendar?year=${year}&month=${month}`, { token }),
    timeOff: () => request<{ time_off: TimeOff[] }>('/time-off', { token }),
    addTimeOff: (entry: NewTimeOff) =>
      request<{ time_off: TimeOff }>('/time-off', { method: 'POST', body: entry, token }),
    deleteTimeOff: (id: number) => request<void>(`/time-off/${id}`, { method: 'DELETE', token }),
    registerPush: (pushToken: string) =>
      request<{ registered: boolean }>('/push-devices', { method: 'POST', body: { token: pushToken }, token }),
    unregisterPush: (pushToken: string) =>
      request<void>('/push-devices', { method: 'DELETE', body: { token: pushToken }, token }),
    testPush: () => request<{ sent: boolean }>('/push-devices/test', { method: 'POST', token }),
  };
}

export type ApiClient = ReturnType<typeof createClient>;
