"""Fuel module models: vehicles + fuel log entries. Distinct from bank
transactions — a fuel entry is what the user actually put in the tank
(litres, odometer reading) which a bank statement line can never fully
capture. An entry can optionally be linked to a matched finance
transaction / fuel-station merchant for cost auto-fill and to avoid
double counting against bank-derived fuel spending stats (see stats.py).
UK-focused throughout: litres pumped, miles driven, MPG expressed in the
UK-gallon (4.54609 litre) sense — see calculations.py.
"""
from datetime import datetime
from app.extensions import db
from app.core.database.models import gen_uuid


class FuelVehicle(db.Model):
    __tablename__ = "fuel_vehicles"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(120), nullable=False)  # e.g. "My car", "Work van"
    make = db.Column(db.String(80))
    model = db.Column(db.String(80))
    year = db.Column(db.Integer)
    registration = db.Column(db.String(20))
    fuel_type = db.Column(db.String(20), default="petrol")  # petrol, diesel, electric, hybrid, lpg
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    entries = db.relationship("FuelEntry", backref="vehicle", cascade="all, delete-orphan",
                               order_by="FuelEntry.date")


class FuelEntry(db.Model):
    __tablename__ = "fuel_entries"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    vehicle_id = db.Column(db.String(36), db.ForeignKey("fuel_vehicles.id"), nullable=False, index=True)

    date = db.Column(db.Date, nullable=False, index=True)
    odometer = db.Column(db.Integer, nullable=True)  # miles, cumulative reading at time of fill
    litres = db.Column(db.Float, nullable=True)  # null for electric charges (use cost only)
    cost_minor = db.Column(db.Integer, nullable=False, default=0)
    full_tank = db.Column(db.Boolean, default=True)  # MPG calc only trusts full-to-full intervals

    station_merchant_id = db.Column(db.String(36), nullable=True)  # loose ref to merchant module's Merchant.id
    transaction_id = db.Column(db.String(36), nullable=True, index=True)  # loose ref to a finance transaction
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @property
    def price_per_litre_minor(self):
        if not self.litres:
            return None
        return round(self.cost_minor / self.litres)
