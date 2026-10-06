-- OPS platform: companies, roles, memberships, customers, jobs, money. Shared by the game (opslabs-phone) and OPS Hub.
-- Accounts are opslabs_phone_opsnet_users (the same sign-in on the phone and the website).
CREATE TABLE IF NOT EXISTS ops_companies (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, code VARCHAR(24) NOT NULL UNIQUE, name VARCHAR(60) NOT NULL, tagline VARCHAR(160) NULL,
  color VARCHAR(9) NOT NULL DEFAULT '#0a84ff', icon VARCHAR(40) NOT NULL DEFAULT 'building', kind VARCHAR(24) NOT NULL DEFAULT 'services',
  balance DECIMAL(14,2) NOT NULL DEFAULT 0, vat_pct DECIMAL(5,2) NOT NULL DEFAULT 20, wage_pct DECIMAL(5,2) NOT NULL DEFAULT 40,
  society VARCHAR(40) NULL, active TINYINT(1) NOT NULL DEFAULT 1, created_at INT NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_roles (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, code VARCHAR(32) NOT NULL UNIQUE, name VARCHAR(60) NOT NULL, rank_no INT NOT NULL DEFAULT 10,
  perms TEXT NOT NULL, builtin TINYINT(1) NOT NULL DEFAULT 0, description VARCHAR(200) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_members (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, account_id INT NOT NULL, company_id INT NOT NULL, role_id INT NULL,
  title VARCHAR(60) NULL, status VARCHAR(12) NOT NULL DEFAULT 'active', note VARCHAR(255) NULL, joined_at INT NOT NULL DEFAULT 0,
  UNIQUE KEY acc_co (account_id, company_id), KEY company (company_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_customers (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, account_no VARCHAR(16) NOT NULL UNIQUE, kind VARCHAR(16) NOT NULL DEFAULT 'residential',
  name VARCHAR(80) NOT NULL, identifier VARCHAR(60) NULL, society VARCHAR(40) NULL, email VARCHAR(80) NULL, phone VARCHAR(24) NULL,
  address VARCHAR(160) NULL, x FLOAT NULL, y FLOAT NULL, z FLOAT NULL, balance DECIMAL(14,2) NOT NULL DEFAULT 0, sla VARCHAR(16) NOT NULL DEFAULT 'standard',
  notes TEXT NULL, created_at INT NOT NULL DEFAULT 0, KEY identifier (identifier)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_jobs (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, ref VARCHAR(16) NOT NULL, company_id INT NOT NULL, type VARCHAR(40) NOT NULL,
  title VARCHAR(120) NOT NULL, description TEXT NULL, priority VARCHAR(10) NOT NULL DEFAULT 'normal', emergency TINYINT(1) NOT NULL DEFAULT 0,
  status VARCHAR(16) NOT NULL DEFAULT 'open', customer_id INT NULL, location VARCHAR(160) NULL, x FLOAT NULL, y FLOAT NULL, z FLOAT NULL,
  price DECIMAL(12,2) NOT NULL DEFAULT 0, wage DECIMAL(12,2) NOT NULL DEFAULT 0, verify TEXT NULL, progress TEXT NULL,
  assigned_to INT NULL, assigned_name VARCHAR(60) NULL, appointment_at INT NULL, due_at INT NULL,
  created_by VARCHAR(60) NULL, created_at INT NOT NULL DEFAULT 0, accepted_at INT NULL, completed_at INT NULL, invoice_id INT NULL, result VARCHAR(255) NULL, announced TINYINT(1) NOT NULL DEFAULT 0,
  KEY company_status (company_id, status), KEY assigned (assigned_to)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_transactions (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, company_id INT NOT NULL, kind VARCHAR(16) NOT NULL, amount DECIMAL(14,2) NOT NULL,
  balance_after DECIMAL(14,2) NOT NULL DEFAULT 0, ref_type VARCHAR(16) NULL, ref_id INT NULL, counterparty VARCHAR(80) NULL,
  memo VARCHAR(200) NULL, actor VARCHAR(60) NULL, at INT NOT NULL DEFAULT 0, KEY company (company_id, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_invoices (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, number VARCHAR(20) NOT NULL UNIQUE, company_id INT NOT NULL, customer_id INT NULL,
  customer_name VARCHAR(80) NULL, job_id INT NULL, kind VARCHAR(10) NOT NULL DEFAULT 'invoice', items TEXT NOT NULL,
  subtotal DECIMAL(12,2) NOT NULL DEFAULT 0, tax DECIMAL(12,2) NOT NULL DEFAULT 0, total DECIMAL(12,2) NOT NULL DEFAULT 0,
  status VARCHAR(10) NOT NULL DEFAULT 'unpaid', issued_at INT NOT NULL DEFAULT 0, paid_at INT NULL, KEY company (company_id), KEY customer (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_wages (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, account_id INT NOT NULL, identifier VARCHAR(60) NULL, company_id INT NOT NULL, job_id INT NULL,
  amount DECIMAL(12,2) NOT NULL, label VARCHAR(160) NULL, status VARCHAR(10) NOT NULL DEFAULT 'paid', at INT NOT NULL DEFAULT 0, paid_at INT NULL,
  KEY account (account_id), KEY pending (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_messages (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, company_id INT NOT NULL, author VARCHAR(60) NULL, title VARCHAR(120) NOT NULL, body TEXT NULL, at INT NOT NULL DEFAULT 0,
  KEY company (company_id, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_audit (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, at INT NOT NULL, actor VARCHAR(60) NULL, company_id INT NULL, action VARCHAR(40) NOT NULL,
  target VARCHAR(80) NULL, detail VARCHAR(400) NULL, KEY at (at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
