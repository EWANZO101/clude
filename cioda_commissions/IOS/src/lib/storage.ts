import * as SecureStore from 'expo-secure-store';

// Small key-value store in the iPhone keychain (tokens, the saved-orders list).
export const storage = {
  get: (key: string) => SecureStore.getItemAsync(key),
  set: (key: string, value: string) => SecureStore.setItemAsync(key, value),
  remove: (key: string) => SecureStore.deleteItemAsync(key),
};
