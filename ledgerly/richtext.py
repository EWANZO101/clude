import bleach

ALLOWED_TAGS = [
    "p", "br", "strong", "b", "em", "i", "u", "s",
    "h1", "h2", "h3", "ul", "ol", "li", "blockquote", "a",
]
ALLOWED_ATTRS = {
    "a": ["href", "target", "rel"],
}
ALLOWED_PROTOCOLS = ["http", "https", "mailto"]


def clean_agreement_html(raw_html):
    """Sanitize rich-text agreement HTML coming from the Quill editor before
    it's stored or rendered. Strips anything outside a small safe allowlist
    (scripts, styles, event handlers, iframes, etc.).

    Notably this excludes <span>: Quill 2.x inserts an empty
    <span class="ql-ui"></span> marker inside list items for its own
    bullet/number UI. It carries no content, but a bare `class` attribute
    isn't in ReportLab's tiny paragraph-markup vocabulary and blows up PDF
    generation later, so it's dropped here rather than stored at all.
    """
    if not raw_html or not raw_html.strip():
        return None
    cleaned = bleach.clean(
        raw_html,
        tags=ALLOWED_TAGS,
        attributes=ALLOWED_ATTRS,
        protocols=ALLOWED_PROTOCOLS,
        strip=True,
    )
    # Quill leaves behind empty "<p><br></p>" for blank lines — collapse a
    # document that's *only* empty paragraphs down to nothing.
    stripped = cleaned.replace("<p><br></p>", "").strip()
    return cleaned if stripped else None
