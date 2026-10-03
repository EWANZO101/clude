import { Image } from 'expo-image';
import * as WebBrowser from 'expo-web-browser';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, Card, EmptyText, LoadingState, MessageState, Page, Pill, SectionTitle, styles as ui } from '@/components/ui';
import type { CommissionRequest } from '@/lib/api';
import { showError } from '@/lib/confirm';
import { timeAgo } from '@/lib/format';
import { useAdmin } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';
import { colors, radius, spacing } from '@/theme/theme';

/**
 * Commission requests. Each already created an order (Awaiting Confirmation) when it
 * came in; accepting/declining here just tracks the request, like the website's Requests page.
 */
export default function Requests() {
  const admin = useAdmin();
  const { data, setData, error, refreshing, refresh, reload } = useApiData(admin.requests);
  const [busy, setBusy] = useState<string | null>(null);

  async function act(r: CommissionRequest, action: 'accept' | 'decline') {
    setBusy(r.request_id);
    try {
      const { status } = await admin.requestAction(r.request_id, action);
      setData((d) => d && { requests: d.requests.map((x) => (x.request_id === r.request_id ? { ...x, status: status as CommissionRequest['status'] } : x)) });
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not update the request.');
    } finally {
      setBusy(null);
    }
  }

  if (!data) return error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />;
  const pending = data.requests.filter((r) => r.status === 'Pending');
  const rest = data.requests.filter((r) => r.status !== 'Pending').slice(0, 30);

  return (
    <Page refreshing={refreshing} onRefresh={refresh}>
      <SectionTitle>{`Pending (${pending.length})`}</SectionTitle>
      {pending.length === 0 ? (
        <Card style={{ padding: spacing.lg }}>
          <EmptyText>New requests become orders straight away, so they wait under Orders as “To confirm”. Their full details are listed here too.</EmptyText>
        </Card>
      ) : (
        pending.map((r) => <RequestCard key={r.request_id} r={r} busy={busy === r.request_id} onAct={act} />)
      )}
      {rest.length > 0 && (
        <>
          <SectionTitle>Earlier</SectionTitle>
          {rest.map((r) => (
            <RequestCard key={r.request_id} r={r} />
          ))}
        </>
      )}
    </Page>
  );
}

function RequestCard({ r, busy, onAct }: { r: CommissionRequest; busy?: boolean; onAct?: (r: CommissionRequest, a: 'accept' | 'decline') => void }) {
  const contact = [r.customer_discord && `Discord ${r.customer_discord}`, r.customer_instagram && `IG ${r.customer_instagram}`, r.customer_email]
    .filter(Boolean)
    .join(' · ');
  return (
    <Card style={{ padding: spacing.lg, marginBottom: spacing.md, gap: spacing.sm }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}>
        <Text style={[ui.strong, { flex: 1 }]}>{r.customer_name}</Text>
        <Pill label={r.status} color={r.status === 'Pending' ? colors.gold : r.status === 'Accepted' ? colors.success : colors.danger} />
      </View>
      <Text style={ui.meta}>
        {r.request_id} · {timeAgo(r.created_at)}
        {contact ? ` · ${contact}` : ''}
      </Text>
      <Text style={[ui.bodySmall, { color: colors.gold }]}>{r.commission_type}</Text>
      {r.description ? <Text style={ui.body}>{r.description}</Text> : null}
      {r.answers.map((a) => (
        <Text key={a.label} style={ui.bodySmall}>
          <Text style={{ color: colors.textMuted }}>{a.label}: </Text>
          {a.value === 'on' ? 'Yes' : a.value}
        </Text>
      ))}
      {r.ref_images.length > 0 && (
        <View style={styles.refs}>
          {r.ref_images.map((url) => (
            <Pressable key={url} onPress={() => WebBrowser.openBrowserAsync(url)} accessibilityLabel="Reference image">
              <Image source={url} style={styles.ref} contentFit="cover" />
            </Pressable>
          ))}
        </View>
      )}
      {onAct && (
        <View style={{ flexDirection: 'row', gap: spacing.sm, marginTop: spacing.sm }}>
          <Button title="Accept" onPress={() => onAct(r, 'accept')} loading={busy} style={{ flex: 1 }} />
          <Button title="Decline" variant="danger" onPress={() => onAct(r, 'decline')} disabled={busy} style={{ flex: 1 }} />
        </View>
      )}
    </Card>
  );
}

const styles = StyleSheet.create({
  refs: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  ref: { width: 72, height: 72, borderRadius: radius.sm, backgroundColor: colors.elevated },
});
