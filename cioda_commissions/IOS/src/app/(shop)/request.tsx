import * as Crypto from 'expo-crypto';
import { Image } from 'expo-image';
import { router, useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Switch, Text, View } from 'react-native';

import { Button, Card, Chips, Field, LoadingState, MessageState, Screen, SectionTitle, styles as ui } from '@/components/ui';
import { ApiError, checkDiscount, getHome, queueHeartbeat, submitRequest, type Home, type QueueState } from '@/lib/api';
import { showError } from '@/lib/confirm';
import { money } from '@/lib/format';
import { appendImage, pickImages, type PickedImage } from '@/lib/images';
import { colors, fonts, radius, spacing } from '@/theme/theme';

type Phase = 'intro' | 'queue' | 'form';
type Discount = { code: string; label: string; type: 'percent' | 'fixed'; value: number };

const CUSTOM = 'Custom / Other';
const POLL_MS = 5000;

export default function RequestScreen() {
  const [home, setHome] = useState<Home | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [phase, setPhase] = useState<Phase>('intro');
  const [queue, setQueue] = useState<QueueState | null>(null);
  const [queueToken, setQueueToken] = useState(() => Crypto.randomUUID());

  const loadHome = useCallback(async () => {
    try {
      setHome(await getHome());
      setLoadError(null);
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : 'Could not load.');
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      loadHome();
    }, [loadHome]),
  );

  // The waiting room: heartbeat until admitted, exactly like the website's queue page.
  useEffect(() => {
    if (phase !== 'queue') return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    const beat = async () => {
      try {
        const state = await queueHeartbeat(queueToken);
        if (stopped) return;
        setQueue(state);
        if (!state.commissions_open) {
          setPhase('intro');
          loadHome();
          return;
        }
        if (!state.busy && state.admitted) {
          setPhase('form');
          return;
        }
      } catch {
        // Network blip: keep trying.
      }
      if (!stopped) timer = setTimeout(beat, POLL_MS);
    };
    beat();
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  }, [phase, loadHome, queueToken]);

  const rejoin = useCallback(() => {
    setQueueToken(Crypto.randomUUID());
    setQueue(null);
    setPhase('queue');
  }, []);

  if (!home) {
    return (
      <Screen title="Request">
        {loadError ? <MessageState message={loadError} onRetry={loadHome} /> : <LoadingState />}
      </Screen>
    );
  }

  if (!home.commissions_open) {
    return (
      <Screen title="Request" refreshing={false} onRefresh={loadHome}>
        <Card style={{ padding: spacing.lg }}>
          <Text style={styles.heading}>Commissions are closed</Text>
          <Text style={[ui.body, { marginTop: spacing.sm, color: colors.textSecondary }]}>{home.closed_message}</Text>
          {home.reopen_date ? <Text style={[ui.meta, { marginTop: spacing.sm }]}>Reopening {home.reopen_date}</Text> : null}
        </Card>
      </Screen>
    );
  }

  if (phase === 'form') {
    return <RequestForm home={home} queueToken={queueToken} onQueueExpired={rejoin} />;
  }

  return (
    <Screen title="Request" subtitle="Let’s make something lovely.">
      {phase === 'intro' ? (
        <Card style={{ padding: spacing.lg, gap: spacing.md }}>
          <Text style={styles.heading}>How it works</Text>
          <Text style={[ui.body, { color: colors.textSecondary }]}>
            To keep things fair, a few people fill in the form at a time. Tap below to join the queue. Most of the time you’ll be straight through.
          </Text>
          <Text style={[ui.body, { color: colors.textSecondary }]}>
            Once you’re in, you have about 5 minutes to send your request. You’ll get an order you can track right here in the app.
          </Text>
          <Button title="Start My Request" onPress={() => setPhase('queue')} />
        </Card>
      ) : (
        <QueueCard state={queue} onCancel={() => setPhase('intro')} onRetry={rejoin} />
      )}
    </Screen>
  );
}

function QueueCard({ state, onCancel, onRetry }: { state: QueueState | null; onCancel: () => void; onRetry: () => void }) {
  if (state && state.commissions_open && state.busy) {
    return (
      <Card style={{ padding: spacing.lg, gap: spacing.md }}>
        <Text style={styles.heading}>It’s really busy right now</Text>
        <Text style={[ui.body, { color: colors.textSecondary }]}>
          Lots of people are requesting at once. Please try again in about {Math.ceil(state.retry_after / 60)} minute
          {Math.ceil(state.retry_after / 60) === 1 ? '' : 's'}.
        </Text>
        <Button title="Try Again" variant="secondary" onPress={onRetry} />
      </Card>
    );
  }
  const waiting = state && state.commissions_open && !state.busy ? state : null;
  return (
    <Card style={{ padding: spacing.lg, gap: spacing.md, alignItems: 'center' }}>
      <ActivityIndicator color={colors.accent} size="large" />
      <Text style={styles.heading}>{waiting && waiting.position > 1 ? `You’re number ${waiting.position} in line` : 'Getting you in…'}</Text>
      <Text style={[ui.bodySmall, { textAlign: 'center' }]}>
        {waiting ? `${waiting.on_form} of ${waiting.on_form + waiting.free_slots} spots on the form are taken.` : 'Joining the queue.'} Keep the app
        open, this page updates by itself.
      </Text>
      <Button title="Leave the Queue" variant="ghost" onPress={onCancel} />
    </Card>
  );
}

function RequestForm({ home, queueToken, onQueueExpired }: { home: Home; queueToken: string; onQueueExpired: () => void }) {
  const allTypes = useMemo(() => home.price_list.flatMap((g) => g.types), [home]);
  const [types, setTypes] = useState<string[]>([]);
  const [name, setName] = useState('');
  const [discord, setDiscord] = useState('');
  const [instagram, setInstagram] = useState('');
  const [email, setEmail] = useState('');
  const [payment, setPayment] = useState<'CashApp' | 'PayPal' | ''>('');
  const [paymentUser, setPaymentUser] = useState('');
  const [description, setDescription] = useState('');
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [images, setImages] = useState<PickedImage[]>([]);
  const [codeInput, setCodeInput] = useState('');
  const [discount, setDiscount] = useState<Discount | null>(null);
  const [codeError, setCodeError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selectedTypes = allTypes.filter((t) => types.includes(t.name));
  const refTypes = selectedTypes.filter((t) => t.allow_ref_images);
  const maxImages = refTypes.length ? Math.max(...refTypes.map((t) => t.max_ref_images)) : 0;
  const subtotal = selectedTypes.reduce((sum, t) => sum + t.price, 0);
  const off = discount ? (discount.type === 'percent' ? (subtotal * discount.value) / 100 : discount.value) : 0;
  const estimate = Math.max(0, subtotal - off);

  // Unticking a type that allowed images can lower the limit; extra picks are simply dropped.
  const shownImages = images.slice(0, maxImages);

  function toggleType(t: string) {
    setTypes((cur) => (cur.includes(t) ? cur.filter((x) => x !== t) : [...cur, t]));
  }

  async function applyCode() {
    setCodeError(null);
    try {
      const res = await checkDiscount(codeInput);
      if (res.valid) setDiscount({ code: codeInput.trim().toUpperCase(), label: res.label, type: res.type, value: res.value });
      else {
        setDiscount(null);
        setCodeError(res.error);
      }
    } catch (e) {
      setCodeError(e instanceof Error ? e.message : 'Could not check that code.');
    }
  }

  async function addImages() {
    const picked = await pickImages(maxImages - shownImages.length);
    setImages((imgs) => [...imgs, ...picked].slice(0, maxImages));
  }

  async function submit() {
    setError(null);
    setSubmitting(true);
    try {
      const form = new FormData();
      form.append('queue_token', queueToken);
      form.append('customer_name', name);
      form.append('customer_discord', discord);
      form.append('customer_instagram', instagram);
      form.append('customer_email', email);
      form.append('payment_method', payment);
      form.append('payment_username', paymentUser);
      form.append('description', description);
      types.forEach((t) => form.append('commission_type', t));
      if (discount) form.append('discount_code', discount.code);
      for (const field of home.form_fields) form.append(field.key, answers[field.key] ?? '');
      for (const img of shownImages) await appendImage(form, 'ref_images', img);
      const res = await submitRequest(form);
      router.replace({ pathname: '/order/[link]/pin', params: { link: res.link, orderId: res.order_id, fresh: '1' } });
    } catch (e) {
      if (e instanceof ApiError && e.data.queue) {
        showError('Your spot in the queue ran out. We\'ll put you back in line. Your answers are kept.');
        onQueueExpired();
      } else setError(e instanceof Error ? e.message : 'Could not send your request.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Screen title="Request" subtitle="You’re in! Your spot is held for 5 minutes.">
      <SectionTitle>What would you like?</SectionTitle>
      <View style={{ paddingHorizontal: spacing.lg, gap: spacing.md }}>
        {home.price_list.map((group) => (
          <View key={group.category} style={{ gap: spacing.sm }}>
            <Text style={styles.category}>{group.category}</Text>
            <Chips options={group.types.map((t) => ({ value: t.name, label: `${t.name}  ${money(t.price)}` }))} selected={types} onToggle={toggleType} />
          </View>
        ))}
        <Chips options={[{ value: CUSTOM, label: `${CUSTOM} (quoted)` }]} selected={types} onToggle={toggleType} />
      </View>

      <SectionTitle>About you</SectionTitle>
      <View style={styles.fields}>
        <Field label="Your name" required value={name} onChangeText={setName} placeholder="What should Cioda call you?" autoComplete="name" />
        <Text style={ui.meta}>Give at least one way to reach you. Discord gets the fastest replies.</Text>
        <Field label="Discord" value={discord} onChangeText={setDiscord} placeholder="@username" autoCapitalize="none" autoCorrect={false} />
        <Field label="Instagram" value={instagram} onChangeText={setInstagram} placeholder="@handle" autoCapitalize="none" autoCorrect={false} />
        <Field
          label="Email"
          value={email}
          onChangeText={setEmail}
          placeholder="your@email.com"
          keyboardType="email-address"
          autoCapitalize="none"
          autoComplete="email"
          hint="For receipts and updates."
        />
      </View>

      <SectionTitle>Your commission</SectionTitle>
      <View style={styles.fields}>
        <Field label="Describe what you’d like" required value={description} onChangeText={setDescription} multiline placeholder="Characters, pose, mood, colours…" />
        {home.form_fields.map((f) => (
          <DynamicField key={f.key} field={f} value={answers[f.key] ?? ''} onChange={(v) => setAnswers((a) => ({ ...a, [f.key]: v }))} />
        ))}
        {maxImages > 0 && (
          <View style={{ gap: spacing.sm }}>
            <Text style={ui.label}>Reference images (up to {maxImages})</Text>
            <View style={styles.thumbs}>
              {shownImages.map((img, i) => (
                <Pressable key={img.uri} onPress={() => setImages((imgs) => imgs.filter((_, j) => j !== i))} accessibilityLabel={`Remove image ${i + 1}`}>
                  <Image source={img.uri} style={styles.thumb} contentFit="cover" />
                  <Text style={styles.remove}>✕</Text>
                </Pressable>
              ))}
              {shownImages.length < maxImages && (
                <Pressable onPress={addImages} style={[styles.thumb, styles.addThumb]} accessibilityRole="button" accessibilityLabel="Add reference images">
                  <Text style={{ color: colors.accent, fontSize: 28 }}>+</Text>
                </Pressable>
              )}
            </View>
          </View>
        )}
      </View>

      <SectionTitle>Payment</SectionTitle>
      <View style={styles.fields}>
        <Chips
          options={[
            { value: 'CashApp', label: '💵 Cash App' },
            { value: 'PayPal', label: '🅿️ PayPal' },
          ]}
          selected={payment ? [payment] : []}
          onToggle={(v) => setPayment(v as 'CashApp' | 'PayPal')}
        />
        {payment ? (
          <Field
            label={payment === 'CashApp' ? 'Your $Cashtag' : 'Your PayPal email'}
            required
            value={paymentUser}
            onChangeText={setPaymentUser}
            autoCapitalize="none"
            keyboardType={payment === 'PayPal' ? 'email-address' : 'default'}
            placeholder={payment === 'CashApp' ? '$yourname' : 'you@email.com'}
          />
        ) : null}
        <Text style={ui.meta}>You won’t pay now. Cioda confirms your request and sends an invoice first.</Text>
      </View>

      <SectionTitle>Discount code</SectionTitle>
      <View style={[styles.fields, { flexDirection: 'row', alignItems: 'flex-end' }]}>
        <View style={{ flex: 1 }}>
          <Field label="Code (optional)" value={codeInput} onChangeText={setCodeInput} autoCapitalize="characters" autoCorrect={false} />
        </View>
        <Button title="Apply" variant="secondary" onPress={applyCode} disabled={!codeInput.trim()} />
      </View>
      {discount && <Text style={[styles.note, { color: colors.success }]}>✓ {discount.label}</Text>}
      {codeError && <Text style={[styles.note, { color: colors.danger }]}>{codeError}</Text>}

      <Card style={{ padding: spacing.lg, marginTop: spacing.xl, gap: spacing.sm }}>
        <View style={styles.totalRow}>
          <Text style={ui.body}>Estimated total</Text>
          <Text style={styles.total}>{money(estimate)}</Text>
        </View>
        {types.includes(CUSTOM) && <Text style={ui.meta}>Plus a quote for your custom piece.</Text>}
        {error && <Text style={{ color: colors.danger, fontSize: 15 }}>{error}</Text>}
        <Button title="Send My Request" onPress={submit} loading={submitting} disabled={!types.length || !name.trim()} />
      </Card>
    </Screen>
  );
}

function DynamicField({ field, value, onChange }: { field: Home['form_fields'][number]; value: string; onChange: (v: string) => void }) {
  if (field.type === 'select') {
    return (
      <View style={{ gap: spacing.sm }}>
        <Text style={ui.label}>
          {field.label}
          {field.required ? <Text style={{ color: colors.accent }}> *</Text> : null}
        </Text>
        <Chips options={field.options.map((o) => ({ value: o, label: o }))} selected={value ? [value] : []} onToggle={onChange} />
      </View>
    );
  }
  if (field.type === 'checkbox') {
    return (
      <View style={styles.switchRow}>
        <Text style={[ui.body, { flex: 1 }]}>{field.label}</Text>
        <Switch
          value={value === 'on'}
          onValueChange={(on) => onChange(on ? 'on' : '')}
          trackColor={{ true: colors.accent, false: colors.border }}
          accessibilityLabel={field.label}
        />
      </View>
    );
  }
  return <Field label={field.label} required={field.required} value={value} onChangeText={onChange} multiline={field.type === 'textarea'} />;
}

const styles = StyleSheet.create({
  heading: { fontFamily: fonts.displaySemi, fontSize: 19, color: colors.text, textAlign: 'center' },
  category: { fontFamily: fonts.bodySemi, fontSize: 17, color: colors.gold },
  fields: { paddingHorizontal: spacing.lg, gap: spacing.md },
  thumbs: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  thumb: { width: 84, height: 84, borderRadius: radius.md, backgroundColor: colors.elevated },
  addThumb: { alignItems: 'center', justifyContent: 'center', borderWidth: 1.5, borderStyle: 'dashed', borderColor: colors.borderAccent },
  remove: {
    position: 'absolute',
    top: 4,
    right: 4,
    color: '#fff',
    backgroundColor: '#000a',
    borderRadius: 10,
    width: 20,
    height: 20,
    textAlign: 'center',
    lineHeight: 20,
    fontSize: 11,
    overflow: 'hidden',
  },
  note: { marginHorizontal: spacing.lg, marginTop: 6, fontSize: 14 },
  totalRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
  total: { fontFamily: fonts.display, fontSize: 24, color: colors.accent },
  switchRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
});
