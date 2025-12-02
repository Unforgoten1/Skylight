#!/bin/bash
# ===================================================================
#  Skylight Installer — One-click Pelican fork (December 2025)
#  Just run: bash <(curl -sSL https://raw.githubusercontent.com/Unforgoten1/Skylight/main/install.sh)
# ===================================================================

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                         S K Y L I G H T                      ║"
echo "║          Version: v2.1.7                                     ║"
echo "║          Author: Unforgotten1                                ║"
echo "║          The Pelican fork that actually feels next-gen       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Root check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

# Prompt: Domain or IPv4?
echo -e "${YELLOW}Use a domain (y) or just the server's IPv4 address (n)? (y/n):${NC}"
read use_domain
if [[ $use_domain == "y" ]]; then
    echo -e "${YELLOW}Enter your domain (e.g. panel.example.com):${NC}"
    read DOMAIN
    PROTOCOL="https"
    SSL=true
else
    DOMAIN=$(curl -4 -s ifconfig.me)
    PROTOCOL="http"
    SSL=false
fi

# System update
echo -e "${YELLOW}Updating system...${NC}"
apt update && apt upgrade -y

# Base packages
echo -e "${YELLOW}Installing base packages...${NC}"
apt install -y software-properties-common ca-certificates lsb-release apt-transport-https \
    gnupg2 curl wget git unzip nginx mariadb-server redis-server certbot python3-certbot-nginx composer

# PHP 8.3 (ondrej PPA)
echo -e "${YELLOW}Installing PHP 8.3...${NC}"
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.3 php8.3-{cli,fpm,mysql,zip,gd,mbstring,curl,xml,bcmath,redis,sqlite3}

update-alternatives --set php /usr/bin/php8.3
phpenmod -v 8.3 sqlite3 pdo_sqlite
systemctl restart php8.3-fpm

# Node.js 22 + Yarn
echo -e "${YELLOW}Installing Node.js 22 + Yarn...${NC}"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs
npm install -g yarn

# Create skylight user
if ! id "skylight" &>/dev/null; then
    useradd -r -m -d /var/www/skylight -s /bin/bash skylight
fi

# Clean old install
echo -e "${YELLOW}Cleaning old install...${NC}"
rm -rf /var/www/skylight

# Clone Panel
echo -e "${YELLOW}Cloning Panel...${NC}"
sudo -u skylight git clone https://github.com/pelican-dev/panel.git /var/www/skylight/panel
cd /var/www/skylight/panel
sudo -u skylight git checkout main

# Composer + Yarn
echo -e "${YELLOW}Installing dependencies...${NC}"
sudo -u skylight composer install --no-dev --optimize-autoloader
sudo -u skylight yarn install
sudo -u skylight yarn run build

# .env setup
sudo -u skylight cp .env.example .env
sudo -u skylight php artisan key:generate

sudo -u skylight sed -i "s|^APP_URL=.*|APP_URL=$PROTOCOL://$DOMAIN|g" .env
sudo -u skylight sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|g" .env
sudo -u skylight sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
sudo -u skylight sed -i "s|^DB_PORT=.*|DB_PORT=3306|g" .env
sudo -u skylight sed -i "s|^DB_DATABASE=.*|DB_DATABASE=skylight|g" .env
sudo -u skylight sed -i "s|^DB_USERNAME=.*|DB_USERNAME=skylight|g" .env
sudo -u skylight sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=SuperSecureRandomPass123!|g" .env
sudo -u skylight sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|g" .env
sudo -u skylight sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|g" .env
sudo -u skylight sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|g" .env
sudo -u skylight sed -i "s|^REDIS_HOST=.*|REDIS_HOST=127.0.0.1|g" .env

# MariaDB setup
echo -e "${YELLOW}Configuring MariaDB...${NC}"
systemctl enable --now mariadb redis-server
mysql -e "DROP DATABASE IF EXISTS skylight;"
mysql -e "CREATE DATABASE skylight;"
mysql -e "DROP USER IF EXISTS 'skylight'@'127.0.0.1';"
mysql -e "CREATE USER 'skylight'@'127.0.0.1' IDENTIFIED BY 'SuperSecureRandomPass123!';"
mysql -e "GRANT ALL PRIVILEGES ON skylight.* TO 'skylight'@'127.0.0.1';"
mysql -e "FLUSH PRIVILEGES;"

# Migrate & seed
cd /var/www/skylight/panel
sudo -u skylight php artisan migrate --seed --force

# Permissions & cache
echo -e "${YELLOW}Fixing permissions & cache...${NC}"
chown -R skylight:www-data storage bootstrap/cache
chmod -R 775 storage bootstrap/cache
sudo -u skylight php artisan optimize:clear
sudo -u skylight php artisan config:cache
sudo -u skylight php artisan view:cache
systemctl restart php8.3-fpm nginx

# Crontab
(crontab -u skylight -l 2>/dev/null || true; echo "* * * * * php /var/www/skylight/panel/artisan schedule:run >> /dev/null 2>&1") | crontab -u skylight -

# Docker (required for Wings)
echo -e "${YELLOW}Installing Docker...${NC}"
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# Wings — pinned stable version (v1.0.0-beta19)
echo -e "${YELLOW}Installing Wings v1.0.0-beta19 (stable)...${NC}"
mkdir -p /etc/skylight /var/lib/skylight /var/log/skylight
curl -L -o /usr/local/bin/wings https://github.com/pelican-dev/wings/releases/download/v1.0.0-beta19/wings_linux_amd64
chmod +x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Skylight Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/skylight
LimitNOFILE=4096
PIDFile=/var/run/wings.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wings

# Wings config template (user must paste token later)
cat > /etc/skylight/config.yml <<EOF
debug: false
uuid: 11111111-1111-1111-1111-111111111111
token_id: 1
token: PASTE_YOUR_TOKEN_HERE
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
remote: $PROTOCOL://$DOMAIN/api/remote
allowed_mounts: []
docker:
  network:
    name: skylight
    is_privileged: true
  tmpfs_size: 100
  timezone: UTC
allowed_origins: []
EOF

systemctl start wings

# Nginx
echo -e "${YELLOW}Configuring Nginx...${NC}"
cat > /etc/nginx/sites-available/skylight <<EOF
server {
    listen 80;
    server_name $DOMAIN _;

    root /var/www/skylight/panel/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    client_max_body_size 100M;
}
EOF

ln -sf /etc/nginx/sites-available/skylight /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# SSL (only for domain)
if [[ $SSL == true ]]; then
    echo -e "${YELLOW}Installing Let's Encrypt SSL...${NC}"
    certbot --nginx --non-interactive --agree-tos --redirect -d $DOMAIN -m admin@$DOMAIN || echo "${YELLOW}SSL failed (will still work on HTTP)${NC}"
else
    # Force HTTP for IP installs
    sudo -u skylight sed -i "s|^APP_URL=https://|APP_URL=http://|g" .env
    sudo -u skylight php artisan optimize:clear
    systemctl restart nginx
fi

# Final permissions
chown -R skylight:www-data /var/www/skylight
chmod -R 755 /var/www/skylight

# Create first admin user
echo -e "${YELLOW}Creating your admin account (follow the prompts)...${NC}"
cd /var/www/skylight/panel
sudo -u skylight php artisan p:user:make

# Final message
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                SKYLIGHT IS NOW INSTALLED!                   ║"
echo "║                                                             ║"
echo "║   Panel URL: $PROTOCOL://$DOMAIN                            ║"
echo "║   Login with the account you just created                   ║"
echo "║                                                             ║"
echo "║   Wings is installed — next steps:                          ║"
echo "║   1. Admin → Nodes → Create New Node                        ║"
echo "║   2. Copy the token → paste into:                         ║"
echo "║       /etc/skylight/config.yml (replace PASTE_YOUR_TOKEN_HERE) ║"
echo "║   3. Run: systemctl restart wings                           ║"
echo "║   Node will turn green in less than 30 seconds              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

exit 0
