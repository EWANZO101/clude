import { Image } from 'expo-image';
import { router, Stack, useLocalSearchParams } from 'expo-router';
import * as WebBrowser from 'expo-web-browser';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { ProgressSteps } from '@/components/progress';
import { Timeline } from '@/components/timeline';
import { Button, Card, EmptyText, LoadingState, MessageState, Page, Pill, Row, SectionTitle, styles as ui } from '@/components/ui';
import { ApiError, getOrder } from '@/lib/api';
import { confirm } from '@/lib/confirm';
import { date, money, timeAgo } from '@/lib/format';
import { useSession } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';
import { colors, fonts, radius, spacing } from '@/theme/theme';

export default function CustomerOrder() {
  const { link } = useLocalSearchParams<{ link: string }>();
  const { tokenFor, removeOrder } = useSession();
  const token = tokenFor(link);
  const { data, error, refreshing, refresh, reload } = useApiData(async () => {
    if (!token) throw new ApiError('locked', 401);
    return getOrder(link, token);
  });

  // No saved token, or the PIN was reset/changed since: the order needs unlocking again.
  const locked = !token || (!data && error === 'Enter your PIN to open this order.');
  if (locked) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background, padding: spacing.lg, gap: spacing.lg }}>
        <Text style={ui.body}>This order needs its PIN to open.</Text>
        <Button title="Enter PIN" onPress={() => router.replace({ pathname: '/order/[link]/pin', params: { link } })} />
      </View>
    );
  }
  if (!data) return error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />;

  const o = data.order;
  const openTickets = o.tickets.filter((t) => t.status === 'Open' && !t.expired);

  async function forget() {
    if (await confirm('Remove from this phone?', `${o.order_id} stays on the website. You can add it back any time with its PIN.`, 'Remove')) {
      await removeOrder(link);
      router.back();
    }
  }

  return (
    <Page refreshing={refreshing} onRefresh={refresh}>
      <Stack.Screen options={{ title: o.order_id }} />

      <View style={styles.hero}>
        <Text style={styles.type}>{o.commission_type || 'Commission'}</Text>
        <Text style={ui.meta}>Ordered {date(o.created_at)}</Text>
      </View>

      <Card style={styles.block}>
        <View style={styles.blockHeader}>
          <Text style={styles.blockTitle}>Order status</Text>
          <Pill label={o.status} />
        </View>
        <ProgressSteps steps={o.progress.order_steps} index={o.progress.order_index} declined={o.status === 'Declined'} />
        {o.eta ? <Text style={[ui.bodySmall, { marginTop: spacing.md }]}>Estimated completion: {o.eta}</Text> : null}
      </Card>

      <Card style={[styles.block, { marginTop: spacing.md }]}>
        <View style={styles.blockHeader}>
          <Text style={styles.blockTitle}>Payment</Text>
          <Pill label={o.payment_status} />
        </View>
        <ProgressSteps steps={o.progress.payment_steps} index={o.progress.payment_index} />
        <View style={[styles.money, { marginTop: spacing.md }]}>
          <Text style={ui.bodySmall}>{o.payment_method ? `Paying by ${o.payment_method}` : 'Price'}</Text>
          <Text style={styles.price}>{o.price > 0 ? money(o.price) : 'To be quoted'}</Text>
        </View>
        {o.discount ? <Text style={[ui.meta, { color: colors.success }]}>{o.discount}</Text> : null}
        {o.invoice?.pdf_url && (
          <Pressable onPress={() => WebBrowser.openBrowserAsync(o.invoice!.pdf_url!)} accessibilityRole="link" hitSlop={6} style={{ marginTop: spacing.sm }}>
            <Text style={styles.link}>View invoice {o.invoice.invoice_id}{o.invoice.paid ? ' (paid)' : ''} ›</Text>
          </Pressable>
        )}
      </Card>

      {o.final_images.length > 0 && (
        <>
          <SectionTitle>Your finished art ✨</SectionTitle>
          <View style={{ paddingHorizontal: spacing.lg, gap: spacing.md }}>
            {o.final_images.map((url) => (
              <Pressable key={url} onPress={() => WebBrowser.openBrowserAsync(url)} accessibilityRole="imagebutton" accessibilityLabel="Open finished artwork full size">
                <Image source={url} style={styles.finalImage} contentFit="contain" transition={200} />
              </Pressable>
            ))}
            <Text style={ui.meta}>Tap an image to open it full size, then press and hold to save it.</Text>
          </View>
        </>
      )}

      <SectionTitle
        right={
          <Pressable onPress={() => router.push(`/order/${link}/new-ticket`)} hitSlop={8} accessibilityRole="button">
            <Text style={styles.link}>Get help</Text>
          </Pressable>
        }
      >
        Support
      </SectionTitle>
      <Card>
        {o.tickets.length === 0 ? (
          <Row last>
            <EmptyText>Questions about your order? Open a ticket and Cioda will reply here.</EmptyText>
          </Row>
        ) : (
          o.tickets.map((t, i) => (
            <Row key={t.ticket_id} last={i === o.tickets.length - 1} chevron onPress={() => router.push(`/order/${link}/ticket/${t.ticket_id}`)}>
              <View style={styles.ticketRow}>
                <Text style={[ui.strong, { flex: 1 }]} numberOfLines={1}>
                  {t.subject || 'Support ticket'}
                </Text>
                <Pill label={t.expired ? 'Expired' : t.status} color={t.expired ? colors.textMuted : undefined} />
              </View>
              <Text style={ui.meta}>{timeAgo(t.created_at)}</Text>
            </Row>
          ))
        )}
      </Card>
      {openTickets.length === 0 && o.tickets.length > 0 && (
        <Text style={[ui.meta, { marginHorizontal: spacing.lg, marginTop: 6 }]}>Tickets stay open for 24 hours. Open a new one any time.</Text>
      )}

      {o.logs.length > 0 && (
        <>
          <SectionTitle>Updates</SectionTitle>
          <Timeline logs={o.logs} />
        </>
      )}

      {(o.description || o.answers.length > 0 || o.ref_images.length > 0) && (
        <>
          <SectionTitle>Your request</SectionTitle>
          <Card style={styles.block}>
            {o.description ? <Text style={ui.body}>{o.description}</Text> : null}
            {o.answers.map((a) => (
              <View key={a.label} style={{ marginTop: spacing.md }}>
                <Text style={ui.label}>{a.label}</Text>
                <Text style={[ui.body, { marginTop: 2 }]}>{a.value === 'on' ? 'Yes' : a.value}</Text>
              </View>
            ))}
            {o.ref_images.length > 0 && (
              <View style={styles.refs}>
                {o.ref_images.map((url) => (
                  <Pressable key={url} onPress={() => WebBrowser.openBrowserAsync(url)} accessibilityLabel="Reference image">
                    <Image source={url} style={styles.ref} contentFit="cover" />
                  </Pressable>
                ))}
              </View>
            )}
          </Card>
        </>
      )}

      <Button title="Remove from This Phone" variant="ghost" onPress={forget} style={{ marginTop: spacing.xxl }} />
    </Page>
  );
}

const styles = StyleSheet.create({
  hero: { padding: spacing.lg, gap: 4 },
  type: { fontFamily: fonts.display, fontSize: 22, color: colors.text },
  block: { padding: spacing.lg },
  blockHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: spacing.md },
  blockTitle: { fontFamily: fonts.displaySemi, fontSize: 15, color: colors.text },
  money: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
  price: { fontFamily: fonts.display, fontSize: 22, color: colors.accent },
  link: { color: colors.accent, fontWeight: '600', fontSize: 15 },
  finalImage: { width: '100%', aspectRatio: 1, borderRadius: radius.lg, backgroundColor: colors.elevated },
  ticketRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  refs: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, marginTop: spacing.md },
  ref: { width: 72, height: 72, borderRadius: radius.sm, backgroundColor: colors.elevated },
});
