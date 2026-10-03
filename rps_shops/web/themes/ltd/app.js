const $ = (id) => document.getElementById(id);

const app = $('app');
const categoriesEl = $('categories');
const productsEl = $('products');
const emptyState = $('empty-state');
const categoryTitle = $('category-title');
const resultCount = $('result-count');
const searchInput = $('search');

const cartItemsEl = $('cart-items');
const cartEmpty = $('cart-empty');
const cartCount = $('cart-count');
const summaryItems = $('summary-items');
const summarySaved = $('summary-saved');
const summaryTotal = $('summary-total');
const purchaseButton = $('purchase-button');
const purchaseMessage = $('purchase-message');
const paymentLabel = $('payment-label');

const shopName = $('shop-name');
const tagline = $('tagline');
const footerText = $('footer-text');
const receiptStore = $('receipt-store');
const receiptTime = $('receipt-time');
const clockEl = $('clock');
const fuelBoard = $('fuel-board');
const fuelRows = $('fuel-rows');

// This theme runs inside the rps_shops loader frame (web/index.html), so the
// resource name comes from the parent page when it isn't defined here.
const RESOURCE_NAME = (() => {
    try {
        if (typeof GetParentResourceName === 'function') return GetParentResourceName();
        if (window.parent !== window && typeof window.parent.GetParentResourceName === 'function') {
            return window.parent.GetParentResourceName();
        }
    } catch (error) { /* not in game */ }
    return null;
})();

const IN_GAME = !!RESOURCE_NAME;

let store = {
    open: false,
    shopId: null,
    currencySymbol: '$',
    currencyLabel: 'Cash',
    categories: [],
    products: [],
    activeCategory: 'all',
    search: '',
    showImages: true,
    cart: new Map()
};

let clockTimer = null;
let lastScanned = null;

function nui(endpoint, payload = {}) {
    if (!IN_GAME) return Promise.resolve(previewResponse(endpoint, payload));

    return fetch(`https://${RESOURCE_NAME}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(payload)
    }).then((response) => response.json());
}

function esc(value) {
    return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function money(value) {
    return `${store.currencySymbol}${Number(value || 0).toLocaleString()}`;
}

function getProduct(id) {
    return store.products.find((product) => product.id === id);
}

function getCategory(id) {
    return store.categories.find((entry) => entry.id === id);
}

function categoryLabel(id) {
    const category = getCategory(id);
    return category ? category.label : id;
}

function categoryEmoji(id) {
    const category = getCategory(id);
    return (category && category.emoji) || '🛒';
}

function availableStock(product) {
    if (product.unlimitedStock) return Infinity;
    return Number(product.stock || 0);
}

function cartQuantity(id) {
    return store.cart.get(id) || 0;
}

function maxAllowed(product) {
    const perPurchase = Number(product.maxPerPurchase || 1);
    const stock = availableStock(product);
    return stock === Infinity ? perPurchase : Math.min(perPurchase, stock);
}

function setMessage(message = '', type = '') {
    purchaseMessage.textContent = message;
    purchaseMessage.className = `purchase-message ${type}`;
}

function filteredProducts() {
    const query = store.search.trim().toLowerCase();

    return store.products.filter((product) => {
        if (store.activeCategory !== 'all' && product.category !== store.activeCategory) {
            return false;
        }

        if (!query) return true;

        return (
            product.label.toLowerCase().includes(query)
            || (product.description || '').toLowerCase().includes(query)
            || product.item.toLowerCase().includes(query)
        );
    });
}

function imageMarkup(product) {
    const emoji = categoryEmoji(product.category);

    if (!store.showImages || !product.image) {
        return `<span class="image-fallback" style="display:block">${emoji}</span>`;
    }

    return `
        <img src="${esc(product.image)}" alt="${esc(product.label)}"
             onerror="this.style.display='none';this.nextElementSibling.style.display='block';">
        <span class="image-fallback">${emoji}</span>
    `;
}

function renderFuelBoard(rows) {
    const list = Array.isArray(rows) ? rows : [];

    fuelBoard.classList.toggle('hidden', list.length === 0);

    fuelRows.innerHTML = list.map((row) => `
        <div class="fuel-row">
            <span>${esc(row.label)}</span>
            <b>${esc(row.price)}<sup>9</sup></b>
        </div>
    `).join('');
}

function renderCategories() {
    const counts = {};
    for (const product of store.products) {
        counts[product.category] = (counts[product.category] || 0) + 1;
    }

    const entries = [
        { id: 'all', label: 'All Products', icon: 'store' },
        ...store.categories.filter((category) => counts[category.id])
    ];

    categoriesEl.innerHTML = entries.map((category) => `
        <button class="category ${store.activeCategory === category.id ? 'active' : ''}"
                data-category="${esc(category.id)}" type="button">
            <span class="cat-icon"><i class="fa-solid fa-${esc(category.icon || 'tag')}"></i></span>
            <span class="cat-label">${esc(category.label)}</span>
            <span class="cat-count">${category.id === 'all' ? store.products.length : counts[category.id]}</span>
        </button>
    `).join('');

    categoriesEl.querySelectorAll('.category').forEach((button) => {
        button.onclick = () => {
            store.activeCategory = button.dataset.category;
            renderCategories();
            renderProducts();
        };
    });
}

function renderProducts() {
    const products = filteredProducts();

    categoryTitle.textContent =
        store.activeCategory === 'all' ? 'All Products' : categoryLabel(store.activeCategory);

    resultCount.textContent = `${products.length} product${products.length === 1 ? '' : 's'}`;

    productsEl.innerHTML = products.map((product) => {
        const stock = availableStock(product);
        const inCart = cartQuantity(product.id);
        const remaining = stock === Infinity ? Infinity : stock - inCart;
        const soldOut = stock <= 0;
        const atLimit = !soldOut && (remaining <= 0 || inCart >= maxAllowed(product));
        const lowStock = stock !== Infinity && stock > 0 && stock <= 5;

        const stockLabel =
            stock === Infinity ? 'IN STOCK'
                : stock <= 0 ? 'SOLD OUT'
                    : `${stock} LEFT`;

        return `
            <article class="product-card ${inCart ? 'in-cart' : ''} ${soldOut ? 'sold-out' : ''}">
                <div class="product-media">
                    ${imageMarkup(product)}
                    ${product.onSale ? '<span class="sale-badge">HOT DEAL</span>' : ''}
                    <span class="stock-badge ${lowStock || soldOut ? 'low' : ''}">${stockLabel}</span>
                    ${inCart ? `<span class="qty-bubble">×${inCart} in basket</span>` : ''}
                </div>

                <div class="product-copy">
                    <span class="product-category">${esc(categoryLabel(product.category))}</span>
                    <h3>${esc(product.label)}</h3>
                    <p>${esc(product.description)}</p>
                </div>

                <div class="product-bottom">
                    <div class="price ${product.onSale ? 'on-sale' : ''}">
                        <strong>${money(product.price)}</strong>
                        ${product.onSale ? `<del>${money(product.originalPrice)}</del>` : ''}
                    </div>

                    <button class="add-button" data-add="${esc(product.id)}" type="button"
                            ${soldOut || atLimit ? 'disabled' : ''}>
                        ${soldOut
                            ? 'SOLD OUT'
                            : atLimit
                                ? 'LIMIT'
                                : '<i class="fa-solid fa-plus"></i> ADD'}
                    </button>
                </div>
            </article>
        `;
    }).join('');

    emptyState.classList.toggle('hidden', products.length !== 0);

    productsEl.querySelectorAll('[data-add]').forEach((button) => {
        button.onclick = () => addToCart(button.dataset.add);
    });
}

function addToCart(id) {
    const product = getProduct(id);
    if (!product) return;

    const current = cartQuantity(id);
    const stock = availableStock(product);

    if (current >= maxAllowed(product)) {
        setMessage(
            stock !== Infinity && current >= stock
                ? 'No more stock on the shelf.'
                : `Limit ${product.maxPerPurchase || 1} per customer.`,
            'error'
        );
        return;
    }

    store.cart.set(id, current + 1);
    lastScanned = id;
    setMessage();
    renderAll();
}

function updateQuantity(id, delta) {
    const product = getProduct(id);
    if (!product) return;

    const next = cartQuantity(id) + delta;

    if (next <= 0) {
        store.cart.delete(id);
    } else if (next <= maxAllowed(product)) {
        store.cart.set(id, next);
        if (delta > 0) lastScanned = id;
    }

    setMessage();
    renderAll();
}

function removeFromCart(id) {
    store.cart.delete(id);
    setMessage();
    renderAll();
}

function cartTotals() {
    let items = 0;
    let total = 0;
    let saved = 0;

    for (const [id, quantity] of store.cart.entries()) {
        const product = getProduct(id);
        if (!product) continue;

        items += quantity;
        total += Number(product.price) * quantity;

        if (product.onSale) {
            saved += (Number(product.originalPrice) - Number(product.price)) * quantity;
        }
    }

    return { items, total, saved: Math.max(0, saved) };
}

function renderCart() {
    const entries = [...store.cart.entries()]
        .map(([id, quantity]) => ({ product: getProduct(id), quantity }))
        .filter((entry) => entry.product);

    cartItemsEl.innerHTML = entries.map(({ product, quantity }) => `
        <div class="cart-item ${product.id === lastScanned ? 'scanned' : ''}">
            <span class="line-name">${esc(product.label)}</span>
            <span class="line-total">${money(product.price * quantity)}</span>
            <span class="line-meta">${quantity} @ ${money(product.price)}</span>
            <span class="line-actions">
                <button data-minus="${esc(product.id)}" type="button"><i class="fa-solid fa-minus"></i></button>
                <button data-plus="${esc(product.id)}" type="button"><i class="fa-solid fa-plus"></i></button>
                <button class="remove" data-remove="${esc(product.id)}" type="button"><i class="fa-solid fa-xmark"></i></button>
            </span>
        </div>
    `).join('');

    lastScanned = null;

    cartItemsEl.querySelectorAll('[data-minus]').forEach((button) => {
        button.onclick = () => updateQuantity(button.dataset.minus, -1);
    });

    cartItemsEl.querySelectorAll('[data-plus]').forEach((button) => {
        button.onclick = () => updateQuantity(button.dataset.plus, 1);
    });

    cartItemsEl.querySelectorAll('[data-remove]').forEach((button) => {
        button.onclick = () => removeFromCart(button.dataset.remove);
    });

    const totals = cartTotals();

    cartCount.textContent = totals.items;
    summaryItems.textContent = totals.items;
    summarySaved.textContent = money(totals.saved);
    summaryTotal.textContent = money(totals.total);

    cartEmpty.classList.toggle('hidden', entries.length !== 0);
    cartItemsEl.classList.toggle('hidden', entries.length === 0);
    purchaseButton.disabled = entries.length === 0;
}

function renderAll() {
    renderCart();
    renderProducts();
}

function applyStockUpdate(stock) {
    for (const product of store.products) {
        if (!(product.id in stock)) continue;

        const value = stock[product.id];

        if (value === false) {
            product.unlimitedStock = true;
            product.stock = 0;
        } else {
            product.unlimitedStock = false;
            product.stock = Number(value || 0);
        }

        const current = cartQuantity(product.id);

        if (!product.unlimitedStock && current > product.stock) {
            if (product.stock <= 0) {
                store.cart.delete(product.id);
            } else {
                store.cart.set(product.id, product.stock);
            }
        }
    }

    renderAll();
}

function tickClock() {
    const now = new Date();
    const hh = String(now.getHours()).padStart(2, '0');
    const mm = String(now.getMinutes()).padStart(2, '0');

    clockEl.textContent = `${hh}:${mm}`;
    receiptTime.textContent = `${now.toLocaleDateString()} ${hh}:${mm}`;
}

function openStore(data) {
    store = {
        open: true,
        shopId: data.shopId,
        currencySymbol: data.currencySymbol || '$',
        currencyLabel: data.currencyLabel || 'Cash',
        categories: data.categories || [],
        products: data.products || [],
        activeCategory: 'all',
        search: '',
        showImages: data.showImages !== false,
        cart: new Map()
    };

    const root = document.documentElement.style;
    const isHex = (value) => /^#[0-9a-f]{6}$/i.test(value || '');
    const toRgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)).join(', ');
    const accent = isHex(data.accent) ? data.accent : '#e0261c';
    const accentAlt = isHex(data.accentAlt) ? data.accentAlt : '#ffc20e';
    root.setProperty('--accent', accent);
    root.setProperty('--accent-2', accentAlt);
    // FiveM's CEF has no color-mix(), so tints are built from rgba(var(--accent-rgb), a)
    root.setProperty('--accent-rgb', toRgb(accent));
    root.setProperty('--accent-2-rgb', toRgb(accentAlt));

    const label = (data.shopLabel || 'LTD Gasoline').toUpperCase();

    shopName.textContent = label;
    receiptStore.textContent = label;
    tagline.textContent = data.tagline || 'FUEL • FOOD • DRINKS';
    footerText.textContent = data.footer || 'LTD GASOLINE';
    paymentLabel.textContent = `PAY WITH ${store.currencyLabel.toUpperCase()}`;
    renderFuelBoard(data.fuelBoard);

    searchInput.value = '';

    tickClock();
    clearInterval(clockTimer);
    clockTimer = setInterval(tickClock, 15000);

    setMessage();
    renderCategories();
    renderAll();

    app.classList.remove('hidden');
    setTimeout(() => searchInput.focus(), 50);
}

function closeStore() {
    store.open = false;
    app.classList.add('hidden');
    store.cart.clear();
    clearInterval(clockTimer);
    setMessage();
}

window.addEventListener('message', (event) => {
    const message = event.data || {};

    if (message.action === 'open') openStore(message.data || {});
    if (message.action === 'close') closeStore();
    if (message.action === 'stockUpdate') applyStockUpdate(message.stock || {});
});

searchInput.addEventListener('input', () => {
    store.search = searchInput.value;
    renderProducts();
});

$('close-button').onclick = () => {
    nui('close');
    closeStore();
};

$('clear-cart').onclick = () => {
    store.cart.clear();
    setMessage();
    renderAll();
};

purchaseButton.onclick = async () => {
    if (purchaseButton.disabled) return;

    const cart = [...store.cart.entries()].map(([id, quantity]) => ({ id, quantity }));
    if (!cart.length) return;

    purchaseButton.disabled = true;
    setMessage('Scanning items...');

    try {
        const result = await nui('purchase', { cart });

        if (result.success) {
            setMessage(result.message || 'Thanks for stopping at LTD!', 'success');
            store.cart.clear();

            if (result.stock) {
                applyStockUpdate(result.stock);
            } else {
                renderAll();
            }
        } else {
            setMessage(result.message || 'Transaction failed.', 'error');
        }
    } catch (error) {
        setMessage('The till is not responding.', 'error');
    }

    purchaseButton.disabled = store.cart.size === 0;
};

document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && store.open) {
        nui('close');
        closeStore();
    }
});

/* ---------- Browser preview (outside FiveM only) ---------- */
function previewResponse(endpoint, payload) {
    if (endpoint !== 'purchase') return { ok: true };

    const stock = {};
    for (const { id, quantity } of payload.cart) {
        const product = getProduct(id);
        if (product && !product.unlimitedStock) stock[id] = product.stock - quantity;
    }

    return { success: true, message: 'Thanks for stopping at LTD!', stock };
}

if (!IN_GAME) {
    const p = (id, label, category, price, stock, extra = {}) => ({
        id, item: id, label, category, price, originalPrice: price, onSale: false,
        stock, unlimitedStock: stock === false, maxPerPurchase: 10,
        description: extra.description || 'Preview product.', image: '', ...extra
    });

    openStore({
        shopId: 'preview',
        shopLabel: 'LTD Grove Street',
        tagline: 'FUEL • FOOD • DRINKS • LOS SANTOS & BLAINE COUNTY',
        footer: 'LTD GASOLINE • FILL UP, STOCK UP',
        fuelBoard: [
            { label: 'UNLEADED', price: '3.49' },
            { label: 'PLUS', price: '3.69' },
            { label: 'PREMIUM', price: '3.89' },
            { label: 'DIESEL', price: '3.99' }
        ],
        categories: [
            { id: 'drinks', label: 'Drinks', icon: 'bottle-water', emoji: '🥤' },
            { id: 'snacks', label: 'Snacks', icon: 'cookie-bite', emoji: '🍫' },
            { id: 'food', label: 'Food', icon: 'burger', emoji: '🍔' },
            { id: 'alcohol', label: 'Liquor', icon: 'wine-bottle', emoji: '🍺' },
            { id: 'essentials', label: 'Essentials', icon: 'kit-medical', emoji: '🩹' },
            { id: 'misc', label: 'Misc', icon: 'fire', emoji: '🔥' }
        ],
        products: [
            p('water', 'Water', 'drinks', 5, 60, { description: 'Bottled Blaine County spring water. Probably.' }),
            p('sprunk', 'Sprunk', 'drinks', 8, 50, { description: 'The essence of life. Lime-green and fizzy.' }),
            p('ecola', 'eCola', 'drinks', 6, 4, { onSale: true, originalPrice: 8, description: 'Deliciously infectious.' }),
            p('chips', 'Phat Chips', 'snacks', 6, 40, { description: 'Extra salty crisps for extra lazy afternoons.' }),
            p('meteorite', 'Meteorite Bar', 'snacks', 5, 40, { onSale: true, originalPrice: 7, description: 'Out of this world.' }),
            p('burger', 'Microwave Burger', 'food', 15, 0, { description: 'Ninety seconds on high.' }),
            p('pisswasser', 'Pißwasser', 'alcohol', 12, 30, { description: 'You are in for a good time.' }),
            p('bandage', 'Bandage', 'essentials', 25, false, { description: 'For minor gunshot wounds.' }),
            p('lighter', 'Lighter', 'misc', 4, 30, { description: 'Please do not burn down the store.' })
        ]
    });
}
