#!/usr/bin/env bash
# ==============================================================
# 🌐 LibreNMS Installer Script
# Target: Ubuntu 26.04 LTS (also supports 24.04 LTS via the ondrej/php PPA)
# Follows https://docs.librenms.org/Installation/Install-LibreNMS/ (NGINX)
#
# Installs and configures LibreNMS end-to-end:
#  • Installs required packages (PHP, MariaDB, Nginx, SNMP, etc.)
#  • Creates librenms user, clones repo, sets ACLs
#  • Installs Composer deps, configures MariaDB (DB + user + charset)
#  • Sets up PHP-FPM pool, Nginx vhost with self-signed SSL
#  • Deploys SNMP agent, cron jobs, logrotate, systemd scheduler
#  • Updates .env with APP_URL/SESSION_SECURE_COOKIE
#
# Non-interactive DevOps variables:
#   LIBRENMS_DOMAIN, DB_PASSWORD, SNMP_COMMUNITY, TZ, PHP_VER,
#   USE_UTF8_LOCALES
# ==============================================================

# --- Fail early, strict shell settings ---
set -euo pipefail
IFS=$'\n\t'
trap 'echo "✖ Error at line $LINENO"; exit 1' ERR
# Files written to /etc must not be world-writable (cron and MariaDB ignore them)
umask 022

# --- Ensure running as root ---
if [[ $EUID -ne 0 ]]; then
  echo "✖ Please run as root or via sudo."
  exit 1
fi

# === 🎨 COLORS ===
RED='\033[1;31m'; GRN='\033[1;32m'
YEL='\033[1;33m'; CYN='\033[1;36m'
RST='\033[0m'

banner() {
  echo -e "\n${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
  echo -e "🛠️  ${1}"
  echo -e "${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
}
success() { echo -e "${GRN}✔ ${1}${RST}"; }
skip()    { echo -e "${YEL}⏭ ${1}${RST}"; }
error()   { echo -e "${RED}✖ ${1}${RST}" >&2; }

# === 🐧 Detect the Ubuntu release ===
. /etc/os-release
case "${VERSION_ID:-}" in
  26.04) USE_PPA="no" ;;  # PHP 8.5 ships in the Ubuntu archive
  24.04) USE_PPA="yes" ;; # PHP 8.3 is too old; PHP 8.5 comes from the ondrej/php PPA
  *)
    echo -e "${YEL}This script supports Ubuntu 26.04 and 24.04. Detected: ${PRETTY_NAME:-unknown}${RST}"
    read -rp "Continue anyway? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1
    USE_PPA="no"
    ;;
esac

# === 🔧 VARIABLES ===
LIBRENMS_DOMAIN="${LIBRENMS_DOMAIN:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
SNMP_COMMUNITY="${SNMP_COMMUNITY:-}"
TZ="${TZ:-}"
PHP_VER="${PHP_VER:-8.5}" # LibreNMS: minimum PHP 8.4, recommended 8.5
USE_UTF8_LOCALES="${USE_UTF8_LOCALES:-yes}"

# === 📥 PROMPTS IF VARIABLES NOT SET ===
while [[ ! "$LIBRENMS_DOMAIN" =~ ^[A-Za-z0-9._:-]+$ ]]; do
  read -rp "Enter LibreNMS domain or IP: " LIBRENMS_DOMAIN
done
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD=$(openssl rand -hex 16)
  echo -e "${YEL}Generated DB password: $DB_PASSWORD${RST}"
fi
if [[ -z "$SNMP_COMMUNITY" ]]; then
  read -rp "Enter SNMP community [public]: " SNMP_COMMUNITY
  SNMP_COMMUNITY=${SNMP_COMMUNITY:-public}
fi
# /etc/timezone no longer exists on current Ubuntu releases
SYS_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
SYS_TZ="${SYS_TZ:-Etc/UTC}"
if [[ -z "$TZ" ]]; then
  echo -e "${CYN}Refer to timezone list: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones${RST}"
  read -rp "Enter timezone [$SYS_TZ]: " TZ
  TZ="${TZ:-$SYS_TZ}"
fi
# system and PHP timezone must match, or validate.php reports a failure
if [[ "$TZ" != "$SYS_TZ" ]]; then
  timedatectl set-timezone "$TZ"
fi

# === 🚨 Nuke Existing Installation Prompt ===
if [[ -d /opt/librenms ]] || mysql -uroot -e "USE librenms;" &>/dev/null; then
  echo -e "\n${YEL}Existing LibreNMS detected!${RST}"
  echo "This will remove:"
  echo "  • /opt/librenms"
  echo "  • MariaDB librenms DB & user"
  echo "  • Nginx librenms site & SSL"
  echo "  • PHP-FPM pool"
  echo "  • SNMP config & agent script"
  echo "  • Cron & logrotate entries"
  read -rp "Proceed to nuke and start fresh? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborting—existing installation preserved."
    exit 1
  fi

  echo "⏳ Removing old installation..."
  rm -rf /opt/librenms \
         /etc/nginx/sites-available/librenms.conf \
         /etc/nginx/sites-enabled/librenms.conf \
         /etc/nginx/conf.d/librenms.conf \
         /etc/ssl/librenms \
         /etc/php/*/fpm/pool.d/librenms.conf \
         /etc/snmp/snmpd.conf /usr/bin/distro \
         /etc/cron.d/librenms /etc/logrotate.d/librenms

  if command -v mysql &>/dev/null; then
    echo "⏳ Dropping database..."
    mysql -uroot <<SQL
DROP DATABASE IF EXISTS librenms;
DROP USER IF EXISTS 'librenms'@'localhost';
FLUSH PRIVILEGES;
SQL
  fi

  success "Previous LibreNMS installation nuked."
fi

# === 🧱 INSTALL BASE PACKAGES ===
banner "Installing Required Packages"
export DEBIAN_FRONTEND=noninteractive

apt update -y
apt full-upgrade -y

if [[ "$USE_PPA" == "yes" ]]; then
  apt install -y software-properties-common
  if [[ "$USE_UTF8_LOCALES" == "yes" ]]; then
    LC_ALL=C.UTF-8 add-apt-repository -y universe
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
  else
    add-apt-repository -y universe
    add-apt-repository -y ppa:ondrej/php
  fi
  apt update -y
fi

# stop early if this release has no PHP $PHP_VER packages
if ! apt-cache show "php${PHP_VER}-fpm" &>/dev/null; then
  error "php${PHP_VER}-fpm is not available on ${PRETTY_NAME:-this release}. Add a PHP ${PHP_VER} repository or set PHP_VER, then re-run."
  exit 1
fi

# Package list from the LibreNMS install guide (Ubuntu 26.04 / NGINX).
# composer is not needed: composer_wrapper.php downloads it.
# lsb-release is needed by the distro SNMP extend; cron is missing on Ubuntu minimal.
PACKAGES=(acl curl fping git graphviz imagemagick mariadb-client \
  mariadb-server mtr-tiny nginx-full nmap cron lsb-release openssl \
  php${PHP_VER}-{cli,curl,fpm,gd,gmp,mbstring,mysql,snmp,xml,zip} \
  python3-{pip,pymysql,psutil,setuptools,systemd,venv,dotenv,redis} \
  python3-command-runner rrdtool snmp snmpd whois unzip traceroute)

apt install -y "${PACKAGES[@]}"

#enable cron for ubuntu minimal
systemctl enable cron
systemctl start cron
success "Base packages installed"

# === 👤 Create librenms user ===
banner "Creating LibreNMS User"
if id librenms &>/dev/null; then
  skip "User 'librenms' exists"
else
  useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
  success "User 'librenms' created"
fi

# === 📦 Clone LibreNMS ===
banner "Cloning LibreNMS Code"
repo_dir=/opt/librenms
if [[ -d "$repo_dir/.git" ]]; then
  skip "$repo_dir exists, skipping clone"
else
  git clone https://github.com/librenms/librenms.git "$repo_dir"
  success "Repository cloned"
fi

chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/{rrd,logs,bootstrap/cache,storage}
setfacl -R -m g::rwx /opt/librenms/{rrd,logs,bootstrap/cache,storage}
success "Permissions set on /opt/librenms"

# verify html directory
if [[ ! -f /opt/librenms/html/index.php ]]; then
  error "Missing html/index.php after clone!"
  exit 1
fi

# === 💾 PHP Composer Dependencies ===
banner "Installing PHP Dependencies"
echo "If this fails behind a proxy, install composer manually. See the LibreNMS install page."
su - librenms -s /bin/bash -c 'cd /opt/librenms && ./scripts/composer_wrapper.php install --no-dev'
success "PHP dependencies installed"

# === 🛢️ MariaDB Setup ===
banner "Configuring MariaDB"
# MariaDB 11.x on 26.04 uses [mariadbd] (there is no [mysqld] section in 50-server.cnf).
# A drop-in file works on 24.04 and 26.04 and is safe to re-run.
cat > /etc/mysql/mariadb.conf.d/99-librenms.cnf <<'EOF'
[mariadbd]
innodb_file_per_table=1
lower_case_table_names=0
EOF
chmod 644 /etc/mysql/mariadb.conf.d/99-librenms.cnf
systemctl enable mariadb
systemctl restart mariadb

# escape \ and ' so any password is safe inside the SQL string
DB_PASSWORD_SQL="${DB_PASSWORD//\\/\\\\}"
DB_PASSWORD_SQL="${DB_PASSWORD_SQL//\'/\\\'}"
mysql -uroot <<MYSQL
CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY '${DB_PASSWORD_SQL}';
ALTER USER 'librenms'@'localhost' IDENTIFIED BY '${DB_PASSWORD_SQL}';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
MYSQL
success "MariaDB configured, database & user ready"

# === 🐘 PHP-FPM Pool Configuration ===
banner "Configuring PHP-FPM Pool"

# socket path used by the pool and by Nginx (same as the LibreNMS install guide)
PHP_SOCKET="/run/php-fpm-librenms.sock"

conf_dir="/etc/php/$PHP_VER/fpm/pool.d"
lib_conf="$conf_dir/librenms.conf"

# 1) Always rebuild the pool from www.conf so it matches $PHP_SOCKET
cp "$conf_dir/www.conf" "$lib_conf"
sed -i \
  -e 's/^\[www\]/[librenms]/' \
  -e 's/^user = www-data/user = librenms/' \
  -e 's/^group = www-data/group = librenms/' \
  -e "s|^listen = .*|listen = ${PHP_SOCKET}|" \
  "$lib_conf"
success "PHP-FPM pool created"

# 2) Apply timezone into PHP INI
for ini in fpm/php.ini cli/php.ini; do
  sed -i "s|^;\?date.timezone =.*|date.timezone = $TZ|" "/etc/php/$PHP_VER/$ini"
done

# 3) Enable & restart the service
systemctl enable php${PHP_VER}-fpm
systemctl restart php${PHP_VER}-fpm
success "PHP-FPM restarted and running on socket: ${PHP_SOCKET}"

# === 🌐 NGINX Config ===
banner "Configuring NGINX & SSL"
mkdir -p /etc/ssl/librenms
cert_key=/etc/ssl/librenms/librenms.key
cert_crt=/etc/ssl/librenms/librenms.crt

if [[ ! -f "$cert_key" || ! -f "$cert_crt" ]]; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$cert_key" -out "$cert_crt" \
    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$LIBRENMS_DOMAIN"
  chmod 640 "$cert_key" && chmod 644 "$cert_crt"
  success "Self-signed SSL cert created"
else
  skip "SSL certs exist"
fi

cat > /etc/nginx/sites-available/librenms.conf <<EOF
server {
    listen 80;
    server_name ${LIBRENMS_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${LIBRENMS_DOMAIN};
    ssl_certificate     $cert_crt;
    ssl_certificate_key $cert_key;
    root /opt/librenms/html;
    index index.php;

    charset utf-8;
    gzip on;
    gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ [^/]\.php(/|\$) {
        fastcgi_pass unix:${PHP_SOCKET};
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        include fastcgi.conf;
    }
    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/librenms.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx
success "NGINX configured"

# === 📟 SNMP Setup ===
banner "Configuring SNMP"
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
# escape characters that are special in a sed replacement (\ & /)
SNMP_COMMUNITY_SED="$(printf '%s' "$SNMP_COMMUNITY" | sed 's/[\\&/]/\\&/g')"
sed -i "s/RANDOMSTRINGGOESHERE/$SNMP_COMMUNITY_SED/g" /etc/snmp/snmpd.conf
curl -fsSL -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd
success "SNMP ready"

# === 🕓 CRON, LOGROTATE and Scheduler ===
banner "CRON, LOGROTATE and Scheduler"
cp /opt/librenms/dist/librenms.cron     /etc/cron.d/librenms
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer
success "Copied cron and logrotate configs and enabled the scheduler"

# === 📝 Update .env file with APP_URL & SESSION_SECURE_COOKIE ===
banner "Updating .env file"
ENV_FILE=/opt/librenms/.env
touch "$ENV_FILE"

# Replace the key if present (commented out or not), otherwise append it,
# so re-runs do not add duplicate lines
set_env() {
  if grep -qE "^#?[[:space:]]*${1}=" "$ENV_FILE"; then
    sed -i -E "s|^#?[[:space:]]*${1}=.*|${1}=${2}|" "$ENV_FILE"
  else
    echo "${1}=${2}" >> "$ENV_FILE"
  fi
}
set_env APP_URL "https://${LIBRENMS_DOMAIN}"
set_env SESSION_SECURE_COOKIE true
chown librenms:librenms "$ENV_FILE"

success ".env file updated with APP_URL and SESSION_SECURE_COOKIE"

# === 🔁 Enable & Restart Services ===
banner "Enabling & Restarting Services"
systemctl enable mariadb php${PHP_VER}-fpm nginx snmpd
systemctl restart mariadb php${PHP_VER}-fpm nginx snmpd
success "All services up"

# === 🔗 Updating binary links ===
banner "🔗 Linking LibreNMS CLI (lnms)"

# Fix lnms symlink only if missing or wrong
if [[ ! -L /usr/local/bin/lnms || "$(readlink -f /usr/local/bin/lnms)" != "/opt/librenms/lnms" ]]; then
  ln -sf /opt/librenms/lnms /usr/local/bin/lnms
  chmod +x /opt/librenms/lnms
  echo "🔗 lnms symlink created/updated."
else
  echo "✅ lnms symlink already correct."
fi

# Always copy bash completion
mkdir -p /etc/bash_completion.d
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/
echo "📋 Bash completion script installed."

success "Binary links updated"

# === ✅ COMPLETE ===
banner "LibreNMS Installation Complete"
echo -e "\n${GRN}✔ Access LibreNMS at: https://${LIBRENMS_DOMAIN}/install${RST}"
echo -e "🔐 MySQL user: librenms"
echo -e "🔑 MySQL password: ${YEL}${DB_PASSWORD}${RST}"
echo -e "🛰️ SNMP Community: ${YEL}${SNMP_COMMUNITY}${RST}"
echo -e "🔒✨ Update SSL key/crt in /etc/ssl/librenms/"
echo -e "\n🔧 To enable UFW for LibreNMS, you can run:"
echo -e "  sudo ufw allow 80,443/tcp"
echo -e "  sudo ufw reload"
echo -e "\n🚀 Then finish the web-UI setup at the URL above."
echo -e "   Afterwards run:  su - librenms -c './validate.php'"
