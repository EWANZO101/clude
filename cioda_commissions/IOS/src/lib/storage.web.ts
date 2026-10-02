// expo-secure-store has no web version; the browser preview uses localStorage.
export const storage = {
  get: async (key: string) => {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set: async (key: string, value: string) => {
    try {
      localStorage.setItem(key, value);
    } catch {}
  },
  remove: async (key: string) => {
    try {
      localStorage.removeItem(key);
    } catch {}
  },
};
