import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';

import { Button, Field, LoadingState, Page, styles as ui } from '@/components/ui';
import { enterPin, lookupOrder } from '@/lib/api';
import { useSession } from '@/lib/session';
import { colors, fonts, spacing } from '@/theme/theme';

/**
 * Unlocks an order on this phone. A brand-new order (or one whose PIN Cioda reset)
 * has no PIN yet, so the customer chooses one; otherwise they enter it.
 */
export default function OrderPin() {
  const { link, orderId: orderIdParam, fresh } = useLocalSearchParams<{ link: string; orderId?: string; fresh?: string }>();
  const { saveOrder } = useSession();
  const [pinSet, setPinSet] = useState<boolean | null>(fresh ? false : null);
  const [orderId, setOrderId] = useState(orderIdParam ?? '');
  const [pin, setPin] = useState('');
  const [confirmPin, setConfirmPin] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (pinSet !== null) return;
    // Find out whether this order already has a PIN: choose one, or enter it.
    lookupOrder({ link })
      .then((r) => {
        setPinSet(r.pin_set);
        setOrderId(r.order_id);
      })
      .catch(() => setPinSet(true));
  }, [link, pinSet]);

  async function submit() {
    setError(null);
    if (!pinSet) {
      if (!/^\d{4,8}$/.test(pin)) return setError('Choose a PIN of 4 to 8 digits.');
      if (pin !== confirmPin) return setError("Those PINs don’t match.");
    }
    setBusy(true);
    try {
      const res = await enterPin(link, pin);
      await saveOrder({ link, orderId: res.order_id, token: res.token });
      router.replace(`/order/${link}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not unlock this order.');
      setBusy(false);
    }
  }

  if (pinSet === null) return <LoadingState />;

  return (
    <Page>
      <View style={{ padding: spacing.lg, gap: spacing.lg }}>
        {fresh ? (
          <View style={{ gap: spacing.sm }}>
            <Text style={{ fontFamily: fonts.display, fontSize: 22, color: colors.text }}>Request sent! 🎨</Text>
            <Text style={ui.body}>
              Your order is <Text style={{ color: colors.accent, fontWeight: '700' }}>{orderId}</Text>. Cioda will take a look and confirm it soon.
            </Text>
          </View>
        ) : orderId ? (
          <Text style={ui.strong}>{orderId}</Text>
        ) : null}
        <Text style={ui.bodySmall}>
          {pinSet
            ? 'Enter the PIN you chose for this order.'
            : 'Choose a PIN to protect your order. You’ll need it to open this order on another phone or on the website.'}
        </Text>
        <Field
          label={pinSet ? 'PIN' : 'Choose a PIN (4–8 digits)'}
          value={pin}
          onChangeText={(v) => setPin(v.replace(/\D/g, ''))}
          keyboardType="number-pad"
          secureTextEntry
          maxLength={8}
          autoFocus
          textContentType={pinSet ? 'password' : 'newPassword'}
        />
        {!pinSet && (
          <Field
            label="Type it again"
            value={confirmPin}
            onChangeText={(v) => setConfirmPin(v.replace(/\D/g, ''))}
            keyboardType="number-pad"
            secureTextEntry
            maxLength={8}
          />
        )}
        {error && <Text style={{ color: colors.danger, fontSize: 15 }}>{error}</Text>}
        <Button title={pinSet ? 'Open Order' : 'Save PIN & Open Order'} onPress={submit} loading={busy} disabled={pin.length < 4} />
      </View>
    </Page>
  );
}
