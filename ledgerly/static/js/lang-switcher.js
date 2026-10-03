/* Ledgerly public-page language switcher.
   Client-side translation via Google Translate's public endpoint —
   no server changes, no stored translation files. */
(function () {
  const LANGS = [
    ["en", "English"], ["af", "Afrikaans"], ["sq", "Albanian"], ["am", "Amharic"],
    ["ar", "Arabic"], ["hy", "Armenian"], ["as", "Assamese"], ["ay", "Aymara"],
    ["az", "Azerbaijani"], ["bm", "Bambara"], ["eu", "Basque"], ["be", "Belarusian"],
    ["bn", "Bengali"], ["bho", "Bhojpuri"], ["bs", "Bosnian"], ["bg", "Bulgarian"],
    ["ca", "Catalan"], ["ceb", "Cebuano"], ["ny", "Chichewa"], ["zh-CN", "Chinese (Simplified)"],
    ["zh-TW", "Chinese (Traditional)"], ["co", "Corsican"], ["hr", "Croatian"], ["cs", "Czech"],
    ["da", "Danish"], ["dv", "Dhivehi"], ["doi", "Dogri"], ["nl", "Dutch"],
    ["en", "English"], ["eo", "Esperanto"], ["et", "Estonian"], ["ee", "Ewe"],
    ["tl", "Filipino"], ["fi", "Finnish"], ["fr", "French"], ["fy", "Frisian"],
    ["gl", "Galician"], ["ka", "Georgian"], ["de", "German"], ["el", "Greek"],
    ["gn", "Guarani"], ["gu", "Gujarati"], ["ht", "Haitian Creole"], ["ha", "Hausa"],
    ["haw", "Hawaiian"], ["he", "Hebrew"], ["hi", "Hindi"], ["hmn", "Hmong"],
    ["hu", "Hungarian"], ["is", "Icelandic"], ["ig", "Igbo"], ["ilo", "Ilocano"],
    ["id", "Indonesian"], ["ga", "Irish"], ["it", "Italian"], ["ja", "Japanese"],
    ["jv", "Javanese"], ["kn", "Kannada"], ["kk", "Kazakh"], ["km", "Khmer"],
    ["rw", "Kinyarwanda"], ["gom", "Konkani"], ["ko", "Korean"], ["kri", "Krio"],
    ["ku", "Kurdish"], ["ckb", "Kurdish (Sorani)"], ["ky", "Kyrgyz"], ["lo", "Lao"],
    ["la", "Latin"], ["lv", "Latvian"], ["ln", "Lingala"], ["lt", "Lithuanian"],
    ["lg", "Luganda"], ["lb", "Luxembourgish"], ["mk", "Macedonian"], ["mai", "Maithili"],
    ["mg", "Malagasy"], ["ms", "Malay"], ["ml", "Malayalam"], ["mt", "Maltese"],
    ["mi", "Maori"], ["mr", "Marathi"], ["mni-Mtei", "Meiteilon (Manipuri)"], ["lus", "Mizo"],
    ["mn", "Mongolian"], ["my", "Myanmar (Burmese)"], ["ne", "Nepali"], ["no", "Norwegian"],
    ["or", "Odia"], ["om", "Oromo"], ["ps", "Pashto"], ["fa", "Persian"],
    ["pl", "Polish"], ["pt", "Portuguese"], ["pa", "Punjabi"], ["qu", "Quechua"],
    ["ro", "Romanian"], ["ru", "Russian"], ["sm", "Samoan"], ["sa", "Sanskrit"],
    ["gd", "Scots Gaelic"], ["nso", "Sepedi"], ["sr", "Serbian"], ["st", "Sesotho"],
    ["sn", "Shona"], ["sd", "Sindhi"], ["si", "Sinhala"], ["sk", "Slovak"],
    ["sl", "Slovenian"], ["so", "Somali"], ["es", "Spanish"], ["su", "Sundanese"],
    ["sw", "Swahili"], ["sv", "Swedish"], ["tg", "Tajik"], ["ta", "Tamil"],
    ["tt", "Tatar"], ["te", "Telugu"], ["th", "Thai"], ["ti", "Tigrinya"],
    ["ts", "Tsonga"], ["tr", "Turkish"], ["tk", "Turkmen"], ["ak", "Twi"],
    ["uk", "Ukrainian"], ["ur", "Urdu"], ["ug", "Uyghur"], ["uz", "Uzbek"],
    ["vi", "Vietnamese"], ["cy", "Welsh"], ["xh", "Xhosa"], ["yi", "Yiddish"],
    ["yo", "Yoruba"], ["zu", "Zulu"],
  ].filter((v, i, arr) => arr.findIndex((x) => x[0] === v[0]) === i)
   .sort((a, b) => a[1].localeCompare(b[1]));

  function initLangSwitcher(rootId, storageKey) {
    const root = document.getElementById(rootId);
    if (!root) return;

    const btn = document.getElementById("lang-btn");
    const currentLabel = document.getElementById("lang-current");
    const spinner = document.getElementById("lang-spinner");
    const panel = document.getElementById("lang-panel");
    const search = document.getElementById("lang-search");
    const list = document.getElementById("lang-list");

    let originalTexts = null; // captured lazily on first translation
    let currentLang = "en";
    let generation = 0; // bumped on every selection so stale requests are ignored

    function renderList(filter) {
      const f = (filter || "").trim().toLowerCase();
      list.innerHTML = "";
      LANGS
        .filter(([, name]) => !f || name.toLowerCase().includes(f))
        .forEach(([code, name]) => {
          const item = document.createElement("button");
          item.type = "button";
          item.className =
            "w-full text-left text-xs px-2.5 py-1.5 rounded-md hover:bg-white/5 flex items-center justify-between" +
            (code === currentLang ? " text-gold" : " text-parchment");
          item.textContent = name;
          if (code === currentLang) {
            const check = document.createElement("span");
            check.textContent = "✓";
            item.appendChild(check);
          }
          item.addEventListener("click", () => selectLang(code, name));
          list.appendChild(item);
        });
      if (!list.children.length) {
        const empty = document.createElement("p");
        empty.className = "text-xs text-muted px-2.5 py-2";
        empty.textContent = "No languages match.";
        list.appendChild(empty);
      }
    }

    function collectTextNodes() {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          if (!node.textContent.trim()) return NodeFilter.FILTER_REJECT;
          const parent = node.parentElement;
          if (!parent) return NodeFilter.FILTER_REJECT;
          if (parent.closest("[data-no-translate]")) return NodeFilter.FILTER_REJECT;
          if (parent.tagName === "SCRIPT" || parent.tagName === "STYLE") return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        },
      });
      const nodes = [];
      let n;
      while ((n = walker.nextNode())) nodes.push(n);
      return nodes;
    }

    async function translateOne(text, tl) {
      const url =
        "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=" +
        encodeURIComponent(tl) + "&dt=t&q=" + encodeURIComponent(text);
      const res = await fetch(url);
      if (!res.ok) throw new Error("translate failed");
      const data = await res.json();
      return data[0].map((seg) => seg[0]).join("");
    }

    function setSpinner(on) {
      spinner.classList.toggle("hidden", !on);
      currentLabel.classList.toggle("hidden", on);
    }

    async function selectLang(code, name) {
      // New selection always wins — bump generation so any in-flight
      // requests from a previous pick discard their results instead
      // of landing late and overwriting this one ("buggy" symptom).
      const myGen = ++generation;
      panel.classList.add("hidden");
      currentLang = code;
      localStorage.setItem(storageKey, code);

      if (!originalTexts) {
        originalTexts = collectTextNodes().map((node) => ({ node, text: node.textContent }));
      }

      // Always restore the true English originals first, so switching
      // straight from one language to another never translates
      // already-translated text or leaves mixed-language leftovers.
      originalTexts.forEach(({ node, text }) => (node.textContent = text));

      if (code === "en") {
        currentLabel.dataset.label = "English";
        currentLabel.textContent = "English";
        renderList(search.value);
        return;
      }

      setSpinner(true);
      let queue = 0;
      const CONCURRENCY = 6;
      async function worker() {
        while (queue < originalTexts.length) {
          const i = queue++;
          const { node, text } = originalTexts[i];
          try {
            const translated = await translateOne(text, code);
            if (generation !== myGen) return; // superseded — drop this result
            node.textContent = translated;
          } catch (e) {
            /* leave original text on this node if the request failed */
          }
        }
      }
      await Promise.all(Array.from({ length: CONCURRENCY }, worker));
      if (generation !== myGen) return; // a newer pick finished after us
      currentLabel.dataset.label = name;
      currentLabel.textContent = name;
      setSpinner(false);
      renderList(search.value);
    }

    btn.addEventListener("click", () => {
      panel.classList.toggle("hidden");
      if (!panel.classList.contains("hidden")) {
        renderList("");
        search.value = "";
        search.focus();
      }
    });
    document.addEventListener("click", (e) => {
      if (!document.getElementById("lang-switcher").contains(e.target)) {
        panel.classList.add("hidden");
      }
    });
    search.addEventListener("input", () => renderList(search.value));

    renderList("");

    const saved = localStorage.getItem(storageKey);
    if (saved && saved !== "en") {
      const match = LANGS.find(([c]) => c === saved);
      if (match) selectLang(match[0], match[1]);
    }
  }

  window.initLangSwitcher = initLangSwitcher;
})();
