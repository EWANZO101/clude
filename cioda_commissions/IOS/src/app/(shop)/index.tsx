import { Image } from 'expo-image';
import { Link, router } from 'expo-router';
import * as WebBrowser from 'expo-web-browser';
import { Pressable, StyleSheet, Text, useWindowDimensions, View } from 'react-native';

import { Button, Card, LoadingState, MessageState, Row, Screen, SectionTitle, styles as ui } from '@/components/ui';
import { getHome } from '@/lib/api';
import { money } from '@/lib/format';
import { useApiData } from '@/lib/use-api-data';
import { colors, fonts, radius, spacing } from '@/theme/theme';

const BANNER_COLORS = { info: colors.info, success: colors.success, warning: colors.gold, danger: colors.danger };

export default function Home() {
  const { data, error, refreshing, refresh, reload } = useApiData(getHome);
  const { width } = useWindowDimensions();
  const tile = (Math.min(width, 700) - spacing.lg * 2 - spacing.sm) / 2;

  if (!data) {
    return (
      <Screen title="Cioda" subtitle="Art made with love, just for you.">
        {error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />}
      </Screen>
    );
  }

  return (
    <Screen title="Cioda" subtitle="Art made with love, just for you." refreshing={refreshing} onRefresh={refresh}>
      <Card style={[styles.status, { borderColor: (data.commissions_open ? colors.success : colors.gold) + '66' }]}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}>
          <View style={[styles.dot, { backgroundColor: data.commissions_open ? colors.success : colors.gold }]} />
          <Text style={styles.statusTitle}>{data.commissions_open ? 'Commissions are open' : 'Commissions are closed'}</Text>
        </View>
        <Text style={[ui.bodySmall, { marginTop: 6 }]}>
          {data.commissions_open ? 'Pick a style below and send a request, it only takes a few minutes.' : data.closed_message}
        </Text>
        {!data.commissions_open && data.reopen_date ? <Text style={[ui.meta, { marginTop: 6 }]}>Reopening {data.reopen_date}</Text> : null}
        {data.commissions_open && (
          <Button title="Request a Commission" onPress={() => router.push('/request')} style={{ marginTop: spacing.md }} />
        )}
      </Card>

      {data.banner && (
        <Card style={[styles.banner, { borderColor: BANNER_COLORS[data.banner.style] + '66' }]}>
          <Text style={[ui.body, { color: colors.text }]}>{data.banner.text}</Text>
          {data.banner.link && (
            <Pressable onPress={() => WebBrowser.openBrowserAsync(data.banner!.link!)} accessibilityRole="link" hitSlop={6}>
              <Text style={{ color: BANNER_COLORS[data.banner.style], fontWeight: '700', marginTop: 6 }}>{data.banner.link_text || 'Learn more'} ›</Text>
            </Pressable>
          )}
        </Card>
      )}

      <SectionTitle>Price List</SectionTitle>
      {data.price_list.map((group) => (
        <View key={group.category} style={{ marginBottom: spacing.md }}>
          <Text style={styles.category}>{group.category}</Text>
          <Card>
            {group.types.map((t, i) => (
              <Row key={t.id} last={i === group.types.length - 1}>
                <View style={styles.priceRow}>
                  <Text style={[ui.body, { flex: 1 }]}>{t.name}</Text>
                  <Text style={styles.price}>{money(t.price)}</Text>
                </View>
              </Row>
            ))}
          </Card>
        </View>
      ))}

      {data.gallery.length > 0 && (
        <>
          <SectionTitle>Gallery</SectionTitle>
          <View style={styles.gallery}>
            {data.gallery.map((img) => (
              <Pressable
                key={img.url}
                onPress={() => WebBrowser.openBrowserAsync(img.url)}
                accessibilityRole="imagebutton"
                accessibilityLabel={img.caption ?? 'Gallery artwork'}
                style={{ width: tile }}
              >
                <Image source={img.url} style={[styles.tile, { width: tile, height: tile }]} contentFit="cover" transition={200} />
                {img.caption ? (
                  <Text style={[ui.meta, { marginTop: 4 }]} numberOfLines={1}>
                    {img.caption}
                  </Text>
                ) : null}
              </Pressable>
            ))}
          </View>
        </>
      )}

      <View style={styles.footer}>
        <Link href="/add-order" asChild>
          <Pressable hitSlop={8} accessibilityRole="link">
            <Text style={styles.footerLink}>Find an existing order</Text>
          </Pressable>
        </Link>
        <Text style={{ color: colors.textMuted }}>·</Text>
        <Link href="/studio-login" asChild>
          <Pressable hitSlop={8} accessibilityRole="link">
            <Text style={styles.footerLink}>Artist sign in</Text>
          </Pressable>
        </Link>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  status: { padding: spacing.lg },
  dot: { width: 10, height: 10, borderRadius: 5 },
  statusTitle: { fontFamily: fonts.displaySemi, fontSize: 17, color: colors.text },
  banner: { padding: spacing.lg, marginTop: spacing.md },
  category: { fontFamily: fonts.bodySemi, fontSize: 18, color: colors.gold, marginHorizontal: spacing.lg + 4, marginBottom: 6 },
  priceRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  price: { fontFamily: fonts.displaySemi, fontSize: 16, color: colors.accent },
  gallery: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, paddingHorizontal: spacing.lg },
  tile: { borderRadius: radius.md, backgroundColor: colors.elevated },
  footer: { flexDirection: 'row', justifyContent: 'center', alignItems: 'center', gap: spacing.md, marginTop: spacing.xxl },
  footerLink: { color: colors.textSecondary, fontSize: 14, textDecorationLine: 'underline' },
});
