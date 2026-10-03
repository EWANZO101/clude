import { router, Stack, useLocalSearchParams } from 'expo-router';
import { Pressable, Text, View } from 'react-native';

import { Chat } from '@/components/chat';
import { LoadingState, MessageState, Pill, styles as ui } from '@/components/ui';
import { confirm, showError } from '@/lib/confirm';
import { dateTime } from '@/lib/format';
import { useAdmin } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';
import { colors, spacing } from '@/theme/theme';

export default function StudioTicket() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const admin = useAdmin();
  const { data, setData, error, reload } = useApiData(() => admin.ticket(id));

  if (!data) return error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />;
  const t = data.ticket;
  const open = t.status === 'Open';

  async function close() {
    if (!(await confirm('Close this ticket?', 'The customer can open a new one if they need more help.', 'Close Ticket'))) return;
    try {
      setData(await admin.closeTicket(id));
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not close it.');
    }
  }

  return (
    <>
      <Stack.Screen
        options={{
          title: t.subject || 'Ticket',
          headerRight: open
            ? () => (
                <Pressable onPress={close} hitSlop={8} accessibilityRole="button" style={{ paddingHorizontal: 4 }}>
                  <Text style={{ color: colors.danger, fontSize: 16 }}>Close</Text>
                </Pressable>
              )
            : undefined,
        }}
      />
      <Chat
        messages={t.messages ?? []}
        me="admin"
        canReply={open}
        closedText="This ticket is closed."
        header={
          <View style={{ gap: 4, marginBottom: spacing.sm }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}>
              <Text style={ui.strong}>{t.customer_name}</Text>
              <Pill label={t.expired && open ? 'Expired' : t.status} color={t.expired && open ? colors.textMuted : undefined} />
            </View>
            {t.order_id ? (
              <Pressable onPress={() => router.push(`/studio/order/${t.order_id}`)} accessibilityRole="link">
                <Text style={{ color: colors.accent }}>Order {t.order_id} ›</Text>
              </Pressable>
            ) : null}
            <Text style={ui.meta}>Opened {dateTime(t.created_at)}. Replies also go to the Discord thread.</Text>
          </View>
        }
        onSend={async (text) => {
          try {
            setData(await admin.replyTicket(id, text));
          } catch (e) {
            showError(e instanceof Error ? e.message : 'Could not send.');
            throw e;
          }
        }}
      />
    </>
  );
}
