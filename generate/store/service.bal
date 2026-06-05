import ballerina/http;
import ballerina/sql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

// Shared listener: hosts both /health and the business catalog routes.
listener http:Listener mainListener = new (9090);

// ---- Data types ----
type Product record {|
    int id;
    string name;
    string sku;
    decimal price;
|};

type NewProduct record {|
    string name;
    string sku;
    decimal price;
|};

// Product detail enriched with live availability from inventory-service.
// `stock` is omitted when the inventory call fails (graceful degradation).
type ProductDetail record {|
    int id;
    string name;
    string sku;
    decimal price;
    int? stock?;
    string availability;
|};

// Shape of inventory-service's stock response (best-effort; we only read `stock`).
type StockResponse record {
    int stock?;
};

// ---- Postgres client (connection read from env, with compose defaults) ----
final postgresql:Client db = check new (
    host = envOr("DB_HOST", "postgres"),
    port = check int:fromString(envOr("DB_PORT", "5432")),
    username = envOr("DB_USER", "poc"),
    password = envOr("DB_PASSWORD", "pocpass"),
    database = envOr("DB_NAME", "storedb")
);

// ---- Inventory service client (cross-service call → child span for topology) ----
final http:Client inventoryClient = check new (envOr("INVENTORY_URL", "http://inventory:9090"));

// On startup: ensure the catalog schema exists and seed ~5 products when empty.
// SKUs SKU-001..SKU-005 line up with inventory-service's seeded stock.
function init() returns error? {
    _ = check db->execute(`CREATE TABLE IF NOT EXISTS products (
        id SERIAL PRIMARY KEY,
        name TEXT,
        sku TEXT,
        price NUMERIC
    )`);

    int count = check db->queryRow(`SELECT count(*) FROM products`);
    if count == 0 {
        NewProduct[] seed = [
            {name: "Aerodynamic Water Bottle", sku: "SKU-001", price: 18.99},
            {name: "Wireless Earbuds", sku: "SKU-002", price: 79.50},
            {name: "Trail Running Shoes", sku: "SKU-003", price: 124.00},
            {name: "Insulated Travel Mug", sku: "SKU-004", price: 24.95},
            {name: "Merino Wool Socks", sku: "SKU-005", price: 16.00}
        ];
        foreach NewProduct p in seed {
            _ = check db->execute(
                `INSERT INTO products (name, sku, price) VALUES (${p.name}, ${p.sku}, ${p.price})`);
        }
        logInfo("seeded products table");
    }
    logInfo("store-service started");
}

// ---- Health ----
service /health on mainListener {
    resource function get .() returns json => {status: "UP", 'service: "store-service"};
}

// ---- Storefront / catalog-browse routes ----
service /products on mainListener {

    // List the catalog.
    isolated resource function get .() returns Product[]|http:Response|error {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }
        stream<Product, sql:Error?> rs = db->query(`SELECT id, name, sku, price FROM products ORDER BY id`);
        Product[] products = check from Product p in rs
            select p;
        logInfo("listed catalog products");
        return products;
    }

    // Product detail, enriched with live stock from inventory-service.
    // If the inventory call fails we degrade gracefully: return the product with
    // `availability` = "unknown" and `stock` omitted, and log the error.
    isolated resource function get [int id]() returns ProductDetail|http:NotFound|http:Response|error {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }
        Product|sql:Error result = db->queryRow(
            `SELECT id, name, sku, price FROM products WHERE id = ${id}`);
        if result is sql:NoRowsError {
            logInfo("product not found");
            return http:NOT_FOUND;
        }
        if result is sql:Error {
            logError("product lookup failed", result);
            return result;
        }

        // Cross-service call to inventory-service for live availability. HTTP context
        // propagates automatically, so this becomes a child span in the trace.
        int? stock = fetchStock(result.sku);

        logInfo("fetched product detail");
        return buildProductDetail(result, stock);
    }
}

// Best-effort stock lookup against inventory-service. Returns the live count, or
// () when the downstream call fails — the caller degrades gracefully instead of
// failing the whole product request.
isolated function fetchStock(string sku) returns int? {
    StockResponse|error resp = inventoryClient->/stock/[sku];
    if resp is error {
        logError("inventory stock lookup failed; degrading to unknown availability", resp);
        return ();
    }
    return resp?.stock;
}

// Pure mapper: combine a product row with the (optional) live stock count
// into the externally-shaped ProductDetail. Extracted from the resource so
// availability/stock-handling rules can be unit-tested without DB or HTTP.
isolated function buildProductDetail(Product p, int? stock) returns ProductDetail {
    string availability = stock is int ? (stock > 0 ? "in_stock" : "out_of_stock") : "unknown";
    return {
        id: p.id,
        name: p.name,
        sku: p.sku,
        price: p.price,
        stock: stock,
        availability: availability
    };
}

// Validate a SKU against the catalog's seeded pattern `SKU-NNN` (three digits).
// Used to guard catalog inputs and to keep the validation rule testable in isolation.
isolated function skuValid(string sku) returns boolean {
    if sku.length() != 7 {
        return false;
    }
    if !sku.startsWith("SKU-") {
        return false;
    }
    string digits = sku.substring(4);
    // The suffix must be exactly three ASCII digits. `int:fromString` rejects
    // signs, whitespace, and non-digit characters, so combined with the fixed
    // length check above this is equivalent to /^SKU-\d{3}$/.
    int|error parsed = int:fromString(digits);
    if parsed is error {
        return false;
    }
    return parsed >= 0 && parsed <= 999;
}
