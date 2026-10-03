import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';

import { ApiError, createClient, login, type ApiClient, type User } from '@/lib/api';
import { registerForPush, unregisterPush, type PushState } from '@/lib/push';
import { tokenStorage } from '@/lib/token-storage';

type AuthState = {
  /** True until the stored token has been checked on launch. */
  loading: boolean;
  user: User | null;
  api: ApiClient | null;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  /** Whether this phone gets booking notifications; null while still checking. */
  pushState: PushState | null;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [token, setToken] = useState<string | null>(null);
  const [user, setUser] = useState<User | null>(null);
  const [pushState, setPushState] = useState<PushState | null>(null);

  useEffect(() => {
    (async () => {
      const stored = await tokenStorage.get();
      if (stored) {
        try {
          const { user } = await createClient(stored).me();
          setToken(stored);
          setUser(user);
        } catch (e) {
          // Only a rejected token means signed out; if the server is just
          // unreachable, keep the token so the next launch can try again.
          if (e instanceof ApiError && e.status === 401) await tokenStorage.clear();
        }
      }
      setLoading(false);
    })();
  }, []);

  const signIn = useCallback(async (email: string, password: string) => {
    const res = await login(email, password);
    await tokenStorage.set(res.token);
    setToken(res.token);
    setUser(res.user);
  }, []);

  const api = useMemo(() => (token ? createClient(token) : null), [token]);

  // Register for notifications whenever someone is signed in (on launch and
  // after signing in). Re-registering an existing token is harmless.
  useEffect(() => {
    if (!api) return;
    let cancelled = false;
    registerForPush(api).then((state) => !cancelled && setPushState(state));
    return () => {
      cancelled = true;
    };
  }, [api]);

  const signOut = useCallback(async () => {
    if (api) await unregisterPush(api);
    await tokenStorage.clear();
    setToken(null);
    setUser(null);
    setPushState(null);
  }, [api]);

  return (
    <AuthContext.Provider value={{ loading, user, api, signIn, signOut, pushState }}>{children}</AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>');
  return ctx;
}

/** For screens behind the auth guard, where the client always exists. */
export function useApi() {
  const { api } = useAuth();
  if (!api) throw new Error('useApi called while signed out');
  return api;
}
