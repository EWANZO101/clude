// react-native-web's Alert.alert is a no-op, so the web preview uses the browser dialogs.
export async function confirm(title: string, message: string, _confirmLabel: string): Promise<boolean> {
  return window.confirm(`${title}\n\n${message}`);
}

export function showError(message: string) {
  window.alert(message);
}
