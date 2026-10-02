const DB_NAME = "bookkeeping-offline";
const DB_VERSION = 1;
const STORE = "pending_expenses";

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        db.createObjectStore(STORE, { keyPath: "client_uuid" });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function queueExpense(record) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(record);
    tx.oncomplete = () => resolve(record);
    tx.onerror = () => reject(tx.error);
  });
}

async function getPendingExpenses() {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readonly");
    const req = tx.objectStore(STORE).getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function removePendingExpense(clientUuid) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).delete(clientUuid);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function markPendingExpenseError(clientUuid, message) {
  const db = await openDb();
  const tx = db.transaction(STORE, "readwrite");
  const store = tx.objectStore(STORE);
  const getReq = store.get(clientUuid);
  getReq.onsuccess = () => {
    const record = getReq.result;
    if (record) {
      record.last_error = message;
      record.retry_count = (record.retry_count || 0) + 1;
      store.put(record);
    }
  };
}

async function flushQueue() {
  const pending = await getPendingExpenses();
  if (pending.length === 0) return { synced: 0, failed: 0 };

  let synced = 0, failed = 0;
  try {
    const resp = await fetch("/sync/expenses", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ items: pending }),
    });
    if (!resp.ok) throw new Error(`Sync request failed: HTTP ${resp.status}`);
    const data = await resp.json();

    for (const result of data.results) {
      if (result.status === "created" || result.status === "duplicate") {
        // Both outcomes mean the server now has this record — safe to
        // drop from the local queue either way. Never treat a duplicate
        // as an error and never retry it into a second transaction.
        await removePendingExpense(result.client_uuid);
        synced += 1;
      } else {
        await markPendingExpenseError(result.client_uuid, result.message || "Unknown error");
        failed += 1;
      }
    }
  } catch (err) {
    // Network genuinely failed (e.g. connection dropped mid-flush) — leave
    // the whole queue intact, nothing is lost, we'll retry on next 'online'.
    console.warn("Offline sync deferred:", err);
  }

  updatePendingBadge();
  return { synced, failed };
}

async function updatePendingBadge() {
  const badge = document.getElementById("offline-pending-badge");
  if (!badge) return;
  const pending = await getPendingExpenses();
  if (pending.length > 0) {
    badge.textContent = `${pending.length} queued offline`;
    badge.classList.remove("hidden");
  } else {
    badge.classList.add("hidden");
  }
}

function setNetworkStatusUI() {
  const el = document.getElementById("network-status");
  if (!el) return;
  if (navigator.onLine) {
    el.textContent = "";
    el.classList.add("hidden");
  } else {
    el.textContent = "You're offline — changes will be saved locally and synced automatically.";
    el.classList.remove("hidden");
  }
}

window.addEventListener("online", () => {
  setNetworkStatusUI();
  flushQueue();
});
window.addEventListener("offline", setNetworkStatusUI);

document.addEventListener("DOMContentLoaded", () => {
  setNetworkStatusUI();
  updatePendingBadge();
  if (navigator.onLine) flushQueue();

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch((e) => console.warn("SW registration failed", e));
  }

  // Intercept the offline-capable expense form, if present on this page.
  const form = document.getElementById("expense-form");
  if (form) {
    form.addEventListener("submit", async (event) => {
      if (navigator.onLine) return; // let it submit to the server normally
      event.preventDefault();

      const formData = new FormData(form);
      const record = {
        client_uuid: crypto.randomUUID(),
        description: formData.get("description"),
        amount: formData.get("amount"),
        expense_date: formData.get("expense_date"),
        supplier_id: formData.get("supplier_id") || null,
        expense_account_id: formData.get("expense_account_id"),
        paid_from_account_id: formData.get("paid_from_account_id"),
        is_reimbursable: formData.get("is_reimbursable") === "on",
        queued_at: new Date().toISOString(),
      };
      await queueExpense(record);
      await updatePendingBadge();
      window.location.href = "/expenses/?queued=1";
    });
  }

  // Render queued-but-not-yet-synced expenses under the server-rendered
  // list, if this page has a slot for them.
  const queuedList = document.getElementById("queued-expenses-list");
  if (queuedList) {
    getPendingExpenses().then((pending) => {
      if (pending.length === 0) return;
      queuedList.innerHTML = pending.map((p) => `
        <tr class="border-t border-gray-100 dark:border-gray-700 opacity-70">
          <td class="p-3">${p.expense_date || ""}</td>
          <td class="p-3">${p.description} <span class="text-xs text-amber-600">(queued offline${p.last_error ? " — retrying" : ""})</span></td>
          <td class="p-3">—</td>
          <td class="p-3 text-right">${Number(p.amount).toFixed(2)}</td>
        </tr>
      `).join("");
    });
  }
});
