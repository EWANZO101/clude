"""Shared list of call-out services. Prices are set in the admin area and
stored in Settings (key 'callout_prices' = {label: pence})."""

OTHER_LABEL = "Other (please specify)"

SERVICE_GROUPS = [
    ("Internet & Network Issues", [
        "Slow internet speeds",
        "Slow loading in some parts of the house/building",
        "Internet connection dropping out",
        "Wi-Fi coverage issues",
        "Poor Wi-Fi signal",
        "Device cannot connect to Wi-Fi",
        "General network troubleshooting",
    ]),
    ("Router & Wi-Fi Setup", [
        "New router installation/setup",
        "Router replacement",
        "Wi-Fi optimization",
        "Guest Wi-Fi setup",
        "Mesh Wi-Fi installation",
    ]),
    ("CCTV & Security Systems", [
        "New CCTV system installation",
        "CCTV upgrade",
        "Additional CCTV cameras",
        "CCTV troubleshooting",
        "Remote viewing setup",
    ]),
    ("Cabling & Hardwired Connections", [
        "New network cabling installation",
        "Hardwired internet connection required in a specific room",
        "Extend an existing network cable",
        "Additional Ethernet/network socket required",
        "Home office network connection",
        "Gaming room network connection",
        "Structured cabling installation",
        "Network cabinet/rack setup",
    ]),
    ("Property & Business Networking", [
        "Full home network installation",
        "Office network installation",
        "Network expansion",
        "Network relocation",
        "New property network setup",
    ]),
    ("Other Services", [
        "Network health check",
        "Internet performance review",
        "General advice and consultation",
        OTHER_LABEL,
    ]),
]


def all_labels():
    out = []
    for _grp, opts in SERVICE_GROUPS:
        out.extend(opts)
    return out


def price_display(val):
    """Render a stored price for display. Supports free text ('100-200',
    'From £100', 'POA') and legacy integer pence."""
    if val is None:
        return None
    if isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        return "£{:,.2f}".format(val / 100)
    s = str(val).strip()
    if not s:
        return None
    # bare number/range like "100" or "100-200" -> prefix a single £
    if s[0].isdigit():
        return "£" + s
    return s
