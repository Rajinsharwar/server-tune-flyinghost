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

# Check required environment variables
if [ -z "${LXD_HOST:-}" ]; then
    log_error "LXD_HOST environment variable is required"
    exit 1
fi

if [ -z "${LXD_CERT_PASS:-}" ]; then
    log_error "LXD_CERT_PASS environment variable is required"
    exit 1
fi

if [ ! -f "/tmp/lxd-client.pfx" ]; then
    log_error "PFX certificate not found at /tmp/lxd-client.pfx"
    exit 1
fi

IMAGE_NAME="$1"
CONTAINER_NAME="build-$(date +%s)-$$"
BASE_IMAGE="ubuntu/24.04"
CLEANUP_DONE=false
LXD_URL="https://$LXD_HOST:8443"
CERT_AUTH="--cert-type P12 --cert /tmp/lxd-client.pfx:$LXD_CERT_PASS"

log_info "Starting LXD image build process"
log_info "Image name: $IMAGE_NAME"
log_info "Container name: $CONTAINER_NAME"
log_info "LXD server: $LXD_URL"

# Helper function to make LXD API calls
lxd_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    if [ -n "$data" ]; then
        curl -k -X "$method" $CERT_AUTH \
            "$LXD_URL$endpoint" \
            -H "Content-Type: application/json" \
            -d "$data" \
            -s
    else
        curl -k -X "$method" $CERT_AUTH \
            "$LXD_URL$endpoint" \
            -s
    fi
}

# Helper function to wait for an operation to complete
wait_for_operation() {
    local operation_path="$1"
    local timeout="${2:-300}"
    
    log_info "Waiting for operation: $operation_path"
    
    local response
    response=$(curl -k $CERT_AUTH \
        "$LXD_URL$operation_path/wait?timeout=$timeout" \
        -s)
    
    local status_code
    status_code=$(echo "$response" | jq -r '.metadata.status_code // 0')
    
    if [ "$status_code" != "200" ]; then
        log_error "Operation failed with status code: $status_code"
        echo "$response" | jq . || echo "$response"
        return 1
    fi
    
    log_info "Operation completed successfully"
    return 0
}

# Helper function to execute command in container
exec_in_container() {
    local command="$1"
    
    log_info "Executing command in container..."
    
    local exec_data
    exec_data=$(cat <<EOF
{
  "command": ["bash", "-c", "$command"],
  "wait-for-websocket": false,
  "record-output": true,
  "environment": {}
}
EOF
)
    
    local response
    response=$(lxd_api POST "/1.0/containers/$CONTAINER_NAME/exec" "$exec_data")
    
    local operation
    operation=$(echo "$response" | jq -r '.operation // empty')
    
    if [ -z "$operation" ]; then
        log_error "Failed to execute command"
        echo "$response" | jq . || echo "$response"
        return 1
    fi
    
    wait_for_operation "$operation"
}

# Cleanup function
cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    
    log_warn "Performing cleanup..."
    
    # Check if container exists
    local check_response
    check_response=$(lxd_api GET "/1.0/containers/$CONTAINER_NAME" 2>/dev/null || echo '{"error":"not found"}')
    
    if echo "$check_response" | jq -e '.metadata' >/dev/null 2>&1; then
        log_info "Stopping container $CONTAINER_NAME..."
        
        local stop_data='{"action":"stop","timeout":30,"force":true}'
        lxd_api PUT "/1.0/containers/$CONTAINER_NAME/state" "$stop_data" >/dev/null 2>&1 || true
        sleep 3
        
        log_info "Deleting container $CONTAINER_NAME..."
        local delete_response
        delete_response=$(lxd_api DELETE "/1.0/containers/$CONTAINER_NAME")
        
        local operation
        operation=$(echo "$delete_response" | jq -r '.operation // empty')
        if [ -n "$operation" ]; then
            wait_for_operation "$operation" 60 || true
        fi
    fi
    
    # Cleanup PFX file
    rm -f /tmp/lxd-client.pfx
    
    CLEANUP_DONE=true
    log_info "Cleanup complete"
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# Create container
log_info "Creating container from $BASE_IMAGE..."

CREATE_DATA=$(cat <<EOF
{
  "name": "$CONTAINER_NAME",
  "source": {
    "type": "image",
    "alias": "$BASE_IMAGE"
  },
  "config": {},
  "devices": {}
}
EOF
)

CREATE_RESPONSE=$(lxd_api POST "/1.0/containers" "$CREATE_DATA")
OPERATION=$(echo "$CREATE_RESPONSE" | jq -r '.operation // empty')

if [ -z "$OPERATION" ]; then
    log_error "Failed to create container"
    echo "$CREATE_RESPONSE" | jq . || echo "$CREATE_RESPONSE"
    exit 1
fi

wait_for_operation "$OPERATION"

# Start container
log_info "Starting container..."
START_DATA='{"action":"start","timeout":30}'
START_RESPONSE=$(lxd_api PUT "/1.0/containers/$CONTAINER_NAME/state" "$START_DATA")
OPERATION=$(echo "$START_RESPONSE" | jq -r '.operation // empty')

if [ -n "$OPERATION" ]; then
    wait_for_operation "$OPERATION"
fi

# Wait for container to be ready
log_info "Waiting for container to be ready..."
sleep 10

# Wait for systemd to be ready
for i in {1..30}; do
    if exec_in_container "systemctl is-system-running --wait 2>/dev/null | grep -q 'running\|degraded'"; then
        log_info "Container is ready"
        break
    fi
    sleep 2
done

# Execute setup commands
log_info "Starting container setup..."

# System packages
log_info "Installing system packages..."
exec_in_container '
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
exec_in_container '
set -euo pipefail
systemctl enable nginx mariadb redis-server
systemctl start nginx mariadb redis-server
'

# MariaDB: secure root, remove test users
log_info "Securing MariaDB..."
exec_in_container "
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
exec_in_container '
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
exec_in_container "
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
exec_in_container '
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

# Push file to container using LXD file API
log_info "Copying mu-plugin to container..."
curl -k -X POST $CERT_AUTH \
    "$LXD_URL/1.0/containers/$CONTAINER_NAME/files?path=/var/www/public/wp-content/mu-plugins/flyinghost.php" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @/tmp/flyinghost.php

rm -f /tmp/flyinghost.php

# SSH configuration
log_info "Configuring SSH and wordpress user..."
exec_in_container "
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
exec_in_container "
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
exec_in_container '
set -euo pipefail
echo "phpmyadmin phpmyadmin/internal/skip-preseed boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | debconf-set-selections
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
apt install -y phpmyadmin
'

# Copy configuration files using LXD file API
log_info "Copying configuration files to container..."

# PHPMyAdmin files
log_info "Copying PHPMyAdmin configuration files..."
curl -k -X POST $CERT_AUTH \
    "$LXD_URL/1.0/containers/$CONTAINER_NAME/files?path=/usr/share/phpmyadmin/signon.php" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @phpmyadmin/signon.php

curl -k -X POST $CERT_AUTH \
    "$LXD_URL/1.0/containers/$CONTAINER_NAME/files?path=/usr/share/phpmyadmin/logout.php" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @phpmyadmin/logout.php

curl -k -X POST $CERT_AUTH \
    "$LXD_URL/1.0/containers/$CONTAINER_NAME/files?path=/etc/phpmyadmin/config.inc.php" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @phpmyadmin/config.inc.php

# Bootstrap script
log_info "Copying bootstrap script..."
curl -k -X POST $CERT_AUTH \
    "$LXD_URL/1.0/containers/$CONTAINER_NAME/files?path=/usr/local/sbin/bootstrap.sh" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @bootstrap.sh

# Nginx config
log_info "Copying Nginx configuration..."
curl -k -X POST $CERT_AUTH \
    "$LXD_URL/1.0/containers/$CONTAINER_NAME/files?path=/etc/nginx/sites-available/wordpress.conf" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @nginx/wordpress.conf

# Final nginx and cloud-init configuration
log_info "Finalizing configuration..."
exec_in_container "
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
STOP_DATA='{"action":"stop","timeout":30}'
STOP_RESPONSE=$(lxd_api PUT "/1.0/containers/$CONTAINER_NAME/state" "$STOP_DATA")
OPERATION=$(echo "$STOP_RESPONSE" | jq -r '.operation // empty')

if [ -n "$OPERATION" ]; then
    wait_for_operation "$OPERATION"
fi

# Wait for container to stop
sleep 5

# Create image from container
log_info "Creating LXD image '$IMAGE_NAME' from container..."

IMAGE_DATA=$(cat <<EOF
{
  "source": {
    "type": "container",
    "name": "$CONTAINER_NAME"
  },
  "properties": {
    "description": "$IMAGE_NAME - Built by GitHub Actions",
    "os": "ubuntu",
    "release": "24.04"
  },
  "public": false,
  "aliases": [{"name": "$IMAGE_NAME"}]
}
EOF
)

IMAGE_RESPONSE=$(lxd_api POST "/1.0/images" "$IMAGE_DATA")
OPERATION=$(echo "$IMAGE_RESPONSE" | jq -r '.operation // empty')

if [ -z "$OPERATION" ]; then
    log_error "Failed to create image"
    echo "$IMAGE_RESPONSE" | jq . || echo "$IMAGE_RESPONSE"
    exit 1
fi

wait_for_operation "$OPERATION"

log_info "Image '$IMAGE_NAME' created successfully"

# List images to verify
log_info "Verifying image creation..."
IMAGES_RESPONSE=$(lxd_api GET "/1.0/images")
if echo "$IMAGES_RESPONSE" | jq -e ".metadata[] | select(. | contains(\"$IMAGE_NAME\"))" >/dev/null 2>&1; then
    log_info "Image verified in LXD image list"
else
    log_warn "Image not found in list (might still be valid)"
fi

log_info "✅ Build complete! LXD image '$IMAGE_NAME' is ready to use."
