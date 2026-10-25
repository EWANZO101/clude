CREATE TABLE IF NOT EXISTS `opslabs_mdt_installs` (
    `plate` VARCHAR(12) NOT NULL PRIMARY KEY,
    `model` VARCHAR(64) NOT NULL,
    `installed_by` VARCHAR(100) DEFAULT NULL,
    `installed_at` INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `opslabs_mdt_officers` (
    `identifier` VARCHAR(64) NOT NULL PRIMARY KEY,
    `cad_token` VARCHAR(191) NOT NULL,
    `cad_username` VARCHAR(100) DEFAULT NULL,
    `linked_at` INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
