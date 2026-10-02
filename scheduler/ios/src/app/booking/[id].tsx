import { useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Linking, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, LoadingState, MessageState, Pill, Row, Section, styles as ui } from '@/components/ui';
import { useApi } from '@/lib/auth';
import { confirm, showError } from '@/lib/confirm';
import { capitalize, formatLongDay, formatRange } from '@/lib/format';
import { useApiData } from '@/lib/use-api-data';
import { bookingStatusColor, spacing, useColors } from '@/theme/colors';

export default function BookingDetail() {
  const colors = useColors();
  const api = useApi();
  const { id } = useLocalSearchParams<{ id: string }>();
  const { data, setData, error, reload } = useApiData(() => api.booking(Number(id)));
  const [busy, setBusy] = useState<string | null>(null);

  if (!data) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.background }}>
        {error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />}
      </View>
    );
  }

  const b = data.booking;
  const active = b.status === 'confirmed' || b.status === 'pending';

  async function act(action: 'cancel' | 'complete' | 'no-show') {
    if (action === 'cancel') {
      const ok = await confirm('Cancel this booking?', `${b.name} will be told it's cancelled.`, 'Cancel Booking');
      if (!ok) return;
    }
    setBusy(action);
    try {
      setData(await api.bookingAction(b.id, action));
    } catch (e) {
      showError(e instanceof Error ? e.message : 'That didn’t work.');
    } finally {
      setBusy(null);
    }
  }

  return (
    <ScrollView style={{ flex: 1, backgroundColor: colors.background }} contentContainerStyle={{ paddingBottom: spacing.xl * 2 }} contentInsetAdjustmentBehavior="automatic">
      <View style={styles.header}>
        <Text style={[styles.name, { color: colors.label }]}>{b.name}</Text>
        <Text style={[ui.body, { color: colors.secondaryLabel }]}>{formatLongDay(b.start)}</Text>
        <Text style={[ui.body, { color: colors.secondaryLabel }]}>
          {formatRange(b.start, b.end)}
          {b.booking_type ? ` · ${b.booking_type}` : ''}
        </Text>
        <View style={{ flexDirection: 'row', gap: spacing.sm, marginTop: spacing.xs }}>
          <Pill label={capitalize(b.status)} color={bookingStatusColor(colors, b.status)} />
          {b.is_out_of_hours && (
            <Pill label={`Out of hours${b.out_of_hours_fee_shown ? ` · ${b.out_of_hours_fee_shown}` : ''}`} color={colors.orange} />
          )}
        </View>
      </View>

      <Section title="Contact">
        <Row onPress={() => Linking.openURL(`mailto:${b.email}`)} last={!b.phone}>
          <Text style={[ui.footnote, { color: colors.secondaryLabel }]}>Email</Text>
          <Text style={[ui.body, { color: colors.tint }]}>{b.email}</Text>
        </Row>
        {b.phone && (
          <Row onPress={() => Linking.openURL(`tel:${b.phone!.replace(/\s/g, '')}`)} last>
            <Text style={[ui.footnote, { color: colors.secondaryLabel }]}>Phone</Text>
            <Text style={[ui.body, { color: colors.tint }]}>{b.phone}</Text>
          </Row>
        )}
      </Section>

      {b.notes && (
        <Section title="Notes">
          <Row last>
            <Text style={[ui.body, { color: colors.label }]} selectable>
              {b.notes}
            </Text>
          </Row>
        </Section>
      )}

      {active && (
        <View style={styles.actions}>
          <Button title="Mark Completed" onPress={() => act('complete')} loading={busy === 'complete'} disabled={!!busy} />
          <Button title="Mark No-Show" variant="plain" onPress={() => act('no-show')} loading={busy === 'no-show'} disabled={!!busy} />
          <Button title="Cancel Booking" variant="destructive" onPress={() => act('cancel')} loading={busy === 'cancel'} disabled={!!busy} />
        </View>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  header: { paddingHorizontal: spacing.lg, paddingTop: spacing.lg, gap: 2 },
  name: { fontSize: 28, fontWeight: '700' },
  actions: { marginHorizontal: spacing.lg, marginTop: spacing.xl, gap: spacing.md },
});
