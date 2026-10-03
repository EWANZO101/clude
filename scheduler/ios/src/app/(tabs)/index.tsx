import { useState } from 'react';
import * as WebBrowser from 'expo-web-browser';
import { Alert, Linking, Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { BookingRow } from '@/components/booking-row';
import { LoadingState, MessageState, Pill, Row, Screen, Section, styles as ui } from '@/components/ui';
import type { ManualStatus } from '@/lib/api';
import type { PushState } from '@/lib/push';
import { useApi, useAuth } from '@/lib/auth';
import { showError } from '@/lib/confirm';
import { WEBSITE_SETTINGS_URL } from '@/lib/links';
import { capitalize, formatDay, formatRange } from '@/lib/format';
import { useApiData } from '@/lib/use-api-data';
import { spacing, statusColor, useColors } from '@/theme/colors';

export default function Today() {
  const colors = useColors();
  const api = useApi();
  const { signOut, pushState } = useAuth();
  const { data, setData, error, loading, refreshing, refresh, reload } = useApiData(api.dashboard);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [task, setTask] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const signOutButton = (
    <Pressable onPress={signOut} accessibilityRole="button" hitSlop={8}>
      <Text style={{ color: colors.tint, fontSize: 17 }}>Sign Out</Text>
    </Pressable>
  );

  if (!data) {
    return (
      <Screen title="Today" headerRight={signOutButton}>
        {loading ? <LoadingState /> : <MessageState message={error!} onRetry={reload} />}
      </Screen>
    );
  }

  const { status } = data;
  // Local edits win until saved; otherwise show what the server has.
  const messageValue = statusMessage ?? (status.is_manual ? status.message ?? '' : '');
  const taskValue = task ?? data.current_task ?? '';

  async function chooseStatus(next: ManualStatus | null) {
    setSaving(true);
    try {
      const res = await api.setStatus(next, next ? messageValue : undefined);
      setData((d) => d && { ...d, status: res.status });
      setStatusMessage(null);
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not update your status.');
    } finally {
      setSaving(false);
    }
  }

  async function saveTask() {
    try {
      const res = await api.setCurrentTask(taskValue);
      setData((d) => d && { ...d, current_task: res.current_task });
      setTask(null);
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not save your current task.');
    }
  }

  async function sendTestPush() {
    try {
      await api.testPush();
      if (Platform.OS !== 'web') Alert.alert('Test sent', 'It should arrive in a few seconds.');
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not send a test notification.');
    }
  }

  const statusOptions: { value: ManualStatus | null; label: string }[] = [
    { value: null, label: 'Automatic' },
    ...data.manual_statuses.map((s) => ({ value: s, label: capitalize(s) })),
  ];
  // A manual status is always one of the manual options; "offline" is only ever automatic.
  const selectedStatus = status.is_manual ? (status.status as ManualStatus) : null;

  return (
    <Screen title="Today" headerRight={signOutButton} refreshing={refreshing} onRefresh={refresh}>
      <Text style={[ui.subhead, styles.date, { color: colors.secondaryLabel }]}>
        {formatDay(data.now)} · Hi, {data.user.name.split(' ')[0]}
      </Text>

      <Section title="Status" footer={status.is_manual ? 'Set manually. Choose Automatic to follow your working hours again.' : 'Following your working hours, breaks and time off.'}>
        <Row>
          <View style={{ gap: 6 }}>
            <Pill label={capitalize(status.status)} color={statusColor(colors, status.status)} />
            {status.message && <Text style={[ui.body, { color: colors.label }]}>{status.message}</Text>}
            {status.next_available && (
              <Text style={[ui.subhead, { color: colors.secondaryLabel }]}>Next available: {status.next_available}</Text>
            )}
          </View>
        </Row>
        <Row>
          <View style={styles.chips}>
            {statusOptions.map((o) => {
              const selected = o.value === selectedStatus;
              const tint = o.value ? statusColor(colors, o.value) : colors.tint;
              return (
                <Pressable
                  key={o.label}
                  disabled={saving}
                  onPress={() => chooseStatus(o.value)}
                  accessibilityRole="button"
                  accessibilityState={{ selected }}
                  style={[styles.chip, { borderColor: tint }, selected && { backgroundColor: tint }]}
                >
                  <Text style={[ui.subhead, { color: selected ? '#FFFFFF' : tint, fontWeight: '600' }]}>{o.label}</Text>
                </Pressable>
              );
            })}
          </View>
        </Row>
        <Row last>
          <TextInput
            style={[ui.body, { color: colors.label }]}
            placeholder="Status message (optional)"
            placeholderTextColor={colors.tertiaryLabel}
            value={messageValue}
            onChangeText={setStatusMessage}
            returnKeyType="done"
            onSubmitEditing={() => selectedStatus && chooseStatus(selectedStatus)}
            accessibilityLabel="Status message"
          />
        </Row>
      </Section>

      <Section title="Current task" footer="Shown on your public /task page.">
        <Row last>
          <TextInput
            style={[ui.body, { color: colors.label }]}
            placeholder="What are you working on?"
            placeholderTextColor={colors.tertiaryLabel}
            value={taskValue}
            onChangeText={setTask}
            onBlur={() => task !== null && saveTask()}
            onSubmitEditing={saveTask}
            returnKeyType="done"
            accessibilityLabel="Current task"
          />
        </Row>
      </Section>

      <View style={styles.stats}>
        <Stat label="Today" value={data.stats.todays_bookings} />
        <Stat label="Next 7 days" value={data.stats.week_bookings} />
      </View>

      <Section title="Today's bookings">
        {data.todays_bookings.length === 0 ? (
          <Row last>
            <Text style={[ui.body, { color: colors.secondaryLabel }]}>No bookings today.</Text>
          </Row>
        ) : (
          data.todays_bookings.map((b, i) => (
            <BookingRow key={b.id} booking={b} showDate={false} last={i === data.todays_bookings.length - 1} />
          ))
        )}
      </Section>

      {data.next_booking && data.next_booking.start.slice(0, 10) !== data.now.slice(0, 10) && (
        <Section title="Next booking" footer={`${formatDay(data.next_booking.start)}, ${formatRange(data.next_booking.start, data.next_booking.end)}`}>
          <BookingRow booking={data.next_booking} last />
        </Section>
      )}

      <NotificationsSection pushState={pushState} onTest={sendTestPush} />

      <Section footer="Availability, booking types, Discord and other settings live on the website.">
        <Row onPress={() => WebBrowser.openBrowserAsync(WEBSITE_SETTINGS_URL)} last>
          <Text style={[ui.body, { color: colors.tint }]}>Website settings</Text>
        </Row>
      </Section>
    </Screen>
  );
}

const PUSH_LABELS: Record<PushState, { label: string; footer: string }> = {
  enabled: { label: 'On', footer: 'You’ll be notified about new bookings and customer cancellations, even when the app is closed.' },
  denied: { label: 'Off', footer: 'Notifications are turned off for this app in iOS Settings.' },
  unsupported: { label: 'Not available', footer: 'This device can’t receive push notifications (simulators, Android Expo Go and the web preview can’t).' },
};

function NotificationsSection({ pushState, onTest }: { pushState: PushState | null; onTest: () => void }) {
  const colors = useColors();
  const info = pushState ? PUSH_LABELS[pushState] : null;
  // The web preview can never get push, so the section would only be noise there.
  if (Platform.OS === 'web') return null;
  return (
    <Section title="Notifications" footer={info?.footer}>
      <Row last={pushState !== 'enabled' && pushState !== 'denied'}>
        <View style={styles.pushRow}>
          <Text style={[ui.body, { color: colors.label }]}>New bookings</Text>
          <Text style={[ui.body, { color: colors.secondaryLabel }]}>{info?.label ?? 'Checking…'}</Text>
        </View>
      </Row>
      {pushState === 'enabled' && (
        <Row onPress={onTest} last>
          <Text style={[ui.body, { color: colors.tint }]}>Send test notification</Text>
        </Row>
      )}
      {pushState === 'denied' && (
        <Row onPress={() => Linking.openSettings()} last>
          <Text style={[ui.body, { color: colors.tint }]}>Turn on in Settings</Text>
        </Row>
      )}
    </Section>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  const colors = useColors();
  return (
    <View style={[styles.stat, { backgroundColor: colors.card }]}>
      <Text style={[styles.statValue, { color: colors.label }]}>{value}</Text>
      <Text style={[ui.footnote, { color: colors.secondaryLabel }]}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  date: { paddingHorizontal: spacing.lg },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  chip: { borderWidth: 1.5, borderRadius: 999, paddingHorizontal: 12, paddingVertical: 6 },
  stats: { flexDirection: 'row', gap: spacing.md, marginHorizontal: spacing.lg, marginTop: spacing.xl },
  pushRow: { flexDirection: 'row', justifyContent: 'space-between' },
  stat: { flex: 1, borderRadius: 10, padding: spacing.lg, gap: 2 },
  statValue: { fontSize: 28, fontWeight: '700', fontVariant: ['tabular-nums'] },
});
