-- opslabs-phone keeps all of its data in its own opslabs_phone_* tables. They are
-- created automatically on resource start, so no SQL import is required.

local schema = {
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_users` (
        `identifier` VARCHAR(60) NOT NULL,
        `phone_number` VARCHAR(20) NOT NULL,
        `email` VARCHAR(100) DEFAULT NULL,
        `settings` LONGTEXT DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`identifier`),
        UNIQUE KEY `phone_number` (`phone_number`),
        UNIQUE KEY `email` (`email`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_contacts` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `owner` VARCHAR(20) NOT NULL,
        `name` VARCHAR(60) NOT NULL,
        `number` VARCHAR(20) NOT NULL,
        `email` VARCHAR(100) DEFAULT NULL,
        `avatar` VARCHAR(512) DEFAULT NULL,
        `favorite` TINYINT(1) NOT NULL DEFAULT 0,
        `blocked` TINYINT(1) NOT NULL DEFAULT 0,
        PRIMARY KEY (`id`),
        KEY `owner` (`owner`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_messages` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `sender` VARCHAR(20) NOT NULL,
        `receiver` VARCHAR(20) NOT NULL,
        `message` TEXT NOT NULL,
        `attachment` LONGTEXT DEFAULT NULL,
        `is_read` TINYINT(1) NOT NULL DEFAULT 0,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `pair` (`sender`, `receiver`),
        KEY `receiver` (`receiver`, `is_read`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_calls` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `caller` VARCHAR(20) NOT NULL,
        `callee` VARCHAR(20) NOT NULL,
        `status` VARCHAR(16) NOT NULL DEFAULT 'missed',
        `duration` INT NOT NULL DEFAULT 0,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `caller` (`caller`),
        KEY `callee` (`callee`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_notes` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `owner` VARCHAR(60) NOT NULL,
        `title` VARCHAR(120) NOT NULL DEFAULT '',
        `body` TEXT NOT NULL,
        `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `owner` (`owner`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_photos` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `owner` VARCHAR(60) NOT NULL,
        `url` VARCHAR(1024) NOT NULL,
        `favorite` TINYINT(1) NOT NULL DEFAULT 0,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `owner` (`owner`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_mail` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `sender` VARCHAR(100) NOT NULL,
        `sender_name` VARCHAR(100) DEFAULT NULL,
        `receiver` VARCHAR(100) NOT NULL,
        `subject` VARCHAR(160) NOT NULL DEFAULT '',
        `body` TEXT NOT NULL,
        `is_read` TINYINT(1) NOT NULL DEFAULT 0,
        `deleted` TINYINT(1) NOT NULL DEFAULT 0,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `receiver` (`receiver`),
        KEY `sender` (`sender`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_chirp_profiles` (
        `identifier` VARCHAR(60) NOT NULL,
        `handle` VARCHAR(30) NOT NULL,
        `display_name` VARCHAR(60) NOT NULL,
        `avatar` VARCHAR(512) DEFAULT NULL,
        `bio` VARCHAR(200) DEFAULT NULL,
        PRIMARY KEY (`identifier`),
        UNIQUE KEY `handle` (`handle`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_chirp_posts` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `author` VARCHAR(60) NOT NULL,
        `content` VARCHAR(400) NOT NULL,
        `image` VARCHAR(1024) DEFAULT NULL,
        `reply_to` INT DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `author` (`author`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_chirp_likes` (
        `post_id` INT NOT NULL,
        `identifier` VARCHAR(60) NOT NULL,
        PRIMARY KEY (`post_id`, `identifier`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_bank_transactions` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `identifier` VARCHAR(60) NOT NULL,
        `label` VARCHAR(120) NOT NULL,
        `amount` INT NOT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `identifier` (`identifier`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_service_requests` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `service` VARCHAR(30) NOT NULL,
        `caller_number` VARCHAR(20) NOT NULL,
        `caller_name` VARCHAR(60) NOT NULL,
        `message` VARCHAR(400) NOT NULL,
        `x` FLOAT NOT NULL,
        `y` FLOAT NOT NULL,
        `z` FLOAT NOT NULL,
        `status` VARCHAR(16) NOT NULL DEFAULT 'open',
        `handled_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `service` (`service`, `status`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_places` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `name` VARCHAR(80) NOT NULL,
        `icon` VARCHAR(40) NOT NULL DEFAULT 'fa-location-dot',
        `category` VARCHAR(30) NOT NULL DEFAULT 'General',
        `x` FLOAT NOT NULL,
        `y` FLOAT NOT NULL,
        `z` FLOAT NOT NULL,
        `blip` TINYINT(1) NOT NULL DEFAULT 0,
        `blip_sprite` INT NOT NULL DEFAULT 1,
        `blip_color` INT NOT NULL DEFAULT 0,
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_wallpapers` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `label` VARCHAR(40) NOT NULL,
        `url` VARCHAR(1024) NOT NULL,
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_music` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `owner` VARCHAR(60) NOT NULL,
        `app` VARCHAR(30) NOT NULL,
        `title` VARCHAR(120) NOT NULL,
        `artist` VARCHAR(120) NOT NULL DEFAULT '',
        `url` VARCHAR(1024) NOT NULL,
        `art` VARCHAR(1024) DEFAULT NULL,
        `kind` VARCHAR(16) NOT NULL DEFAULT 'track',
        `playlist` VARCHAR(60) DEFAULT NULL,
        `liked` TINYINT(1) NOT NULL DEFAULT 0,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `owner_app` (`owner`, `app`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    -- linked Spotify / TIDAL accounts (tokens never leave the server)
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_oauth` (
        `identifier` VARCHAR(60) NOT NULL,
        `provider` VARCHAR(20) NOT NULL,
        `access_token` TEXT NOT NULL,
        `refresh_token` TEXT DEFAULT NULL,
        `expires_at` INT NOT NULL DEFAULT 0,
        `account_id` VARCHAR(120) DEFAULT NULL,
        `account_name` VARCHAR(120) DEFAULT NULL,
        `product` VARCHAR(30) DEFAULT NULL,
        `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (`identifier`, `provider`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    -- Ops-Networks engineer app: own accounts (scrypt-hashed passwords), jobs and pay
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_opsnet_users` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `username` VARCHAR(24) NOT NULL,
        `pass_hash` VARCHAR(255) NOT NULL,
        `identifier` VARCHAR(60) DEFAULT NULL,
        `display_name` VARCHAR(60) NOT NULL DEFAULT '',
        `role` VARCHAR(20) NOT NULL DEFAULT 'custom',
        `perms` TEXT DEFAULT NULL,
        `disabled` TINYINT(1) NOT NULL DEFAULT 0,
        `default_pw` TINYINT(1) NOT NULL DEFAULT 0,
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` INT NOT NULL DEFAULT 0,
        `last_login` INT DEFAULT NULL,
        PRIMARY KEY (`id`),
        UNIQUE KEY `username` (`username`),
        KEY `identifier` (`identifier`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_opsnet_jobs` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `kind` VARCHAR(10) NOT NULL DEFAULT 'planned',
        `fault_id` INT DEFAULT NULL,
        `fault_type` VARCHAR(30) DEFAULT NULL,
        `fault_status` VARCHAR(16) DEFAULT NULL,
        `title` VARCHAR(120) NOT NULL,
        `description` TEXT DEFAULT NULL,
        `location` VARCHAR(160) DEFAULT NULL,
        `x` FLOAT NOT NULL DEFAULT 0,
        `y` FLOAT NOT NULL DEFAULT 0,
        `z` FLOAT NOT NULL DEFAULT 0,
        `pole_id` INT DEFAULT NULL,
        `priority` VARCHAR(10) NOT NULL DEFAULT 'medium',
        `status` VARCHAR(12) NOT NULL DEFAULT 'open',
        `assigned_to` INT DEFAULT NULL,
        `assigned_name` VARCHAR(60) DEFAULT NULL,
        `pay` INT NOT NULL DEFAULT 0,
        `paid` TINYINT(1) NOT NULL DEFAULT 0,
        `paid_amount` INT NOT NULL DEFAULT 0,
        `created_by` VARCHAR(60) DEFAULT NULL,
        `created_at` INT NOT NULL DEFAULT 0,
        `completed_at` INT DEFAULT NULL,
        `completed_by` INT DEFAULT NULL,
        `completed_name` VARCHAR(60) DEFAULT NULL,
        PRIMARY KEY (`id`),
        UNIQUE KEY `fault_id` (`fault_id`),
        KEY `status` (`status`),
        KEY `assigned_to` (`assigned_to`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_opsnet_payments` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `user_id` INT NOT NULL,
        `identifier` VARCHAR(60) NOT NULL,
        `job_id` INT DEFAULT NULL,
        `label` VARCHAR(160) NOT NULL,
        `amount` INT NOT NULL DEFAULT 0,
        `bonus` INT NOT NULL DEFAULT 0,
        `created_at` INT NOT NULL DEFAULT 0,
        PRIMARY KEY (`id`),
        KEY `user_id` (`user_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

    -- server-wide key/value settings changed in-game (e.g. mail domain)
    [[CREATE TABLE IF NOT EXISTS `opslabs_phone_kv` (
        `k` VARCHAR(60) NOT NULL,
        `v` TEXT NOT NULL,
        PRIMARY KEY (`k`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

-- columns added after the first release (MySQL 8 has no ADD COLUMN IF NOT EXISTS)
local columns = {
    { 'opslabs_phone_users', 'display_name', '`display_name` VARCHAR(60) DEFAULT NULL' },
    { 'opslabs_phone_users', 'setup_done', '`setup_done` TINYINT(1) NOT NULL DEFAULT 0' },
}

DatabaseReady = false
KV = {}

MySQL.ready(function()
    for _, query in ipairs(schema) do
        MySQL.query.await(query)
    end
    for _, c in ipairs(columns) do
        local exists = MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?', { c[1], c[2] })
        if exists == 0 then MySQL.query.await(('ALTER TABLE `%s` ADD COLUMN %s'):format(c[1], c[3])) end
    end
    for _, row in ipairs(MySQL.query.await('SELECT k, v FROM opslabs_phone_kv') or {}) do
        KV[row.k] = row.v
    end
    DatabaseReady = true
    print('^2[opslabs-phone]^7 database ready')
end)

function SetKV(k, v)
    KV[k] = v
    MySQL.query.await('INSERT INTO opslabs_phone_kv (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v)', { k, v })
end

--- Mail domain: set in-game from the Developer app, otherwise Config.MailDomain.
function GetMailDomain()
    return KV.mail_domain or Config.MailDomain
end

function AwaitDatabase()
    while not DatabaseReady do Wait(100) end
end
