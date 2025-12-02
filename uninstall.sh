#!/bin/bash
# ===================================================================
#  Skylight Uninstaller — Remove Skylight installation
#  Run as root: bash uninstall.sh
#  WARNING: This will delete all data, configs, and databases related to Skylight!
# ===================================================================

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  S K Y L I G H T   Uninstaller              ║"
echo "║          This will remove Skylight and related components   ║"
echo "║          WARNING: Data loss! Backup first if needed.        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

read -p "Are you sure you want to uninstall Skylight? (y/n): " confirm
if [[ $confirm != "y" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Stop services
echo -e "${YELLOW}Stopping services...${NC}"
systemctl stop skylight-wings || true
systemctl disable skylight-wings || true
systemctl stop nginx || true
systemctl stop php8.3-fpm || true
systemctl stop mariadb || true
systemctl stop redis-server || true

# Remove systemd service
echo -e "${YELLOW}Removing systemd service...${NC}"
rm -f /etc/systemd/system/skylight-wings.service
systemctl daemon-reload

# Remove files and directories
echo -e "${YELLOW}Removing files and directories...${NC}"
rm -rf /var/www/skylight
rm -f /usr/local/bin/skylight-wings
rm -rf /etc/skylight

# Remove Nginx config
echo -e "${YELLOW}Removing Nginx config...${NC}"
rm -f /etc/nginx/sites-available/skylight
rm -f /etc/nginx/sites-enabled/skylight
systemctl restart nginx || true

# Drop database and user (MySQL/MariaDB)
echo -e "${YELLOW}Dropping database and user...${NC}"
mysql -e "DROP DATABASE IF EXISTS skylight;" || true
mysql -e "DROP USER IF EXISTS 'skylight'@'127.0.0.1';" || true
mysql -e "FLUSH PRIVILEGES;" || true

# Remove crontab
echo -e "${YELLOW}Removing crontab...${NC}"
crontab -u skylight -r || true

# Remove user
echo -e "${YELLOW}Removing user skylight...${NC}"
userdel -r skylight || true

# Remove installed packages (be careful, only remove if not needed elsewhere)
echo -e "${YELLOW}Removing installed packages...${NC}"
apt purge -y php8.3* nodejs yarn nginx mariadb-server redis-server certbot python3-certbot-nginx composer git unzip tar || true
apt autoremove -y || true

# Remove PPA
echo -e "${YELLOW}Removing PHP PPA...${NC}"
add-apt-repository --remove ppa:ondrej/php -y || true
apt update || true

# Clean up any remaining certs (if SSL was set up)
echo -e "${YELLOW}Cleaning up SSL certs...${NC}"
certbot delete --cert-name $DOMAIN --non-interactive || true

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                Skylight Uninstalled!                        ║"
echo "║                                                             ║"
echo "║   Some shared packages may remain if used elsewhere.        ║"
echo "║   Reboot recommended: reboot                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
