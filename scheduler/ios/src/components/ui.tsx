import type { ReactNode } from 'react';
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { radius, spacing, useColors } from '@/theme/colors';

/** A tab's root screen: scrolling content under a large iOS-style title. */
export function Screen({
  title,
  headerRight,
  refreshing,
  onRefresh,
  children,
}: {
  title: string;
  headerRight?: ReactNode;
  refreshing?: boolean;
  onRefresh?: () => void;
  children: ReactNode;
}) {
  const colors = useColors();
  const insets = useSafeAreaInsets();
  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: colors.background }}
      contentContainerStyle={{ paddingTop: insets.top + spacing.sm, paddingBottom: insets.bottom + spacing.xl * 3 }}
      contentInsetAdjustmentBehavior="never"
      refreshControl={onRefresh ? <RefreshControl refreshing={!!refreshing} onRefresh={onRefresh} /> : undefined}
    >
      <View style={styles.titleRow}>
        <Text style={[styles.largeTitle, { color: colors.label }]} accessibilityRole="header">
          {title}
        </Text>
        {headerRight}
      </View>
      {children}
    </ScrollView>
  );
}

/** An inset grouped section, like a Settings table section. */
export function Section({ title, footer, children }: { title?: string; footer?: string; children: ReactNode }) {
  const colors = useColors();
  return (
    <View style={styles.section}>
      {title && <Text style={[styles.sectionTitle, { color: colors.secondaryLabel }]}>{title.toUpperCase()}</Text>}
      <View style={[styles.sectionBody, { backgroundColor: colors.card }]}>{children}</View>
      {footer && <Text style={[styles.sectionFooter, { color: colors.secondaryLabel }]}>{footer}</Text>}
    </View>
  );
}

export function Row({
  children,
  onPress,
  last,
  style,
}: {
  children: ReactNode;
  onPress?: () => void;
  last?: boolean;
  style?: StyleProp<ViewStyle>;
}) {
  const colors = useColors();
  const rowStyle = [
    styles.row,
    !last && { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.separator },
    style,
  ];
  if (!onPress) return <View style={rowStyle}>{children}</View>;
  return (
    <Pressable onPress={onPress} style={({ pressed }) => [rowStyle, pressed && { backgroundColor: colors.fill }]}>
      {children}
    </Pressable>
  );
}

export function Pill({ label, color }: { label: string; color: string }) {
  return (
    <View style={[styles.pill, { backgroundColor: color + '26' }]}>
      <View style={[styles.dot, { backgroundColor: color }]} />
      <Text style={[styles.pillText, { color }]}>{label}</Text>
    </View>
  );
}

export function Segmented<T extends string>({
  options,
  value,
  onChange,
}: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (value: T) => void;
}) {
  const colors = useColors();
  return (
    <View style={[styles.segmented, { backgroundColor: colors.fill }]} accessibilityRole="tablist">
      {options.map((o) => {
        const selected = o.value === value;
        return (
          <Pressable
            key={o.value}
            onPress={() => onChange(o.value)}
            accessibilityRole="tab"
            accessibilityState={{ selected }}
            style={[styles.segment, selected && [styles.segmentSelected, { backgroundColor: colors.card }]]}
          >
            <Text style={[styles.segmentText, { color: colors.label }, selected && { fontWeight: '600' }]}>
              {o.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

export function Button({
  title,
  onPress,
  variant = 'primary',
  disabled,
  loading,
}: {
  title: string;
  onPress: () => void;
  variant?: 'primary' | 'plain' | 'destructive';
  disabled?: boolean;
  loading?: boolean;
}) {
  const colors = useColors();
  const primary = variant === 'primary';
  const textColor = primary ? '#FFFFFF' : variant === 'destructive' ? colors.destructive : colors.tint;
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled || loading}
      accessibilityRole="button"
      style={({ pressed }) => [
        styles.button,
        { backgroundColor: primary ? colors.tint : colors.card },
        (pressed || disabled) && { opacity: 0.5 },
      ]}
    >
      {loading ? <ActivityIndicator color={textColor} /> : <Text style={[styles.buttonText, { color: textColor }]}>{title}</Text>}
    </Pressable>
  );
}

export function LoadingState() {
  return (
    <View style={styles.centered}>
      <ActivityIndicator />
    </View>
  );
}

export function MessageState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  const colors = useColors();
  return (
    <View style={styles.centered}>
      <Text style={[styles.message, { color: colors.secondaryLabel }]}>{message}</Text>
      {onRetry && (
        <Pressable onPress={onRetry} accessibilityRole="button" hitSlop={8}>
          <Text style={{ color: colors.tint, fontSize: 17 }}>Try again</Text>
        </Pressable>
      )}
    </View>
  );
}

export const styles = StyleSheet.create({
  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.lg,
    marginBottom: spacing.sm,
  },
  largeTitle: { fontSize: 34, fontWeight: '700', letterSpacing: 0.37 },
  section: { marginHorizontal: spacing.lg, marginTop: spacing.xl },
  sectionTitle: { fontSize: 13, marginBottom: 6, marginLeft: spacing.lg },
  sectionBody: { borderRadius: radius.md, overflow: 'hidden' },
  sectionFooter: { fontSize: 13, marginTop: 6, marginHorizontal: spacing.lg },
  row: { paddingVertical: 11, paddingHorizontal: spacing.lg, minHeight: 44, justifyContent: 'center' },
  body: { fontSize: 17 },
  subhead: { fontSize: 15 },
  footnote: { fontSize: 13 },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    gap: 6,
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 999,
  },
  dot: { width: 8, height: 8, borderRadius: 4 },
  pillText: { fontSize: 13, fontWeight: '600' },
  segmented: { flexDirection: 'row', borderRadius: 9, padding: 2, marginHorizontal: spacing.lg },
  segment: { flex: 1, paddingVertical: 6, alignItems: 'center', borderRadius: 7 },
  segmentSelected: { shadowColor: '#000', shadowOpacity: 0.12, shadowRadius: 4, shadowOffset: { width: 0, height: 1 } },
  segmentText: { fontSize: 13 },
  button: { borderRadius: radius.md, minHeight: 50, alignItems: 'center', justifyContent: 'center', paddingHorizontal: spacing.lg },
  buttonText: { fontSize: 17, fontWeight: '600' },
  centered: { alignItems: 'center', justifyContent: 'center', padding: spacing.xl * 2, gap: spacing.md },
  message: { fontSize: 15, textAlign: 'center' },
});
