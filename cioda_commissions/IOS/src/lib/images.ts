import * as ImagePicker from 'expo-image-picker';
import { Platform } from 'react-native';

export type PickedImage = { uri: string; name: string; type: string };

/** Opens the photo library. Returns [] if cancelled. */
export async function pickImages(limit: number): Promise<PickedImage[]> {
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ['images'],
    allowsMultipleSelection: limit > 1,
    selectionLimit: limit,
    quality: 0.85,
  });
  if (result.canceled) return [];
  return result.assets.slice(0, limit).map((a, i) => {
    const type = a.mimeType ?? 'image/jpeg';
    const ext = type.split('/')[1]?.replace('jpeg', 'jpg') ?? 'jpg';
    return { uri: a.uri, type, name: a.fileName ?? `image-${Date.now()}-${i}.${ext}` };
  });
}

/**
 * Adds an image to a multipart form. React Native accepts {uri, name, type}
 * directly; in the browser preview the picked URI has to become a real Blob.
 */
export async function appendImage(form: FormData, field: string, image: PickedImage) {
  if (Platform.OS === 'web') {
    const blob = await (await fetch(image.uri)).blob();
    form.append(field, blob, image.name);
  } else {
    form.append(field, image as unknown as Blob);
  }
}
