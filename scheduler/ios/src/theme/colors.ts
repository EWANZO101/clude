import { useColorScheme } from 'react-native';

import type { BookingStatus, StatusName } from '@/lib/api';

// iOS system colors (light / dark), so the app sits naturally next to
// Settings, Calendar, etc. Kept as plain values rather than PlatformColor so
// the web preview renders the same palette.
const light = {
  background: '#F2F2F7',
  card: '#FFFFFF',
  label: '#000000',
  secondaryLabel: '#3C3C4399',
  tertiaryLabel: '#3C3C434D',
  separator: '#C6C6C8',
  fill: '#7878801F',
  tint: '#007AFF',
  destructive: '#FF3B30',
  green: '#34C759',
  orange: '#FF9500',
  red: '#FF3B30',
  purple: '#AF52DE',
  gray: '#8E8E93',
};

const dark: typeof light = {
  background: '#000000',
  card: '#1C1C1E',
  label: '#FFFFFF',
  secondaryLabel: '#EBEBF599',
  tertiaryLabel: '#EBEBF54D',
  separator: '#38383A',
  fill: '#7878805C',
  tint: '#0A84FF',
  destructive: '#FF453A',
  green: '#30D158',
  orange: '#FF9F0A',
  red: '#FF453A',
  purple: '#BF5AF2',
  gray: '#8E8E93',
};

export type Colors = typeof light;

export function useColors(): Colors {
  return useColorScheme() === 'dark' ? dark : light;
}

export function statusColor(colors: Colors, status: StatusName) {
  return { available: colors.green, busy: colors.orange, unavailable: colors.red, away: colors.purple, offline: colors.gray }[
    status
  ];
}

export function bookingStatusColor(colors: Colors, status: BookingStatus) {
  return {
    pending: colors.orange,
    confirmed: colors.tint,
    cancelled: colors.red,
    completed: colors.green,
    no_show: colors.gray,
  }[status];
}

export const spacing = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24 };
export const radius = { md: 10, lg: 14 };
