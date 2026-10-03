import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';

import { adminClient, adminLogin, followOrderPush, type AdminClient } from '@/lib/api';
import { getPushToken } from '@/lib/push';
import { storage } from '@/lib/storage';

export type SavedOrder = { link: string; orderId: string; token: string };

type SessionState = {
  ready: boolean;
  /** Orders this phone can open (each unlocked once with its PIN). */
  orders: SavedOrder[];
  saveOrder: (order: SavedOrder) => Promise<void>;
  removeOrder: (link: string) => Promise<void>;
  tokenFor: (link: string) => string | null;
  /** Cioda's admin session, if signed in on this phone. */
  admin: AdminClient | null;
  signInAdmin: (username: string, password: string) => Promise<void>;
  signOutAdmin: () => Promise<void>;
};

const ORDERS_KEY = 'cioda.orders';
const ADMIN_KEY = 'cioda.admin-token';

const SessionContext = createContext<SessionState | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  const [orders, setOrders] = useState<SavedOrder[]>([]);
  const [adminToken, setAdminToken] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const [savedOrders, savedAdmin] = await Promise.all([storage.get(ORDERS_KEY), storage.get(ADMIN_KEY)]);
      try {
        setOrders(savedOrders ? JSON.parse(savedOrders) : []);
      } catch {
        setOrders([]);
      }
      setAdminToken(savedAdmin);
      setReady(true);
    })();
  }, []);

  const persistOrders = useCallback(async (next: SavedOrder[]) => {
    setOrders(next);
    await storage.set(ORDERS_KEY, JSON.stringify(next));
  }, []);

  const saveOrder = useCallback(
    async (order: SavedOrder) => {
      await persistOrders([order, ...orders.filter((o) => o.link !== order.link)]);
      // Follow this order for status/reply notifications. Best-effort: the order still saves without it.
      getPushToken()
        .then((push) => push && followOrderPush(order.link, order.token, push))
        .catch(() => {});
    },
    [orders, persistOrders],
  );

  const removeOrder = useCallback(
    async (link: string) => {
      const order = orders.find((o) => o.link === link);
      await persistOrders(orders.filter((o) => o.link !== link));
      if (order) {
        getPushToken()
          .then((push) => push && followOrderPush(order.link, order.token, push, false))
          .catch(() => {});
      }
    },
    [orders, persistOrders],
  );

  const tokenFor = useCallback((link: string) => orders.find((o) => o.link === link)?.token ?? null, [orders]);

  const admin = useMemo(() => (adminToken ? adminClient(adminToken) : null), [adminToken]);

  const signInAdmin = useCallback(async (username: string, password: string) => {
    const { token } = await adminLogin(username, password);
    await storage.set(ADMIN_KEY, token);
    setAdminToken(token);
    getPushToken()
      .then((push) => push && adminClient(token).registerPush(push))
      .catch(() => {});
  }, []);

  const signOutAdmin = useCallback(async () => {
    if (admin) {
      const push = await getPushToken().catch(() => null);
      if (push) await admin.registerPush(push, false).catch(() => {});
    }
    await storage.remove(ADMIN_KEY);
    setAdminToken(null);
  }, [admin]);

  return (
    <SessionContext.Provider value={{ ready, orders, saveOrder, removeOrder, tokenFor, admin, signInAdmin, signOutAdmin }}>
      {children}
    </SessionContext.Provider>
  );
}

export function useSession() {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error('useSession must be used inside <SessionProvider>');
  return ctx;
}

/** For Studio screens, which only exist while signed in as admin. */
export function useAdmin() {
  const { admin } = useSession();
  if (!admin) throw new Error('useAdmin called while signed out');
  return admin;
}
