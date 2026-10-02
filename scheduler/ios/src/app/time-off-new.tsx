import { router } from 'expo-router';
import { useState } from 'react';
import { ScrollView, StyleSheet, Switch, Text, TextInput, View } from 'react-native';

import { DateField } from '@/components/date-field';
import { Button, Row, Section, styles as ui } from '@/components/ui';
import { useApi } from '@/lib/auth';
import { toDateString, toTimeString } from '@/lib/format';
import { spacing, useColors } from '@/theme/colors';

function atHour(hour: number) {
  const d = new Date();
  d.setHours(hour, 0, 0, 0);
  return d;
}

export default function NewTimeOff() {
  const colors = useColors();
  const api = useApi();
  const [allDay, setAllDay] = useState(true);
  const [startDate, setStartDate] = useState(new Date());
  const [endDate, setEndDate] = useState(new Date());
  const [startTime, setStartTime] = useState(atHour(9));
  const [endTime, setEndTime] = useState(atHour(17));
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  function changeStart(d: Date) {
    setStartDate(d);
    // Keep the range valid when the start moves past the end.
    if (toDateString(d) > toDateString(endDate)) setEndDate(d);
  }

  async function save() {
    setSaving(true);
    setError(null);
    try {
      await api.addTimeOff({
        start_date: toDateString(startDate),
        end_date: toDateString(endDate),
        all_day: allDay,
        ...(!allDay && { start_time: toTimeString(startTime), end_time: toTimeString(endTime) }),
        reason,
      });
      router.back();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save.');
      setSaving(false);
    }
  }

  const label = [ui.body, { color: colors.label }];

  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: colors.background }}
      contentContainerStyle={{ paddingBottom: spacing.xl * 2 }}
      contentInsetAdjustmentBehavior="automatic"
      automaticallyAdjustKeyboardInsets
      keyboardShouldPersistTaps="handled"
      keyboardDismissMode="interactive"
    >
      <Section>
        <Row>
          <View style={styles.field}>
            <Text style={label}>All day</Text>
            <Switch value={allDay} onValueChange={setAllDay} accessibilityLabel="All day" />
          </View>
        </Row>
        <Row>
          <View style={styles.field}>
            <Text style={label}>Starts</Text>
            <View style={styles.pickers}>
              <DateField mode="date" value={startDate} onChange={changeStart} accessibilityLabel="Start date" />
              {!allDay && <DateField mode="time" value={startTime} onChange={setStartTime} accessibilityLabel="Start time" />}
            </View>
          </View>
        </Row>
        <Row last>
          <View style={styles.field}>
            <Text style={label}>Ends</Text>
            <View style={styles.pickers}>
              <DateField mode="date" value={endDate} onChange={setEndDate} accessibilityLabel="End date" />
              {!allDay && <DateField mode="time" value={endTime} onChange={setEndTime} accessibilityLabel="End time" />}
            </View>
          </View>
        </Row>
      </Section>

      <Section footer={error ?? undefined}>
        <Row last>
          <TextInput
            style={label}
            placeholder="Reason (optional), e.g. Holiday"
            placeholderTextColor={colors.tertiaryLabel}
            value={reason}
            onChangeText={setReason}
            maxLength={255}
            accessibilityLabel="Reason"
          />
        </Row>
      </Section>

      <View style={styles.button}>
        <Button title="Add Time Off" onPress={save} loading={saving} />
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  field: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md, minHeight: 32 },
  // Wraps the time picker under the date on narrow phones instead of overlapping the label.
  pickers: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'flex-end', alignItems: 'center', gap: spacing.sm, flexShrink: 1 },
  button: { marginHorizontal: spacing.lg, marginTop: spacing.xl },
});
