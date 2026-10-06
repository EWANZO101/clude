-- Optional: the resource also creates this table automatically on start.
CREATE TABLE IF NOT EXISTS `advanced_parking` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `plate` VARCHAR(12) NOT NULL,
  `owner` VARCHAR(64) NOT NULL,
  `model` BIGINT NOT NULL,
  `vtype` VARCHAR(20) NOT NULL DEFAULT 'automobile',
  `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL, `heading` FLOAT NOT NULL,
  `props` LONGTEXT NOT NULL,
  `owner_name` VARCHAR(100) DEFAULT NULL,
  `zone` VARCHAR(50) DEFAULT NULL,
  `spot` INT DEFAULT NULL,
  `fines` INT NOT NULL DEFAULT 0,
  `impounded` TINYINT NOT NULL DEFAULT 0,
  `impound_reason` VARCHAR(255) DEFAULT NULL,
  `parked_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `plate` (`plate`),
  KEY `owner` (`owner`)
);

CREATE TABLE IF NOT EXISTS `parking_logs` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `action` VARCHAR(20) NOT NULL,
  `plate` VARCHAR(12) DEFAULT NULL,
  `actor` VARCHAR(64) NOT NULL DEFAULT 'system',
  `actor_name` VARCHAR(100) DEFAULT NULL,
  `owner` VARCHAR(64) DEFAULT NULL,
  `lot` VARCHAR(50) DEFAULT NULL,
  `spot` INT DEFAULT NULL,
  `amount` INT NOT NULL DEFAULT 0,
  `fines` INT NOT NULL DEFAULT 0,
  `details` VARCHAR(255) DEFAULT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `plate` (`plate`),
  KEY `action_time` (`action`, `created_at`),
  KEY `created_at` (`created_at`)
);


CREATE TABLE IF NOT EXISTS `ParkingLots` (
  `name` VARCHAR(50) NOT NULL,
  `label` VARCHAR(60) NOT NULL,
  `price_per_hour` INT NOT NULL DEFAULT 0,
  `max_fee` INT NOT NULL DEFAULT 0,
  `blip` TINYINT NOT NULL DEFAULT 1,
  `coords` VARCHAR(100) DEFAULT NULL,
  `radius` FLOAT DEFAULT NULL,
  `machine` VARCHAR(100) DEFAULT NULL,
  `zone` LONGTEXT DEFAULT NULL,
  `spots` LONGTEXT NOT NULL,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`name`)
);
-- The Legion Square and Del Perro Pier example lots are inserted automatically on first start.
