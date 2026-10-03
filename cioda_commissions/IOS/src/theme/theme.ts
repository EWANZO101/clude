// Palette and type taken from the website (templates/base.html) so the app
// feels like the same place: near-black surfaces, soft purple accent, gold highlights.
export const colors = {
  background: '#0F0F11',
  surface: '#17171B',
  card: '#22222A',
  elevated: '#1E1E24',
  border: '#2E2E38',
  borderAccent: '#3D3D4D',
  text: '#E8E6F0',
  textSecondary: '#9694A8',
  textMuted: '#5F5D72',
  accent: '#C084FC',
  accentDim: '#A855F7',
  gold: '#F59E0B',
  goldDim: '#D97706',
  success: '#22C55E',
  danger: '#EF4444',
  info: '#6366F1',
  onAccent: '#1A0B2E',
};

export const fonts = {
  display: 'Cinzel_700Bold',
  displaySemi: 'Cinzel_600SemiBold',
  body: 'CrimsonPro_400Regular',
  bodyItalic: 'CrimsonPro_400Regular_Italic',
  bodySemi: 'CrimsonPro_600SemiBold',
};

export const spacing = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 };
export const radius = { sm: 8, md: 12, lg: 16, pill: 999 };

const STATUS_COLORS: Record<string, string> = {
  'Awaiting Confirmation': colors.gold,
  Accepted: colors.info,
  Declined: colors.danger,
  Pending: colors.textSecondary,
  'In Progress': colors.accent,
  Done: colors.success,
  Unpaid: colors.danger,
  Paid: colors.success,
  Open: colors.accent,
  Closed: colors.textMuted,
};

export function statusColor(status: string) {
  return STATUS_COLORS[status] ?? colors.textSecondary;
}
