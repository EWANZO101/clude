"""Seed data for common UK retailers/merchants. Not exhaustive — a starting
directory covering the categories called out in the spec (supermarkets,
online retailers, restaurants/takeaways, fuel, streaming/subscriptions,
utilities, transport). Companies House sync (companies_house.py) is the
path to a fuller, maintained company dataset; this seed data is what ships
without any external API access.
"""
from app.extensions import db
from .models import Merchant, MerchantAlias, MerchantCategory

# (display_name, category, merchant_type, aliases, online_only)
SEED_MERCHANTS = [
    ("Tesco", "Groceries", "retailer", ["TESCO", "TESCO STORES", "TESCO STORES LTD", "TESCO.COM", "TESCO EXTRA", "TESCO EXPRESS"], False),
    ("Sainsbury's", "Groceries", "retailer", ["SAINSBURYS", "SAINSBURY'S", "SAINSBURYS SMKT", "SAINSBURYS SUPERMARKET"], False),
    ("ASDA", "Groceries", "retailer", ["ASDA", "ASDA STORES", "ASDA SUPERSTORE"], False),
    ("Aldi", "Groceries", "retailer", ["ALDI", "ALDI STORES"], False),
    ("Lidl", "Groceries", "retailer", ["LIDL", "LIDL GB"], False),
    ("Morrisons", "Groceries", "retailer", ["MORRISONS", "WM MORRISON"], False),
    ("Waitrose", "Groceries", "retailer", ["WAITROSE", "WAITROSE & PARTNERS"], False),
    ("Co-op", "Groceries", "retailer", ["CO-OP", "COOP", "THE CO-OPERATIVE"], False),
    ("Amazon", "Online shopping", "retailer", ["AMAZON", "AMAZON.CO.UK", "AMAZON UK", "AMAZON MKTPLACE", "AMAZON PRIME"], True),
    ("eBay", "Online shopping", "retailer", ["EBAY", "EBAY.CO.UK"], True),
    ("Argos", "Shopping", "retailer", ["ARGOS", "ARGOS LTD"], False),
    ("Next", "Clothing", "retailer", ["NEXT", "NEXT RETAIL"], False),
    ("IKEA", "Home", "retailer", ["IKEA", "IKEA LTD"], False),
    ("McDonald's", "Fast food", "restaurant", ["MCDONALDS", "MCDONALD'S", "MCD "], False),
    ("KFC", "Fast food", "restaurant", ["KFC"], False),
    ("Nando's", "Restaurants", "restaurant", ["NANDOS", "NANDO'S"], False),
    ("Deliveroo", "Delivery", "delivery", ["DELIVEROO"], True),
    ("Just Eat", "Delivery", "delivery", ["JUST EAT", "JUSTEAT"], True),
    ("Uber Eats", "Delivery", "delivery", ["UBER EATS", "UBER *EATS"], True),
    ("Shell", "Fuel", "fuel_station", ["SHELL", "SHELL UK"], False),
    ("BP", "Fuel", "fuel_station", ["BP ", "BP FUEL"], False),
    ("Esso", "Fuel", "fuel_station", ["ESSO"], False),
    ("Netflix", "Streaming", "subscription", ["NETFLIX", "NETFLIX.COM", "NETFLIX COM"], True),
    ("Spotify", "Streaming", "subscription", ["SPOTIFY", "SPOTIFY PREMIUM", "SPOTIFY UK"], True),
    ("Disney+", "Streaming", "subscription", ["DISNEY PLUS", "DISNEY+"], True),
    ("British Gas", "Utilities", "utility", ["BRITISH GAS"], False),
    ("Octopus Energy", "Utilities", "utility", ["OCTOPUS ENERGY"], False),
    ("Thames Water", "Utilities", "utility", ["THAMES WATER"], False),
    ("TfL", "Transport", "transport", ["TFL", "TFL TRAVEL", "TRANSPORT FOR LONDON"], False),
    ("Uber", "Transport", "transport", ["UBER", "UBER *TRIP", "UBER TRIP"], True),
    ("Trainline", "Transport", "transport", ["TRAINLINE", "THETRAINLINE"], True),
    ("Boots", "Pharmacy", "retailer", ["BOOTS", "BOOTS UK"], False),
    ("Superdrug", "Pharmacy", "retailer", ["SUPERDRUG"], False),
]


def seed_merchants():
    if Merchant.query.first():
        return 0

    created = 0
    for display_name, category_name, merchant_type, aliases, online_only in SEED_MERCHANTS:
        category = MerchantCategory.query.filter_by(name=category_name).first()
        if not category:
            category = MerchantCategory(name=category_name)
            db.session.add(category)
            db.session.flush()

        merchant = Merchant(
            display_name=display_name, category_id=category.id, merchant_type=merchant_type,
            logo_initials=display_name[0].upper(), online_only=online_only, data_source="seed",
        )
        db.session.add(merchant)
        db.session.flush()

        for alias in aliases:
            db.session.add(MerchantAlias(merchant_id=merchant.id, alias_text=alias.strip().upper()))
        created += 1

    db.session.commit()
    return created
