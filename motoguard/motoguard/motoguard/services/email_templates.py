"""Reusable, email-client-safe HTML building blocks styled after Flowbite.

Email clients strip <style>/classes and don't run JS, so everything here is
inline-styled and table-based to render consistently in Gmail, Outlook, Apple
Mail, etc. Light body for readability, dark header with the plate-yellow accent.
"""
from html import escape

ASPHALT = "#0E1216"
PLATE = "#F5C518"
RED = "#FF453A"
GREEN = "#30D158"
FONT = ("-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,"
        "sans-serif")


def shell(badge, body_html, accent=PLATE, preheader=""):
    """Wrap body content in the branded responsive email frame."""
    return f"""\
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"></head>
<body style="margin:0;padding:0;background:#eef2f6;">
<span style="display:none!important;visibility:hidden;opacity:0;height:0;width:0;overflow:hidden;">{escape(preheader)}</span>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2f6;padding:24px 12px;">
<tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border:1px solid #e3e8ef;border-radius:16px;overflow:hidden;font-family:{FONT};">
  <tr><td style="background:{ASPHALT};padding:20px 28px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
      <td style="font-weight:800;font-size:20px;color:#ffffff;letter-spacing:-.3px;">Moto<span style="color:{PLATE};">Guard</span></td>
      <td align="right"><span style="display:inline-block;background:{accent};color:{ASPHALT};font-weight:700;font-size:11px;padding:5px 11px;border-radius:999px;text-transform:uppercase;letter-spacing:.6px;">{escape(badge)}</span></td>
    </tr></table>
  </td></tr>
  <tr><td style="padding:28px;color:#0f172a;font-size:15px;line-height:1.6;">{body_html}</td></tr>
  <tr><td style="padding:18px 28px;background:#f7f9fb;border-top:1px solid #e7ebf0;color:#94a3b8;font-size:12px;line-height:1.55;">
    MotoGuard &middot; community motorcycle theft recovery.<br>
    You're receiving this because you have a MotoGuard account.
  </td></tr>
</table>
</td></tr></table>
</body></html>"""


def heading(text):
    return (f'<h1 style="margin:0 0 12px;font-size:21px;line-height:1.3;'
            f'font-weight:800;color:#0f172a;">{escape(text)}</h1>')


def paragraph(text, color="#334155"):
    return f'<p style="margin:0 0 16px;color:{color};">{escape(text)}</p>'


def button(label, url, accent=PLATE, text_color=ASPHALT):
    """Bulletproof CTA button. The URL lives only in the href — never shown."""
    return (
        '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:6px 0 20px;">'
        f'<tr><td align="center" bgcolor="{accent}" style="border-radius:10px;">'
        f'<a href="{url}" target="_blank" style="display:inline-block;padding:13px 28px;'
        f'font-size:15px;font-weight:700;color:{text_color};text-decoration:none;'
        f'border-radius:10px;">{escape(label)}</a></td></tr></table>')


def button_row(buttons):
    """buttons: list of (label, url, accent, text_color)."""
    cells = ""
    for label, url, accent, tc in buttons:
        cells += (
            f'<td style="padding-right:10px;"><table role="presentation" cellpadding="0" cellspacing="0">'
            f'<tr><td bgcolor="{accent}" style="border-radius:10px;">'
            f'<a href="{url}" target="_blank" style="display:inline-block;padding:12px 22px;'
            f'font-size:14px;font-weight:700;color:{tc};text-decoration:none;border-radius:10px;">'
            f'{escape(label)}</a></td></tr></table></td>')
    return f'<table role="presentation" cellpadding="0" cellspacing="0" style="margin:6px 0 20px;"><tr>{cells}</tr></table>'


def detail_table(pairs):
    """pairs: list of (label, value). Falsy values are skipped."""
    rows = ""
    for k, v in pairs:
        if not v:
            continue
        rows += (
            f'<tr><td style="padding:8px 16px 8px 0;color:#64748b;font-size:13px;'
            f'white-space:nowrap;vertical-align:top;border-bottom:1px solid #eef2f6;">{escape(str(k))}</td>'
            f'<td style="padding:8px 0;color:#0f172a;font-size:14px;font-weight:600;'
            f'border-bottom:1px solid #eef2f6;">{escape(str(v))}</td></tr>')
    return (
        '<table role="presentation" cellpadding="0" cellspacing="0" '
        'style="width:100%;border-collapse:collapse;background:#f8fafc;border:1px solid #e7ebf0;'
        'border-radius:12px;padding:6px 16px;margin:4px 0 20px;">'
        f'{rows}</table>')


def photo(url):
    return (f'<img src="{url}" alt="bike" width="544" '
            f'style="display:block;width:100%;max-width:544px;height:auto;'
            f'border-radius:12px;margin:0 0 20px;border:1px solid #e7ebf0;">')


def copy_box(text, label="Tap and hold (mobile) or triple-click (desktop) to select, then copy"):
    """Dark monospace box that's easy to read and select for copy-paste."""
    return (
        f'<p style="margin:0 0 8px;color:#64748b;font-size:12px;">{escape(label)}</p>'
        '<div style="background:#0E1216;border:1px solid #283038;border-radius:12px;padding:18px 20px;margin:0 0 20px;">'
        '<pre style="margin:0;white-space:pre-wrap;word-break:break-word;'
        "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace;"
        f'font-size:13px;line-height:1.6;color:#E8ECF1;">{escape(text)}</pre></div>')
