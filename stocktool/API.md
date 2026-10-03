# StockTool REST API

All endpoints are accessible at `http://<your-host>:5000/api/`  
Remote access via Cloudflare Tunnel or direct IP works out of the box.

## Authentication

All API requests (except `/api/auth/login`) require a Bearer token.

```
Authorization: Bearer <your_token>
```

### POST /api/auth/login
```json
{ "username": "admin", "password": "yourpassword" }
```
Returns: `{ "access_token": "...", "user": {...} }`

### GET /api/auth/me
Returns the authenticated user's profile.

### POST /api/auth/change-password
```json
{ "current_password": "old", "new_password": "new" }
```

---

## Items  `(admin: create/update/delete — all users: list/view/adjust)`

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /api/items/ | List all active items |
| GET | /api/items/?q=bolt | Search by name |
| GET | /api/items/?stock=low | Filter low stock |
| GET | /api/items/?stock=out | Filter out of stock |
| POST | /api/items/ | Create item *(admin)* |
| GET | /api/items/{id} | Get item by ID |
| PUT | /api/items/{id} | Update item *(admin)* |
| DELETE | /api/items/{id} | Remove item *(admin)* |
| POST | /api/items/{id}/adjust | Adjust stock |

**Create/Update body:**
```json
{
  "name": "M8 Hex Bolt",
  "sku": "BOLT-M8-50",
  "category": "Fasteners",
  "location": "Shelf A3",
  "quantity": 200,
  "unit": "pcs",
  "low_stock_threshold": 20
}
```

**Adjust stock body:**
```json
{ "delta": -10 }
```

---

## Tools  `(admin: create/update/delete — all users: list/view/checkout/checkin)`

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /api/tools/ | List all active tools |
| GET | /api/tools/?status=available | Filter by status |
| GET | /api/tools/?q=drill | Search by name |
| POST | /api/tools/ | Create tool *(admin)* |
| GET | /api/tools/{id} | Get tool by ID |
| PUT | /api/tools/{id} | Update tool *(admin)* |
| DELETE | /api/tools/{id} | Remove tool *(admin)* |
| POST | /api/tools/{id}/checkout | Check out tool |
| POST | /api/tools/{id}/checkin | Check in tool |
| GET | /api/tools/{id}/history | Tool usage history |

**Tool statuses:** `available`, `checked_out`, `broken`, `under_repair`, `stolen`, `lost`

**Checkout body:**
```json
{ "notes": "For job on site B" }
```

**Checkin body:**
```json
{ "condition": "available", "notes": "All good" }
```

---

## Example: Full checkout flow (curl)

```bash
# 1. Login
TOKEN=$(curl -s -X POST http://localhost:5000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"yourpassword"}' | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 2. List available tools
curl http://localhost:5000/api/tools/?status=available \
  -H "Authorization: Bearer $TOKEN"

# 3. Check out tool ID 1
curl -X POST http://localhost:5000/api/tools/1/checkout \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"notes":"Job site A"}'

# 4. Check tool back in
curl -X POST http://localhost:5000/api/tools/1/checkin \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"condition":"available","notes":"Returned clean"}'
```
