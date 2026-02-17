#!/usr/bin/env bash
set -euo pipefail

WEB_ROOT="${WEB_ROOT:-/var/www/public}"

DB_NAME="wordpress"
DB_USER="wordpress"
DB_HOST="localhost"

# Generate random DB password (not persisted)
DB_PASS="$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_')"

# Wait for MariaDB
for i in {1..30}; do
  mysqladmin --protocol=socket ping >/dev/null 2>&1 && break
  sleep 1
done

# Create DB + user
mysql --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

# Create wp-config.php
wp config create \
  --path="$WEB_ROOT" \
  --dbname="$DB_NAME" \
  --dbuser="$DB_USER" \
  --dbpass="$DB_PASS" \
  --dbhost="$DB_HOST" \
  --dbcharset="utf8mb4" \
  --skip-check \
  --allow-root

# Add salts
wp config shuffle-salts --path="$WEB_ROOT" --allow-root

# Disable WP-Cron (use system cron instead)
wp config set DISABLE_WP_CRON true --raw --path="$WEB_ROOT" --allow-root

# Install system cron for WordPress (every minute)
cat > /etc/cron.d/wordpress-cron <<CRON
* * * * * www-data cd $WEB_ROOT && /usr/local/bin/wp cron event run --allow-root
CRON
chmod 644 /etc/cron.d/wordpress-cron

# Fix ownership
chown www-data:www-data "$WEB_ROOT/wp-config.php"

# Reset last modified time for all files under web root
find "$WEB_ROOT" -exec touch -m {} +

echo "Bootstrap complete"

# Delete this script after execution
rm -- "$0"