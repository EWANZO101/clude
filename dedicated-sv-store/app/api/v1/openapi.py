from flask import jsonify, render_template
from apispec import APISpec

from app.api.v1 import api_v1_bp

spec = APISpec(
    title="OpsLabs Servers API",
    version="v1",
    openapi_version="3.0.3",
    info={"description": "REST API for the dedicated server marketplace, BYOE hosting, orders and billing."},
)

spec.options["servers"] = [{"url": "/api/v1", "description": "This deployment"}]

spec.components.security_scheme(
    "ApiKeyAuth", {"type": "apiKey", "in": "header", "name": "X-API-Key"}
)

_SUCCESS_ENVELOPE = {
    "type": "object",
    "properties": {
        "success": {"type": "boolean"},
        "data": {"type": "object"},
        "meta": {
            "type": "object",
            "properties": {
                "page": {"type": "integer"}, "per_page": {"type": "integer"}, "total": {"type": "integer"},
            },
        },
    },
}
_ERROR_ENVELOPE = {
    "type": "object",
    "properties": {
        "success": {"type": "boolean", "example": False},
        "error": {
            "type": "object",
            "properties": {"code": {"type": "string"}, "message": {"type": "string"}},
        },
    },
}

spec.components.schema("SuccessEnvelope", _SUCCESS_ENVELOPE)
spec.components.schema("ErrorEnvelope", _ERROR_ENVELOPE)

_OK = {"description": "Success", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/SuccessEnvelope"}}}}
_UNAUTHORIZED = {"description": "Missing or invalid API key", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
_FORBIDDEN = {"description": "API key lacks the required scope or ownership", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}
_NOT_FOUND = {"description": "Not found", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/ErrorEnvelope"}}}}

_PAGE_PARAMS = [
    {"name": "page", "in": "query", "schema": {"type": "integer", "default": 1}},
    {"name": "per_page", "in": "query", "schema": {"type": "integer", "default": 25, "maximum": 100}},
]

spec.path(
    path="/servers",
    operations={
        "get": {
            "summary": "List published marketplace servers",
            "tags": ["Servers"],
            "parameters": _PAGE_PARAMS,
            "responses": {"200": _OK},
        },
        "post": {
            "summary": "Create a server listing (seller API key required)",
            "tags": ["Servers"],
            "security": [{"ApiKeyAuth": []}],
            "responses": {"201": _OK, "401": _UNAUTHORIZED, "403": _FORBIDDEN},
        },
    },
)
spec.path(
    path="/servers/{server_id}",
    operations={
        "get": {"summary": "Get a server", "tags": ["Servers"], "responses": {"200": _OK, "404": _NOT_FOUND}},
        "put": {
            "summary": "Update a server you own", "tags": ["Servers"], "security": [{"ApiKeyAuth": []}],
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "403": _FORBIDDEN, "404": _NOT_FOUND},
        },
        "delete": {
            "summary": "Deactivate a server you own", "tags": ["Servers"], "security": [{"ApiKeyAuth": []}],
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "403": _FORBIDDEN, "404": _NOT_FOUND},
        },
    },
)
spec.path(
    path="/inventory",
    operations={
        "get": {
            "summary": "List your servers' inventory status (seller API key required)",
            "tags": ["Servers"], "security": [{"ApiKeyAuth": []}], "responses": {"200": _OK, "401": _UNAUTHORIZED, "403": _FORBIDDEN},
        }
    },
)
spec.path(
    path="/hardware",
    operations={"get": {"summary": "List hardware catalog categories", "tags": ["Hardware"], "responses": {"200": _OK}}},
)
spec.path(
    path="/hardware/{category}",
    operations={
        "get": {
            "summary": "List hardware items in a category", "tags": ["Hardware"],
            "parameters": _PAGE_PARAMS + [{"name": "category", "in": "path", "required": True, "schema": {"type": "string"}}],
            "responses": {"200": _OK, "404": _NOT_FOUND},
        }
    },
)
spec.path(
    path="/orders",
    operations={
        "get": {
            "summary": "List your orders (customer) or orders for your servers (seller)",
            "tags": ["Orders"], "security": [{"ApiKeyAuth": []}], "parameters": _PAGE_PARAMS,
            "responses": {"200": _OK, "401": _UNAUTHORIZED},
        }
    },
)
spec.path(
    path="/orders/{order_id}",
    operations={
        "get": {
            "summary": "Get an order", "tags": ["Orders"], "security": [{"ApiKeyAuth": []}],
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "404": _NOT_FOUND},
        }
    },
)
spec.path(
    path="/orders/{order_id}/status",
    operations={
        "post": {
            "summary": "Update fulfilment status of an order for your server (seller API key required)",
            "tags": ["Orders"], "security": [{"ApiKeyAuth": []}],
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "404": _NOT_FOUND},
        }
    },
)
spec.path(
    path="/requests",
    operations={
        "get": {
            "summary": "List your Bring Your Own Equipment hosting requests",
            "tags": ["BYOE"], "security": [{"ApiKeyAuth": []}], "parameters": _PAGE_PARAMS,
            "responses": {"200": _OK, "401": _UNAUTHORIZED},
        }
    },
)
spec.path(
    path="/requests/{request_id}",
    operations={
        "get": {
            "summary": "Get a hosting request", "tags": ["BYOE"], "security": [{"ApiKeyAuth": []}],
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "404": _NOT_FOUND},
        }
    },
)
spec.path(
    path="/equipment/{item_id}",
    operations={
        "get": {
            "summary": "Get one of your equipment items", "tags": ["BYOE"], "security": [{"ApiKeyAuth": []}],
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "404": _NOT_FOUND},
        }
    },
)
spec.path(
    path="/invoices",
    operations={
        "get": {
            "summary": "List your invoices", "tags": ["Billing"], "security": [{"ApiKeyAuth": []}], "parameters": _PAGE_PARAMS,
            "responses": {"200": _OK, "401": _UNAUTHORIZED},
        }
    },
)
spec.path(
    path="/payments",
    operations={
        "get": {
            "summary": "List your payments", "tags": ["Billing"], "security": [{"ApiKeyAuth": []}], "parameters": _PAGE_PARAMS,
            "responses": {"200": _OK, "401": _UNAUTHORIZED},
        }
    },
)
spec.path(
    path="/shipments",
    operations={
        "get": {
            "summary": "List shipments for your hosting requests", "tags": ["BYOE"],
            "security": [{"ApiKeyAuth": []}], "parameters": _PAGE_PARAMS,
            "responses": {"200": _OK, "401": _UNAUTHORIZED},
        }
    },
)
spec.path(
    path="/customers",
    operations={
        "get": {
            "summary": "List customers (admin API key required)", "tags": ["Admin"],
            "security": [{"ApiKeyAuth": []}], "parameters": _PAGE_PARAMS,
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "403": _FORBIDDEN},
        }
    },
)
spec.path(
    path="/sellers",
    operations={
        "get": {
            "summary": "List sellers (admin API key required)", "tags": ["Admin"],
            "security": [{"ApiKeyAuth": []}], "parameters": _PAGE_PARAMS,
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "403": _FORBIDDEN},
        }
    },
)
spec.path(
    path="/webhooks",
    operations={
        "get": {
            "summary": "List your registered webhooks", "tags": ["Webhooks"], "security": [{"ApiKeyAuth": []}],
            "responses": {"200": _OK, "401": _UNAUTHORIZED},
        },
        "post": {
            "summary": "Register a webhook", "tags": ["Webhooks"], "security": [{"ApiKeyAuth": []}],
            "responses": {"201": _OK, "401": _UNAUTHORIZED},
        },
    },
)
spec.path(
    path="/webhooks/{webhook_id}",
    operations={
        "delete": {
            "summary": "Delete a webhook you own", "tags": ["Webhooks"], "security": [{"ApiKeyAuth": []}],
            "responses": {"200": _OK, "401": _UNAUTHORIZED, "404": _NOT_FOUND},
        }
    },
)


@api_v1_bp.route("/openapi.json")
def openapi_json():
    return jsonify(spec.to_dict())


@api_v1_bp.route("/docs")
def api_docs():
    return render_template("api_docs.html")
