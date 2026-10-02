import { router } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { LoadingState, MessageState, Row, Screen, Section, styles as ui } from '@/components/ui';
import type { CalendarDay } from '@/lib/api';
import { useApi } from '@/lib/auth';
import { formatDay, formatRange, formatTime } from '@/lib/format';
import { useApiData } from '@/lib/use-api-data';
import { spacing, useColors } from '@/theme/colors';

export default function Calendar() {
  const colors = useColors();
  const api = useApi();
  const now = new Date();
  const [month, setMonth] = useState({ year: now.getFullYear(), month: now.getMonth() + 1 });
  const [showEarlier, setShowEarlier] = useState(false);
  const { data, setData, error, refreshing, refresh, reload } = useApiData(() => api.calendar(month.year, month.month));

  // The focus effect in useApiData does the first load; this only handles month changes.
  const firstRender = useRef(true);
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false;
      return;
    }
    setData(null);
    reload();
  }, [month, reload, setData]);

  function shift(delta: number) {
    setShowEarlier(false);
    setMonth(({ year, month }) => {
      const d = new Date(year, month - 1 + delta, 1);
      return { year: d.getFullYear(), month: d.getMonth() + 1 };
    });
  }

  const label = new Date(month.year, month.month - 1, 1).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });

  return (
    <Screen title="Calendar" refreshing={refreshing} onRefresh={refresh}>
      <View style={styles.nav}>
        <NavButton label="‹" accessibilityLabel="Previous month" onPress={() => shift(-1)} />
        <Pressable onPress={() => setMonth({ year: now.getFullYear(), month: now.getMonth() + 1 })} accessibilityRole="button" accessibilityHint="Jump to this month">
          <Text style={[styles.month, { color: colors.label }]}>{label}</Text>
        </Pressable>
        <NavButton label="›" accessibilityLabel="Next month" onPress={() => shift(1)} />
      </View>

      {error && !data ? (
        <MessageState message={error} onRetry={reload} />
      ) : !data ? (
        <LoadingState />
      ) : (
        <CalendarDays days={data.days} today={data.today} showEarlier={showEarlier} onShowEarlier={() => setShowEarlier(true)} />
      )}
    </Screen>
  );
}

function CalendarDays({
  days,
  today,
  showEarlier,
  onShowEarlier,
}: {
  days: CalendarDay[];
  today: string;
  showEarlier: boolean;
  onShowEarlier: () => void;
}) {
  const colors = useColors();
  // In the current month, start the agenda at today; earlier days are one tap away.
  const hidesPast = !showEarlier && days.some((d) => d.date === today) && days[0].date !== today;
  const visible = hidesPast ? days.filter((d) => d.date >= today) : days;
  return (
    <Section>
      {hidesPast && (
        <Row onPress={onShowEarlier}>
          <Text style={[ui.body, { color: colors.tint }]}>Show earlier days</Text>
        </Row>
      )}
      {visible.map((day, i) => (
        <DayRow key={day.date} day={day} isToday={day.date === today} last={i === visible.length - 1} />
      ))}
    </Section>
  );
}

function NavButton({ label, accessibilityLabel, onPress }: { label: string; accessibilityLabel: string; onPress: () => void }) {
  const colors = useColors();
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel={accessibilityLabel} hitSlop={12} style={styles.navButton}>
      <Text style={{ color: colors.tint, fontSize: 28, lineHeight: 30 }}>{label}</Text>
    </Pressable>
  );
}

function DayRow({ day, isToday, last }: { day: CalendarDay; isToday: boolean; last: boolean }) {
  const colors = useColors();
  const quiet = !day.is_working_day && day.bookings.length === 0 && day.time_offs.length === 0;

  return (
    <Row last={last} style={isToday && { backgroundColor: colors.tint + '14' }}>
      <View style={{ gap: 4 }}>
        <View style={styles.dayHeader}>
          <Text style={[ui.body, { color: isToday ? colors.tint : quiet ? colors.secondaryLabel : colors.label, fontWeight: '600' }]}>
            {formatDay(day.date)}
            {isToday ? ' · Today' : ''}
          </Text>
          <Text style={[ui.subhead, { color: colors.secondaryLabel }]}>
            {day.working_hours ? `${day.working_hours.start} – ${day.working_hours.end}` : 'Day off'}
          </Text>
        </View>

        {day.time_offs.map((t) => (
          <Text key={`t${t.id}`} style={[ui.subhead, { color: colors.purple }]}>
            ✈︎ {t.reason || 'Time off'}
            {t.all_day ? '' : ` · ${formatTime(t.start)} – ${formatTime(t.end)}`}
          </Text>
        ))}

        {day.bookings.map((b) => (
          <Pressable key={`b${b.id}`} onPress={() => router.push(`/booking/${b.id}`)} accessibilityRole="link" hitSlop={4}>
            <Text style={[ui.subhead, { color: colors.tint }]}>
              {formatRange(b.start, b.end)} · {b.name}
            </Text>
          </Pressable>
        ))}
      </View>
    </Row>
  );
}

const styles = StyleSheet.create({
  nav: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: spacing.lg },
  navButton: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
  month: { fontSize: 20, fontWeight: '600' },
  dayHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
});
