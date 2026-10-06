-- OPS business layer (Phase 6): quotes, contracts & SLAs, stock, suppliers, purchase orders, assets & warranties,
-- certifications, vehicles, tools, support tickets and alerts. Shared by the game (server/business.lua) and OPS Hub.

CREATE TABLE IF NOT EXISTS ops_quotes (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, number VARCHAR(20) NULL, company_id INT NOT NULL, customer_id INT NOT NULL,
  title VARCHAR(120) NOT NULL, items LONGTEXT NOT NULL, subtotal DECIMAL(12,2) NOT NULL DEFAULT 0, tax DECIMAL(12,2) NOT NULL DEFAULT 0, total DECIMAL(12,2) NOT NULL DEFAULT 0,
  status VARCHAR(12) NOT NULL DEFAULT 'draft',             -- draft · sent · accepted · declined · expired
  valid_until INT NULL, notes TEXT NULL, jobs VARCHAR(200) NULL, contract_id INT NULL, notify TINYINT(1) NOT NULL DEFAULT 0,
  created_by VARCHAR(60) NULL, created_at INT NOT NULL, sent_at INT NULL, decided_at INT NULL, decided_by VARCHAR(60) NULL,
  KEY company (company_id, status), KEY customer (customer_id)
);
CREATE TABLE IF NOT EXISTS ops_contracts (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, number VARCHAR(20) NULL, company_id INT NOT NULL, customer_id INT NOT NULL,
  title VARCHAR(120) NOT NULL, kind VARCHAR(16) NOT NULL DEFAULT 'support', sla VARCHAR(16) NOT NULL DEFAULT 'business', response_hours INT NOT NULL DEFAULT 24,
  fee DECIMAL(12,2) NOT NULL DEFAULT 0, status VARCHAR(12) NOT NULL DEFAULT 'active',  -- active · suspended · ended
  start_at INT NOT NULL, end_at INT NULL, next_bill_at INT NOT NULL, auto_renew TINYINT(1) NOT NULL DEFAULT 1, overdue_since INT NULL,
  notes TEXT NULL, created_by VARCHAR(60) NULL, created_at INT NOT NULL,
  KEY company (company_id, status), KEY customer (customer_id)
);
CREATE TABLE IF NOT EXISTS ops_suppliers (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, code VARCHAR(24) NOT NULL UNIQUE, name VARCHAR(80) NOT NULL, contact VARCHAR(100) NULL, phone VARCHAR(24) NULL,
  lead_hours INT NOT NULL DEFAULT 2, terms VARCHAR(40) NULL, active TINYINT(1) NOT NULL DEFAULT 1, notes TEXT NULL
);
CREATE TABLE IF NOT EXISTS ops_stock (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, company_id INT NOT NULL, sku VARCHAR(24) NOT NULL, name VARCHAR(80) NOT NULL, unit VARCHAR(8) NOT NULL DEFAULT 'each',
  qty DECIMAL(12,2) NOT NULL DEFAULT 0, min_qty DECIMAL(12,2) NOT NULL DEFAULT 0, cost DECIMAL(12,2) NOT NULL DEFAULT 0, supplier VARCHAR(24) NULL,
  UNIQUE KEY co_sku (company_id, sku)
);
CREATE TABLE IF NOT EXISTS ops_stock_moves (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, company_id INT NOT NULL, sku VARCHAR(24) NOT NULL, qty DECIMAL(12,2) NOT NULL, reason VARCHAR(16) NOT NULL,
  ref VARCHAR(40) NULL, actor VARCHAR(60) NULL, at INT NOT NULL, KEY company (company_id, at)
);
CREATE TABLE IF NOT EXISTS ops_pos (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, number VARCHAR(20) NULL, company_id INT NOT NULL, supplier VARCHAR(24) NOT NULL, items LONGTEXT NOT NULL,
  total DECIMAL(12,2) NOT NULL DEFAULT 0, status VARCHAR(12) NOT NULL DEFAULT 'ordered',   -- ordered · received · cancelled
  ordered_at INT NOT NULL, eta INT NOT NULL, received_at INT NULL, created_by VARCHAR(60) NULL, KEY company (company_id, status)
);
CREATE TABLE IF NOT EXISTS ops_assets (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, company_id INT NOT NULL, customer_id INT NULL, sku VARCHAR(24) NOT NULL, name VARCHAR(80) NOT NULL,
  serial VARCHAR(24) NOT NULL, location VARCHAR(160) NULL, job_id INT NULL, installed_at INT NOT NULL, warranty_until INT NULL,
  status VARCHAR(12) NOT NULL DEFAULT 'installed', notes VARCHAR(200) NULL, KEY customer (customer_id), KEY company (company_id), KEY serial (serial)
);
CREATE TABLE IF NOT EXISTS ops_member_certs (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, account_id INT NOT NULL, cert VARCHAR(24) NOT NULL, issued_at INT NOT NULL, expires_at INT NOT NULL,
  issued_by VARCHAR(60) NULL, score INT NULL, UNIQUE KEY acc_cert (account_id, cert)
);
CREATE TABLE IF NOT EXISTS ops_vehicles (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, company_id INT NOT NULL, plate VARCHAR(8) NOT NULL UNIQUE, model VARCHAR(32) NOT NULL, label VARCHAR(60) NULL,
  assigned_to INT NULL, status VARCHAR(12) NOT NULL DEFAULT 'available',   -- available · maintenance · retired
  mileage INT NOT NULL DEFAULT 0, service_due_at INT NULL, out_at INT NULL, notes VARCHAR(200) NULL, created_at INT NOT NULL,
  KEY company (company_id), KEY assigned (assigned_to)
);
CREATE TABLE IF NOT EXISTS ops_tools (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, company_id INT NOT NULL, kind VARCHAR(40) NOT NULL, serial VARCHAR(24) NOT NULL, assigned_to INT NULL,
  `condition` VARCHAR(12) NOT NULL DEFAULT 'good', calibration_due INT NULL, status VARCHAR(12) NOT NULL DEFAULT 'in_use', notes VARCHAR(200) NULL, created_at INT NOT NULL,
  KEY company (company_id)
);
CREATE TABLE IF NOT EXISTS ops_tickets (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, ref VARCHAR(16) NULL, company_id INT NOT NULL, customer_id INT NULL, subject VARCHAR(120) NOT NULL,
  status VARCHAR(12) NOT NULL DEFAULT 'open', priority VARCHAR(10) NOT NULL DEFAULT 'normal', messages LONGTEXT NULL, job_id INT NULL, source VARCHAR(12) NULL, notify TINYINT(1) NOT NULL DEFAULT 0,
  created_at INT NOT NULL, updated_at INT NOT NULL, KEY company (company_id, status), KEY customer (customer_id)
);
CREATE TABLE IF NOT EXISTS ops_alerts (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, dkey VARCHAR(80) NOT NULL UNIQUE, company_id INT NULL, kind VARCHAR(24) NOT NULL, severity VARCHAR(8) NOT NULL DEFAULT 'warn',
  title VARCHAR(160) NOT NULL, body VARCHAR(300) NULL, link VARCHAR(160) NULL, created_at INT NOT NULL, resolved_at INT NULL, KEY open_ (resolved_at, company_id)
);
