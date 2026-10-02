(function () {
  "use strict";

  var STATUS_COLORS = {
    available: "#3DDC97",
    busy: "#F2637B",
    away: "#5B8DEF",
    unavailable: "#B98BF2",
    offline: "#5B6478",
  };

  var currentScript = document.currentScript;
  if (!currentScript) return;

  // Derive the scheduler's own origin from the script's own src, so the
  // widget works when embedded on a different domain (which is the whole
  // point) — a relative fetch() here would resolve against the *embedding*
  // page's origin instead, not the scheduler.
  var origin = currentScript.src.replace(/\/widget\.js.*$/, "");

  var badgeStyle =
    "display:inline-flex;align-items:center;gap:8px;padding:8px 14px;" +
    "border-radius:999px;border:1px solid #E4E6EB;background:#FFFFFF;" +
    "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;" +
    "font-size:13px;color:#1A1D24;text-decoration:none;box-shadow:0 1px 2px rgba(0,0,0,0.06);";

  var placeholder = document.createElement("span");
  placeholder.style.cssText = badgeStyle;
  placeholder.textContent = "Loading status…";
  currentScript.parentNode.insertBefore(placeholder, currentScript.nextSibling);

  fetch(origin + "/api/status")
    .then(function (res) {
      if (!res.ok) throw new Error("status fetch failed");
      return res.json();
    })
    .then(function (data) {
      var color = STATUS_COLORS[data.status] || STATUS_COLORS.offline;
      var label = data.name + " \u00B7 " + data.status.charAt(0).toUpperCase() + data.status.slice(1);
      var href = data.book_url || data.status_url;

      var badge = document.createElement(href ? "a" : "span");
      badge.style.cssText = badgeStyle;
      if (href) {
        badge.href = href;
        badge.target = "_blank";
        badge.rel = "noopener noreferrer";
      }

      var dot = document.createElement("span");
      dot.style.cssText = "display:inline-block;width:8px;height:8px;border-radius:50%;background:" + color + ";flex-shrink:0;";
      badge.appendChild(dot);
      badge.appendChild(document.createTextNode(label));

      placeholder.replaceWith(badge);
    })
    .catch(function () {
      placeholder.textContent = "Status unavailable";
    });
})();
