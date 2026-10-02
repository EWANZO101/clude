"""Best-effort keyword categorizer for Items/Tools whose `category` is
blank — powers the "Auto-categorize" bulk action on the Items/Tools list
pages. Matches against the category names already in real use on real
kiosk installs (Abrasives & Grinding, Welding Wire & Rods, PPE & Safety,
etc.) rather than inventing new ones, so a guess always lands in a bucket
the business already recognizes.

Deliberately conservative: only ever fills in a *blank* category, never
overwrites one a human already set (enforced by the caller, not here —
see items.py/tools.py's auto_categorize routes), and returns None (leaving
the item alone) rather than force a low-confidence guess. Matching is
whole-word/whole-phrase (via regex word boundaries), not bare substring —
without that, a keyword like "screw" would wrongly claim a "Screwdriver"
for Fasteners instead of Hand Tools.
"""
import re

# Checked top-to-bottom, first match wins — more specific/distinctive
# categories are listed before broader ones so a term that could plausibly
# belong to either lands in the more specific bucket (e.g. "ground clamp"
# hits Electrical before the bare word "clamp" could pull it into Hand
# Tools & Drill Bits).
CATEGORY_KEYWORDS = {
    "Welding Wire & Rods": [
        "welding wire", "mig wire", "tig rod", "welding rod", "flux core",
        "flux-cored", "filler metal", "filler wire", "electrode wire", "spool wire",
    ],
    "Welding Gun & Torch Parts": [
        "contact tip", "gas nozzle", "gas cup", "gun liner", "wire liner",
        "diffuser", "mig gun", "tig torch", "welding gun", "tip holder",
        "nozzle insulator", "torch neck", "torch body",
    ],
    "Gas, Regulators & Torches": [
        "regulator", "gas cylinder", "flowmeter", "flow meter", "argon",
        "acetylene", "oxygen cylinder", "cutting torch", "torch tip",
        "gas hose", "gauge set", "cylinder cart",
    ],
    "Cutting & Gouging": [
        "cutting tip", "gouging", "plasma", "carbon arc", "cutting nozzle",
        "cutting guide", "oxy-fuel", "oxy fuel",
    ],
    "Abrasives & Grinding": [
        "grinding disc", "grinding wheel", "flap disc", "cut-off wheel",
        "cutoff wheel", "cutting disc", "sanding disc", "sandpaper",
        "wire wheel", "wire brush", "abrasive", "sanding belt", "buffing",
        "polishing pad", "grinding stone",
    ],
    "Electrical": [
        "welding cable", "ground clamp", "electrode holder", "cable lug",
        "circuit breaker", "extension cord", "extension lead", "power cable",
        "electrical tape", "wire connector", "terminal block", "fuse",
    ],
    "Fittings, Hose & Pipe": [
        "hose clamp", "pipe fitting", "coupling", "elbow fitting",
        "nipple", "hose", "pipe fitting", "quick connect", "barb fitting",
        "tube fitting", "fitting",
    ],
    "Fasteners": [
        "bolt", "hex nut", "washer", "rivet", "fastener", "anchor bolt",
        "threaded rod", "screw", "wing nut", "lock nut", "cap screw",
    ],
    "Inspection & NDT": [
        "weld gauge", "fillet gauge", "thickness gauge", "dye penetrant",
        "magnetic particle", "ultrasonic", "caliper", "inspection mirror", "ndt",
    ],
    "PPE & Safety": [
        "welding helmet", "safety glasses", "safety goggles", "ear plug",
        "respirator", "welding jacket", "welding glove", "leather glove",
        "face shield", "hard hat", "safety vest", "welding apron", "ppe",
    ],
    "Paint, Coatings & Marking": [
        "spray paint", "primer", "paint pen", "soapstone", "marking crayon",
        "touch-up paint", "coating", "marking chalk",
    ],
    "Lubricants & Fluids": [
        "anti-seize", "anti seize", "penetrating oil", "lubricant", "grease",
        "coolant", "hydraulic fluid", "cutting fluid",
    ],
    "Hand Tools & Drill Bits": [
        "drill bit", "hammer", "wrench", "pliers", "screwdriver", "chisel",
        "hex key", "allen key", "tape measure", "vice grip", "hacksaw",
        "utility knife", "clamp",
    ],
    "General Consumables": [
        "shop rag", "wipe", "degreaser", "cleaner", "solvent", "cloth",
        "masking tape", "duct tape",
    ],
}

_COMPILED = [
    # "s?" before the closing boundary so a plural keyword ("glove" ->
    # "gloves", "shop rag" -> "shop rags") still matches without needing
    # every entry above spelled out twice.
    (category, [re.compile(r"\b" + re.escape(kw) + r"s?\b") for kw in keywords])
    for category, keywords in CATEGORY_KEYWORDS.items()
]


def guess_category(name):
    """Returns the best-guess category for `name`, or None if nothing in
    CATEGORY_KEYWORDS matches (leave it alone rather than force a guess)."""
    if not name:
        return None
    lowered = name.lower()
    for category, patterns in _COMPILED:
        for pattern in patterns:
            if pattern.search(lowered):
                return category
    return None
