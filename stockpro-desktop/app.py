# pip install customtkinter

import customtkinter as ctk
from tkinter import messagebox

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

# =========================================================
# APP
# =========================================================

app = ctk.CTk()
app.title("StockPro - Barcode Scan")
app.geometry("1350x850")
app.minsize(1100, 700)

# =========================================================
# COLORS
# =========================================================

BG = "#08111f"
CARD = "#111e2e"
CARD_2 = "#16263a"

TEXT = "#ffffff"
MUTED = "#9daec2"

BLUE = "#2383ff"
GREEN = "#18c77a"
RED = "#d83b45"
ORANGE = "#f59e0b"

app.configure(fg_color=BG)

# =========================================================
# SAMPLE PRODUCT DATABASE
# Replace this later with MySQL / API lookup
# =========================================================

PRODUCTS = {

    "5060894123457": {
        "name": "Logitech Wireless Mouse",
        "sku": "MOUSE001",
        "barcode": "5060894123457",
        "category": "Computer Accessories",
        "supplier": "Tech Supplies Ltd",
        "warehouse": "Main Warehouse",
        "location": "A-04-02",
        "stock": 48,
        "reserved": 5
    },

    "6009704086407": {
        "name": "HP Keyboard",
        "sku": "KEY001",
        "barcode": "6009704086407",
        "category": "Computer Accessories",
        "supplier": "Office Tech SA",
        "warehouse": "Main Warehouse",
        "location": "A-04-03",
        "stock": 25,
        "reserved": 2
    },

    "9780201379624": {
        "name": "Office Chair",
        "sku": "CHAIR001",
        "barcode": "9780201379624",
        "category": "Office Furniture",
        "supplier": "Office World",
        "warehouse": "Main Warehouse",
        "location": "B-01-01",
        "stock": 12,
        "reserved": 3
    },

    "6001234567890": {
        "name": "A4 Copy Paper",
        "sku": "PAPER001",
        "barcode": "6001234567890",
        "category": "Office Supplies",
        "supplier": "Paper Supplies SA",
        "warehouse": "Main Warehouse",
        "location": "C-02-05",
        "stock": 110,
        "reserved": 20
    },

    "5060951734021": {
        "name": "USB-C Cable",
        "sku": "CABLE001",
        "barcode": "5060951734021",
        "category": "Computer Accessories",
        "supplier": "Tech Supplies Ltd",
        "warehouse": "Main Warehouse",
        "location": "A-05-01",
        "stock": 8,
        "reserved": 1
    }
}

# Currently selected product
current_product = None


# =========================================================
# HELPER FUNCTIONS
# =========================================================

def calculate_available(product):
    return max(
        product["stock"] - product["reserved"],
        0
    )


def get_stock_status(product):

    stock = product["stock"]

    if stock <= 0:
        return "OUT OF STOCK", RED

    elif stock <= 10:
        return "LOW STOCK", ORANGE

    else:
        return "IN STOCK", GREEN


def clear_product_details():
    global current_product

    current_product = None

    product_name.configure(
        text="No Product Scanned"
    )

    product_status.configure(
        text="● WAITING FOR SCAN",
        text_color=MUTED
    )

    sku_value.configure(text="-")
    barcode_value.configure(text="-")
    category_value.configure(text="-")
    supplier_value.configure(text="-")
    warehouse_value.configure(text="-")
    location_value.configure(text="-")

    current_stock_value.configure(text="0")
    reserved_stock_value.configure(text="0")
    available_stock_value.configure(text="0")

    add_button.configure(state="disabled")
    remove_button.configure(state="disabled")
    history_button.configure(state="disabled")


def update_product_details(product):
    global current_product

    current_product = product

    product_name.configure(
        text=product["name"]
    )

    status_text, status_color = get_stock_status(product)

    product_status.configure(
        text=f"● {status_text}",
        text_color=status_color
    )

    sku_value.configure(
        text=product["sku"]
    )

    barcode_value.configure(
        text=product["barcode"]
    )

    category_value.configure(
        text=product["category"]
    )

    supplier_value.configure(
        text=product["supplier"]
    )

    warehouse_value.configure(
        text=product["warehouse"]
    )

    location_value.configure(
        text=product["location"]
    )

    current_stock_value.configure(
        text=str(product["stock"])
    )

    reserved_stock_value.configure(
        text=str(product["reserved"])
    )

    available_stock_value.configure(
        text=str(calculate_available(product))
    )

    barcode_display.configure(
        text=(
            "┌                                      ┐\n\n"
            "        || |||||| || |||| ||||\n\n"
            f"            {product['barcode']}\n\n"
            "└                                      ┘"
        )
    )

    scanner_status.configure(
        text="● Product Found",
        text_color=GREEN
    )

    add_button.configure(state="normal")
    remove_button.configure(state="normal")
    history_button.configure(state="normal")


# =========================================================
# PRODUCT LOOKUP
# =========================================================

def lookup_product(barcode=None):

    if barcode is None:
        barcode = barcode_entry.get()

    barcode = barcode.strip()

    if not barcode:
        scanner_status.configure(
            text="● Enter a barcode",
            text_color=ORANGE
        )

        barcode_entry.focus()
        return

    scanner_status.configure(
        text="● Searching...",
        text_color=BLUE
    )

    product = PRODUCTS.get(barcode)

    if product:

        update_product_details(product)

        barcode_entry.delete(0, "end")

    else:

        clear_product_details()

        product_name.configure(
            text="Product Not Found"
        )

        product_status.configure(
            text="● UNKNOWN BARCODE",
            text_color=RED
        )

        barcode_value.configure(
            text=barcode
        )

        barcode_display.configure(
            text=(
                "┌                                      ┐\n\n"
                "            BARCODE NOT FOUND\n\n"
                f"            {barcode}\n\n"
                "└                                      ┘"
            )
        )

        scanner_status.configure(
            text="● Barcode Not Found",
            text_color=RED
        )

        barcode_entry.delete(0, "end")

    barcode_entry.focus()


# =========================================================
# ENTER / BARCODE SCANNER EVENT
# =========================================================

def barcode_enter_pressed(event=None):
    lookup_product()


# =========================================================
# STOCK ACTIONS
# =========================================================

def add_stock():

    if current_product is None:
        return

    quantity_window(
        "Add Stock",
        GREEN,
        add=True
    )


def remove_stock():

    if current_product is None:
        return

    quantity_window(
        "Remove Stock",
        RED,
        add=False
    )


def quantity_window(title, color, add=True):

    window = ctk.CTkToplevel(app)

    window.title(title)

    window.geometry("420x300")

    window.resizable(False, False)

    window.transient(app)

    window.grab_set()

    ctk.CTkLabel(
        window,
        text=title,
        font=("Arial", 24, "bold")
    ).pack(
        pady=(25, 5)
    )

    ctk.CTkLabel(
        window,
        text=current_product["name"],
        text_color=MUTED,
        font=("Arial", 14)
    ).pack()

    ctk.CTkLabel(
        window,
        text=f"Current Stock: {current_product['stock']}",
        font=("Arial", 15)
    ).pack(
        pady=(15, 5)
    )

    quantity_entry = ctk.CTkEntry(
        window,
        placeholder_text="Enter quantity...",
        height=45,
        justify="center",
        font=("Arial", 16)
    )

    quantity_entry.pack(
        fill="x",
        padx=40,
        pady=10
    )

    quantity_entry.focus()

    def save_quantity():

        try:
            quantity = int(
                quantity_entry.get()
            )

        except ValueError:

            messagebox.showerror(
                "Invalid Quantity",
                "Please enter a valid number."
            )

            return

        if quantity <= 0:

            messagebox.showerror(
                "Invalid Quantity",
                "Quantity must be greater than zero."
            )

            return

        if add:

            current_product["stock"] += quantity

        else:

            if quantity > current_product["stock"]:

                messagebox.showerror(
                    "Insufficient Stock",
                    "You cannot remove more stock than is available."
                )

                return

            current_product["stock"] -= quantity

        update_product_details(
            current_product
        )

        window.destroy()

        barcode_entry.focus()

    ctk.CTkButton(
        window,
        text="Confirm",
        height=48,
        fg_color=color,
        command=save_quantity,
        font=("Arial", 15, "bold")
    ).pack(
        fill="x",
        padx=40,
        pady=15
    )

    quantity_entry.bind(
        "<Return>",
        lambda event: save_quantity()
    )


# =========================================================
# STOCK HISTORY
# =========================================================

def view_history():

    if current_product is None:
        return

    messagebox.showinfo(
        "Stock History",
        f"Stock history for:\n\n"
        f"{current_product['name']}\n\n"
        f"Barcode: {current_product['barcode']}\n"
        f"Current Stock: {current_product['stock']}"
    )


# =========================================================
# NEW SCAN
# =========================================================

def new_scan():

    clear_product_details()

    barcode_display.configure(
        text=(
            "┌                                      ┐\n\n"
            "        SCAN BARCODE HERE\n\n"
            "        || |||||| || |||| ||||\n\n"
            "└                                      ┘"
        )
    )

    scanner_status.configure(
        text="● Scanner Ready",
        text_color=GREEN
    )

    barcode_entry.delete(
        0,
        "end"
    )

    barcode_entry.focus()


# =========================================================
# MAIN LAYOUT
# =========================================================

app.grid_columnconfigure(
    (0, 1),
    weight=1
)

app.grid_rowconfigure(
    2,
    weight=1
)

# =========================================================
# HEADER
# =========================================================

header = ctk.CTkFrame(
    app,
    fg_color="transparent"
)

header.grid(
    row=0,
    column=0,
    columnspan=2,
    sticky="ew",
    padx=35,
    pady=(25, 5)
)

header.grid_columnconfigure(
    0,
    weight=1
)

title = ctk.CTkLabel(
    header,
    text="▥  Barcode Scan",
    font=("Arial", 30, "bold"),
    text_color=TEXT
)

title.grid(
    row=0,
    column=0,
    sticky="w"
)

scanner_status = ctk.CTkLabel(
    header,
    text="● Scanner Ready",
    text_color=GREEN,
    font=("Arial", 14, "bold")
)

scanner_status.grid(
    row=0,
    column=1,
    sticky="e"
)

subtitle = ctk.CTkLabel(
    app,
    text="Scan a barcode to quickly view and manage stock.",
    text_color=MUTED,
    font=("Arial", 14)
)

subtitle.grid(
    row=1,
    column=0,
    columnspan=2,
    sticky="w",
    padx=37,
    pady=(0, 15)
)

# =========================================================
# SCANNER CARD
# =========================================================

scanner_card = ctk.CTkFrame(
    app,
    fg_color=CARD,
    corner_radius=15
)

scanner_card.grid(
    row=2,
    column=0,
    sticky="nsew",
    padx=(35, 12),
    pady=10
)

ctk.CTkLabel(
    scanner_card,
    text="📷  Scan Barcode",
    font=("Arial", 21, "bold")
).pack(
    anchor="w",
    padx=25,
    pady=(22, 10)
)

# =========================================================
# SCANNER AREA
# =========================================================

scan_area = ctk.CTkFrame(
    scanner_card,
    fg_color="#172638",
    corner_radius=12,
    height=370
)

scan_area.pack(
    fill="both",
    expand=True,
    padx=22,
    pady=10
)

scan_area.pack_propagate(False)

barcode_display = ctk.CTkLabel(
    scan_area,
    text=(
        "┌                                      ┐\n\n"
        "        SCAN BARCODE HERE\n\n"
        "        || |||||| || |||| ||||\n\n"
        "└                                      ┘"
    ),
    font=("Consolas", 23, "bold"),
    text_color=TEXT
)

barcode_display.pack(
    expand=True
)

scan_line = ctk.CTkProgressBar(
    scan_area,
    width=380,
    height=4,
    progress_color=BLUE
)

scan_line.place(
    relx=0.5,
    rely=0.55,
    anchor="center"
)

scan_line.set(1)

ctk.CTkLabel(
    scanner_card,
    text="USB barcode scanners can scan directly into the field below.",
    text_color=MUTED,
    font=("Arial", 13)
).pack(
    pady=(3, 10)
)

# =========================================================
# BARCODE INPUT
# =========================================================

barcode_entry = ctk.CTkEntry(
    scanner_card,
    placeholder_text="Scan or enter barcode...",
    height=50,
    font=("Arial", 16)
)

barcode_entry.pack(
    fill="x",
    padx=22,
    pady=(5, 10)
)

barcode_entry.bind(
    "<Return>",
    barcode_enter_pressed
)

scan_button = ctk.CTkButton(
    scanner_card,
    text="Search Barcode",
    height=50,
    fg_color=BLUE,
    font=("Arial", 15, "bold"),
    command=lookup_product
)

scan_button.pack(
    fill="x",
    padx=22,
    pady=(0, 22)
)

# =========================================================
# PRODUCT DETAILS CARD
# =========================================================

product_card = ctk.CTkFrame(
    app,
    fg_color=CARD,
    corner_radius=15
)

product_card.grid(
    row=2,
    column=1,
    sticky="nsew",
    padx=(12, 35),
    pady=10
)

ctk.CTkLabel(
    product_card,
    text="▣  Item Details",
    font=("Arial", 21, "bold")
).pack(
    anchor="w",
    padx=25,
    pady=(22, 10)
)

# =========================================================
# PRODUCT NAME
# =========================================================

product_name = ctk.CTkLabel(
    product_card,
    text="No Product Scanned",
    font=("Arial", 24, "bold")
)

product_name.pack(
    anchor="w",
    padx=25,
    pady=(20, 5)
)

product_status = ctk.CTkLabel(
    product_card,
    text="● WAITING FOR SCAN",
    text_color=MUTED,
    font=("Arial", 13, "bold")
)

product_status.pack(
    anchor="w",
    padx=25,
    pady=(0, 15)
)

# =========================================================
# PRODUCT INFORMATION GRID
# =========================================================

details_frame = ctk.CTkFrame(
    product_card,
    fg_color="transparent"
)

details_frame.pack(
    fill="x",
    padx=25
)


def create_detail_row(row, label):

    ctk.CTkLabel(
        details_frame,
        text=label,
        text_color=MUTED,
        anchor="w",
        width=100
    ).grid(
        row=row,
        column=0,
        sticky="w",
        pady=5
    )

    value = ctk.CTkLabel(
        details_frame,
        text="-",
        anchor="w",
        font=("Arial", 14, "bold")
    )

    value.grid(
        row=row,
        column=1,
        sticky="w",
        pady=5
    )

    return value


sku_value = create_detail_row(
    0,
    "SKU:"
)

barcode_value = create_detail_row(
    1,
    "Barcode:"
)

category_value = create_detail_row(
    2,
    "Category:"
)

supplier_value = create_detail_row(
    3,
    "Supplier:"
)

warehouse_value = create_detail_row(
    4,
    "Warehouse:"
)

location_value = create_detail_row(
    5,
    "Location:"
)

# =========================================================
# STOCK CARDS
# =========================================================

stock_container = ctk.CTkFrame(
    product_card,
    fg_color="transparent"
)

stock_container.pack(
    fill="x",
    padx=20,
    pady=25
)

for column in range(3):
    stock_container.grid_columnconfigure(
        column,
        weight=1
    )


def create_stock_box(column, title_text):

    box = ctk.CTkFrame(
        stock_container,
        fg_color=CARD_2,
        corner_radius=10
    )

    box.grid(
        row=0,
        column=column,
        padx=5,
        sticky="ew"
    )

    ctk.CTkLabel(
        box,
        text=title_text,
        text_color=MUTED,
        font=("Arial", 12)
    ).pack(
        pady=(15, 2)
    )

    value = ctk.CTkLabel(
        box,
        text="0",
        font=("Arial", 28, "bold")
    )

    value.pack(
        pady=(0, 15)
    )

    return value


current_stock_value = create_stock_box(
    0,
    "Current Stock"
)

reserved_stock_value = create_stock_box(
    1,
    "Reserved"
)

available_stock_value = create_stock_box(
    2,
    "Available"
)

# =========================================================
# ACTION BUTTONS
# =========================================================

action_frame = ctk.CTkFrame(
    product_card,
    fg_color="transparent"
)

action_frame.pack(
    fill="x",
    padx=20,
    pady=10
)

add_button = ctk.CTkButton(
    action_frame,
    text="+ Add Stock",
    fg_color=GREEN,
    height=52,
    font=("Arial", 15, "bold"),
    state="disabled",
    command=add_stock
)

add_button.pack(
    side="left",
    expand=True,
    fill="x",
    padx=5
)

remove_button = ctk.CTkButton(
    action_frame,
    text="− Remove Stock",
    fg_color=RED,
    height=52,
    font=("Arial", 15, "bold"),
    state="disabled",
    command=remove_stock
)

remove_button.pack(
    side="left",
    expand=True,
    fill="x",
    padx=5
)

history_button = ctk.CTkButton(
    product_card,
    text="View Stock History",
    fg_color=CARD_2,
    height=48,
    state="disabled",
    command=view_history,
    font=("Arial", 14)
)

history_button.pack(
    fill="x",
    padx=25,
    pady=(10, 10)
)

new_scan_button = ctk.CTkButton(
    product_card,
    text="Scan Next Product",
    fg_color=BLUE,
    height=50,
    command=new_scan,
    font=("Arial", 15, "bold")
)

new_scan_button.pack(
    fill="x",
    padx=25,
    pady=(0, 25)
)

# =========================================================
# STARTUP
# =========================================================

barcode_entry.focus()

app.mainloop()
