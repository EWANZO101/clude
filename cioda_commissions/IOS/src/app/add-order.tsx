import { router } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';

import { Button, Field, Page, styles as ui } from '@/components/ui';
import { lookupOrder } from '@/lib/api';
import { parseOrderInput } from '@/lib/format';
import { spacing } from '@/theme/theme';

export default function AddOrder() {
  const [input, setInput] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function next() {
    setError(null);
    const parsed = parseOrderInput(input);
    if (parsed.link) {
      router.replace({ pathname: '/order/[link]/pin', params: { link: parsed.link } });
      return;
    }
    setBusy(true);
    try {
      const res = await lookupOrder({ orderId: parsed.orderId });
      router.replace({ pathname: '/order/[link]/pin', params: { link: res.link, orderId: res.order_id } });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not find that order.');
      setBusy(false);
    }
  }

  return (
    <Page>
      <View style={{ padding: spacing.lg, gap: spacing.lg }}>
        <Text style={ui.body}>Enter your order ID (like ORD-1A2B3C), or paste the order link Cioda sent you.</Text>
        <Field
          label="Order ID or link"
          value={input}
          onChangeText={setInput}
          autoCapitalize="characters"
          autoCorrect={false}
          placeholder="ORD-1A2B3C"
          returnKeyType="next"
          onSubmitEditing={next}
          autoFocus
        />
        {error && <Text style={{ color: '#EF4444', fontSize: 15 }}>{error}</Text>}
        <Button title="Continue" onPress={next} loading={busy} disabled={!input.trim()} />
        <Text style={ui.meta}>Next you’ll enter your order’s PIN, or choose one if you haven’t set it yet.</Text>
      </View>
    </Page>
  );
}
