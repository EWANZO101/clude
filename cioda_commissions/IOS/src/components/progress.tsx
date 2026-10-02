import { StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing } from '@/theme/theme';

/** The website's step tracker: completed steps filled, the current one highlighted. */
export function ProgressSteps({ steps, index, declined }: { steps: string[]; index: number; declined?: boolean }) {
  if (declined) {
    return (
      <View style={[styles.declined]}>
        <Text style={{ color: colors.danger, fontWeight: '700' }}>Declined</Text>
      </View>
    );
  }
  return (
    <View style={{ gap: spacing.sm }}>
      <View style={styles.track} accessibilityRole="progressbar" accessibilityValue={{ min: 0, max: steps.length - 1, now: Math.max(index, 0) }}>
        {steps.map((s, i) => (
          <View key={s} style={[styles.segment, { backgroundColor: i <= index ? (i === index ? colors.accent : colors.accentDim) : colors.border }]} />
        ))}
      </View>
      <View style={styles.labels}>
        {steps.map((s, i) => (
          <Text
            key={s}
            numberOfLines={2}
            style={[styles.label, i === index && { color: colors.accent, fontWeight: '700' }, i < index && { color: colors.textSecondary }]}
          >
            {s}
          </Text>
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  track: { flexDirection: 'row', gap: 4 },
  segment: { flex: 1, height: 6, borderRadius: radius.pill },
  labels: { flexDirection: 'row', gap: 4 },
  label: { flex: 1, fontSize: 11, color: colors.textMuted, textAlign: 'center' },
  declined: {
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.danger + '55',
    backgroundColor: colors.danger + '1A',
    padding: spacing.md,
    alignItems: 'center',
  },
});
