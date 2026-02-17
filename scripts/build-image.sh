#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if image name is provided
if [ $# -eq 0 ]; then
    log_error "Usage: $0 <image-name>"
    exit 1
fi

IMAGE_NAME="$1"
CONTAINER_NAME="build-$(date +%s)-$$"
LXD_REMOTE="flyinghost"
BASE_IMAGE="ubuntu:24.04"
CLEANUP_DONE=false

log_info "Starting LXD image build process"
log_info "Image name: $IMAGE_NAME"
log_info "Container name: $CONTAINER_NAME"

# Cleanup function
cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    
    log_warn "Performing cleanup..."
    
    # Stop and delete container if it exists
    if lxc info "$LXD_REMOTE:$CONTAINER_NAME" >/dev/null 2>&1; then
        log_info "Stopping container $CONTAINER_NAME..."
        lxc stop "$LXD_REMOTE:$CONTAINER_NAME" --force 2>/dev/null || true
        
        log_info "Deleting container $CONTAINER_NAME..."
        lxc delete "$LXD_REMOTE:$CONTAINER_NAME" --force 2>/dev/null || true
    fi
    
    CLEANUP_DONE=true
    log_info "Cleanup complete"
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# Create container
log_info "Creating container from $BASE_IMAGE..."
lxc launch "$LXD_REMOTE:$BASE_IMAGE" "$LXD_REMOTE:$CONTAINER_NAME"

# Wait for container to start
log_info "Waiting for container to start..."
sleep 10

# Wait for container to be ready
log_info "Waiting for container network..."
for i in {1..30}; do
    if lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- systemctl is-system-running --wait 2>/dev/null | grep -q "running\|degraded"; then
        log_info "Container is ready"
        break
    fi
    sleep 2
done

# Execute setup commands
log_info "Starting container setup..."

# System packages
log_info "Installing system packages..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c '
set -euo pipefail
apt update
DEBIAN_FRONTEND=noninteractive apt -y upgrade
apt install -y --no-install-recommends \
  ca-certificates apt-transport-https imagemagick mariadb-client software-properties-common \
  curl wget unzip zip gnupg lsb-release ufw mariadb-server unattended-upgrades vim \
  nginx redis-server
dpkg-reconfigure -f noninteractive unattended-upgrades
'

# MariaDB, Nginx, Redis
log_info "Configuring services..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c '
set -euo pipefail
systemctl enable nginx mariadb redis-server
systemctl start nginx mariadb redis-server
'

# MariaDB: secure root, remove test users
log_info "Securing MariaDB..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c "
set -euo pipefail
mysql --protocol=socket <<'EOF'
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';
DROP USER IF EXISTS 'root'@'%';
DROP USER IF EXISTS 'root'@'127.0.0.1';
DROP USER IF EXISTS 'root'@'::1';
CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED VIA unix_socket;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF
"

# PHP 8.3, 8.4, 8.5
log_info "Installing PHP versions..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c '
set -euo pipefail
add-apt-repository -y ppa:ondrej/php
apt update
apt install -y \
  php8.3-fpm php8.3-redis php8.3-cli php8.3-common php8.3-mysql php8.3-curl php8.3-gd php8.3-intl php8.3-mbstring php8.3-imagick php8.3-soap php8.3-xml php8.3-zip php8.3-opcache php8.3-imap php8.3-gmp php8.3-bcmath \
  php8.4-fpm php8.4-redis php8.4-cli php8.4-common php8.4-mysql php8.4-curl php8.4-gd php8.4-intl php8.4-mbstring php8.4-imagick php8.4-soap php8.4-xml php8.4-zip php8.4-opcache php8.4-imap php8.4-gmp php8.4-bcmath \
  php8.5-fpm php8.5-redis php8.5-cli php8.5-common php8.5-mysql php8.5-curl php8.5-gd php8.5-intl php8.5-mbstring php8.5-imagick php8.5-soap php8.5-xml php8.5-zip php8.5-imap php8.5-gmp php8.5-bcmath
update-alternatives --set php-fpm.sock /run/php/php8.3-fpm.sock
'

# PHP config
log_info "Configuring PHP..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c "
set -euo pipefail
mkdir -p /var/log/php
chown www-data:www-data /var/log/php
chmod 755 /var/log/php
PHP_SETTINGS='max_input_vars=3000
max_execution_time=120
memory_limit=512M
max_input_time=120
upload_max_filesize=64M
post_max_size=64M
log_errors=On
error_log=/var/log/php/error.log'
for ver in 8.3 8.4 8.5; do
  for s in max_input_vars max_execution_time memory_limit max_input_time upload_max_filesize post_max_size log_errors error_log; do
    sed -i \"/^\$s=/d\" /etc/php/\$ver/fpm/php.ini
  done
  echo \"\$PHP_SETTINGS\" >> /etc/php/\$ver/fpm/php.ini
done
"

# WP-CLI, WordPress core, Redis cache plugin
log_info "Installing WP-CLI and WordPress..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c '
set -euo pipefail
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
mkdir -p /var/www/public /var/www/public/wp-content/mu-plugins
wp core download --path=/var/www/public --allow-root
rm -rf /var/www/html/
curl -sLo /tmp/redis-cache.zip https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip
unzip -q /tmp/redis-cache.zip -d /tmp
mv /tmp/redis-cache /var/www/public/wp-content/plugins/
chown -R www-data:www-data /var/www/public
'

# Download and copy mu-plugin
log_info "Downloading and installing mu-plugin..."
curl -sLo /tmp/flyinghost.php https://raw.githubusercontent.com/Flying-Host/mu-plugin/main/flyinghost.php
lxc file push /tmp/flyinghost.php "$LXD_REMOTE:$CONTAINER_NAME/var/www/public/wp-content/mu-plugins/flyinghost.php"
rm -f /tmp/flyinghost.php

# SSH configuration
log_info "Configuring SSH and wordpress user..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c "
set -euo pipefail
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
id -u wordpress >/dev/null 2>&1 || useradd -m -s /bin/bash wordpress
usermod -aG www-data wordpress
chown -R www-data:www-data /var/www/public
chmod -R g+rwX /var/www/public
find /var/www/public -type d -exec chmod g+s {} \;
echo 'cd /var/www/public' >> /home/wordpress/.bashrc
chmod -x /etc/update-motd.d/*
echo 'Welcome to FlyingHost Terminal' | tee /etc/motd
truncate -s 0 /etc/legal
"

# Log rotation
log_info "Setting up log rotation..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c "
set -euo pipefail
cat > /etc/logrotate.d/flyinghost-logs <<'EOF'
/var/log/nginx/*.log /var/log/php/*.log {
  size 500k
  rotate 1
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
  create 0640 www-data www-data
}
EOF
"

# PHPMyAdmin installation
log_info "Installing PHPMyAdmin..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c '
set -euo pipefail
echo "phpmyadmin phpmyadmin/internal/skip-preseed boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | debconf-set-selections
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
apt install -y phpmyadmin
'

# Copy configuration files
log_info "Copying configuration files to container..."

# PHPMyAdmin files
lxc file push phpmyadmin/signon.php "$LXD_REMOTE:$CONTAINER_NAME/usr/share/phpmyadmin/signon.php"
lxc file push phpmyadmin/logout.php "$LXD_REMOTE:$CONTAINER_NAME/usr/share/phpmyadmin/logout.php"
lxc file push phpmyadmin/config.inc.php "$LXD_REMOTE:$CONTAINER_NAME/etc/phpmyadmin/config.inc.php"

# Bootstrap script
lxc file push bootstrap.sh "$LXD_REMOTE:$CONTAINER_NAME/usr/local/sbin/bootstrap.sh"

# Nginx config
lxc file push nginx/wordpress.conf "$LXD_REMOTE:$CONTAINER_NAME/etc/nginx/sites-available/wordpress.conf"

# Final nginx and cloud-init configuration
log_info "Finalizing configuration..."
lxc exec "$LXD_REMOTE:$CONTAINER_NAME" -- bash -c "
set -euo pipefail
ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/
rm -rf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

chmod 750 /usr/local/sbin/bootstrap.sh
cat > /etc/cloud/cloud.cfg.d/99-bootstrap.cfg <<'EOF'
#cloud-config
runcmd:
  - [bash, -lc, \"/usr/local/sbin/bootstrap.sh >> /var/log/bootstrap.log 2>&1\"]
EOF
cloud-init clean --logs
rm -rf /var/lib/cloud/*
"

# Stop the container
log_info "Stopping container..."
lxc stop "$LXD_REMOTE:$CONTAINER_NAME"

# Wait for container to stop
sleep 5

# Create image from container
log_info "Creating LXD image '$IMAGE_NAME' from container..."
lxc publish "$LXD_REMOTE:$CONTAINER_NAME" "$LXD_REMOTE:" \
    --alias "$IMAGE_NAME" \
    description="FlyingHost WordPress optimized Ubuntu 24.04 LTS" \
    os=ubuntu \
    release=24.04

log_info "Image '$IMAGE_NAME' created successfully"

# List images to verify
log_info "Verifying image creation..."
lxc image list "$LXD_REMOTE:" | grep "$IMAGE_NAME" || log_warn "Image not found in list (might still be valid)"

log_info "✅ Build complete! LXD image '$IMAGE_NAME' is ready to use."
