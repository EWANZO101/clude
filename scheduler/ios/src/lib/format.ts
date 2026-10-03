// The API sends naive local datetimes ("2026-09-27T14:00") in the owner's
// timezone. Building Dates with the local-time constructor and formatting
// them locally round-trips the same wall-clock values, so nothing shifts
// even if the phone is set to a different timezone than the scheduler.

export function parseLocal(value: string): Date {
  const [datePart, timePart = '00:00'] = value.split('T');
  const [y, m, d] = datePart.split('-').map(Number);
  const [hh, mm] = timePart.split(':').map(Number);
  return new Date(y, m - 1, d, hh, mm);
}

const pad = (n: number) => String(n).padStart(2, '0');

export const toDateString = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
export const toTimeString = (d: Date) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;

export const formatTime = (value: string) => toTimeString(parseLocal(value));

export const formatDay = (value: string) =>
  parseLocal(value).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });

export const formatLongDay = (value: string) =>
  parseLocal(value).toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });

export const formatRange = (start: string, end: string) => `${formatTime(start)} – ${formatTime(end)}`;

export function formatTimeOff(entry: { start: string; end: string; all_day: boolean }) {
  const sameDay = entry.start.slice(0, 10) === entry.end.slice(0, 10);
  if (entry.all_day) return sameDay ? formatDay(entry.start) : `${formatDay(entry.start)} – ${formatDay(entry.end)}`;
  if (sameDay) return `${formatDay(entry.start)}, ${formatRange(entry.start, entry.end)}`;
  return `${formatDay(entry.start)} ${formatTime(entry.start)} – ${formatDay(entry.end)} ${formatTime(entry.end)}`;
}

export const capitalize = (s: string) => s.charAt(0).toUpperCase() + s.slice(1).replace('_', '-');
