-- OPS Cloud: customer virtual servers, running on OPS Data compute hosts (opslabs-towers server/datacentre.lua places
-- them; server/cloud.lua sells and bills them). ops_dc_status is written by the data centre engine for everyone else.

CREATE TABLE IF NOT EXISTS ops_cloud_vms (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(40) NOT NULL, customer_id INT NULL, identifier VARCHAR(80) NULL, owner_name VARCHAR(80) NULL,
  plan VARCHAR(16) NOT NULL, vcpu INT NOT NULL, ram_gb INT NOT NULL, disk_gb INT NOT NULL, image VARCHAR(16) NOT NULL,
  region VARCHAR(16) NOT NULL DEFAULT 'LS-1', ip VARCHAR(18) NULL,
  desired VARCHAR(10) NOT NULL DEFAULT 'running',          -- what the customer wants: running · stopped
  state VARCHAR(16) NOT NULL DEFAULT 'provisioning',        -- provisioning · running · stopped · host_down · no_capacity · suspended
  host_rack INT NULL, host_u INT NULL, firewall TEXT NULL, log LONGTEXT NULL,
  price DECIMAL(10,2) NOT NULL DEFAULT 0,
  status VARCHAR(12) NOT NULL DEFAULT 'active',             -- active · suspended · cancelled
  created_at INT NOT NULL, next_bill_at INT NOT NULL, overdue_since INT NULL, booted_at INT NULL, state_at INT NULL,
  UNIQUE KEY ip (ip), KEY identifier (identifier), KEY host (host_rack, host_u)
);

CREATE TABLE IF NOT EXISTS ops_cloud_snapshots (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  vm_id INT NOT NULL, name VARCHAR(40) NOT NULL, size_gb INT NOT NULL DEFAULT 0, created_at INT NOT NULL,
  KEY vm (vm_id)
);

CREATE TABLE IF NOT EXISTS ops_dc_status (
  k VARCHAR(32) NOT NULL PRIMARY KEY, v LONGTEXT NULL, updated_at INT NOT NULL DEFAULT 0
);
