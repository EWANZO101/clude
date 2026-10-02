import { Alert } from 'react-native';

export function confirm(title: string, message: string, confirmLabel: string, destructive = true): Promise<boolean> {
  return new Promise((resolve) =>
    Alert.alert(title, message, [
      { text: 'Cancel', style: 'cancel', onPress: () => resolve(false) },
      { text: confirmLabel, style: destructive ? 'destructive' : 'default', onPress: () => resolve(true) },
    ]),
  );
}

export function showError(message: string) {
  Alert.alert('Something went wrong', message);
}

export function showInfo(title: string, message: string) {
  Alert.alert(title, message);
}
