// Initializes a Quill rich text editor bound to a hidden input/textarea,
// used for the agreement/terms field. Works on any element with class
// "rich-editor" that has a data-target attribute pointing to the id of the
// hidden form field it should sync into on submit.
(function () {
  function initRichEditor(root) {
    const targetId = root.dataset.target;
    const target = document.getElementById(targetId);
    const editorEl = root.querySelector(".rich-editor-surface");
    const previewEl = document.querySelector(root.dataset.previewTarget || "");

    const quill = new Quill(editorEl, {
      theme: "snow",
      placeholder: root.dataset.placeholder || "Write the agreement here…",
      modules: {
        toolbar: [
          [{ header: [2, 3, false] }],
          ["bold", "italic", "underline"],
          [{ list: "ordered" }, { list: "bullet" }],
          ["blockquote", "link"],
          ["clean"],
        ],
      },
    });

    if (target && target.value) {
      quill.root.innerHTML = target.value;
    }

    function sync() {
      const html = quill.root.innerHTML;
      const isEmpty = quill.getText().trim().length === 0;
      if (target) target.value = isEmpty ? "" : html;
      if (previewEl) previewEl.innerHTML = isEmpty
        ? '<p class="text-muted italic">Nothing written yet — this section won\u2019t appear for the client.</p>'
        : html;
    }

    quill.on("text-change", sync);
    sync();

    const form = root.closest("form");
    if (form) form.addEventListener("submit", sync);
  }

  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".rich-editor").forEach(initRichEditor);
  });
})();
