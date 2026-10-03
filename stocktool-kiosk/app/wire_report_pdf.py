"""
Welding wire PDF report generation (spec items 11, 12, 14, 15). Takes
the dict produced by routes_wire.py's _build_report() and lays it out
as a PDF: one row per transaction with everything the spec asks for
(user, project, wire info, weights, dates/times), followed by total
sections (overall / by project / by user / by wire type/code / by
coil), so the admin never has to add anything up by hand.
"""
from datetime import datetime
from io import BytesIO
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle


def _fmt_dt(iso_str):
    if not iso_str:
        return ""
    try:
        dt = datetime.fromisoformat(iso_str)
        return dt.strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return iso_str


def build_wire_report_pdf(report: dict) -> bytes:
    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=landscape(A4),
        leftMargin=14 * mm, rightMargin=14 * mm, topMargin=14 * mm, bottomMargin=14 * mm,
    )
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle("WireTitle", parent=styles["Title"], fontSize=16, spaceAfter=2)
    subtitle_style = ParagraphStyle("WireSubtitle", parent=styles["Normal"], textColor=colors.grey,
                                     fontSize=9, spaceAfter=12)
    section_style = ParagraphStyle("WireSection", parent=styles["Heading2"], fontSize=12,
                                    spaceBefore=14, spaceAfter=6)

    elements = [Paragraph("Welding Wire Usage Report", title_style)]

    date_range = "All dates"
    if report["date_from"] or report["date_to"]:
        date_range = f"{report['date_from'] or 'start'} to {report['date_to'] or 'now'}"
    elements.append(Paragraph(
        f"Date range: {date_range} &nbsp;&nbsp;|&nbsp;&nbsp; "
        f"Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M')} UTC &nbsp;&nbsp;|&nbsp;&nbsp; "
        f"{report['transaction_count']} transaction(s)",
        subtitle_style,
    ))

    # ── Transaction detail table ────────────────────────────────────
    headers = ["User", "Project", "Wire / Coil", "Wire Code/Type",
               "Start (kg)", "Finish (kg)", "Used (kg)", "Checked Out", "Checked In"]
    rows = [headers]
    for t in report["transactions"]:
        rows.append([
            t["user_name"] or "", t["project"] or "",
            t["coil_reference"] or t["coil_name"] or f"#{t['coil_id']}",
            t["wire_code_name"] or "",
            f"{t['starting_weight']:.2f}" if t["starting_weight"] is not None else "",
            f"{t['finishing_weight']:.2f}" if t["finishing_weight"] is not None else "",
            f"{t['consumed']:.2f}" if t["consumed"] is not None else "",
            _fmt_dt(t["checked_out_at"]), _fmt_dt(t["checked_in_at"]),
        ])
    if len(rows) == 1:
        rows.append(["No transactions in this date range.", "", "", "", "", "", "", "", ""])

    table = Table(rows, repeatRows=1, colWidths=[28*mm, 30*mm, 28*mm, 26*mm, 20*mm, 20*mm, 20*mm, 28*mm, 28*mm])
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#2b2f38")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 8),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f2f2f2")]),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#cccccc")),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (4, 1), (6, -1), "RIGHT"),
    ]))
    elements.append(table)

    # ── Totals ───────────────────────────────────────────────────────
    elements.append(Paragraph(f"Total Welding Weight: {report['total_used']:.2f} kg", section_style))

    def _totals_table(title, group_rows):
        elements.append(Paragraph(title, section_style))
        if not group_rows:
            elements.append(Paragraph("No data.", styles["Normal"]))
            return
        data = [["", "Total Used (kg)"]] + [[g["label"], f"{g['total_used']:.2f}"] for g in group_rows]
        t = Table(data, colWidths=[80*mm, 40*mm])
        t.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e5e5e5")),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("FONTSIZE", (0, 0), (-1, -1), 9),
            ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#cccccc")),
            ("ALIGN", (1, 0), (1, -1), "RIGHT"),
        ]))
        elements.append(t)
        elements.append(Spacer(1, 4 * mm))

    _totals_table("By Project", report["by_project"])
    _totals_table("By User", report["by_user"])
    _totals_table("By Wire Code/Type", report["by_wire_code"])
    _totals_table("By Individual Coil", report["by_coil"])

    doc.build(elements)
    return buf.getvalue()
