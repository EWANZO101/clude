import { Image } from 'expo-image';
import * as WebBrowser from 'expo-web-browser';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { styles as ui } from '@/components/ui';
import type { LogEntry } from '@/lib/api';
import { dateTime } from '@/lib/format';
import { colors, radius, spacing } from '@/theme/theme';

/** Order history, newest first. Admin view also marks internal (hidden-from-customer) notes. */
export function Timeline({ logs, showVisibility }: { logs: LogEntry[]; showVisibility?: boolean }) {
  return (
    <View style={{ paddingHorizontal: spacing.lg }}>
      {logs.map((entry, i) => (
        <View key={`${entry.created_at}-${i}`} style={styles.item}>
          <View style={styles.rail}>
            <View style={[styles.dot, i === 0 && { backgroundColor: colors.accent, borderColor: colors.accent }]} />
            {i < logs.length - 1 && <View style={styles.line} />}
          </View>
          <View style={styles.content}>
            <Text style={ui.strong}>{entry.event}</Text>
            <Text style={ui.meta}>
              {dateTime(entry.created_at)}
              {showVisibility && !entry.customer_visible ? ' · Internal note' : ''}
            </Text>
            {entry.details ? <Text style={[ui.bodySmall, { marginTop: 4 }]}>{entry.details}</Text> : null}
            {entry.image_url ? (
              <Pressable onPress={() => WebBrowser.openBrowserAsync(entry.image_url!)} accessibilityRole="imagebutton" accessibilityLabel={`Image for ${entry.event}`}>
                <Image source={entry.image_url} style={styles.image} contentFit="cover" transition={150} />
              </Pressable>
            ) : null}
          </View>
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  item: { flexDirection: 'row', gap: spacing.md },
  rail: { alignItems: 'center', width: 14 },
  dot: { width: 12, height: 12, borderRadius: 6, borderWidth: 2, borderColor: colors.borderAccent, backgroundColor: colors.background, marginTop: 4 },
  line: { flex: 1, width: 2, backgroundColor: colors.border, marginVertical: 2 },
  content: { flex: 1, paddingBottom: spacing.lg, gap: 2 },
  image: { width: '100%', aspectRatio: 4 / 3, borderRadius: radius.md, marginTop: spacing.sm, backgroundColor: colors.elevated },
});
