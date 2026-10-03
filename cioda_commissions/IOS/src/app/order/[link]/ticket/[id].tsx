import { Stack, useLocalSearchParams } from 'expo-router';

import { Chat } from '@/components/chat';
import { LoadingState, MessageState } from '@/components/ui';
import { getTicket, replyTicket } from '@/lib/api';
import { showError } from '@/lib/confirm';
import { useSession } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';

export default function CustomerTicket() {
  const { link, id } = useLocalSearchParams<{ link: string; id: string }>();
  const { tokenFor } = useSession();
  const token = tokenFor(link) ?? '';
  const { data, setData, error, reload } = useApiData(() => getTicket(link, token, id));

  if (!data) return error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />;
  const t = data.ticket;
  const canReply = t.status === 'Open' && !t.expired;

  return (
    <>
      <Stack.Screen options={{ title: t.subject || 'Support' }} />
      <Chat
        messages={t.messages ?? []}
        me="customer"
        canReply={canReply}
        closedText={t.expired ? 'This ticket has expired. Open a new one from your order if you still need help.' : 'This ticket is closed.'}
        onSend={async (text) => {
          try {
            setData(await replyTicket(link, token, id, text));
          } catch (e) {
            showError(e instanceof Error ? e.message : 'Could not send.');
            throw e;
          }
        }}
      />
    </>
  );
}
