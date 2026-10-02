// Client for the commission site's /api/m/v1 (mobile_api.py in cioda-commissions).
// Times come back as UTC ISO strings ("…Z"); see lib/format.ts.

export const API_URL = process.env.EXPO_PUBLIC_API_URL ?? 'https://order.ciodrawz.space/api/m/v1';

export type CommissionType = { id: number; name: string; price: number; allow_ref_images: boolean; max_ref_images: number };
export type FormField = { key: string; label: string; type: 'text' | 'textarea' | 'select' | 'checkbox'; required: boolean; options: string[] };

export type Home = {
  commissions_open: boolean;
  closed_message: string;
  reopen_date: string | null;
  banner: { text: string; style: 'info' | 'success' | 'warning' | 'danger'; link: string | null; link_text: string | null } | null;
  price_list: { category: string; types: CommissionType[] }[];
  gallery: { url: string; caption: string | null }[];
  form_fields: FormField[];
  site_url: string;
};

export type QueueState =
  | { commissions_open: false; closed_message: string }
  | { commissions_open: true; busy: true; retry_after: number }
  | {
      commissions_open: true;
      busy: false;
      admitted: boolean;
      position: number;
      total: number;
      on_form: number;
      free_slots: number;
      wait_remaining: number;
    };

export type Answer = { label: string; value: string };
export type LogEntry = { event: string; details: string | null; image_url: string | null; customer_visible: boolean; created_at: string };
export type Invoice = {
  invoice_id: string;
  order_id: string;
  customer_name: string | null;
  amount: number;
  items: { desc: string; amount: number }[];
  paid: boolean;
  paid_at: string | null;
  due_date: string | null;
  notes: string | null;
  created_at: string;
  pdf_url: string | null;
};
export type TicketMessage = { sender: 'customer' | 'admin'; message: string; created_at: string };
export type Ticket = {
  ticket_id: string;
  order_id: string | null;
  customer_name: string;
  subject: string | null;
  status: string;
  created_at: string;
  expires_at: string | null;
  expired: boolean;
  messages?: TicketMessage[];
};

export type OrderSummary = {
  order_id: string;
  customer_name: string;
  commission_type: string | null;
  price: number;
  status: string;
  payment_status: string;
  eta: string | null;
  created_at: string;
};

export type CustomerOrder = OrderSummary & {
  description: string | null;
  payment_method: string | null;
  progress: { order_steps: string[]; order_index: number; payment_steps: string[]; payment_index: number };
  discount: string | null;
  answers: Answer[];
  ref_images: string[];
  logs: LogEntry[];
  invoice: Invoice | null;
  tickets: Ticket[];
  final_images: string[];
};

export type AdminOrder = OrderSummary & {
  link: string;
  tracking_url: string;
  customer_email: string | null;
  customer_discord: string | null;
  customer_instagram: string | null;
  payment_method: string | null;
  payment_username: string | null;
  description: string | null;
  notes: string | null;
  pin_set: boolean;
  discount: string | null;
  answers: Answer[];
  ref_images: string[];
  logs: LogEntry[];
  invoices: Invoice[];
  tickets: Ticket[];
  payments: { amount: number; method: string; recorded_at: string; notes: string | null }[];
  final_images: { id: number; url: string }[];
};

export type CommissionRequest = {
  request_id: string;
  customer_name: string;
  customer_email: string | null;
  customer_discord: string | null;
  customer_instagram: string | null;
  commission_type: string | null;
  description: string | null;
  status: 'Pending' | 'Accepted' | 'Declined';
  payment_method: string | null;
  discount: string | null;
  answers: Answer[];
  ref_images: string[];
  created_at: string;
};

export type Dashboard = {
  commissions_open: boolean;
  stats: {
    pending_requests: number;
    awaiting_confirmation: number;
    in_progress: number;
    open_tickets: number;
    unpaid: number;
    total_orders: number;
  };
  recent_orders: OrderSummary[];
};

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public data: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

type Options = { method?: 'GET' | 'POST' | 'DELETE'; body?: unknown; form?: FormData; token?: string | null };

async function request<T>(path: string, { method = 'GET', body, form, token }: Options = {}): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${API_URL}${path}`, {
      method,
      headers: {
        Accept: 'application/json',
        ...(body !== undefined && { 'Content-Type': 'application/json' }),
        ...(token && { Authorization: `Bearer ${token}` }),
      },
      body: form ?? (body !== undefined ? JSON.stringify(body) : undefined),
    });
  } catch {
    throw new ApiError("Can't reach the server. Check your connection and try again.", 0);
  }
  if (res.status === 204) return undefined as T;
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(data?.error ?? `Something went wrong (${res.status}).`, res.status, data ?? {});
  return data as T;
}

// ── public ──
export const getHome = () => request<Home>('/public/home');
export const checkDiscount = (code: string) =>
  request<{ valid: true; label: string; type: 'percent' | 'fixed'; value: number } | { valid: false; error: string }>('/public/discount', {
    method: 'POST',
    body: { code },
  });
export const queueHeartbeat = (token: string) => request<QueueState>('/queue', { method: 'POST', body: { token } });
export const submitRequest = (form: FormData) => request<{ order_id: string; link: string }>('/requests', { method: 'POST', form });

// ── customer ──
export const lookupOrder = (by: { orderId?: string; link?: string }) =>
  request<{ order_id: string; link: string; pin_set: boolean }>('/orders/lookup', {
    method: 'POST',
    body: { order_id: by.orderId, link: by.link },
  });
export const enterPin = (link: string, pin: string) =>
  request<{ token: string; order_id: string; created: boolean }>(`/orders/${link}/pin`, { method: 'POST', body: { pin } });
export const getOrder = (link: string, token: string) => request<{ order: CustomerOrder }>(`/orders/${link}`, { token });
export const openTicket = (link: string, token: string, subject: string, message: string) =>
  request<{ ticket: Ticket }>(`/orders/${link}/tickets`, { method: 'POST', body: { subject, message }, token });
export const getTicket = (link: string, token: string, id: string) => request<{ ticket: Ticket }>(`/orders/${link}/tickets/${id}`, { token });
export const replyTicket = (link: string, token: string, id: string, message: string) =>
  request<{ ticket: Ticket }>(`/orders/${link}/tickets/${id}/messages`, { method: 'POST', body: { message }, token });
export const followOrderPush = (link: string, token: string, pushToken: string, follow = true) =>
  request<unknown>(`/orders/${link}/push`, { method: follow ? 'POST' : 'DELETE', body: { token: pushToken }, token });

// ── admin ──
export const adminLogin = (username: string, password: string) =>
  request<{ token: string }>('/admin/login', { method: 'POST', body: { username, password } });

export function adminClient(token: string) {
  return {
    dashboard: () => request<Dashboard>('/admin/dashboard', { token }),
    toggleCommissions: (notifySubscribers: boolean) =>
      request<{ commissions_open: boolean }>('/admin/commissions/toggle', { method: 'POST', body: { notify_subscribers: notifySubscribers }, token }),
    orders: (q = '', status = '') =>
      request<{ orders: OrderSummary[]; statuses: string[]; payment_statuses: string[] }>(
        `/admin/orders?q=${encodeURIComponent(q)}&status=${encodeURIComponent(status)}`,
        { token },
      ),
    order: (id: string) => request<{ order: AdminOrder; statuses: string[]; payment_statuses: string[] }>(`/admin/orders/${id}`, { token }),
    updateOrder: (id: string, changes: Partial<{ status: string; payment_status: string; eta: string; notes: string; price: number }>) =>
      request<{ order: AdminOrder }>(`/admin/orders/${id}/update`, { method: 'POST', body: changes, token }),
    addUpdate: (id: string, form: FormData) => request<{ order: AdminOrder }>(`/admin/orders/${id}/log`, { method: 'POST', form, token }),
    uploadFinal: (id: string, form: FormData) => request<{ order: AdminOrder }>(`/admin/orders/${id}/final-images`, { method: 'POST', form, token }),
    deleteFinal: (id: string, imageId: number) => request<void>(`/admin/orders/${id}/final-images/${imageId}`, { method: 'DELETE', token }),
    requests: () => request<{ requests: CommissionRequest[] }>('/admin/requests', { token }),
    requestAction: (id: string, action: 'accept' | 'decline') =>
      request<{ status: string }>(`/admin/requests/${id}/action`, { method: 'POST', body: { action }, token }),
    tickets: () => request<{ tickets: Ticket[] }>('/admin/tickets', { token }),
    ticket: (id: string) => request<{ ticket: Ticket }>(`/admin/tickets/${id}`, { token }),
    replyTicket: (id: string, message: string) => request<{ ticket: Ticket }>(`/admin/tickets/${id}/reply`, { method: 'POST', body: { message }, token }),
    closeTicket: (id: string) => request<{ ticket: Ticket }>(`/admin/tickets/${id}/close`, { method: 'POST', token }),
    invoices: () => request<{ invoices: Invoice[] }>('/admin/invoices', { token }),
    markPaid: (id: string) => request<{ invoice: Invoice }>(`/admin/invoices/${id}/mark-paid`, { method: 'POST', body: {}, token }),
    registerPush: (pushToken: string, register = true) =>
      request<unknown>('/admin/push', { method: register ? 'POST' : 'DELETE', body: { token: pushToken }, token }),
    testPush: () => request<{ sent: boolean }>('/admin/push/test', { method: 'POST', token }),
  };
}

export type AdminClient = ReturnType<typeof adminClient>;
