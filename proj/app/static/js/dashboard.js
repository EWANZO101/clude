async function startAccount(id) {
  const res = await fetch(`/api/accounts/${id}/start`, { method: "POST" });
  const data = await res.json();
  refreshStatus(id);
  if (!data.ok) alert(data.message);
}

async function stopAccount(id) {
  const res = await fetch(`/api/accounts/${id}/stop`, { method: "POST" });
  const data = await res.json();
  refreshStatus(id);
  if (!data.ok) alert(data.message);
}

async function refreshStatus(id) {
  const res = await fetch(`/api/accounts/${id}/status`);
  const data = await res.json();
  const badge = document.getElementById(`status-${id}`);
  if (!badge) return;
  const dot = badge.querySelector("span:first-child");
  const label = badge.querySelector(".status-label");
  label.textContent = data.running ? "running" : "stopped";
  badge.className = "shrink-0 inline-flex items-center gap-1.5 text-xs font-medium px-2.5 py-1 rounded-full " +
    (data.running ? "bg-emerald-950/60 text-emerald-300 ring-1 ring-emerald-900" : "bg-gray-800/80 text-gray-400 ring-1 ring-gray-700");
  dot.className = "h-1.5 w-1.5 rounded-full " + (data.running ? "bg-emerald-400 animate-pulse" : "bg-gray-500");
}

let logTimer = null;
let currentConsoleId = null;

async function openConsole(id, name) {
  currentConsoleId = id;
  document.getElementById("console-title").textContent = `Console — ${name}`;
  document.getElementById("console-input").value = "";
  document.getElementById("log-modal").classList.remove("hidden");
  document.getElementById("console-input").focus();
  await refreshLog();
  clearInterval(logTimer);
  logTimer = setInterval(refreshLog, 2000);
}

async function refreshLog() {
  if (!currentConsoleId) return;
  const res = await fetch(`/api/accounts/${currentConsoleId}/log`);
  const data = await res.json();
  const pre = document.getElementById("log-content");
  const wasAtBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
  pre.textContent = data.log || "(no activity yet — hit Start on the card, then come back here)";
  if (wasAtBottom) pre.scrollTop = pre.scrollHeight;
}

async function sendConsoleInput(withEnter) {
  if (!currentConsoleId) return;
  const input = document.getElementById("console-input");
  const text = input.value;
  if (!text && !withEnter) return;
  const res = await fetch(`/api/accounts/${currentConsoleId}/input`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text, enter: withEnter }),
  });
  const data = await res.json();
  if (!data.ok) {
    alert(data.message);
    return;
  }
  input.value = "";
  setTimeout(refreshLog, 300);
}

function closeConsole() {
  document.getElementById("log-modal").classList.add("hidden");
  clearInterval(logTimer);
  currentConsoleId = null;
}

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && currentConsoleId) closeConsole();
});

setInterval(() => {
  document.querySelectorAll("[id^='status-']").forEach(el => {
    const id = el.id.replace("status-", "");
    refreshStatus(id);
  });
}, 5000);
