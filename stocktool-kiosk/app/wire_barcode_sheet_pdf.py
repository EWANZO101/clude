"""
Printable PDF sheet of individual barcodes for a batch of welding-wire
boxes (bulk 'Add Welding Wire' -> "print individual barcodes?" popup).

Built directly with reportlab's own Code128 renderer (reportlab.graphics.
barcode) rather than app/barcode_render.py's SVG output, so there's no
SVG-to-PDF conversion step and no extra dependency (this project is
offline-first and bundled by PyInstaller -- see barcode_render.py's
docstring for why that matters here too).

Layout: a simple grid of labels, several per page, each with the
Code128 barcode, the human-readable code underneath, and the box's
name/weight if it has one -- enough to identify one physical box
without needing to scan it first.
"""
from io import BytesIO

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.graphics.barcode.code128 import Code128
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

_COLS = 3
_LABEL_W = 60 * mm
_LABEL_H = 34 * mm


def _label_flowable(coil: dict, code_style, meta_style):
    code = coil.get("barcode_code") or ""
    barcode = Code128(code, barHeight=12 * mm, barWidth=0.35 * mm, humanReadable=False)
    barcode.hAlign = "CENTER"

    label_text = coil.get("name") or "Welding wire"
    weight = coil.get("initial_weight")
    meta = f"{label_text} — {weight:.2f}kg" if isinstance(weight, (int, float)) else label_text

    rows = [
        [barcode],
        [Paragraph(code, code_style)],
        [Paragraph(meta, meta_style)],
    ]
    t = Table(rows, colWidths=[_LABEL_W])
    t.setStyle(TableStyle([
        ("ALIGN", (0, 0), (-1, -1), "CENTER"),
        ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#999999")),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return t


def build_wire_barcode_sheet_pdf(coils: list) -> bytes:
    """coils: list of coil dicts (WireCoil.to_dict() output) -- one
    label is produced per coil, in the order given."""
    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        leftMargin=12 * mm, rightMargin=12 * mm, topMargin=14 * mm, bottomMargin=14 * mm,
    )
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle("SheetTitle", parent=styles["Title"], fontSize=14, spaceAfter=10)
    code_style = ParagraphStyle("Code", parent=styles["Normal"], fontSize=9,
                                 fontName="Helvetica-Bold", alignment=1)
    meta_style = ParagraphStyle("Meta", parent=styles["Normal"], fontSize=7.5,
                                 textColor=colors.grey, alignment=1)

    elements = [Paragraph(f"Welding Wire Barcodes — {len(coils)} box(es)", title_style)]

    labels = [_label_flowable(c, code_style, meta_style) for c in coils]
    grid_rows = []
    for i in range(0, len(labels), _COLS):
        row = labels[i:i + _COLS]
        while len(row) < _COLS:
            row.append("")
        grid_rows.append(row)

    if grid_rows:
        grid = Table(grid_rows, colWidths=[_LABEL_W + 4 * mm] * _COLS)
        grid.setStyle(TableStyle([
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("TOPPADDING", (0, 0), (-1, -1), 4),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ]))
        elements.append(grid)
    else:
        elements.append(Paragraph("No boxes to print.", styles["Normal"]))
        elements.append(Spacer(1, 4 * mm))

    doc.build(elements)
    return buf.getvalue()
