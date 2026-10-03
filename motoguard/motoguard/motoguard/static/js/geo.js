/* Location picker backed by GeoNames (proxied via /geo/search so the username
   stays server-side). Type-ahead worldwide search of towns, cities, regions and
   countries; fills hidden city/region/country/lat/lng. Free typing still submits
   as the city so users are never forced to pick from the list. */
(function () {
  var URL = window.GEO_SEARCH_URL || "/geo/search";
  function deb(fn, ms) { var t; return function () { var a = arguments, c = this; clearTimeout(t); t = setTimeout(function () { fn.apply(c, a); }, ms); }; }
  function el(id) { return id ? document.getElementById(id) : null; }

  function init(host) {
    var d = host.dataset;
    var q = el(d.q), list = el(d.list);
    var fCity = el(d.city), fRegion = el(d.region), fCountry = el(d.country), fLat = el(d.lat), fLng = el(d.lng);
    var items = [], active = -1, picking = false;

    function close() { list.classList.remove("show"); list.innerHTML = ""; items = []; active = -1; }

    function render(rows) {
      list.innerHTML = ""; items = rows || [];
      if (!items.length) { close(); return; }
      items.forEach(function (r, i) {
        var row = document.createElement("div");
        row.className = "ac-item";
        var sub = [r.region, r.country].filter(Boolean).join(", ");
        row.innerHTML = '<span class="main"></span>' + (sub ? '<span class="sub"></span>' : "");
        row.querySelector(".main").textContent = r.city || r.region || r.country || r.label;
        if (sub) row.querySelector(".sub").textContent = sub;
        row.addEventListener("mousedown", function (e) { e.preventDefault(); choose(i); });
        list.appendChild(row);
      });
      var credit = document.createElement("div");
      credit.className = "ac-credit"; credit.textContent = "Powered by GeoNames";
      list.appendChild(credit);
      list.classList.add("show");
    }

    function choose(i) {
      var r = items[i]; if (!r) return; picking = true;
      if (fCity) fCity.value = r.city || "";
      if (fRegion) fRegion.value = r.region || "";
      if (fCountry) fCountry.value = r.country || "";
      if (fLat) fLat.value = (r.lat == null ? "" : r.lat);
      if (fLng) fLng.value = (r.lng == null ? "" : r.lng);
      q.value = r.label || [r.city, r.region, r.country].filter(Boolean).join(", ");
      close(); picking = false;
    }

    var run = deb(function () {
      var v = q.value.trim();
      if (fCity) fCity.value = v;          // free typing -> city; cleared coords until a pick
      if (fRegion) fRegion.value = ""; if (fCountry) fCountry.value = "";
      if (fLat) fLat.value = ""; if (fLng) fLng.value = "";
      if (v.length < 2) { close(); return; }
      fetch(URL + "?q=" + encodeURIComponent(v))
        .then(function (r) { return r.json(); })
        .then(function (j) { if (!j.ok) { close(); return; } render(j.results); })
        .catch(function () { close(); });
    }, 220);

    function paint() { list.querySelectorAll(".ac-item").forEach(function (r, i) { r.classList.toggle("active", i === active); }); }

    q.addEventListener("input", run);
    q.addEventListener("focus", function () { if (items.length) list.classList.add("show"); });
    q.addEventListener("blur", function () { setTimeout(function () { if (!picking) close(); }, 150); });
    q.addEventListener("keydown", function (e) {
      if (!list.classList.contains("show")) return;
      if (e.key === "ArrowDown") { e.preventDefault(); active = Math.min(active + 1, items.length - 1); paint(); }
      else if (e.key === "ArrowUp") { e.preventDefault(); active = Math.max(active - 1, 0); paint(); }
      else if (e.key === "Enter") { if (active >= 0) { e.preventDefault(); choose(active); } }
      else if (e.key === "Escape") { close(); }
    });
  }

  window.addEventListener("load", function () {
    var hosts = document.querySelectorAll(".geo-search");
    if (!hosts.length) return;
    hosts.forEach(init);
  });
})();
