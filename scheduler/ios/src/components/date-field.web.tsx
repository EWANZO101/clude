import { toDateString, toTimeString } from '@/lib/format';
import { useColors } from '@/theme/colors';

type Props = { mode: 'date' | 'time'; value: Date; onChange: (value: Date) => void; accessibilityLabel: string };

/** The native picker has no web implementation, so the web preview uses the browser's own input. */
export function DateField({ mode, value, onChange, accessibilityLabel }: Props) {
  const colors = useColors();
  return (
    <input
      type={mode}
      aria-label={accessibilityLabel}
      value={mode === 'date' ? toDateString(value) : toTimeString(value)}
      onChange={(e) => {
        const next = new Date(value);
        if (mode === 'date') {
          const [y, m, d] = e.target.value.split('-').map(Number);
          if (!y) return;
          next.setFullYear(y, m - 1, d);
        } else {
          const [hh, mm] = e.target.value.split(':').map(Number);
          if (Number.isNaN(hh)) return;
          next.setHours(hh, mm);
        }
        onChange(next);
      }}
      style={{
        font: 'inherit',
        fontSize: 15,
        // Browsers size these inputs generously; pin them so two fit in a phone-width row.
        width: mode === 'date' ? 130 : 112,
        color: colors.tint,
        background: 'transparent',
        border: 'none',
        colorScheme: 'light dark',
      }}
    />
  );
}
