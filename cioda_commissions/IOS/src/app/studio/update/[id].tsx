import { Image } from 'expo-image';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { Pressable, StyleSheet, Switch, Text, View } from 'react-native';

import { Button, Chips, Field, Page, styles as ui } from '@/components/ui';
import { showError } from '@/lib/confirm';
import { appendImage, pickImages, type PickedImage } from '@/lib/images';
import { useAdmin } from '@/lib/session';
import { colors, radius, spacing } from '@/theme/theme';

const QUICK = ['Sketch done', 'Line art done', 'Colouring', 'Final touches', 'Delivered'];

/** A progress update on the order timeline, optionally with a WIP image. */
export default function PostUpdate() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const admin = useAdmin();
  const [event, setEvent] = useState('');
  const [details, setDetails] = useState('');
  const [visible, setVisible] = useState(true);
  const [image, setImage] = useState<PickedImage | null>(null);
  const [busy, setBusy] = useState(false);

  async function post() {
    setBusy(true);
    try {
      const form = new FormData();
      form.append('event', event);
      form.append('details', details);
      form.append('customer_visible', visible ? 'true' : 'false');
      if (image) await appendImage(form, 'image', image);
      await admin.addUpdate(id, form);
      router.back();
    } catch (e) {
      showError(e instanceof Error ? e.message : 'Could not post the update.');
      setBusy(false);
    }
  }

  return (
    <Page>
      <View style={{ padding: spacing.lg, gap: spacing.lg }}>
        <Chips options={QUICK.map((q) => ({ value: q, label: q }))} selected={[event]} onToggle={setEvent} />
        <Field label="Title" required value={event} onChangeText={setEvent} placeholder="e.g. Sketch done" />
        <Field label="Details" value={details} onChangeText={setDetails} multiline placeholder="Anything the customer should know" />
        <View style={{ gap: spacing.sm }}>
          <Text style={ui.label}>Work-in-progress image</Text>
          {image ? (
            <Pressable onPress={() => setImage(null)} accessibilityLabel="Remove image">
              <Image source={image.uri} style={styles.preview} contentFit="cover" />
              <Text style={ui.meta}>Tap the image to remove it.</Text>
            </Pressable>
          ) : (
            <Button title="Choose Image" variant="secondary" onPress={async () => setImage((await pickImages(1))[0] ?? null)} />
          )}
        </View>
        <View style={styles.switchRow}>
          <View style={{ flex: 1 }}>
            <Text style={ui.strong}>Show to customer</Text>
            <Text style={ui.meta}>{visible ? 'Appears on their order page.' : 'Private note, only you see it.'}</Text>
          </View>
          <Switch value={visible} onValueChange={setVisible} trackColor={{ true: colors.accent, false: colors.border }} accessibilityLabel="Show to customer" />
        </View>
        <Button title="Post Update" onPress={post} loading={busy} disabled={!event.trim()} />
      </View>
    </Page>
  );
}

const styles = StyleSheet.create({
  preview: { width: '100%', aspectRatio: 4 / 3, borderRadius: radius.md, backgroundColor: colors.elevated },
  switchRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
});
