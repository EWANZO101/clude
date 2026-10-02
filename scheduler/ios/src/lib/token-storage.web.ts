// expo-secure-store has no web implementation, so the web preview keeps the
// token in localStorage. Wrapped in try/catch because storage can be blocked.
const KEY = 'scheduler.api-token';

export const tokenStorage = {
  get: async () => {
    try {
      return localStorage.getItem(KEY);
    } catch {
      return null;
    }
  },
  set: async (token: string) => {
    try {
      localStorage.setItem(KEY, token);
    } catch {}
  },
  clear: async () => {
    try {
      localStorage.removeItem(KEY);
    } catch {}
  },
};
