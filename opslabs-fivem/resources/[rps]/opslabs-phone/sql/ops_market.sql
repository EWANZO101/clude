-- OPS market: sub-companies, wholesale products, leases, company stores and network reports.
-- Shared by opslabs-phone (server/market.lua), opslabs-towers (ISP retail) and OPS Hub (ops_market.py).
-- Columns added to existing tables (by server/market.lua on start):
--   ops_companies: parent_id, owner_account, logo, provides, may_lease, approved
--   ops_isp_packages / ops_isp_services / opslabs_phone_carrier_plans: company_id (the retailer; NULL = the role company)

CREATE TABLE IF NOT EXISTS ops_wholesale (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  provider_id INT NOT NULL,
  code VARCHAR(40) NOT NULL,
  kind VARCHAR(24) NOT NULL,
  name VARCHAR(80) NOT NULL,
  description VARCHAR(255) NULL,
  unit VARCHAR(8) NOT NULL DEFAULT 'month',
  price DECIMAL(10,2) NOT NULL DEFAULT 0,
  setup_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
  approval TINYINT(1) NOT NULL DEFAULT 1,
  active TINYINT(1) NOT NULL DEFAULT 1,
  sort INT NOT NULL DEFAULT 0,
  UNIQUE KEY provider_code (provider_id, code)
);

CREATE TABLE IF NOT EXISTS ops_leases (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  ref VARCHAR(16) NULL,
  company_id INT NOT NULL,
  provider_id INT NOT NULL,
  product_id INT NOT NULL,
  kind VARCHAR(24) NOT NULL,
  asset VARCHAR(60) NULL,
  asset_label VARCHAR(120) NULL,
  unit VARCHAR(8) NOT NULL DEFAULT 'month',
  price DECIMAL(10,2) NOT NULL DEFAULT 0,
  setup_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
  status VARCHAR(12) NOT NULL DEFAULT 'requested',
  note VARCHAR(255) NULL,
  requested_by VARCHAR(60) NULL,
  decided_by VARCHAR(60) NULL,
  created_at INT NOT NULL DEFAULT 0,
  started_at INT NULL,
  next_bill_at INT NULL,
  overdue_since INT NULL,
  ended_at INT NULL,
  KEY company (company_id, status),
  KEY provider (provider_id, status)
);

CREATE TABLE IF NOT EXISTS ops_stores (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  company_id INT NOT NULL,
  slug VARCHAR(40) NOT NULL,
  name VARCHAR(80) NOT NULL,
  tagline VARCHAR(160) NULL,
  about TEXT NULL,
  logo VARCHAR(255) NULL,
  color VARCHAR(9) NULL,
  accent VARCHAR(9) NULL,
  active TINYINT(1) NOT NULL DEFAULT 1,
  created_at INT NOT NULL DEFAULT 0,
  updated_at INT NOT NULL DEFAULT 0,
  UNIQUE KEY slug (slug),
  UNIQUE KEY company (company_id)
);

CREATE TABLE IF NOT EXISTS ops_store_items (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  store_id INT NOT NULL,
  kind VARCHAR(16) NOT NULL DEFAULT 'product',
  name VARCHAR(80) NOT NULL,
  description VARCHAR(400) NULL,
  price DECIMAL(10,2) NOT NULL DEFAULT 0,
  period VARCHAR(8) NOT NULL DEFAULT 'once',
  image VARCHAR(255) NULL,
  featured TINYINT(1) NOT NULL DEFAULT 0,
  active TINYINT(1) NOT NULL DEFAULT 1,
  sort INT NOT NULL DEFAULT 0,
  created_at INT NOT NULL DEFAULT 0,
  KEY store (store_id)
);

CREATE TABLE IF NOT EXISTS ops_store_orders (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  ref VARCHAR(16) NULL,
  store_id INT NOT NULL,
  company_id INT NOT NULL,
  item_id INT NULL,
  kind VARCHAR(16) NOT NULL,
  title VARCHAR(120) NOT NULL,
  price DECIMAL(10,2) NOT NULL DEFAULT 0,
  account_id INT NULL,
  customer_id INT NULL,
  customer_name VARCHAR(80) NULL,
  note VARCHAR(400) NULL,
  status VARCHAR(12) NOT NULL DEFAULT 'new',
  invoice_id INT NULL,
  created_at INT NOT NULL DEFAULT 0,
  updated_at INT NOT NULL DEFAULT 0,
  KEY company (company_id, status)
);

CREATE TABLE IF NOT EXISTS ops_net_reports (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  ref VARCHAR(16) NULL,
  dkey VARCHAR(80) NULL,
  company_id INT NOT NULL,
  kind VARCHAR(16) NOT NULL,
  severity VARCHAR(8) NOT NULL DEFAULT 'warn',
  title VARCHAR(160) NOT NULL,
  body VARCHAR(600) NULL,
  source VARCHAR(12) NOT NULL DEFAULT 'auto',
  asset VARCHAR(60) NULL,
  affected INT NOT NULL DEFAULT 0,
  x FLOAT NULL,
  y FLOAT NULL,
  status VARCHAR(12) NOT NULL DEFAULT 'open',
  created_at INT NOT NULL DEFAULT 0,
  ack_at INT NULL,
  ack_by VARCHAR(60) NULL,
  resolved_at INT NULL,
  UNIQUE KEY dkey (dkey),
  KEY company (company_id, status)
);
