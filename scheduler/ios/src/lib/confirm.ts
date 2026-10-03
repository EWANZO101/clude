import { Alert } from 'react-native';

/** Asks before a destructive action; resolves true if confirmed. */
export function confirm(title: string, message: string, confirmLabel: string): Promise<boolean> {
  return new Promise((resolve) =>
    Alert.alert(title, message, [
      { text: 'Keep', style: 'cancel', onPress: () => resolve(false) },
      { text: confirmLabel, style: 'destructive', onPress: () => resolve(true) },
    ]),
  );
}

export function showError(message: string) {
  Alert.alert('Something went wrong', message);
}
