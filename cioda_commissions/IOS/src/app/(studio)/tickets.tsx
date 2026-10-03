import { router } from 'expo-router';
import { Text, View } from 'react-native';

import { Card, EmptyText, LoadingState, MessageState, Pill, Row, Screen, SectionTitle, styles as ui } from '@/components/ui';
import type { Ticket } from '@/lib/api';
import { timeAgo } from '@/lib/format';
import { useAdmin } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';
import { colors, spacing } from '@/theme/theme';

export default function Tickets() {
  const admin = useAdmin();
  const { data, error, refreshing, refresh, reload } = useApiData(admin.tickets);

  const open = data?.tickets.filter((t) => t.status === 'Open') ?? [];
  const closed = data?.tickets.filter((t) => t.status !== 'Open') ?? [];

  return (
    <Screen title="Tickets" refreshing={refreshing} onRefresh={refresh}>
      {!data ? (
        error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />
      ) : (
        <>
          <SectionTitle>{`Open (${open.length})`}</SectionTitle>
          <TicketList tickets={open} empty="No open tickets. All caught up!" />
          {closed.length > 0 && (
            <>
              <SectionTitle>Closed</SectionTitle>
              <TicketList tickets={closed.slice(0, 30)} empty="" />
            </>
          )}
        </>
      )}
    </Screen>
  );
}

function TicketList({ tickets, empty }: { tickets: Ticket[]; empty: string }) {
  if (!tickets.length) {
    return (
      <Card style={{ padding: spacing.lg }}>
        <EmptyText>{empty}</EmptyText>
      </Card>
    );
  }
  return (
    <Card>
      {tickets.map((t, i) => (
        <Row key={t.ticket_id} last={i === tickets.length - 1} chevron onPress={() => router.push(`/studio/ticket/${t.ticket_id}`)}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}>
            <Text style={[ui.strong, { flex: 1 }]} numberOfLines={1}>
              {t.subject || 'Support ticket'}
            </Text>
            {t.expired && t.status === 'Open' ? <Pill label="Expired" color={colors.textMuted} /> : null}
          </View>
          <Text style={ui.meta} numberOfLines={1}>
            {t.customer_name} · {t.order_id ?? 'No order'} · {timeAgo(t.created_at)}
          </Text>
        </Row>
      ))}
    </Card>
  );
}
