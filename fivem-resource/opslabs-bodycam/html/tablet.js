// Tablet module (modules/tablet/client.lua) - was xonsight-tablet's app.js. Shares this page with the recorder.
(function () {
  const tablet = document.getElementById("tablet");
  const frame = document.getElementById("screenFrame");
  const closeBtn = document.getElementById("closeBtn");

  function getParentResourceName() {
    try {
      return window.GetParentResourceName();
    } catch (err) {
      return "opslabs-bodycam";
    }
  }

  function nuiCallback(name, data) {
    fetch(`https://${getParentResourceName()}/${name}`, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=UTF-8" },
      body: JSON.stringify(data || {}),
    }).catch(() => {});
  }

  window.addEventListener("message", (event) => {
    const data = event.data || {};

    if (data.action === "tabletOpen") {
      frame.src = data.url || "about:blank";
      tablet.classList.remove("hidden");
    } else if (data.action === "tabletClose") {
      tablet.classList.add("hidden");
      // Drop the iframe once it's hidden so a background video/audio feed
      // (if a future page ever adds one) doesn't keep playing off-screen.
      frame.src = "about:blank";
    }
  });

  closeBtn.addEventListener("click", () => {
    nuiCallback("tabletClose");
  });

  document.addEventListener("keyup", (event) => {
    if (event.key === "Escape" && !tablet.classList.contains("hidden")) {
      nuiCallback("tabletClose");
    }
  });
})();
