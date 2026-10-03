// The API sends UTC ISO timestamps ending in "Z"; these render them in the phone's own timezone.

export const money = (n: number) => `$${n.toFixed(n % 1 === 0 ? 0 : 2)}`;

export const date = (iso: string | null) =>
  iso ? new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : '';

export const dateTime = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleString(undefined, { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' })
    : '';

export function timeAgo(iso: string) {
  const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  return days < 7 ? `${days}d ago` : date(iso);
}

/** Accepts "ORD-1A2B3C", "1a2b3c", or a full https://…/order/<link> URL pasted from the website. */
export function parseOrderInput(input: string): { link?: string; orderId?: string } {
  const trimmed = input.trim();
  const link = trimmed.match(/\/order\/([0-9a-f]{32})/i)?.[1] ?? trimmed.match(/^([0-9a-f]{32})$/i)?.[1];
  if (link) return { link: link.toLowerCase() };
  return trimmed ? { orderId: trimmed.toUpperCase() } : {};
}
