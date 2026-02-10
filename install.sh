#!/bin/bash
# ===================================================================
#  Skylight Installer — One-click Pelican fork
#  Updated: better DB setup + safe permissions + verbose migrate/seed
# ===================================================================

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                         S K Y L I G H T                      ║"
echo "║          Install path: /Skylight/panel                       ║"
echo "║          User home:    /home/skylight                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

echo -e "${YELLOW}Use a domain (y) or server's IPv4 (n)? (y/n):${NC}"
read use_domain
if [[ $use_domain == "y" ]]; then
    echo -e "${YELLOW}Enter domain (e.g. panel.example.com):${NC}"
    read DOMAIN
    PROTOCOL="https"
    SSL=true
else
    DOMAIN=$(curl -4 -s ifconfig.me)
    PROTOCOL="http"
    SSL=false
fi

apt update && apt upgrade -y

apt install -y software-properties-common ca-certificates lsb-release apt-transport-https \
    gnupg2 curl wget git unzip nginx mariadb-server redis-server certbot python3-certbot-nginx composer

echo -e "${YELLOW}Installing PHP 8.3 + extensions...${NC}"
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.3 php8.3-{cli,fpm,mysql,zip,gd,mbstring,curl,xml,bcmath,redis,sqlite3,intl}

update-alternatives --set php /usr/bin/php8.3
phpenmod -v 8.3 intl sqlite3 pdo_sqlite mysqlnd mysqli pdo_mysql
systemctl restart php8.3-fpm

echo -e "${YELLOW}Installing Node.js 22 + Yarn...${NC}"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs
npm install -g yarn

# User with standard home
if ! id "skylight" &>/dev/null; then
    useradd -r -m -d /home/skylight -s /bin/bash skylight
else
    usermod -d /home/skylight -m skylight 2>/dev/null || true
fi

rm -rf /Skylight
mkdir -p /Skylight
chown skylight:www-data /Skylight
chmod 755 /Skylight

# Yarn fixes in real home
mkdir -p /home/skylight/.cache/yarn /home/skylight/.yarn
touch /home/skylight/.yarnrc
chown -R skylight:www-data /home/skylight/.yarn /home/skylight/.cache /home/skylight/.yarnrc
chmod -R 755 /home/skylight/.yarn /home/skylight/.cache
chmod 644 /home/skylight/.yarnrc

echo -e "${YELLOW}Cloning Panel...${NC}"
sudo -H -u skylight git clone https://github.com/pelican-dev/panel.git /Skylight/panel
cd /Skylight/panel
sudo -H -u skylight git checkout main

echo -e "${YELLOW}Installing dependencies...${NC}"
sudo -H -u skylight composer install --no-dev --optimize-autoloader
sudo -H -u skylight yarn install
sudo -H -u skylight yarn run build

# .env setup
sudo -H -u skylight cp .env.example .env
sudo -H -u skylight php artisan key:generate

sudo -H -u skylight sed -i "s|^APP_URL=.*|APP_URL=$PROTOCOL://$DOMAIN|g" .env
sudo -H -u skylight sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|g" .env
sudo -H -u skylight sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
sudo -H -u skylight sed -i "s|^DB_PORT=.*|DB_PORT=3306|g" .env
sudo -H -u skylight sed -i "s|^DB_DATABASE=.*|DB_DATABASE=skylight|g" .env
sudo -H -u skylight sed -i "s|^DB_USERNAME=.*|DB_USERNAME=skylight|g" .env
sudo -H -u skylight sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=SuperSecureRandomPass123!|g" .env
sudo -H -u skylight sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|g" .env
sudo -H -u skylight sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|g" .env
sudo -H -u skylight sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|g" .env
sudo -H -u skylight sed -i "s|^REDIS_HOST=.*|REDIS_HOST=127.0.0.1|g" .env

# MariaDB setup with proper charset/collation
echo -e "${YELLOW}Configuring MariaDB...${NC}"
systemctl enable --now mariadb redis-server

mysql -e "DROP DATABASE IF EXISTS skylight;"
mysql -e "CREATE DATABASE skylight CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "DROP USER IF EXISTS 'skylight'@'127.0.0.1';"
mysql -e "CREATE USER 'skylight'@'127.0.0.1' IDENTIFIED BY 'SuperSecureRandomPass123!';"
mysql -e "GRANT ALL PRIVILEGES ON skylight.* TO 'skylight'@'127.0.0.1';"
mysql -e "FLUSH PRIVILEGES;"

# Migrate and seed – separated + verbose
cd /Skylight/panel
echo -e "${YELLOW}Running migrations...${NC}"
sudo -H -u skylight php artisan migrate --force --verbose || { echo -e "${RED}Migration failed. Check output above.${NC}"; exit 1; }

echo -e "${YELLOW}Seeding database...${NC}"
sudo -H -u skylight php artisan db:seed --force --verbose || { echo -e "${RED}Seeding failed. Check output above.${NC}"; exit 1; }

# Permissions – safe handling
echo -e "${YELLOW}Fixing permissions & cache...${NC}"
chown -R skylight:www-data /Skylight

find /Skylight -type d -exec chmod 755 {} \;
find /Skylight -type f -exec chmod 644 {} \;

# Only chmod writable dirs if they exist now
[ -d "/Skylight/storage" ]         && chmod -R 775 /Skylight/storage
[ -d "/Skylight/bootstrap/cache" ] && chmod -R 775 /Skylight/bootstrap/cache

sudo -H -u skylight php artisan optimize:clear
sudo -H -u skylight php artisan config:cache
sudo -H -u skylight php artisan view:cache

systemctl restart php8.3-fpm nginx

# Crontab
(crontab -u skylight -l 2>/dev/null || true; echo "* * * * * php /Skylight/panel/artisan schedule:run >> /dev/null 2>&1") | crontab -u skylight -

# Docker + Wings
echo -e "${YELLOW}Installing Docker...${NC}"
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

echo -e "${YELLOW}Installing Wings v1.0.0-beta19...${NC}"
mkdir -p /etc/skylight /var/lib/skylight /var/log/skylight
curl -L -o /usr/local/bin/wings https://github.com/pelican-dev/wings/releases/download/v1.0.0-beta19/wings_linux_amd64
chmod +x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<'EOF'
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

    root /Skylight/panel/public;
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

# SSL
if [[ $SSL == true ]]; then
    echo -e "${YELLOW}Installing Let's Encrypt SSL...${NC}"
    certbot --nginx --non-interactive --agree-tos --redirect -d $DOMAIN -m admin@$DOMAIN || echo "${YELLOW}SSL failed (will still work on HTTP)${NC}"
else
    sudo -H -u skylight sed -i "s|^APP_URL=https://|APP_URL=http://|g" /Skylight/panel/.env
    sudo -H -u skylight php artisan optimize:clear
    systemctl restart nginx
fi

echo -e "${YELLOW}Creating your admin account (follow the prompts)...${NC}"
cd /Skylight/panel
sudo -H -u skylight php artisan p:user:make

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                SKYLIGHT IS NOW INSTALLED!                   ║"
echo "║                                                             ║"
echo "║   Panel URL:          $PROTOCOL://$DOMAIN                   ║"
echo "║   Install location:   /Skylight/panel                       ║"
echo "║   Login with the account you just created                   ║"
echo "║                                                             ║"
echo "║   Wings next steps:                                         ║"
echo "║   1. Admin → Nodes → Create New Node                        ║"
echo "║   2. Copy token → edit /etc/skylight/config.yml             ║"
echo "║   3. systemctl restart wings                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

exit 0
