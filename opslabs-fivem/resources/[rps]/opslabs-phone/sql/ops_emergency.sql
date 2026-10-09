-- OPS Emergency Alerts: city-wide / area / staff alerts sent by companies with the premium switched on (OPS Hub → Companies).
-- Shared with OPS Hub (ops_emergency.py). opslabs-phone creates this table and the ops_companies.emergency_alerts column on start.
-- status: pending (sent from OPS Hub, the game picks it up) → live → ended (expired) | cancelled
CREATE TABLE IF NOT EXISTS ops_emergency_alerts (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  company_id INT NOT NULL,
  severity VARCHAR(10) NOT NULL DEFAULT 'warning',
  title VARCHAR(80) NOT NULL,
  body VARCHAR(600) NOT NULL,
  audience VARCHAR(8) NOT NULL DEFAULT 'all',
  x FLOAT NULL, y FLOAT NULL, radius INT NULL, area_label VARCHAR(80) NULL,
  status VARCHAR(10) NOT NULL DEFAULT 'pending',
  source VARCHAR(8) NOT NULL DEFAULT 'phone',
  sent_by VARCHAR(60) NULL,
  reach INT NOT NULL DEFAULT 0,
  created_at INT NOT NULL,
  expires_at INT NOT NULL,
  ended_at INT NULL,
  KEY status_ (status, expires_at),
  KEY company (company_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
