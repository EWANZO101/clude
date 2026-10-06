-- OPS Domains · OPS Web · OPS Trust: the in-game internet (server/web.lua, OPS Hub → OPS Web & Domains)
-- Domains are registered by players (or staff on the Hub), point anywhere with DNS, and serve sites built with the
-- OPS Web site builder — on OPS Web shared hosting or self-hosted on an OPS Network static IP.

CREATE TABLE IF NOT EXISTS ops_web_domains (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(80) NOT NULL, tld VARCHAR(16) NOT NULL,
  customer_id INT NULL, identifier VARCHAR(80) NULL, owner_name VARCHAR(80) NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'active',          -- active · expired (grace) · suspended (staff)
  auto_renew TINYINT(1) NOT NULL DEFAULT 1, privacy TINYINT(1) NOT NULL DEFAULT 1, locked TINYINT(1) NOT NULL DEFAULT 1,
  transfer_code VARCHAR(16) NULL, note VARCHAR(200) NULL, dns_changed_at INT NULL,
  created_at INT NOT NULL, expires_at INT NOT NULL, warned_at INT NULL,
  UNIQUE KEY name (name), KEY identifier (identifier), KEY customer (customer_id)
);

CREATE TABLE IF NOT EXISTS ops_web_dns (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id INT NOT NULL, host VARCHAR(63) NOT NULL DEFAULT '@', type VARCHAR(8) NOT NULL, value VARCHAR(255) NOT NULL,
  prio INT NOT NULL DEFAULT 0, ttl INT NOT NULL DEFAULT 3600,
  KEY domain (domain_id)
);

CREATE TABLE IF NOT EXISTS ops_web_hosting (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  customer_id INT NULL, identifier VARCHAR(80) NULL, owner_name VARCHAR(80) NULL,
  plan VARCHAR(16) NOT NULL, price DECIMAL(10,2) NOT NULL DEFAULT 0,
  status VARCHAR(16) NOT NULL DEFAULT 'active',          -- active · suspended · cancelled
  created_at INT NOT NULL, next_bill_at INT NOT NULL, overdue_since INT NULL,
  KEY identifier (identifier)
);

CREATE TABLE IF NOT EXISTS ops_web_sites (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  hosting_id INT NULL,                                     -- NULL = self-hosted on self_ip
  self_ip VARCHAR(45) NULL,
  customer_id INT NULL, identifier VARCHAR(80) NULL, owner_name VARCHAR(80) NULL,
  domain_id INT NULL, host VARCHAR(63) NOT NULL DEFAULT '@',
  title VARCHAR(80) NOT NULL, description VARCHAR(240) NULL, keywords VARCHAR(240) NULL,
  data LONGTEXT NULL,                                      -- { theme, contact, pages: [{ slug, title, blocks: [...] }] }
  published TINYINT(1) NOT NULL DEFAULT 0, noindex TINYINT(1) NOT NULL DEFAULT 0,
  status VARCHAR(16) NOT NULL DEFAULT 'ok',                -- ok · taken_down (staff)
  takedown_reason VARCHAR(200) NULL,
  views INT NOT NULL DEFAULT 0,
  created_at INT NOT NULL, updated_at INT NOT NULL, published_at INT NULL, edited_by VARCHAR(80) NULL,
  KEY domain (domain_id), KEY identifier (identifier), KEY customer (customer_id)
);

CREATE TABLE IF NOT EXISTS ops_web_certs (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id INT NOT NULL, common_name VARCHAR(90) NOT NULL, wildcard TINYINT(1) NOT NULL DEFAULT 0,
  kind VARCHAR(4) NOT NULL DEFAULT 'dv', org VARCHAR(80) NULL, serial VARCHAR(24) NOT NULL,
  status VARCHAR(12) NOT NULL DEFAULT 'valid',             -- valid · expired · revoked
  auto TINYINT(1) NOT NULL DEFAULT 0,                      -- renewed by OPS Web hosting
  issued_at INT NOT NULL, expires_at INT NOT NULL, issued_by VARCHAR(80) NULL,
  KEY domain (domain_id)
);

CREATE TABLE IF NOT EXISTS ops_web_mailboxes (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  domain_id INT NOT NULL, address VARCHAR(100) NOT NULL,
  deliver_to VARCHAR(20) NOT NULL,                         -- phone number whose Mail app receives it
  catch_all TINYINT(1) NOT NULL DEFAULT 0,
  created_at INT NOT NULL, created_by VARCHAR(80) NULL,
  UNIQUE KEY address (address), KEY domain (domain_id), KEY deliver (deliver_to)
);
