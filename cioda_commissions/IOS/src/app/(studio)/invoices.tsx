import { router } from 'expo-router';
import { useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { Card, EmptyText, LoadingState, MessageState, Pill, Row, Screen, SectionTitle, styles as ui } from '@/components/ui';
import type { Invoice } from '@/lib/api';
import { confirm, showError } from '@/lib/confirm';
import { date, money } from '@/lib/format';
import { useAdmin } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';
import { colors, spacing } from '@/theme/theme';

export default function Invoices() {
  const admin = useAdmin();
  const { data, setData, error, refreshing, refresh, reload } = useApiData(admin.invoices);
  const [busy, setBusy] = useState<string | null>(null);

  async function markPaid(inv: Invoice) {
    if (!(await confirm(`Mark ${money(inv.amount)} as paid?`, `${inv.customer_name ?? 'Customer'} · ${inv.order_id}. The order will show as Paid.`, 'Mark Paid', false))) return;
    setBusy(inv.invoice_id);
    try {
      const { invoice } = await admin.markPaid(inv.invoice_id);
      setData((d) => d && { invoices: d.invoices.map((i) => (i.invoice_id === invoice.invoice_id ? invoice : i)) });
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not mark it paid.');
    } finally {
      setBusy(null);
    }
  }

  const unpaid = data?.invoices.filter((i) => !i.paid) ?? [];
  const paid = data?.invoices.filter((i) => i.paid) ?? [];
  const outstanding = unpaid.reduce((sum, i) => sum + i.amount, 0);

  return (
    <Screen title="Invoices" subtitle={data ? `${money(outstanding)} outstanding` : undefined} refreshing={refreshing} onRefresh={refresh}>
      {!data ? (
        error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />
      ) : (
        <>
          <SectionTitle>{`Unpaid (${unpaid.length})`}</SectionTitle>
          <Card>
            {unpaid.length === 0 ? (
              <Row last>
                <EmptyText>Nothing waiting to be paid.</EmptyText>
              </Row>
            ) : (
              unpaid.map((inv, i) => (
                <Row key={inv.invoice_id} last={i === unpaid.length - 1}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.md }}>
                    <Pressable style={{ flex: 1 }} onPress={() => router.push(`/studio/order/${inv.order_id}`)} accessibilityRole="link">
                      <Text style={ui.strong}>
                        {money(inv.amount)} · {inv.customer_name ?? 'Customer'}
                      </Text>
                      <Text style={ui.meta}>
                        {inv.order_id} · {inv.invoice_id} · {date(inv.created_at)}
                      </Text>
                    </Pressable>
                    <Pressable onPress={() => markPaid(inv)} disabled={busy === inv.invoice_id} hitSlop={6} accessibilityRole="button">
                      <Text style={{ color: colors.success, fontWeight: '700' }}>{busy === inv.invoice_id ? '…' : 'Mark paid'}</Text>
                    </Pressable>
                  </View>
                </Row>
              ))
            )}
          </Card>
          {paid.length > 0 && (
            <>
              <SectionTitle>Paid</SectionTitle>
              <Card>
                {paid.slice(0, 40).map((inv, i, arr) => (
                  <Row key={inv.invoice_id} last={i === arr.length - 1} chevron onPress={() => router.push(`/studio/order/${inv.order_id}`)}>
                    <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}>
                      <Text style={[ui.strong, { flex: 1 }]}>
                        {money(inv.amount)} · {inv.customer_name ?? 'Customer'}
                      </Text>
                      <Pill label="Paid" />
                    </View>
                    <Text style={ui.meta}>
                      {inv.order_id} · paid {date(inv.paid_at)}
                    </Text>
                  </Row>
                ))}
              </Card>
            </>
          )}
        </>
      )}
    </Screen>
  );
}
