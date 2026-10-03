import { useState } from 'react';
import { KeyboardAvoidingView, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import type { TicketMessage } from '@/lib/api';
import { dateTime } from '@/lib/format';
import { colors, fonts, radius, spacing } from '@/theme/theme';

/**
 * A ticket conversation. `me` is which side this phone is on, so its own
 * messages sit on the right like any messaging app.
 */
export function Chat({
  messages,
  me,
  canReply,
  closedText,
  onSend,
  header,
}: {
  messages: TicketMessage[];
  me: 'customer' | 'admin';
  canReply: boolean;
  closedText: string;
  onSend: (text: string) => Promise<void>;
  header?: React.ReactNode;
}) {
  const insets = useSafeAreaInsets();
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);

  async function send() {
    const body = text.trim();
    if (!body) return;
    setSending(true);
    try {
      await onSend(body);
      setText('');
    } finally {
      setSending(false);
    }
  }

  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: colors.background }} behavior={Platform.OS === 'ios' ? 'padding' : undefined} keyboardVerticalOffset={90}>
      <ScrollView contentContainerStyle={{ padding: spacing.lg, gap: spacing.md }} contentInsetAdjustmentBehavior="automatic">
        {header}
        {messages.map((m, i) => {
          const mine = m.sender === me;
          return (
            <View key={i} style={[styles.bubbleWrap, mine ? { alignItems: 'flex-end' } : { alignItems: 'flex-start' }]}>
              <View style={[styles.bubble, mine ? styles.mine : styles.theirs]}>
                <Text style={[styles.text, mine && { color: colors.onAccent }]} selectable>
                  {m.message}
                </Text>
              </View>
              <Text style={styles.meta}>
                {m.sender === 'admin' ? 'Cioda' : 'Customer'} · {dateTime(m.created_at)}
              </Text>
            </View>
          );
        })}
      </ScrollView>
      {canReply ? (
        <View style={[styles.composer, { paddingBottom: insets.bottom + spacing.sm }]}>
          <TextInput
            style={styles.input}
            value={text}
            onChangeText={setText}
            placeholder="Write a message…"
            placeholderTextColor={colors.textMuted}
            keyboardAppearance="dark"
            selectionColor={colors.accent}
            multiline
            accessibilityLabel="Message"
          />
          <Pressable
            onPress={send}
            disabled={sending || !text.trim()}
            accessibilityRole="button"
            accessibilityLabel="Send"
            style={({ pressed }) => [styles.send, (pressed || sending || !text.trim()) && { opacity: 0.5 }]}
          >
            <Text style={{ color: colors.onAccent, fontWeight: '700' }}>{sending ? '…' : 'Send'}</Text>
          </Pressable>
        </View>
      ) : (
        <Text style={[styles.closed, { paddingBottom: insets.bottom + spacing.md }]}>{closedText}</Text>
      )}
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  bubbleWrap: { gap: 4 },
  bubble: { maxWidth: '85%', borderRadius: radius.lg, paddingHorizontal: 14, paddingVertical: 10 },
  mine: { backgroundColor: colors.accent, borderBottomRightRadius: 4 },
  theirs: { backgroundColor: colors.card, borderWidth: 1, borderColor: colors.border, borderBottomLeftRadius: 4 },
  text: { fontFamily: fonts.body, fontSize: 17, color: colors.text, lineHeight: 22 },
  meta: { fontSize: 11, color: colors.textMuted, marginHorizontal: 4 },
  composer: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: spacing.sm,
    paddingHorizontal: spacing.md,
    paddingTop: spacing.sm,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.border,
    backgroundColor: colors.surface,
  },
  input: {
    flex: 1,
    maxHeight: 120,
    backgroundColor: colors.elevated,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    paddingHorizontal: 14,
    paddingVertical: 10,
    fontSize: 16,
    color: colors.text,
  },
  send: { backgroundColor: colors.accent, borderRadius: radius.lg, paddingHorizontal: 16, paddingVertical: 11 },
  closed: { textAlign: 'center', color: colors.textSecondary, fontSize: 14, paddingTop: spacing.md, backgroundColor: colors.surface },
});
