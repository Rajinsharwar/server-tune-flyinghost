#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate required environment variables
if [[ -z "${LXD_HOST:-}" ]]; then
  log_error "LXD_HOST is not set"
  exit 1
fi

if [[ -z "${LXD_CERT_FILE:-}" ]]; then
  log_error "LXD_CERT_FILE is not set"
  exit 1
fi

if [[ -z "${LXD_CERT_PASS:-}" ]]; then
  log_error "LXD_CERT_PASS is not set"
  exit 1
fi

if [[ -z "${IMAGE_NAME:-}" ]]; then
  log_error "IMAGE_NAME is not set"
  exit 1
fi

# LXD API base URL
LXD_API="https://${LXD_HOST}:8443/1.0"

# Container name (temporary, will be deleted after image creation)
CONTAINER_NAME="build-${IMAGE_NAME}-$(date +%s)"

log_info "Starting LXD image build process"
log_info "Target image name: ${IMAGE_NAME}"
log_info "Temporary container: ${CONTAINER_NAME}"

# Function to make LXD API calls using curl with PFX certificate
lxd_api_call() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  
  local url="${LXD_API}${endpoint}"
  local args=(
    -s
    -X "$method"
    --cert-type P12
    --cert "${LXD_CERT_FILE}:${LXD_CERT_PASS}"
    # Skip certificate verification to match Next.js app behavior (rejectUnauthorized: false)
    # This is acceptable for internal infrastructure where the server cert may be self-signed
    -k
    -H "Content-Type: application/json"
  )
  
  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi
  
  curl "${args[@]}" "$url"
}

# Function to wait for LXD operation to complete
wait_for_operation() {
  local operation_id="$1"
  local max_wait="${2:-300}"  # Default 5 minutes
  local elapsed=0
  
  log_info "Waiting for operation: $operation_id"
  
  while [ $elapsed -lt $max_wait ]; do
    local status=$(lxd_api_call GET "/operations/${operation_id}" | jq -r '.metadata.status')
    
    if [[ "$status" == "Success" ]]; then
      log_info "Operation completed successfully"
      return 0
    elif [[ "$status" == "Failure" ]]; then
      log_error "Operation failed"
      lxd_api_call GET "/operations/${operation_id}" | jq '.metadata.err'
      return 1
    fi
    
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  log_error "Operation timed out after ${max_wait} seconds"
  return 1
}

# Function to execute command in container
exec_in_container() {
  local command="$1"
  local wait_for_websocket="${2:-true}"
  
  log_info "Executing in container: $command"
  
  local payload=$(jq -n \
    --arg cmd "$command" \
    --argjson wait "$([[ "$wait_for_websocket" == "true" ]] && echo true || echo false)" \
    '{
      "command": ["/bin/bash", "-c", $cmd],
      "record-output": true,
      "interactive": false,
      "environment": {}
    }')
  
  local response=$(lxd_api_call POST "/instances/${CONTAINER_NAME}/exec" "$payload")
  local operation_id=$(echo "$response" | jq -r '.operation' | sed 's|/1.0/operations/||')
  
  if [[ -z "$operation_id" || "$operation_id" == "null" ]]; then
    log_error "Failed to get operation ID"
    echo "$response" | jq .
    return 1
  fi
  
  wait_for_operation "$operation_id" 600
  
  # Get the output
  local output=$(lxd_api_call GET "/operations/${operation_id}")
  local return_code=$(echo "$output" | jq -r '.metadata.metadata.return // 0')
  
  if [[ "$return_code" != "0" ]]; then
    log_error "Command failed with exit code: $return_code"

    STDERR_PATH=$(echo "$output" | jq -r '.metadata.metadata.output["2"]')
    STDOUT_PATH=$(echo "$output" | jq -r '.metadata.metadata.output["1"]')

    if [[ -n "$STDERR_PATH" && "$STDERR_PATH" != "null" ]]; then
      CLEAN_STDERR_PATH="${STDERR_PATH#/1.0}"
      lxd_api_call GET "$CLEAN_STDERR_PATH"
    fi

    if [[ -n "$STDOUT_PATH" && "$STDOUT_PATH" != "null" ]]; then
      CLEAN_STDOUT_PATH="${STDOUT_PATH#/1.0}"
      lxd_api_call GET "$CLEAN_STDOUT_PATH"
    fi

    return 1
  fi
  
  return 0
}

# Function to copy file to container
copy_to_container() {
  local source="$1"
  local dest="$2"
  
  log_info "Copying $source to container:$dest"
  
  # Create parent directory in container
  local parent_dir=$(dirname "$dest")
  exec_in_container "mkdir -p '$parent_dir'" false || true
  
  # Use LXD file API to push file
  local encoded_path=$(echo -n "$dest" | jq -sRr @uri)
  
  curl -s \
    -X POST \
    --cert-type P12 \
    --cert "${LXD_CERT_FILE}:${LXD_CERT_PASS}" \
    -k \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${source}" \
    "${LXD_API}/instances/${CONTAINER_NAME}/files?path=${encoded_path}"
}

# Step 1: Create container from Ubuntu 24.04 image
log_info "Creating container from Ubuntu 24.04..."

log_info "Selecting cluster member from 'production' group..."

MEMBERS_JSON=$(lxd_api_call GET "/cluster/members?recursion=1")

TARGET_MEMBER=$(echo "$MEMBERS_JSON" | jq -r '
  .metadata[] |
  select(.groups[]? == "production") |
  .server_name' | head -n1)

if [[ -z "$TARGET_MEMBER" ]]; then
  log_error "No cluster member found in 'production' group"
  exit 1
fi

log_info "Selected cluster member: $TARGET_MEMBER"

CREATE_PAYLOAD=$(jq -n \
  --arg name "$CONTAINER_NAME" \
  '{
    "name": $name,
    "source": {
      "type": "image",
      "server": "https://cloud-images.ubuntu.com/releases",
      "protocol": "simplestreams",
      "alias": "24.04"
    },
    "type": "container"
  }')

RESPONSE=$(lxd_api_call POST "/instances?target=${TARGET_MEMBER}" "$CREATE_PAYLOAD")
OPERATION_ID=$(echo "$RESPONSE" | jq -r '.operation' | sed 's|/1.0/operations/||')

if [[ -z "$OPERATION_ID" || "$OPERATION_ID" == "null" ]]; then
  log_error "Failed to create container"
  echo "$RESPONSE" | jq .
  exit 1
fi

wait_for_operation "$OPERATION_ID"

# Step 2: Start the container
log_info "Starting container..."

START_PAYLOAD='{"action": "start", "timeout": 30}'
RESPONSE=$(lxd_api_call PUT "/instances/${CONTAINER_NAME}/state" "$START_PAYLOAD")
OPERATION_ID=$(echo "$RESPONSE" | jq -r '.operation' | sed 's|/1.0/operations/||')

wait_for_operation "$OPERATION_ID"

# Wait for container to be fully ready
sleep 10

# Step 3: Copy configuration files to container
log_info "Copying configuration files..."

# Copy MariaDB config files if they exist
if [[ -d "mariadb.conf.d" ]]; then
  for conf_file in mariadb.conf.d/*; do
    if [[ -f "$conf_file" ]]; then
      copy_to_container "$conf_file" "/etc/mysql/mariadb.conf.d/$(basename "$conf_file")"
    fi
  done
fi

# Copy Redis config if it exists
if [[ -f "redis/redis.conf" ]]; then
  copy_to_container "redis/redis.conf" "/etc/redis/redis.conf"
fi

# Copy nginx configs
if [[ -f "nginx/nginx.conf" ]]; then
  copy_to_container "nginx/nginx.conf" "/etc/nginx/nginx.conf"
fi
if [[ -f "nginx/mime.types" ]]; then
  copy_to_container "nginx/mime.types" "/etc/nginx/mime.types"
fi
if [[ -f "nginx/fastcgi_params" ]]; then
  copy_to_container "nginx/fastcgi_params" "/etc/nginx/fastcgi_params"
fi
if [[ -f "nginx/wordpress.conf" ]]; then
  copy_to_container "nginx/wordpress.conf" "/etc/nginx/sites-available/wordpress.conf"
fi

# Copy bootstrap script
if [[ -f "bootstrap.sh" ]]; then
  copy_to_container "bootstrap.sh" "/usr/local/sbin/bootstrap.sh"
  exec_in_container "chmod 750 /usr/local/sbin/bootstrap.sh" false
fi

# Copy phpMyAdmin configs if they exist
if [[ -f "phpmyadmin/signon.php" ]]; then
  copy_to_container "phpmyadmin/signon.php" "/usr/share/phpmyadmin/signon.php"
fi
if [[ -f "phpmyadmin/logout.php" ]]; then
  copy_to_container "phpmyadmin/logout.php" "/usr/share/phpmyadmin/logout.php"
fi
if [[ -f "phpmyadmin/config.inc.php" ]]; then
  copy_to_container "phpmyadmin/config.inc.php" "/etc/phpmyadmin/config.inc.php"
fi

# Step 4: Run setup commands from README
log_info "Running system setup..."

# System packages and upgrade
exec_in_container "apt update && DEBIAN_FRONTEND=noninteractive apt -y upgrade"

# Install base packages
exec_in_container "apt install -y --no-install-recommends \
  ca-certificates apt-transport-https imagemagick mariadb-client \
  software-properties-common curl wget unzip zip gnupg lsb-release \
  ufw mariadb-server unattended-upgrades vim nginx redis-server"

exec_in_container "dpkg-reconfigure -f noninteractive unattended-upgrades"

# Enable services
exec_in_container "systemctl enable nginx mariadb redis-server"
exec_in_container "systemctl start nginx mariadb redis-server"

# Secure MariaDB
log_info "Securing MariaDB..."
exec_in_container "mysql --protocol=socket <<'EOSQL'
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';
DROP USER IF EXISTS 'root'@'%';
DROP USER IF EXISTS 'root'@'127.0.0.1';
DROP USER IF EXISTS 'root'@'::1';
CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED VIA unix_socket;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOSQL
"

# Install PHP versions
log_info "Installing PHP 8.3, 8.4, 8.5..."
exec_in_container "add-apt-repository -y ppa:ondrej/php"
exec_in_container "apt update"

# Install PHP 8.3, 8.4, and 8.5 with common extensions
exec_in_container "apt install -y \
  php8.3-fpm php8.3-redis php8.3-cli php8.3-common php8.3-mysql \
  php8.3-curl php8.3-gd php8.3-intl php8.3-mbstring php8.3-imagick \
  php8.3-soap php8.3-xml php8.3-zip php8.3-opcache php8.3-imap \
  php8.3-gmp php8.3-bcmath \
  php8.4-fpm php8.4-redis php8.4-cli php8.4-common php8.4-mysql \
  php8.4-curl php8.4-gd php8.4-intl php8.4-mbstring php8.4-imagick \
  php8.4-soap php8.4-xml php8.4-zip php8.4-opcache php8.4-imap \
  php8.4-gmp php8.4-bcmath \
  php8.5-fpm php8.5-redis php8.5-cli php8.5-common php8.5-mysql \
  php8.5-curl php8.5-gd php8.5-intl php8.5-mbstring php8.5-imagick \
  php8.5-soap php8.5-xml php8.5-zip php8.5-imap php8.5-gmp php8.5-bcmath"

exec_in_container "update-alternatives --set php-fpm.sock /run/php/php8.3-fpm.sock"

# Configure PHP
log_info "Configuring PHP..."
exec_in_container "mkdir -p /var/log/php && chown www-data:www-data /var/log/php && chmod 755 /var/log/php"

exec_in_container "cat > /tmp/php_config.txt <<'EOPHP'
max_input_vars=3000
max_execution_time=120
memory_limit=512M
max_input_time=120
upload_max_filesize=64M
post_max_size=64M
log_errors=On
error_log=/var/log/php/error.log
EOPHP
"

exec_in_container "for ver in 8.3 8.4 8.5; do
  for s in max_input_vars max_execution_time memory_limit max_input_time upload_max_filesize post_max_size log_errors error_log; do
    sed -i \"/^\$s=/d\" /etc/php/\$ver/fpm/php.ini
  done
  cat /tmp/php_config.txt >> /etc/php/\$ver/fpm/php.ini
done && rm /tmp/php_config.txt"

# Install WP-CLI and WordPress
log_info "Installing WP-CLI and WordPress..."
exec_in_container "curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp"

exec_in_container "mkdir -p /var/www/public /var/www/public/wp-content/mu-plugins"
exec_in_container "wp core download --path=/var/www/public --allow-root"
exec_in_container "rm -rf /var/www/html/"

# Install Redis Cache plugin
exec_in_container "curl -sLo /tmp/redis-cache.zip https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip && unzip -q /tmp/redis-cache.zip -d /tmp && mv /tmp/redis-cache /var/www/public/wp-content/plugins/ && chown -R www-data:www-data /var/www/public"

# SSH configuration
log_info "Configuring SSH..."
exec_in_container "sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/60-cloudimg-settings.conf"
exec_in_container "id -u wordpress >/dev/null 2>&1 || useradd -m -s /bin/bash wordpress"
exec_in_container "usermod -aG www-data wordpress"
exec_in_container "chown -R www-data:www-data /var/www/public"
exec_in_container "chmod -R g+rwX /var/www/public"
exec_in_container "find /var/www/public -type d -exec chmod g+s {} \;"
exec_in_container "echo 'cd /var/www/public' >> /home/wordpress/.bashrc"
exec_in_container "chmod -x /etc/update-motd.d/*"
exec_in_container "echo 'Welcome to FlyingHost Terminal' | tee /etc/motd"
exec_in_container "truncate -s 0 /etc/legal"

# Log rotation
log_info "Configuring log rotation..."
exec_in_container "cat > /etc/logrotate.d/flyinghost-logs <<'EOLOG'
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
EOLOG
"

# Install PHPMyAdmin
log_info "Installing PHPMyAdmin..."
exec_in_container "echo 'phpmyadmin phpmyadmin/internal/skip-preseed boolean true' | debconf-set-selections"
exec_in_container "echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect' | debconf-set-selections"
exec_in_container "echo 'phpmyadmin phpmyadmin/dbconfig-install boolean false' | debconf-set-selections"
exec_in_container "apt install -y phpmyadmin"

# Enable WordPress nginx config
log_info "Configuring nginx..."
exec_in_container "ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/"
exec_in_container "rm -rf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default"
exec_in_container "nginx -t && systemctl reload nginx"

# Configure cloud-init
log_info "Configuring cloud-init..."
exec_in_container "cat > /etc/cloud/cloud.cfg.d/99-bootstrap.cfg <<'EOCLOUD'
#cloud-config
runcmd:
  - [bash, -lc, \"/usr/local/sbin/bootstrap.sh >> /var/log/bootstrap.log 2>&1\"]
EOCLOUD
"

exec_in_container "cloud-init clean --logs"
exec_in_container "rm -rf /var/lib/cloud/*"

# Step 5: Stop the container
log_info "Stopping container..."

STOP_PAYLOAD='{"action": "stop", "timeout": 30, "force": false}'
RESPONSE=$(lxd_api_call PUT "/instances/${CONTAINER_NAME}/state" "$STOP_PAYLOAD")
OPERATION_ID=$(echo "$RESPONSE" | jq -r '.operation' | sed 's|/1.0/operations/||')

wait_for_operation "$OPERATION_ID" 60

# Step 6: Delete existing image with the same alias if it exists
log_info "Checking for existing image with alias: ${IMAGE_NAME}..."
EXISTING_IMAGE=$(lxd_api_call GET "/images/aliases/${IMAGE_NAME}" 2>/dev/null || echo "")

if echo "$EXISTING_IMAGE" | jq -e '.metadata.target' >/dev/null 2>&1; then
  log_info "Found existing image, deleting it..."
  IMAGE_FINGERPRINT=$(echo "$EXISTING_IMAGE" | jq -r '.metadata.target')
  lxd_api_call DELETE "/images/${IMAGE_FINGERPRINT}"
  sleep 2
fi

# Step 7: Create image from container
log_info "Creating image from container..."

PUBLISH_PAYLOAD=$(jq -n \
  --arg alias "$IMAGE_NAME" \
  --arg desc "FlyingHost server image: $IMAGE_NAME" \
  --arg container "$CONTAINER_NAME" \
  '{
    "source": {
      "type": "instance",
      "name": $container
    },
    "properties": {
      "description": $desc
    },
    "aliases": [
      {
        "name": $alias,
        "description": $desc
      }
    ],
    "public": false
  }' | jq -c .)

RESPONSE=$(lxd_api_call POST "/images" "$PUBLISH_PAYLOAD")
OPERATION_ID=$(echo "$RESPONSE" | jq -r '.operation' | sed 's|/1.0/operations/||')

if [[ -z "$OPERATION_ID" || "$OPERATION_ID" == "null" ]]; then
  log_error "Failed to publish image"
  echo "$RESPONSE" | jq .
  exit 1
fi

wait_for_operation "$OPERATION_ID" 300

log_info "Image created successfully with alias: ${IMAGE_NAME}"

# Step 8: Delete temporary container
log_info "Deleting temporary container..."

RESPONSE=$(lxd_api_call DELETE "/instances/${CONTAINER_NAME}")
OPERATION_ID=$(echo "$RESPONSE" | jq -r '.operation' | sed 's|/1.0/operations/||')

wait_for_operation "$OPERATION_ID" 60

log_info "Build process completed successfully!"
log_info "Image '${IMAGE_NAME}' is now available in LXD"
