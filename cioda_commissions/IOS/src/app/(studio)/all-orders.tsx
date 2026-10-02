import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, TextInput, View } from 'react-native';

import { Card, Chips, EmptyText, LoadingState, MessageState, Pill, Row, Screen, styles as ui } from '@/components/ui';
import { money, timeAgo } from '@/lib/format';
import { useAdmin } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';
import { colors, radius, spacing, statusColor } from '@/theme/theme';

const FILTERS = ['All', 'Awaiting Confirmation', 'Accepted', 'Pending', 'In Progress', 'Done', 'Declined'];

export default function AllOrders() {
  const admin = useAdmin();
  const params = useLocalSearchParams<{ status?: string }>();
  // A dashboard tile passes ?status=…; a chip tapped here overrides it until the next tile tap.
  const [picked, setPicked] = useState<{ from?: string; value: string } | null>(null);
  const status = picked && picked.from === params.status ? picked.value : (params.status ?? 'All');
  const setStatus = (value: string) => setPicked({ from: params.status, value });
  const [q, setQ] = useState('');
  const { data, error, refreshing, refresh, reload } = useApiData(() => admin.orders(q, status === 'All' ? '' : status));

  // Reload when the filter changes, and a moment after typing stops.
  const first = useRef(true);
  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    const t = setTimeout(reload, q ? 300 : 0);
    return () => clearTimeout(t);
  }, [q, status, reload]);

  return (
    <Screen title="Orders" refreshing={refreshing} onRefresh={refresh}>
      <View style={{ paddingHorizontal: spacing.lg, gap: spacing.md }}>
        <TextInput
          style={styles.search}
          value={q}
          onChangeText={setQ}
          placeholder="Search name, order ID, Discord, email…"
          placeholderTextColor={colors.textMuted}
          autoCapitalize="none"
          autoCorrect={false}
          clearButtonMode="while-editing"
          keyboardAppearance="dark"
          accessibilityLabel="Search orders"
        />
        <Chips
          options={FILTERS.map((f) => ({ value: f, label: f === 'Awaiting Confirmation' ? 'To confirm' : f }))}
          selected={[status]}
          onToggle={setStatus}
          colorFor={(f) => (f === 'All' ? colors.accent : statusColor(f))}
        />
      </View>
      <View style={{ marginTop: spacing.lg }}>
        {!data ? (
          error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />
        ) : data.orders.length === 0 ? (
          <Card style={{ padding: spacing.lg }}>
            <EmptyText>No orders match.</EmptyText>
          </Card>
        ) : (
          <Card>
            {data.orders.map((o, i) => (
              <Row key={o.order_id} last={i === data.orders.length - 1} chevron onPress={() => router.push(`/studio/order/${o.order_id}`)}>
                <View style={styles.titleRow}>
                  <Text style={[ui.strong, { flex: 1 }]} numberOfLines={1}>
                    {o.customer_name}
                  </Text>
                  <Pill label={o.status} />
                </View>
                <Text style={ui.meta} numberOfLines={1}>
                  {o.order_id} · {o.commission_type || 'Commission'}
                </Text>
                <Text style={ui.meta}>
                  {o.price ? money(o.price) : 'No price'} ·{' '}
                  <Text style={{ color: o.payment_status === 'Paid' ? colors.success : colors.textSecondary }}>{o.payment_status}</Text> · {timeAgo(o.created_at)}
                </Text>
              </Row>
            ))}
          </Card>
        )}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  search: {
    backgroundColor: colors.elevated,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    paddingHorizontal: spacing.md,
    paddingVertical: 11,
    fontSize: 16,
    color: colors.text,
  },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
});
