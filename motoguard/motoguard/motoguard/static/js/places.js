/* Google Places Autocomplete (Places API New) -> fills hidden location fields.
   Each picker is a <div class="place-autocomplete" data-city data-region
   data-country data-lat data-lng> naming the hidden input ids to populate. */
(function () {
  function val(v) { return v == null ? "" : (typeof v === "function" ? v() : v); }
  function setField(id, v) {
    if (!id) return;
    var el = document.getElementById(id);
    if (el) el.value = v;
  }

  async function initOne(host) {
    var places;
    try {
      places = await google.maps.importLibrary("places");
    } catch (e) {
      console.error("Places library failed to load", e);
      return;
    }
    var ac = new places.PlaceAutocompleteElement();
    ac.style.width = "100%";
    host.appendChild(ac);
    var d = host.dataset;

    ac.addEventListener("gmp-select", async function (ev) {
      var place = ev.placePrediction.toPlace();
      await place.fetchFields({ fields: ["addressComponents", "location", "displayName"] });
      var comp = {};
      (place.addressComponents || []).forEach(function (c) {
        (c.types || []).forEach(function (t) { comp[t] = c; });
      });
      var pick = function (t) { return comp[t] ? comp[t].longText : ""; };

      var city = pick("locality") || pick("postal_town") || pick("administrative_area_level_2");
      var county = pick("administrative_area_level_2") || pick("administrative_area_level_1");
      var country = pick("country");
      var loc = place.location;
      var lat = loc ? val(loc.lat) : "";
      var lng = loc ? val(loc.lng) : "";

      setField(d.city, city);
      setField(d.region, county);
      setField(d.country, country);
      setField(d.lat, lat);
      setField(d.lng, lng);

      var label = document.getElementById(d.label);
      if (label) label.textContent = [city, county, country].filter(Boolean).join(", ");
    });
  }

  window.addEventListener("load", function () {
    var hosts = document.querySelectorAll(".place-autocomplete");
    if (!hosts.length) return;
    if (!(window.google && google.maps && google.maps.importLibrary)) return; // key missing
    hosts.forEach(initOne);
  });
})();
