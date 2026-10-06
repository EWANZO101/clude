-- OPS Network ISP: packages, customer services (lines), IP addresses, router config, speed tests, tickets, outages.
-- Shared by the game (opslabs-towers server/opsisp.lua) and OPS Hub.
CREATE TABLE IF NOT EXISTS ops_isp_packages (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, code VARCHAR(24) NOT NULL UNIQUE, name VARCHAR(60) NOT NULL, segment VARCHAR(16) NOT NULL DEFAULT 'residential',
  tech VARCHAR(12) NOT NULL DEFAULT 'fibre', down_mbps INT NOT NULL, up_mbps INT NOT NULL, price DECIMAL(10,2) NOT NULL, setup_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
  ip_mode VARCHAR(12) NOT NULL DEFAULT 'dynamic', static_ips INT NOT NULL DEFAULT 0, contract_months INT NOT NULL DEFAULT 12, sla VARCHAR(16) NOT NULL DEFAULT 'standard',
  fix_hours INT NOT NULL DEFAULT 48, description VARCHAR(255) NULL, active TINYINT(1) NOT NULL DEFAULT 1, sort INT NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_isp_services (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, ref VARCHAR(16) NULL, customer_id INT NOT NULL, package_id INT NOT NULL, status VARCHAR(24) NOT NULL DEFAULT 'pending_install',
  address VARCHAR(160) NULL, x FLOAT NULL, y FLOAT NULL, z FLOAT NULL, ont_id INT NULL, router_tower INT NULL, install_job INT NULL,
  ip_mode VARCHAR(12) NOT NULL DEFAULT 'dynamic', price DECIMAL(10,2) NOT NULL DEFAULT 0, contract_start INT NULL, contract_end INT NULL,
  next_bill_at INT NULL, overdue_since INT NULL, last_seen_up INT NULL, line_state VARCHAR(10) NULL, ordered_by VARCHAR(60) NULL, created_at INT NOT NULL DEFAULT 0, notes TEXT NULL,
  KEY customer (customer_id), KEY status (status), KEY ont (ont_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_isp_ips (
  ip VARCHAR(18) NOT NULL PRIMARY KEY, pool VARCHAR(16) NOT NULL, service_id INT NULL, kind VARCHAR(10) NOT NULL DEFAULT 'dynamic',
  ptr VARCHAR(120) NULL, assigned_at INT NULL, KEY service (service_id), KEY pool (pool)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_isp_config (
  service_id INT NOT NULL PRIMARY KEY, config LONGTEXT NOT NULL, updated_by VARCHAR(60) NULL, updated_at INT NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_isp_speedtests (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, service_id INT NULL, down_mbps DECIMAL(10,1) NOT NULL, up_mbps DECIMAL(10,1) NOT NULL, ping_ms INT NOT NULL,
  jitter_ms INT NOT NULL DEFAULT 0, via VARCHAR(12) NOT NULL DEFAULT 'wifi', by_name VARCHAR(60) NULL, x FLOAT NULL, y FLOAT NULL, at INT NOT NULL, KEY service (service_id, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_isp_tickets (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, ref VARCHAR(16) NULL, service_id INT NULL, customer_id INT NULL, kind VARCHAR(16) NOT NULL DEFAULT 'fault',
  subject VARCHAR(120) NOT NULL, status VARCHAR(12) NOT NULL DEFAULT 'open', priority VARCHAR(10) NOT NULL DEFAULT 'normal', job_id INT NULL,
  messages LONGTEXT NULL, opened_by VARCHAR(60) NULL, created_at INT NOT NULL DEFAULT 0, closed_at INT NULL, KEY status (status), KEY customer (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ops_isp_outages (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, ref VARCHAR(16) NULL, title VARCHAR(120) NOT NULL, area VARCHAR(120) NULL, x FLOAT NULL, y FLOAT NULL, radius FLOAT NULL,
  cause VARCHAR(160) NULL, status VARCHAR(16) NOT NULL DEFAULT 'investigating', affected INT NOT NULL DEFAULT 0, services TEXT NULL, job_id INT NULL,
  planned TINYINT(1) NOT NULL DEFAULT 0, started_at INT NOT NULL, resolved_at INT NULL, updates LONGTEXT NULL, KEY status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
