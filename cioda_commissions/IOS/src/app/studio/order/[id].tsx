import * as Clipboard from 'expo-clipboard';
import { Image } from 'expo-image';
import { router, Stack, useLocalSearchParams } from 'expo-router';
import * as WebBrowser from 'expo-web-browser';
import { useState } from 'react';
import { Pressable, Share, StyleSheet, Text, View } from 'react-native';

import { Timeline } from '@/components/timeline';
import { Button, Card, Chips, EmptyText, Field, LoadingState, MessageState, Page, Pill, Row, SectionTitle, styles as ui } from '@/components/ui';
import type { AdminOrder } from '@/lib/api';
import { confirm, showError, showInfo } from '@/lib/confirm';
import { date, money, timeAgo } from '@/lib/format';
import { appendImage, pickImages } from '@/lib/images';
import { useAdmin } from '@/lib/session';
import { useApiData } from '@/lib/use-api-data';
import { colors, fonts, radius, spacing, statusColor } from '@/theme/theme';

export default function StudioOrder() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const admin = useAdmin();
  const { data, setData, error, refreshing, refresh, reload } = useApiData(() => admin.order(id));
  const [uploading, setUploading] = useState(false);

  const o = data?.order;
  if (!data || !o) return error ? <MessageState message={error} onRetry={reload} /> : <LoadingState />;

  const replaceOrder = (order: AdminOrder) => setData((d) => d && { ...d, order });

  async function setStatus(field: 'status' | 'payment_status', value: string) {
    if (value === o![field]) return;
    const label = field === 'status' ? 'status' : 'payment status';
    if (!(await confirm(`Set ${label} to ${value}?`, 'The customer is notified if they use the app.', 'Update', false))) return;
    try {
      replaceOrder((await admin.updateOrder(o!.order_id, { [field]: value })).order);
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not update.');
    }
  }

  async function uploadFinal() {
    const picked = await pickImages(10);
    if (!picked.length) return;
    setUploading(true);
    try {
      const form = new FormData();
      for (const img of picked) await appendImage(form, 'images', img);
      replaceOrder((await admin.uploadFinal(o!.order_id, form)).order);
      if (o!.status !== 'Done') showInfo('Uploaded', "Customers see finished art once the order is marked Done.");
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Upload failed.');
    } finally {
      setUploading(false);
    }
  }

  async function deleteFinal(imageId: number) {
    if (!(await confirm('Delete this image?', 'It will be removed from the order.', 'Delete'))) return;
    try {
      await admin.deleteFinal(o!.order_id, imageId);
      reload();
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not delete.');
    }
  }

  async function copy(value: string, what: string) {
    await Clipboard.setStringAsync(value);
    showInfo('Copied', `${what} copied to the clipboard.`);
  }

  const contacts = [
    { label: 'Discord', value: o.customer_discord },
    { label: 'Instagram', value: o.customer_instagram },
    { label: 'Email', value: o.customer_email },
    { label: o.payment_method ?? 'Payment', value: o.payment_username },
  ].filter((c) => c.value);

  return (
    <Page refreshing={refreshing} onRefresh={refresh}>
      <Stack.Screen options={{ title: o.order_id }} />
      <View style={styles.hero}>
        <Text style={styles.name}>{o.customer_name}</Text>
        <Text style={ui.bodySmall}>{o.commission_type || 'Commission'}</Text>
        <Text style={ui.meta}>
          Ordered {date(o.created_at)} · {o.pin_set ? 'Customer has set a PIN' : 'No PIN set yet'}
        </Text>
      </View>

      <SectionTitle>Status</SectionTitle>
      <View style={styles.pad}>
        <Chips options={data.statuses.map((s) => ({ value: s, label: s }))} selected={[o.status]} onToggle={(v) => setStatus('status', v)} colorFor={statusColor} />
      </View>
      <SectionTitle>Payment</SectionTitle>
      <View style={styles.pad}>
        <Chips
          options={data.payment_statuses.map((s) => ({ value: s, label: s }))}
          selected={[o.payment_status]}
          onToggle={(v) => setStatus('payment_status', v)}
          colorFor={(s) => (s === 'Pending' ? colors.gold : statusColor(s))}
        />
      </View>

      <SectionTitle>Details</SectionTitle>
      {/* Keyed on the saved values, so the form starts fresh whenever they change on the server. */}
      <DetailsForm key={`${o.order_id}|${o.eta}|${o.price}|${o.notes}`} order={o} onSaved={replaceOrder} />

      <SectionTitle>Customer</SectionTitle>
      <Card>
        {contacts.map((c) => (
          <Row key={c.label} onPress={() => copy(c.value!, c.label)}>
            <Text style={ui.label}>{c.label}</Text>
            <Text style={[ui.body, { marginTop: 2 }]} selectable>
              {c.value}
            </Text>
          </Row>
        ))}
        <Row last onPress={() => Share.share({ message: `Track your commission: ${o.tracking_url}`, url: o.tracking_url })}>
          <Text style={{ color: colors.accent, fontSize: 16 }}>Share tracking link</Text>
        </Row>
      </Card>

      <SectionTitle
        right={
          <Pressable onPress={() => router.push(`/studio/update/${o.order_id}`)} hitSlop={8} accessibilityRole="button">
            <Text style={styles.link}>Post update</Text>
          </Pressable>
        }
      >
        Progress
      </SectionTitle>
      {o.logs.length ? (
        <Timeline logs={o.logs} showVisibility />
      ) : (
        <Card style={{ padding: spacing.lg }}>
          <EmptyText>No updates yet.</EmptyText>
        </Card>
      )}

      <SectionTitle
        right={
          <Pressable onPress={uploadFinal} disabled={uploading} hitSlop={8} accessibilityRole="button">
            <Text style={styles.link}>{uploading ? 'Uploading…' : 'Upload'}</Text>
          </Pressable>
        }
      >
        Finished art
      </SectionTitle>
      {o.final_images.length ? (
        <View style={styles.finals}>
          {o.final_images.map((img) => (
            <Pressable key={img.id} onPress={() => WebBrowser.openBrowserAsync(img.url)} onLongPress={() => deleteFinal(img.id)} accessibilityHint="Long press to delete">
              <Image source={img.url} style={styles.final} contentFit="cover" />
            </Pressable>
          ))}
        </View>
      ) : (
        <Card style={{ padding: spacing.lg }}>
          <EmptyText>Upload the finished piece here. The customer sees it when the order is Done.</EmptyText>
        </Card>
      )}
      {o.final_images.length > 0 && <Text style={[ui.meta, styles.pad, { marginTop: 6 }]}>Long-press an image to delete it.</Text>}

      <SectionTitle>Request</SectionTitle>
      <Card style={{ padding: spacing.lg }}>
        {o.description ? <Text style={ui.body}>{o.description}</Text> : <EmptyText>No description.</EmptyText>}
        {o.answers.map((a) => (
          <View key={a.label} style={{ marginTop: spacing.md }}>
            <Text style={ui.label}>{a.label}</Text>
            <Text style={[ui.body, { marginTop: 2 }]}>{a.value === 'on' ? 'Yes' : a.value}</Text>
          </View>
        ))}
        {o.ref_images.length > 0 && (
          <View style={[styles.finals, { paddingHorizontal: 0, marginTop: spacing.md }]}>
            {o.ref_images.map((url) => (
              <Pressable key={url} onPress={() => WebBrowser.openBrowserAsync(url)} accessibilityLabel="Reference image">
                <Image source={url} style={styles.ref} contentFit="cover" />
              </Pressable>
            ))}
          </View>
        )}
      </Card>

      {(o.invoices.length > 0 || o.tickets.length > 0) && (
        <>
          <SectionTitle>Invoices & tickets</SectionTitle>
          <Card>
            {o.invoices.map((inv) => (
              <Row key={inv.invoice_id} onPress={inv.pdf_url ? () => WebBrowser.openBrowserAsync(inv.pdf_url!) : undefined} chevron={!!inv.pdf_url}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: spacing.sm }}>
                  <Text style={[ui.strong, { flex: 1 }]}>
                    {inv.invoice_id} · {money(inv.amount)}
                  </Text>
                  <Pill label={inv.paid ? 'Paid' : 'Unpaid'} />
                </View>
              </Row>
            ))}
            {o.tickets.map((t, i) => (
              <Row key={t.ticket_id} last={i === o.tickets.length - 1} chevron onPress={() => router.push(`/studio/ticket/${t.ticket_id}`)}>
                <Text style={ui.strong} numberOfLines={1}>
                  🎫 {t.subject || 'Support ticket'}
                </Text>
                <Text style={ui.meta}>
                  {t.status} · {timeAgo(t.created_at)}
                </Text>
              </Row>
            ))}
          </Card>
        </>
      )}
    </Page>
  );
}

function DetailsForm({ order, onSaved }: { order: AdminOrder; onSaved: (o: AdminOrder) => void }) {
  const admin = useAdmin();
  const [eta, setEta] = useState(order.eta ?? '');
  const [price, setPrice] = useState(order.price ? String(order.price) : '');
  const [notes, setNotes] = useState(order.notes ?? '');
  const [saving, setSaving] = useState(false);
  const dirty = eta !== (order.eta ?? '') || price !== (order.price ? String(order.price) : '') || notes !== (order.notes ?? '');

  async function save() {
    const priceNum = price.trim() === '' ? 0 : Number(price);
    if (Number.isNaN(priceNum)) return showError('Price must be a number, like 25 or 25.50.');
    setSaving(true);
    try {
      onSaved((await admin.updateOrder(order.order_id, { eta, notes, price: priceNum })).order);
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not save.');
      setSaving(false);
    }
  }

  return (
    <View style={[styles.pad, { gap: spacing.md }]}>
      <View style={{ flexDirection: 'row', gap: spacing.md }}>
        <View style={{ flex: 1 }}>
          <Field label="Price ($)" value={price} onChangeText={setPrice} keyboardType="decimal-pad" placeholder="0" />
        </View>
        <View style={{ flex: 1.4 }}>
          <Field label="ETA" value={eta} onChangeText={setEta} placeholder="e.g. 2 weeks" />
        </View>
      </View>
      <Field label="Private notes" value={notes} onChangeText={setNotes} multiline placeholder="Only you see these" />
      {order.discount ? <Text style={[ui.meta, { color: colors.success }]}>Customer used: {order.discount}</Text> : null}
      {dirty && <Button title="Save Details" onPress={save} loading={saving} />}
    </View>
  );
}

const styles = StyleSheet.create({
  hero: { padding: spacing.lg, gap: 4 },
  name: { fontFamily: fonts.display, fontSize: 24, color: colors.text },
  pad: { paddingHorizontal: spacing.lg },
  link: { color: colors.accent, fontWeight: '600', fontSize: 15 },
  finals: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, paddingHorizontal: spacing.lg },
  final: { width: 104, height: 104, borderRadius: radius.md, backgroundColor: colors.elevated },
  ref: { width: 72, height: 72, borderRadius: radius.sm, backgroundColor: colors.elevated },
});
