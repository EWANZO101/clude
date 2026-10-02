import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';

import { Button, Field, Page, styles as ui } from '@/components/ui';
import { openTicket } from '@/lib/api';
import { useSession } from '@/lib/session';
import { colors, spacing } from '@/theme/theme';

export default function NewTicket() {
  const { link } = useLocalSearchParams<{ link: string }>();
  const { tokenFor } = useSession();
  const [subject, setSubject] = useState('');
  const [message, setMessage] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function send() {
    const token = tokenFor(link);
    if (!token) return setError('Open your order first.');
    setBusy(true);
    setError(null);
    try {
      const { ticket } = await openTicket(link, token, subject, message);
      router.replace(`/order/${link}/ticket/${ticket.ticket_id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not open a ticket.');
      setBusy(false);
    }
  }

  return (
    <Page>
      <View style={{ padding: spacing.lg, gap: spacing.lg }}>
        <Text style={ui.bodySmall}>Cioda gets your message straight away and replies here. Tickets stay open for 24 hours.</Text>
        <Field label="Subject" value={subject} onChangeText={setSubject} placeholder="e.g. Changing the colours" maxLength={300} />
        <Field label="Message" required value={message} onChangeText={setMessage} multiline placeholder="How can Cioda help?" autoFocus />
        {error && <Text style={{ color: colors.danger, fontSize: 15 }}>{error}</Text>}
        <Button title="Send" onPress={send} loading={busy} disabled={!message.trim()} />
      </View>
    </Page>
  );
}
