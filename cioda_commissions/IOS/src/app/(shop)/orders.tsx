import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, Card, EmptyText, Pill, Row, Screen, styles as ui } from '@/components/ui';
import { ApiError, getOrder, type CustomerOrder } from '@/lib/api';
import { date } from '@/lib/format';
import { useSession } from '@/lib/session';
import { colors, spacing } from '@/theme/theme';

type Loaded = { order?: CustomerOrder; locked?: boolean; error?: string };

export default function MyOrders() {
  const { orders } = useSession();
  const [details, setDetails] = useState<Record<string, Loaded>>({});
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    const entries = await Promise.all(
      orders.map(async (o): Promise<[string, Loaded]> => {
        try {
          return [o.link, { order: (await getOrder(o.link, o.token)).order }];
        } catch (e) {
          // 401 = the PIN was reset (by Cioda) or changed; the order needs unlocking again.
          if (e instanceof ApiError && e.status === 401) return [o.link, { locked: true }];
          return [o.link, { error: e instanceof Error ? e.message : 'Could not load' }];
        }
      }),
    );
    setDetails(Object.fromEntries(entries));
  }, [orders]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  const addButton = (
    <Pressable onPress={() => router.push('/add-order')} hitSlop={8} accessibilityRole="button" accessibilityLabel="Add an order">
      <Text style={{ color: colors.accent, fontSize: 17, fontWeight: '600' }}>Add</Text>
    </Pressable>
  );

  return (
    <Screen
      title="My Orders"
      headerRight={addButton}
      refreshing={refreshing}
      onRefresh={async () => {
        setRefreshing(true);
        await load();
        setRefreshing(false);
      }}
    >
      {orders.length === 0 ? (
        <Card style={{ padding: spacing.lg, gap: spacing.md }}>
          <EmptyText>No orders on this phone yet.</EmptyText>
          <Text style={ui.bodySmall}>Send a request and your order appears here automatically. Already ordered on the website? Add it with your order ID.</Text>
          <Button title="Add an Existing Order" variant="secondary" onPress={() => router.push('/add-order')} />
        </Card>
      ) : (
        <Card>
          {orders.map((o, i) => {
            const d = details[o.link];
            const order = d?.order;
            return (
              <Row
                key={o.link}
                last={i === orders.length - 1}
                chevron
                onPress={() => router.push(d?.locked ? { pathname: '/order/[link]/pin', params: { link: o.link, orderId: o.orderId } } : `/order/${o.link}`)}
              >
                <View style={{ gap: 4 }}>
                  <View style={styles.titleRow}>
                    <Text style={ui.strong}>{o.orderId}</Text>
                    {order ? <Pill label={order.status} /> : d?.locked ? <Pill label="Locked" color={colors.gold} /> : null}
                  </View>
                  <Text style={ui.bodySmall} numberOfLines={1}>
                    {order ? `${order.commission_type || 'Commission'} · ${date(order.created_at)}` : d?.locked ? 'Enter your PIN to open' : d?.error ?? 'Loading…'}
                  </Text>
                </View>
              </Row>
            );
          })}
        </Card>
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  titleRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.sm },
});
