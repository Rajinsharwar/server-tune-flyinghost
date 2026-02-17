# FlyingHost Server Tuning 

WordPress server setup and optimization for Ubuntu 24.04 LTS.

## Automated Image Creation

This repository includes automated LXD image creation via GitHub Actions. When you commit changes with a special flag in the commit message, a new LXD image will be automatically built and published.

### Setup

1. Add the following secrets to your GitHub repository (Settings → Secrets and variables → Actions):
   - `LXD_HOST`: Your LXD server IP address (e.g., `65.109.28.250`)
   - `LXD_CERT_FILE`: Base64-encoded PFX certificate file for LXD authentication
   - `LXD_CERT_PASS`: Password for the PFX certificate
   - `HOST_SSH_KEY_BASE64`: (Optional) Base64-encoded SSH private key for host access

2. To encode your PFX certificate:
   ```bash
   base64 -w 0 /path/to/lxd.pfx
   ```

### Usage

To trigger automated image creation, include `--release=<image-name>` in your commit message:

```bash
git add .
git commit -m "Updated nginx config --release=imagev3"
git push
```

This will:
1. Trigger the GitHub Actions workflow
2. Create a temporary LXD container from Ubuntu 24.04
3. Copy all configuration files from this repository
4. Run all setup commands from the "Container" section below
5. Publish the container as an LXD image with alias `imagev3`
6. Clean up the temporary container

The image will be available in your LXD server and can be used to launch new containers.

## Host

### CPU Governor

```bash
# Set performance mode for optimal DB
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$cpu"
done
```

### Host Nginx

Copy [`ssl/cf-origin.crt`](ssl/cf-origin.crt), [`ssl/cf-origin.key`](ssl/cf-origin.key) to `/etc/nginx/ssl/` before running:

```bash
# Install nginx
apt-get update
apt-get install -y nginx
systemctl enable nginx

# Remove defaults, create ssl and site config dirs
rm -f /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*
mkdir -p /etc/nginx/ssl /etc/nginx/flyinghost

# Create flyinghost config (catch-all + include per-site configs)
cat > /etc/nginx/sites-available/flyinghost.conf <<'EOF'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  return 444;
}
server {
  listen 443 ssl http2 default_server;
  listen [::]:443 ssl http2 default_server;
  server_name _;
  ssl_certificate     /etc/nginx/ssl/cf-origin.crt;
  ssl_certificate_key /etc/nginx/ssl/cf-origin.key;
  return 444;
}
include /etc/nginx/flyinghost/*.conf;
EOF

# Enable config
ln -sf /etc/nginx/sites-available/flyinghost.conf /etc/nginx/sites-enabled/
nginx -t
```

## Container

```bash
# System packages
apt update
DEBIAN_FRONTEND=noninteractive apt -y upgrade
apt install -y --no-install-recommends \
  ca-certificates apt-transport-https imagemagick mariadb-client software-properties-common \
  curl wget unzip zip gnupg lsb-release ufw mariadb-server unattended-upgrades vim \
  nginx redis-server
dpkg-reconfigure -f noninteractive unattended-upgrades

# MariaDB, Nginx, Redis
systemctl enable nginx mariadb redis-server
systemctl start nginx mariadb redis-server

# MariaDB: secure root, remove test users
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

# PHP 8.3, 8.4, 8.5
add-apt-repository -y ppa:ondrej/php
apt update
apt install -y \
  php8.3-fpm php8.3-redis php8.3-cli php8.3-common php8.3-mysql php8.3-curl php8.3-gd php8.3-intl php8.3-mbstring php8.3-imagick php8.3-soap php8.3-xml php8.3-zip php8.3-opcache php8.3-imap php8.3-gmp php8.3-bcmath \
  php8.4-fpm php8.4-redis php8.4-cli php8.4-common php8.4-mysql php8.4-curl php8.4-gd php8.4-intl php8.4-mbstring php8.4-imagick php8.4-soap php8.4-xml php8.4-zip php8.4-opcache php8.4-imap php8.4-gmp php8.4-bcmath \
  php8.5-fpm php8.5-redis php8.5-cli php8.5-common php8.5-mysql php8.5-curl php8.5-gd php8.5-intl php8.5-mbstring php8.5-imagick php8.5-soap php8.5-xml php8.5-zip php8.5-imap php8.5-gmp php8.5-bcmath
update-alternatives --set php-fpm.sock /run/php/php8.3-fpm.sock

# PHP config: error log, limits, upload size
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
    sed -i "/^$s=/d" /etc/php/$ver/fpm/php.ini
  done
  echo "$PHP_SETTINGS" >> /etc/php/$ver/fpm/php.ini
done

# WP-CLI, WordPress core, Redis cache plugin
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
```

Copy [`mu-plugin/flyinghost.php`](https://github.com/Flying-Host/mu-plugin/blob/main/flyinghost.php) to `/var/www/public/wp-content/mu-plugins/flyinghost.php`.

```bash
# SSH: enable password auth, create wordpress user, permissions, custom banner
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
id -u wordpress >/dev/null 2>&1 || useradd -m -s /bin/bash wordpress
usermod -aG www-data wordpress
chown -R www-data:www-data /var/www/public
chmod -R g+rwX /var/www/public
find /var/www/public -type d -exec chmod g+s {} \;
echo 'cd /var/www/public' >> /home/wordpress/.bashrc
chmod -x /etc/update-motd.d/*
echo "Welcome to FlyingHost Terminal" | tee /etc/motd
truncate -s 0 /etc/legal

# Log rotation for nginx and PHP
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

# PHPMyAdmin (unattended install)
echo "phpmyadmin phpmyadmin/internal/skip-preseed boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | debconf-set-selections
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
apt install -y phpmyadmin
```

Copy [`phpmyadmin/signon.php`](phpmyadmin/signon.php), [`phpmyadmin/logout.php`](phpmyadmin/logout.php) to `/usr/share/phpmyadmin/` and [`phpmyadmin/config.inc.php`](phpmyadmin/config.inc.php) to `/etc/phpmyadmin/config.inc.php`.

Copy [`bootstrap.sh`](bootstrap.sh) to `/usr/local/sbin/bootstrap.sh` and [`nginx/wordpress.conf`](nginx/wordpress.conf) to `/etc/nginx/sites-available/wordpress.conf`.

```bash
# Enable WordPress nginx config, bootstrap permissions, cloud-init
ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/
rm -rf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

chmod 750 /usr/local/sbin/bootstrap.sh
cat > /etc/cloud/cloud.cfg.d/99-bootstrap.cfg <<'EOF'
#cloud-config
runcmd:
  - [bash, -lc, "/usr/local/sbin/bootstrap.sh >> /var/log/bootstrap.log 2>&1"]
EOF
cloud-init clean --logs
rm -rf /var/lib/cloud/*
```
