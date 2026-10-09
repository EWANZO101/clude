-- OPS Voice: phone numbers for OPS Hub — one per company and one per Hub account (server/voip.lua, OPS Hub ops_voip.py).
-- Numbers come from Config.Voip.Reserved (555-0100 … 555-0999), which phones never get.
CREATE TABLE IF NOT EXISTS ops_voip_lines (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  number VARCHAR(20) NOT NULL,
  kind VARCHAR(8) NOT NULL DEFAULT 'company',
  company_id INT NULL,
  account_id INT NULL,
  label VARCHAR(60) NOT NULL,
  active TINYINT(1) NOT NULL DEFAULT 1,
  created_at INT NOT NULL,
  UNIQUE KEY number_ (number),
  UNIQUE KEY company (company_id),
  UNIQUE KEY account (account_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
