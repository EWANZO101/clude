"""Local OCR (Tesseract, via pytesseract) for reading a motorbike odometer
photo or a fuel pump/receipt photo taken on a phone.

Deliberately conservative: this is reading a photo of a physical display,
not a scanned document, so accuracy varies a lot with lighting, glare and
angle. Every result returned here is meant to pre-fill an editable form
field, never to save anything automatically -- the raw OCR text is always
returned alongside the parsed guess so the person can see what Tesseract
actually read and correct it if it's wrong.
"""
import io
import re

from PIL import Image, ImageOps, ImageFilter
import pytesseract


def _preprocess(image_bytes, upscale_to=1600):
    img = Image.open(io.BytesIO(image_bytes))
    img = ImageOps.exif_transpose(img)
    img = img.convert("L")
    if img.width < upscale_to:
        ratio = upscale_to / img.width
        img = img.resize((upscale_to, int(img.height * ratio)))
    img = ImageOps.autocontrast(img)
    img = img.filter(ImageFilter.SHARPEN)
    return img


def read_odometer(image_bytes):
    img = _preprocess(image_bytes)
    config = "--psm 7 -c tessedit_char_whitelist=0123456789"
    raw_text = pytesseract.image_to_string(img, config=config)

    digit_runs = re.findall(r"\d+", raw_text)
    odometer = max((int(d) for d in digit_runs), default=None) if digit_runs else None

    return {"odometer": odometer, "raw_text": raw_text.strip()}


def read_fillup(image_bytes):
    img = _preprocess(image_bytes)
    config = "--psm 6"
    raw_text = pytesseract.image_to_string(img, config=config)

    cost = None
    cost_match = re.search(r"£\s*(\d+\.\d{2})", raw_text)
    if not cost_match:
        cost_match = re.search(r"(?:total|amount)\D{0,10}(\d+\.\d{2})", raw_text, re.IGNORECASE)
    if cost_match:
        cost = float(cost_match.group(1))

    litres = None
    litres_match = re.search(r"(\d+\.\d{1,3})\s*(?:l\b|ltr|litre)", raw_text, re.IGNORECASE)
    if litres_match:
        litres = float(litres_match.group(1))

    return {"cost": cost, "litres": litres, "raw_text": raw_text.strip()}
