// react-native-web's Alert.alert does nothing, so the browser preview uses the browser's dialogs.
export async function confirm(title: string, message: string, _confirmLabel: string, _destructive = true): Promise<boolean> {
  return window.confirm(`${title}\n\n${message}`);
}

export function showError(message: string) {
  window.alert(message);
}

export function showInfo(title: string, message: string) {
  window.alert(`${title}\n\n${message}`);
}
