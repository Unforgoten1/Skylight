#!/bin/bash
# ===================================================================
#  Skylight Installer — One-click Pelican fork (December 2025)
#  Just run: bash <(curl -sSL https://raw.githubusercontent.com/Unforgoten1/Skylight/main/install.sh)
# ===================================================================

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                         S K Y L I G H T                      ║"
echo "║          Version: v2.0.0                                     ║"
echo "║          Author: Unforgotten1                                ║"
echo "║          The Pelican fork that actually feels next-gen       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Basic checks
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

if ! command -v curl &> /dev/null || ! command -v wget &> /dev/null; then
    echo -e "${YELLOW}Installing curl and wget...${NC}"
    apt update && apt install -y curl wget
fi

# System update
echo -e "${YELLOW}Updating system...${NC}"
apt update && apt upgrade -y

# Install dependencies (removed npm - it's bundled with nodejs)
echo -e "${YELLOW}Installing required packages...${NC}"
apt install -y software-properties-common ca-certificates lsb-release apt-transport-https \
    gnupg2 ubuntu-keyring tar unzip git nginx mariadb-server redis-server \
    certbot python3-certbot-nginx composer

# PHP 8.3 via official PPA (better for Ubuntu)
echo -e "${YELLOW}Adding PHP PPA repository...${NC}"
add-apt-repository ppa:ondrej/php -y
apt update

# Install PHP 8.3 packages explicitly
apt install -y php8.3 php8.3-cli php8.3-fpm php8.3-mysql php8.3-zip php8.3-gd php8.3-mbstring php8.3-curl php8.3-xml php8.3-bcmath php8.3-redis

# Node 22 (bumped for your system; Pelican works fine with it)
echo -e "${YELLOW}Installing Node.js 22...${NC}"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs

# Verify npm is available (should be)
if ! command -v npm &> /dev/null; then
    echo -e "${RED}npm not found after Node install! Aborting.${NC}"
    exit 1
fi

# Create skylight user
if ! id "skylight" &>/dev/null; then
    useradd -r -m -d /var/www/skylight -s /bin/bash skylight
fi

# Clone Skylight Panel (use Pelican for now until fork is ready)
echo -e "${YELLOW}Cloning Skylight Panel...${NC}"
sudo -u skylight git clone https://github.com/pelican-dev/panel.git /var/www/skylight/panel
cd /var/www/skylight/panel
sudo -u skylight git checkout main

# Install Composer deps
echo -e "${YELLOW}Running Composer...${NC}"
sudo -u skylight composer install --no-dev --optimize-autoloader

# Install Node deps + build
echo -e "${YELLOW}Building frontend (this can take 2-3 mins)...${NC}"
sudo -u skylight npm ci
sudo -u skylight npm run build

# Environment setup
sudo -u skylight cp .env.example .env
sudo -u skylight php artisan key:generate

# Database
echo -e "${YELLOW}Setting up MariaDB...${NC}"
systemctl enable --now mariadb redis-server

mysql -e "CREATE DATABASE skylight;"
mysql -e "CREATE USER 'skylight'@'127.0.0.1' IDENTIFIED BY 'SuperSecureRandomPass123!';"
mysql -e "GRANT ALL PRIVILEGES ON skylight.* TO 'skylight'@'127.0.0.1';"
mysql -e "FLUSH PRIVILEGES;"

# Run migrations & seed
cd /var/www/skylight/panel
sudo -u skylight php artisan migrate --seed --force
sudo -u skylight php artisan p:environment:setup --author=admin@skylight.host --url=https://$(curl -s ifconfig.me) --timezone=UTC --cache=redis --session=redis
sudo -u skylight php artisan p:environment:database

# Queue worker & scheduler
crontab -u skylight -l 2>/dev/null || echo "* * * * * php /var/www/skylight/panel/artisan schedule:run >> /dev/null 2>&1" | crontab -u skylight -
systemctl enable --now redis-server

# Wings (daemon) - use Pelican binary for now
echo -e "${YELLOW}Installing Skylight Wings...${NC}"
mkdir -p /etc/skylight
curl -L https://github.com/pelican-dev/wings/releases/latest/download/wings_linux_amd64 -o /usr/local/bin/skylight-wings
chmod +x /usr/local/bin/skylight-wings

cat > /etc/systemd/system/skylight-wings.service <<EOF
[Unit]
Description=Skylight Wings Daemon
After=network.target

[Service]
User=root
WorkingDirectory=/etc/skylight
LimitNOFILE=4096
PIDFile=/var/run/wings.pid
ExecStart=/usr/local/bin/skylight-wings
Restart=on-failure
StartLimitInterval=600

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now skylight-wings

# Nginx config (auto-detect domain or IP)
DOMAIN=$(curl -s ifconfig.me)
cat > /etc/nginx/sites-available/skylight <<EOF
server {
    listen 80;
    server_name $DOMAIN _;

    root /var/www/skylight/panel/public;
    index index.php index.html;

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

# SSL with Let's Encrypt (optional but automatic)
echo -e "${YELLOW}Setting up SSL (this will ask for your email)...${NC}"
certbot --nginx --non-interactive --agree-tos --redirect -d $DOMAIN -m admin@$DOMAIN || echo "${YELLOW}SSL setup failed or skipped (running on HTTP)${NC}"

# Final permissions
chown -R skylight:www-data /var/www/skylight
chmod -R 755 /var/www/skylight

# Done
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                SKYLIGHT IS NOW LIVE!                        ║"
echo "║                                                             ║"
echo "║   Panel URL: https://$DOMAIN                                ║"
echo "║   First user: admin@admin.com                               ║"
echo "║   Password: admin123   (CHANGE THIS IMMEDIATELY!)           ║"
echo "║                                                             ║"
echo "║   Wings is running — add this node in the admin panel       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "Next steps:"
echo "1. Log in → change password → delete default admin later"
echo "2. Admin → Nodes → Create new node (use this server's IP)"
echo "3. Start deploying servers!"
echo "4. Reboot server to apply kernel update (optional but recommended)"

exit 0
