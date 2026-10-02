import { router } from 'expo-router';
import { useState } from 'react';
import { Pressable, StyleSheet, Switch, Text, View } from 'react-native';

import { Card, LoadingState, MessageState, Pill, Row, Screen, SectionTitle, styles as ui } from '@/components/ui';
import { confirm, showError, showInfo } from '@/lib/confirm';
import { money, timeAgo } from '@/lib/format';
import { getPushToken } from '@/lib/push';
import { useAdmin, useSession } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';
import { colors, fonts, spacing } from '@/theme/theme';

export default function Dashboard() {
  const admin = useAdmin();
  const { signOutAdmin } = useSession();
  const { data, setData, error, refreshing, refresh, reload } = useApiData(admin.dashboard);
  const [toggling, setToggling] = useState(false);

  const signOut = (
    <Pressable onPress={signOutAdmin} hitSlop={8} accessibilityRole="button">
      <Text style={{ color: colors.accent, fontSize: 16 }}>Sign Out</Text>
    </Pressable>
  );

  if (!data) {
    return (
      <Screen title="Studio" headerRight={signOut}>
        {error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />}
      </Screen>
    );
  }

  async function toggle(open: boolean) {
    let notify = false;
    if (open) {
      // Same choice as the website's toggle: tell the "notify me" list, or open quietly (e.g. to test).
      notify = await confirm('Open commissions?', 'Also notify everyone waiting to hear when you reopen (Discord and email)?', 'Open & Notify', false);
      if (!notify && !(await confirm('Open without notifying?', 'Nobody on the notify list will be told.', 'Open Quietly', false))) return;
    } else if (!(await confirm('Close commissions?', 'New requests will be turned away until you reopen.', 'Close'))) {
      return;
    }
    setToggling(true);
    try {
      const res = await admin.toggleCommissions(notify);
      setData((d) => d && { ...d, commissions_open: res.commissions_open });
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not change that.');
    } finally {
      setToggling(false);
    }
  }

  async function testPush() {
    const token = await getPushToken();
    if (!token) return showInfo('Notifications are off', 'Allow notifications for this app in iOS Settings, then try again.');
    try {
      await admin.registerPush(token);
      await admin.testPush();
      showInfo('Test sent', 'It should arrive in a few seconds.');
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not send a test.');
    }
  }

  const s = data.stats;
  const tiles: { label: string; value: number; color: string; onPress: () => void }[] = [
    { label: 'To confirm', value: s.awaiting_confirmation, color: colors.gold, onPress: () => router.push({ pathname: '/all-orders', params: { status: 'Awaiting Confirmation' } }) },
    { label: 'In progress', value: s.in_progress, color: colors.accent, onPress: () => router.push({ pathname: '/all-orders', params: { status: 'In Progress' } }) },
    { label: 'Open tickets', value: s.open_tickets, color: colors.info, onPress: () => router.push('/tickets') },
    { label: 'Unpaid', value: s.unpaid, color: colors.danger, onPress: () => router.push('/invoices') },
    { label: 'All orders', value: s.total_orders, color: colors.textSecondary, onPress: () => router.push('/all-orders') },
  ];

  return (
    <Screen title="Studio" subtitle="Welcome back, Cioda" headerRight={signOut} refreshing={refreshing} onRefresh={refresh}>
      <Card style={styles.toggle}>
        <View style={{ flex: 1 }}>
          <Text style={styles.toggleTitle}>{data.commissions_open ? 'Commissions open' : 'Commissions closed'}</Text>
          <Text style={ui.meta}>{data.commissions_open ? 'People can send requests.' : 'Requests are turned away.'}</Text>
        </View>
        <Switch
          value={data.commissions_open}
          onValueChange={toggle}
          disabled={toggling}
          trackColor={{ true: colors.success, false: colors.border }}
          accessibilityLabel="Commissions open"
        />
      </Card>

      <View style={styles.tiles}>
        {tiles.map((t) => (
          <Pressable
            key={t.label}
            onPress={t.onPress}
            accessibilityRole="button"
            accessibilityLabel={`${t.label}: ${t.value}`}
            style={({ pressed }) => [styles.tile, pressed && { opacity: 0.75 }]}
          >
            <Text style={[styles.tileValue, { color: t.value ? t.color : colors.textMuted }]}>{t.value}</Text>
            <Text style={ui.meta}>{t.label}</Text>
          </Pressable>
        ))}
      </View>

      <SectionTitle
        right={
          <Pressable onPress={() => router.push('/studio/requests')} hitSlop={8} accessibilityRole="link">
            <Text style={{ color: colors.accent, fontWeight: '600', fontSize: 14 }}>All requests</Text>
          </Pressable>
        }
      >
        Recent orders
      </SectionTitle>
      <Card>
        {data.recent_orders.map((o, i) => (
          <Row key={o.order_id} last={i === data.recent_orders.length - 1} chevron onPress={() => router.push(`/studio/order/${o.order_id}`)}>
            <View style={styles.orderRow}>
              <Text style={[ui.strong, { flex: 1 }]} numberOfLines={1}>
                {o.customer_name}
              </Text>
              <Pill label={o.status} />
            </View>
            <Text style={ui.meta} numberOfLines={1}>
              {o.order_id} · {o.commission_type || 'Commission'} · {o.price ? money(o.price) : 'No price'} · {timeAgo(o.created_at)}
            </Text>
          </Row>
        ))}
      </Card>

      <SectionTitle>Notifications</SectionTitle>
      <Card>
        <Row last onPress={testPush}>
          <Text style={{ color: colors.accent, fontSize: 16 }}>Send test notification</Text>
        </Row>
      </Card>
      <Text style={[ui.meta, { marginHorizontal: spacing.lg, marginTop: 6 }]}>
        This phone is notified about new requests, new tickets and customer replies.
      </Text>
    </Screen>
  );
}

const styles = StyleSheet.create({
  toggle: { flexDirection: 'row', alignItems: 'center', padding: spacing.lg, gap: spacing.md },
  toggleTitle: { fontFamily: fonts.displaySemi, fontSize: 17, color: colors.text },
  tiles: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, paddingHorizontal: spacing.lg, marginTop: spacing.md },
  tile: {
    width: '31.5%',
    flexGrow: 1,
    backgroundColor: colors.card,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
    gap: 2,
  },
  tileValue: { fontFamily: fonts.display, fontSize: 26 },
  orderRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
});
