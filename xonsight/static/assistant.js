(function () {
  const chatLog = document.getElementById("chat-log");
  const chatForm = document.getElementById("chat-form");
  const chatInput = document.getElementById("chat-input");

  let history = [];

  function appendMessage(role, text) {
    const bubble = document.createElement("div");
    bubble.className =
      role === "user"
        ? "ml-auto max-w-[85%] bg-gradient-to-br from-accent/15 to-accent2/15 border border-accent/30 text-slate-100 rounded-2xl rounded-br-sm px-3.5 py-2.5"
        : "mr-auto max-w-[85%] bg-base border border-border text-slate-200 rounded-2xl rounded-bl-sm px-3.5 py-2.5 whitespace-pre-wrap";
    bubble.textContent = text;
    chatLog.appendChild(bubble);
    chatLog.scrollTop = chatLog.scrollHeight;
  }

  async function api(path, options) {
    const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
    if (!res.ok) throw new Error(`Request failed: ${res.status}`);
    return res.json();
  }

  chatForm.addEventListener("submit", async (evt) => {
    evt.preventDefault();
    const message = chatInput.value.trim();
    if (!message) return;
    chatInput.value = "";
    appendMessage("user", message);
    history.push({ role: "user", content: message });

    try {
      const result = await api("/api/assistant/ask", { method: "POST", body: JSON.stringify({ message, history }) });
      if (result.ok) {
        appendMessage("assistant", result.reply);
        history.push({ role: "assistant", content: result.reply });
      } else {
        appendMessage("assistant", result.error);
      }
    } catch (e) {
      appendMessage("assistant", "Request failed.");
    }
  });

  document.getElementById("btn-draft-bolo").addEventListener("click", async (evt) => {
    const notes = document.getElementById("bolo-notes").value.trim();
    if (!notes) return;
    const btn = evt.currentTarget;
    const label = document.getElementById("btn-draft-bolo-label");
    btn.disabled = true;
    label.textContent = "Drafting…";
    try {
      const result = await api("/api/assistant/draft-bolo", { method: "POST", body: JSON.stringify({ notes }) });
      if (result.ok) {
        document.getElementById("bolo-subject").value = result.subject;
        document.getElementById("bolo-details").value = result.details;
      } else {
        alert(result.error);
      }
    } finally {
      btn.disabled = false;
      label.textContent = "Draft with AI";
    }
  });

  document.getElementById("btn-publish-bolo").addEventListener("click", async () => {
    const subject = document.getElementById("bolo-subject").value.trim();
    const details = document.getElementById("bolo-details").value.trim();
    const author = document.getElementById("bolo-author").value.trim();
    if (!subject) {
      alert("Subject is required.");
      return;
    }
    await api("/api/bolos", { method: "POST", body: JSON.stringify({ subject, details, author }) });
    document.getElementById("bolo-subject").value = "";
    document.getElementById("bolo-details").value = "";
    document.getElementById("bolo-notes").value = "";
    loadBolos();
  });

  async function loadBolos() {
    const bolos = await api("/api/bolos");
    const list = document.getElementById("bolo-list");
    list.innerHTML = bolos.length
      ? bolos
          .map(
            (b) => `
      <div class="bg-base rounded-xl border border-amber-500/20 px-3 py-2.5">
        <div class="flex items-center justify-between gap-2">
          <div class="text-white font-medium">${b.subject}</div>
          <button type="button" data-resolve="${b.id}" class="text-[11px] text-slate-500 hover:text-accent2 shrink-0 px-1.5 py-0.5 rounded hover:bg-accent2/10">Resolve</button>
        </div>
        <p class="text-slate-400 mt-1 whitespace-pre-wrap">${b.details}</p>
        <div class="text-slate-600 text-[10px] mt-1.5">${b.author || "Unknown"} &middot; ${new Date(b.createdAt).toLocaleString()}</div>
      </div>`
          )
          .join("")
      : '<div class="rounded-xl border border-dashed border-border bg-panel/40 px-4 py-6 text-center text-slate-600 text-xs">No active BOLOs.</div>';
  }

  document.getElementById("bolo-list").addEventListener("click", async (evt) => {
    const btn = evt.target.closest("[data-resolve]");
    if (!btn) return;
    await api(`/api/bolos/${btn.dataset.resolve}/resolve`, { method: "POST" });
    loadBolos();
  });

  if (window.XON_SIGHT_AI_CONFIGURED) {
    appendMessage("assistant", "Ask me about recent evidence, open cases, or active BOLOs.");
  }
  loadBolos();
})();
