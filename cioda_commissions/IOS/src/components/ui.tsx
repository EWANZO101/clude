import type { ReactNode } from 'react';
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  type StyleProp,
  type TextInputProps,
  type TextStyle,
  type ViewStyle,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { colors, fonts, radius, spacing, statusColor } from '@/theme/theme';

/** A tab's root screen: scrolling content under a large Cinzel title. */
export function Screen({
  title,
  subtitle,
  headerRight,
  refreshing,
  onRefresh,
  children,
}: {
  title: string;
  subtitle?: string;
  headerRight?: ReactNode;
  refreshing?: boolean;
  onRefresh?: () => void;
  children: ReactNode;
}) {
  const insets = useSafeAreaInsets();
  return (
    <ScrollView
      style={styles.fill}
      contentContainerStyle={{ paddingTop: insets.top + spacing.md, paddingBottom: insets.bottom + spacing.xxl * 3 }}
      contentInsetAdjustmentBehavior="never"
      keyboardShouldPersistTaps="handled"
      refreshControl={onRefresh ? <RefreshControl refreshing={!!refreshing} onRefresh={onRefresh} tintColor={colors.accent} /> : undefined}
    >
      <View style={styles.titleRow}>
        <View style={{ flex: 1 }}>
          <Text style={styles.title} accessibilityRole="header">
            {title}
          </Text>
          {subtitle ? <Text style={styles.subtitle}>{subtitle}</Text> : null}
        </View>
        {headerRight}
      </View>
      {children}
    </ScrollView>
  );
}

/** For pushed screens with a native header. */
export function Page({ children, refreshing, onRefresh }: { children: ReactNode; refreshing?: boolean; onRefresh?: () => void }) {
  const insets = useSafeAreaInsets();
  return (
    <ScrollView
      style={styles.fill}
      contentContainerStyle={{ paddingBottom: insets.bottom + spacing.xxl * 2 }}
      contentInsetAdjustmentBehavior="automatic"
      keyboardShouldPersistTaps="handled"
      automaticallyAdjustKeyboardInsets
      refreshControl={onRefresh ? <RefreshControl refreshing={!!refreshing} onRefresh={onRefresh} tintColor={colors.accent} /> : undefined}
    >
      {children}
    </ScrollView>
  );
}

export function SectionTitle({ children, right }: { children: string; right?: ReactNode }) {
  return (
    <View style={styles.sectionTitleRow}>
      <Text style={styles.sectionTitle}>{children.toUpperCase()}</Text>
      {right}
    </View>
  );
}

export function Card({ children, style, onPress }: { children: ReactNode; style?: StyleProp<ViewStyle>; onPress?: () => void }) {
  if (!onPress) return <View style={[styles.card, style]}>{children}</View>;
  return (
    <Pressable onPress={onPress} style={({ pressed }) => [styles.card, style, pressed && styles.pressed]} accessibilityRole="button">
      {children}
    </Pressable>
  );
}

export function Row({
  children,
  onPress,
  last,
  style,
  chevron,
}: {
  children: ReactNode;
  onPress?: () => void;
  last?: boolean;
  style?: StyleProp<ViewStyle>;
  chevron?: boolean;
}) {
  const content = (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.md }}>
      <View style={{ flex: 1 }}>{children}</View>
      {chevron && <Text style={{ color: colors.textMuted, fontSize: 20 }}>›</Text>}
    </View>
  );
  const rowStyle = [styles.row, !last && styles.rowDivider, style];
  if (!onPress) return <View style={rowStyle}>{content}</View>;
  return (
    <Pressable onPress={onPress} style={({ pressed }) => [rowStyle, pressed && { backgroundColor: colors.elevated }]}>
      {content}
    </Pressable>
  );
}

export function Pill({ label, color }: { label: string; color?: string }) {
  const c = color ?? statusColor(label);
  return (
    <View style={[styles.pill, { backgroundColor: c + '22', borderColor: c + '55' }]}>
      <Text style={[styles.pillText, { color: c }]}>{label}</Text>
    </View>
  );
}

export function Button({
  title,
  onPress,
  variant = 'primary',
  disabled,
  loading,
  style,
}: {
  title: string;
  onPress: () => void;
  variant?: 'primary' | 'secondary' | 'danger' | 'ghost';
  disabled?: boolean;
  loading?: boolean;
  style?: StyleProp<ViewStyle>;
}) {
  const bg = { primary: colors.accent, secondary: colors.card, danger: colors.danger + '22', ghost: 'transparent' }[variant];
  const fg = { primary: colors.onAccent, secondary: colors.text, danger: colors.danger, ghost: colors.accent }[variant];
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled || loading}
      accessibilityRole="button"
      accessibilityState={{ disabled: !!(disabled || loading) }}
      style={({ pressed }) => [
        styles.button,
        { backgroundColor: bg },
        variant === 'secondary' && { borderWidth: 1, borderColor: colors.borderAccent },
        (pressed || disabled) && { opacity: 0.55 },
        style,
      ]}
    >
      {loading ? <ActivityIndicator color={fg} /> : <Text style={[styles.buttonText, { color: fg }]}>{title}</Text>}
    </Pressable>
  );
}

export function Field({
  label,
  hint,
  required,
  style,
  ...input
}: TextInputProps & { label: string; hint?: string; required?: boolean; style?: StyleProp<TextStyle> }) {
  return (
    <View style={{ gap: 6 }}>
      <Text style={styles.label}>
        {label}
        {required ? <Text style={{ color: colors.accent }}> *</Text> : null}
      </Text>
      <TextInput
        placeholderTextColor={colors.textMuted}
        selectionColor={colors.accent}
        keyboardAppearance="dark"
        accessibilityLabel={label}
        style={[styles.input, input.multiline && { minHeight: 96, textAlignVertical: 'top' }, style]}
        {...input}
      />
      {hint ? <Text style={styles.hint}>{hint}</Text> : null}
    </View>
  );
}

/** A row of selectable chips (single or multiple choice). */
export function Chips<T extends string>({
  options,
  selected,
  onToggle,
  colorFor,
}: {
  options: { value: T; label: string }[];
  selected: T[];
  onToggle: (value: T) => void;
  colorFor?: (value: T) => string;
}) {
  return (
    <View style={styles.chips}>
      {options.map((o) => {
        const on = selected.includes(o.value);
        const c = colorFor?.(o.value) ?? colors.accent;
        return (
          <Pressable
            key={o.value}
            onPress={() => onToggle(o.value)}
            accessibilityRole="button"
            accessibilityState={{ selected: on }}
            style={({ pressed }) => [
              styles.chip,
              { borderColor: on ? c : colors.borderAccent, backgroundColor: on ? c + '26' : 'transparent' },
              pressed && { opacity: 0.7 },
            ]}
          >
            <Text style={[styles.chipText, { color: on ? c : colors.textSecondary }]}>{o.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

export function LoadingState() {
  return (
    <View style={styles.centered}>
      <ActivityIndicator color={colors.accent} />
    </View>
  );
}

export function MessageState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <View style={styles.centered}>
      <Text style={styles.message}>{message}</Text>
      {onRetry && (
        <Pressable onPress={onRetry} hitSlop={8} accessibilityRole="button">
          <Text style={{ color: colors.accent, fontSize: 16, fontWeight: '600' }}>Try again</Text>
        </Pressable>
      )}
    </View>
  );
}

export function EmptyText({ children }: { children: string }) {
  return <Text style={[styles.body, { color: colors.textSecondary, fontFamily: fonts.bodyItalic }]}>{children}</Text>;
}

export const styles = StyleSheet.create({
  fill: { flex: 1, backgroundColor: colors.background },
  titleRow: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: spacing.lg, marginBottom: spacing.md, gap: spacing.md },
  title: { fontFamily: fonts.display, fontSize: 30, color: colors.text, letterSpacing: 0.5 },
  subtitle: { fontFamily: fonts.bodyItalic, fontSize: 17, color: colors.textSecondary, marginTop: 2 },
  sectionTitleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginHorizontal: spacing.lg,
    marginTop: spacing.xl,
    marginBottom: spacing.sm,
  },
  sectionTitle: { fontFamily: fonts.displaySemi, fontSize: 13, color: colors.textSecondary, letterSpacing: 1.5 },
  card: {
    marginHorizontal: spacing.lg,
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    overflow: 'hidden',
  },
  pressed: { opacity: 0.8 },
  row: { paddingVertical: 13, paddingHorizontal: spacing.lg, minHeight: 48, justifyContent: 'center' },
  rowDivider: { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.border },
  body: { fontFamily: fonts.body, fontSize: 18, color: colors.text, lineHeight: 24 },
  bodySmall: { fontFamily: fonts.body, fontSize: 16, color: colors.textSecondary, lineHeight: 21 },
  strong: { fontSize: 16, fontWeight: '600', color: colors.text },
  meta: { fontSize: 13, color: colors.textSecondary },
  label: { fontSize: 13, fontWeight: '600', color: colors.textSecondary, letterSpacing: 0.3 },
  hint: { fontSize: 12, color: colors.textMuted },
  input: {
    backgroundColor: colors.elevated,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: 12,
    fontSize: 16,
    color: colors.text,
  },
  pill: { alignSelf: 'flex-start', borderRadius: radius.pill, borderWidth: 1, paddingHorizontal: 10, paddingVertical: 3 },
  pillText: { fontSize: 12, fontWeight: '700', letterSpacing: 0.3 },
  button: { minHeight: 50, borderRadius: radius.md, alignItems: 'center', justifyContent: 'center', paddingHorizontal: spacing.lg },
  buttonText: { fontSize: 16, fontWeight: '700', letterSpacing: 0.3 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  chip: { borderWidth: 1.5, borderRadius: radius.pill, paddingHorizontal: 14, paddingVertical: 7 },
  chipText: { fontSize: 14, fontWeight: '600' },
  centered: { alignItems: 'center', justifyContent: 'center', padding: spacing.xxl * 2, gap: spacing.md },
  message: { fontFamily: fonts.body, fontSize: 17, color: colors.textSecondary, textAlign: 'center' },
});
