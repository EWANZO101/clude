(function () {
  const form = document.getElementById("new-case-form");
  if (!form) return;

  form.addEventListener("submit", async (evt) => {
    evt.preventDefault();
    const title = document.getElementById("new-case-title").value.trim();
    if (!title) return;
    const res = await fetch("/api/cases", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title }),
    });
    if (res.ok) {
      const created = await res.json();
      window.location.href = `/cases/${created.id}`;
    }
  });
})();
