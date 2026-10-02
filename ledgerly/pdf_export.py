import io
import os
import re
from datetime import date

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.platypus import (
    SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer, Image
)
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

from currencies import get_currency

_BLOCK_RE = re.compile(
    r"<(h1|h2|h3|p|blockquote)>(.*?)</\1>|<(ul|ol)>(.*?)</\3>", re.S | re.I
)
_LI_RE = re.compile(r"<li>(.*?)</li>", re.S | re.I)

DEFAULT_BG = "#0B1F3A"
DEFAULT_ACCENT = "#B08D3E"


# ---------------------------------------------------------------- theming --

def _hex_to_rgb(hex_color):
    h = (hex_color or "").lstrip("#")
    if len(h) != 6:
        h = "0B1F3A"
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _luminance(hex_color):
    r, g, b = _hex_to_rgb(hex_color)
    return 0.299 * r + 0.587 * g + 0.114 * b


def _blend(hex_a, hex_b, t):
    """Linear-interpolate between two hex colors; t=0 -> a, t=1 -> b."""
    ra, ga, ba = _hex_to_rgb(hex_a)
    rb, gb, bb = _hex_to_rgb(hex_b)
    r = round(ra + (rb - ra) * t)
    g = round(ga + (gb - ga) * t)
    b = round(ba + (bb - ba) * t)
    return colors.Color(r / 255, g / 255, b / 255)


def build_theme(company):
    """Derive a full set of PDF colors from a company's branding settings.
    Text/muted/line colors are computed for contrast against whatever
    background color the company picked, so light or dark brand colors
    both stay legible without per-company manual tuning."""
    bg_hex = (company.brand_bg_color if company else None) or DEFAULT_BG
    accent_hex = (company.brand_accent_color if company else None) or DEFAULT_ACCENT

    dark_bg = _luminance(bg_hex) < 140
    contrast_hex = "#FFFFFF" if dark_bg else "#141414"

    return {
        "bg": colors.HexColor(bg_hex),
        "accent": colors.HexColor(accent_hex),
        "ink": _blend(bg_hex, contrast_hex, 0.94),
        "muted": _blend(bg_hex, contrast_hex, 0.55),
        "line": _blend(bg_hex, contrast_hex, 0.22),
        "row_alt": _blend(bg_hex, contrast_hex, 0.06),
        "header_bg": _blend(bg_hex, contrast_hex, 0.14),
        "dark_bg": dark_bg,
    }


# ------------------------------------------------------- agreement content -

def _inline_to_reportlab(html_fragment):
    """Map the sanitized inline tags we allow onto ReportLab's mini markup."""
    text = html_fragment
    # Defensive: strip any <span> markup that slipped in from an agreement
    # saved before span was excluded from the sanitizer allowlist (notably
    # Quill's own <span class="ql-ui"></span> list-marker elements, which
    # ReportLab's paragraph parser rejects outright because of the bare
    # `class` attribute).
    text = re.sub(r"</?span[^>]*>", "", text, flags=re.I)
    text = re.sub(r"</?strong>", lambda m: "</b>" if m.group(0).startswith("</") else "<b>", text, flags=re.I)
    text = re.sub(r"</?em>", lambda m: "</i>" if m.group(0).startswith("</") else "<i>", text, flags=re.I)
    text = text.replace("<br>", "<br/>").replace("<br/>", "<br/>\n")
    return text.strip()


def agreement_flowables(agreement_text, styles, theme):
    """Turn stored agreement content (rich HTML, or legacy plain text with
    blank-line paragraphs) into a list of ReportLab flowables."""
    body_style = ParagraphStyle("AgreeBody", parent=styles["Normal"], textColor=theme["ink"], fontSize=10, leading=15, spaceAfter=8)
    h_style = ParagraphStyle("AgreeH", parent=styles["Normal"], textColor=theme["ink"], fontSize=13, leading=17, fontName="Helvetica-Bold", spaceBefore=10, spaceAfter=6)
    quote_style = ParagraphStyle("AgreeQuote", parent=body_style, leftIndent=14, textColor=theme["muted"], fontName="Helvetica-Oblique")
    li_style = ParagraphStyle("AgreeLi", parent=body_style, leftIndent=14, spaceAfter=4)

    elems = []
    blocks = list(_BLOCK_RE.finditer(agreement_text or ""))

    if not blocks:
        # Legacy plain-text content (pre rich-text editor): blank-line paragraphs.
        for para in (agreement_text or "").strip().split("\n\n"):
            if not para.strip():
                continue
            safe = para.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br/>")
            elems.append(Paragraph(safe, body_style))
        return elems

    for m in blocks:
        tag, inner, list_tag, list_inner = m.group(1), m.group(2), m.group(3), m.group(4)
        if tag:
            content = _inline_to_reportlab(inner)
            if not content:
                continue
            if tag.lower() in ("h1", "h2", "h3"):
                elems.append(Paragraph(content, h_style))
            elif tag.lower() == "blockquote":
                elems.append(Paragraph(content, quote_style))
            else:
                elems.append(Paragraph(content, body_style))
        elif list_tag:
            items = _LI_RE.findall(list_inner)
            for i, item in enumerate(items, start=1):
                bullet = "•" if list_tag.lower() == "ul" else f"{i}."
                elems.append(Paragraph(f"{bullet}&nbsp;&nbsp;{_inline_to_reportlab(item)}", li_style))
    return elems


def money(amount, code):
    cur = get_currency(code)
    symbol = cur["symbol"] if cur else code
    return f"{symbol}{float(amount):,.2f}"


# --------------------------------------------------------------- PDF build -

def build_contract_pdf(contract, upload_folder=None):
    company = contract.company
    theme = build_theme(company)
    display_name = (company.brand_display_name if company else None) or (company.name if company else "Ledgerly")

    logo_path = None
    if company and company.brand_logo_filename and upload_folder:
        candidate = os.path.join(upload_folder, company.brand_logo_filename)
        if os.path.isfile(candidate):
            logo_path = candidate

    buf = io.BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        topMargin=24 * mm, bottomMargin=18 * mm,
        leftMargin=20 * mm, rightMargin=20 * mm,
    )
    styles = getSampleStyleSheet()

    title_style = ParagraphStyle(
        "Title", parent=styles["Title"], textColor=theme["ink"], fontSize=22, spaceAfter=2, leading=26,
    )
    eyebrow_style = ParagraphStyle(
        "Eyebrow", parent=styles["Normal"], textColor=theme["accent"], fontSize=10,
        spaceAfter=14, fontName="Helvetica-Bold",
    )
    brand_style = ParagraphStyle(
        "Brand", parent=styles["Normal"], textColor=theme["accent"], fontSize=15,
        fontName="Helvetica-Bold", spaceAfter=16,
    )
    label_style = ParagraphStyle("Label", parent=styles["Normal"], textColor=theme["muted"], fontSize=9)
    value_style = ParagraphStyle("Value", parent=styles["Normal"], textColor=theme["ink"], fontSize=12)

    def page_background(canvas_obj, doc_obj):
        canvas_obj.saveState()
        canvas_obj.setFillColor(theme["bg"])
        canvas_obj.rect(0, 0, doc_obj.pagesize[0], doc_obj.pagesize[1], fill=1, stroke=0)
        canvas_obj.restoreState()

    elems = []

    if logo_path:
        try:
            img = Image(logo_path)
            max_w, max_h = 44 * mm, 16 * mm
            ratio = min(max_w / img.imageWidth, max_h / img.imageHeight, 1)
            img.drawWidth = img.imageWidth * ratio
            img.drawHeight = img.imageHeight * ratio
            img.hAlign = "LEFT"
            elems.append(img)
            elems.append(Spacer(1, 10))
        except Exception:
            elems.append(Paragraph(display_name, brand_style))
    else:
        elems.append(Paragraph(display_name, brand_style))

    elems.append(Paragraph("PAYMENT SCHEDULE", eyebrow_style))
    elems.append(Paragraph(contract.title, title_style))
    elems.append(Paragraph(f"Client: {contract.client.name}", value_style))
    elems.append(Spacer(1, 14))

    summary_data = [
        ["Total contract value", money(contract.total_amount, contract.currency_code)],
        ["Currency", f"{contract.currency_code}"],
        ["Amount paid", money(contract.amount_paid, contract.currency_code)],
        ["Remaining balance", money(contract.amount_remaining, contract.currency_code)],
        ["Status", contract.status.upper()],
    ]
    t = Table(summary_data, colWidths=[70 * mm, 90 * mm])
    t.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (0, -1), "Helvetica"),
        ("FONTNAME", (1, 0), (1, -1), "Helvetica-Bold"),
        ("TEXTCOLOR", (0, 0), (0, -1), theme["muted"]),
        ("TEXTCOLOR", (1, 0), (1, -1), theme["ink"]),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("LINEBELOW", (0, 0), (-1, -2), 0.5, theme["line"]),
    ]))
    elems.append(t)
    elems.append(Spacer(1, 22))

    elems.append(Paragraph("INSTALMENTS", eyebrow_style))
    if contract.schedule:
        rows = [["#", "Date", "Description", "Amount", "Status"]]
        for p in contract.schedule.payments:
            rows.append([
                str(p.sequence),
                p.due_date.strftime("%-d %B %Y") if hasattr(p.due_date, "strftime") else str(p.due_date),
                p.label or "Instalment",
                money(p.amount, contract.currency_code),
                p.status.capitalize(),
            ])
        pt = Table(rows, colWidths=[10 * mm, 38 * mm, 45 * mm, 32 * mm, 25 * mm], repeatRows=1)
        pt.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), theme["header_bg"]),
            ("TEXTCOLOR", (0, 0), (-1, 0), theme["ink"]),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("FONTSIZE", (0, 0), (-1, -1), 9.5),
            ("TEXTCOLOR", (0, 1), (-1, -1), theme["ink"]),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.transparent, theme["row_alt"]]),
            ("GRID", (0, 0), (-1, -1), 0.4, theme["line"]),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ("ALIGN", (3, 0), (3, -1), "RIGHT"),
        ]))
        elems.append(pt)
    else:
        elems.append(Paragraph("No payment schedule has been created for this contract yet.", value_style))

    if contract.agreement_text and contract.agreement_text.strip():
        elems.append(Spacer(1, 24))
        elems.append(Paragraph("AGREEMENT", eyebrow_style))
        elems.extend(agreement_flowables(contract.agreement_text, styles, theme))

    elems.append(Spacer(1, 18))
    elems.append(Paragraph("SIGNATURE", eyebrow_style))
    if contract.is_signed:
        sig_style = ParagraphStyle("Sig", parent=styles["Normal"], textColor=theme["ink"], fontSize=14, fontName="Helvetica-Oblique")
        elems.append(Paragraph(contract.signature_text or contract.signed_by_name, sig_style))
        elems.append(Paragraph(
            f"Signed by {contract.signed_by_name} on {contract.signed_at.strftime('%-d %B %Y')}",
            ParagraphStyle("SigMeta", parent=styles["Normal"], textColor=theme["muted"], fontSize=9),
        ))
    else:
        elems.append(Paragraph(
            "Not yet signed. &nbsp;&nbsp;&nbsp; Signature: ______________________  &nbsp;&nbsp; Date: ____________",
            value_style,
        ))

    elems.append(Spacer(1, 24))
    elems.append(Paragraph(
        f"Generated via Ledgerly on {date.today().strftime('%-d %B %Y')}.",
        ParagraphStyle("Footer", parent=styles["Normal"], textColor=theme["muted"], fontSize=8),
    ))

    doc.build(elems, onFirstPage=page_background, onLaterPages=page_background)
    buf.seek(0)
    return buf
