import { router } from 'expo-router';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { LoadingState, MessageState, Row, Screen, Section, styles as ui } from '@/components/ui';
import type { TimeOff } from '@/lib/api';
import { useApi } from '@/lib/auth';
import { confirm, showError } from '@/lib/confirm';
import { formatTimeOff, toDateString } from '@/lib/format';
import { useApiData } from '@/lib/use-api-data';
import { useColors } from '@/theme/colors';

export default function TimeOffScreen() {
  const colors = useColors();
  const api = useApi();
  const { data, setData, error, refreshing, refresh, reload } = useApiData(api.timeOff);

  async function remove(entry: TimeOff) {
    const ok = await confirm('Remove this time off?', formatTimeOff(entry), 'Remove');
    if (!ok) return;
    try {
      await api.deleteTimeOff(entry.id);
      setData((d) => d && { time_off: d.time_off.filter((t) => t.id !== entry.id) });
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not remove that time off.');
    }
  }

  const addButton = (
    <Pressable onPress={() => router.push('/time-off-new')} accessibilityRole="button" accessibilityLabel="Add time off" hitSlop={8}>
      <Text style={{ color: colors.tint, fontSize: 17 }}>Add</Text>
    </Pressable>
  );

  const today = toDateString(new Date());
  const entries = data?.time_off ?? [];
  const upcoming = entries.filter((t) => t.end.slice(0, 10) >= today).reverse(); // soonest first
  const past = entries.filter((t) => t.end.slice(0, 10) < today);

  return (
    <Screen title="Time Off" headerRight={addButton} refreshing={refreshing} onRefresh={refresh}>
      {error && !data ? (
        <MessageState message={error} onRetry={reload} />
      ) : !data ? (
        <LoadingState />
      ) : (
        <>
          <Section title="Upcoming" footer="Bookings can't be made during time off.">
            {upcoming.length === 0 ? (
              <Row last>
                <Text style={[ui.body, { color: colors.secondaryLabel }]}>No upcoming time off.</Text>
              </Row>
            ) : (
              upcoming.map((t, i) => <TimeOffRow key={t.id} entry={t} onRemove={remove} last={i === upcoming.length - 1} />)
            )}
          </Section>
          {past.length > 0 && (
            <Section title="Past">
              {past.slice(0, 20).map((t, i, arr) => (
                <TimeOffRow key={t.id} entry={t} onRemove={remove} last={i === arr.length - 1} />
              ))}
            </Section>
          )}
        </>
      )}
    </Screen>
  );
}

function TimeOffRow({ entry, onRemove, last }: { entry: TimeOff; onRemove: (t: TimeOff) => void; last: boolean }) {
  const colors = useColors();
  return (
    <Row last={last}>
      <View style={styles.row}>
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={[ui.body, { color: colors.label }]}>{entry.reason || 'Time off'}</Text>
          <Text style={[ui.subhead, { color: colors.secondaryLabel }]}>{formatTimeOff(entry)}</Text>
        </View>
        <Pressable onPress={() => onRemove(entry)} accessibilityRole="button" accessibilityLabel={`Remove ${entry.reason || 'time off'}`} hitSlop={8}>
          <Text style={{ color: colors.destructive, fontSize: 15 }}>Remove</Text>
        </Pressable>
      </View>
    </Row>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 12 },
});
