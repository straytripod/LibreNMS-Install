#!/bin/bash
# LibreNMS Install script
# NOTE: Script will update and upgrade currently installed packages.
# Updated for Ubuntu 26.04 LTS (also supports 24.04 LTS via the ondrej/php PPA)
# Follows https://docs.librenms.org/Installation/Install-LibreNMS/ (NGINX)

# Set the script to exit immediately if a command exits with a non-zero status.
set -e
# Files written to /etc must not be world-writable (cron and MariaDB ignore them)
umask 022

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root (e.g. sudo $0)"
    exit 1
fi

# Detect the Ubuntu release
. /etc/os-release
PHP_VER="8.5" # LibreNMS: minimum PHP 8.4, recommended 8.5
case "$VERSION_ID" in
    26.04) USE_PPA="no" ;;  # PHP 8.5 ships in the Ubuntu archive
    24.04) USE_PPA="yes" ;; # PHP 8.3 is too old; PHP 8.5 comes from the ondrej/php PPA
    *)
        echo "This script supports Ubuntu 26.04 and 24.04. Detected: $PRETTY_NAME"
        read -r -p "Continue anyway? [y/N]: " ANS
        [[ "$ANS" =~ ^[Yy]$ ]] || exit 1
        USE_PPA="no"
        ;;
esac

# Avoid interactive apt/debconf prompts
export DEBIAN_FRONTEND=noninteractive

echo "This will install LibreNMS on $PRETTY_NAME with PHP $PHP_VER"
echo "###########################################################"

# Set the system timezone
echo "Have you set the system time zone?: [yes/no]"
read -r ANS
if [[ "$ANS" =~ ^[Nn][Oo]?$ ]]; then
    echo "We will list the timezones"
    echo "Use q to quit the list"
    echo "-----------------------------"
    sleep 5
    echo " "
    timedatectl list-timezones
    echo "Enter system time zone:"
    read -r TZ
    timedatectl set-timezone "$TZ"
    echo "The timezone $TZ has been set"
else
    # /etc/timezone no longer exists on current Ubuntu releases
    TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    [[ -z "$TZ" ]] && TZ="$(readlink -f /etc/localtime | sed 's|^/usr/share/zoneinfo/||')"
    [[ -z "$TZ" ]] && TZ="Etc/UTC"
    echo "Using system timezone: $TZ"
fi

echo " "
echo "Updating repos"
echo "###########################################################"
apt update -y

if [[ "$USE_PPA" == "yes" ]]; then
    apt install -y software-properties-common
    # Workaround for non-UTF-8 locales
    LC_ALL=C.UTF-8 add-apt-repository -y universe
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    apt update -y
fi

echo "Upgrading installed packages in the system"
echo "###########################################################"
apt upgrade -y

echo "Installing dependencies"
echo "###########################################################"
echo " Here we GO!!! "
echo "###########################################################"

# Package list from the LibreNMS install guide (Ubuntu 26.04 / NGINX).
# composer is not needed: composer_wrapper.php downloads it.
apt install -y acl curl fping git graphviz imagemagick mariadb-client \
    mariadb-server mtr-tiny nginx-full nmap \
    php${PHP_VER}-cli php${PHP_VER}-curl php${PHP_VER}-fpm php${PHP_VER}-gd \
    php${PHP_VER}-gmp php${PHP_VER}-mbstring php${PHP_VER}-mysql php${PHP_VER}-snmp \
    php${PHP_VER}-xml php${PHP_VER}-zip \
    python3-command-runner python3-dotenv python3-pip python3-psutil python3-pymysql \
    python3-redis python3-setuptools python3-systemd \
    rrdtool snmp snmpd traceroute unzip whois cron lsb-release

# Add librenms user (system user, home /opt/librenms, home not created)
echo "Creating libreNMS user account"
echo "###########################################################"
if ! id librenms &>/dev/null; then
    useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
fi

# Download LibreNMS
echo "Downloading libreNMS to /opt"
echo "###########################################################"
if [[ ! -d /opt/librenms/.git ]]; then
    git clone https://github.com/librenms/librenms.git /opt/librenms
else
    echo "/opt/librenms already exists, skipping clone"
fi

# Set permissions and access controls
echo "Setting permissions and file access controls"
echo "###########################################################"
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

### Install PHP dependencies
echo "Running PHP installer script as librenms user"
echo "###########################################################"
echo "If this fails behind a proxy, install composer manually. See the LibreNMS install page."
su - librenms -s /bin/bash -c 'cd /opt/librenms && ./scripts/composer_wrapper.php install --no-dev'

#### Set PHP timezone ####
echo "Setting date.timezone = $TZ in /etc/php/$PHP_VER/{fpm,cli}/php.ini"
echo "###########################################################"
for ini in /etc/php/$PHP_VER/fpm/php.ini /etc/php/$PHP_VER/cli/php.ini; do
    sed -i "s|^;\?date.timezone =.*|date.timezone = $TZ|" "$ini"
done

# Configure MariaDB
echo "###########################################################"
echo "Configuring MariaDB"
echo "###########################################################"
# MariaDB 11.x on 26.04 uses [mariadbd] (there is no [mysqld] section in 50-server.cnf).
# A drop-in file works on 24.04 and 26.04 and is safe to re-run.
cat > /etc/mysql/mariadb.conf.d/99-librenms.cnf <<'EOF'
[mariadbd]
innodb_file_per_table=1
lower_case_table_names=0
EOF
chmod 644 /etc/mysql/mariadb.conf.d/99-librenms.cnf # MariaDB ignores world-writable config files
systemctl enable mariadb
systemctl restart mariadb

# Create DB, user, and privileges
while true; do
    read -r -s -p "Please enter a password for the librenms database user: " DBPASS; echo
    read -r -s -p "Confirm password: " DBPASS2; echo
    [[ -n "$DBPASS" && "$DBPASS" == "$DBPASS2" ]] && break
    echo "Passwords were empty or did not match, try again."
done
DBPASS_SQL="${DBPASS//\\/\\\\}"
DBPASS_SQL="${DBPASS_SQL//\'/\\\'}"
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'localhost' IDENTIFIED BY '${DBPASS_SQL}';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF

### Configure PHP-FPM ####
POOL=/etc/php/$PHP_VER/fpm/pool.d/librenms.conf
cp /etc/php/$PHP_VER/fpm/pool.d/www.conf "$POOL"
sed -i \
    -e 's/^\[www\]/[librenms]/' \
    -e 's/^user = www-data/user = librenms/' \
    -e 's/^group = www-data/group = librenms/' \
    -e 's|^listen = .*|listen = /run/php-fpm-librenms.sock|' \
    "$POOL"
systemctl enable php${PHP_VER}-fpm
systemctl restart php${PHP_VER}-fpm

####  Config NGINX webserver ####
echo "################################################################################"
echo "Enter the server name for /etc/nginx/conf.d/librenms.conf"
echo "Use the IP unless the name is resolvable."
echo "################################################################################"
read -r -p "Enter Hostname [x.x.x.x or serv.example.com]: " HOSTNAME
# Quoted heredoc so nginx variables ($uri, $query_string) are written literally
cat > /etc/nginx/conf.d/librenms.conf <<'EOF'
server {
 listen      80;
 server_name __SERVER_NAME__;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 location / {
  try_files $uri $uri/ /index.php?$query_string;
 }
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF
sed -i "s|__SERVER_NAME__|$HOSTNAME|" /etc/nginx/conf.d/librenms.conf

##### remove the default site #####
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
nginx -t
systemctl enable nginx
systemctl restart nginx

#### Enable LNMS Command completion ####
ln -sf /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

### Configure snmpd
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
read -r -p "Enter SNMP community string for this server [e.g.: public]: " ANS
sed -i "s/RANDOMSTRINGGOESHERE/$ANS/g" /etc/snmp/snmpd.conf

######## distro script used by snmpd extend
curl -fsSL -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro

#### Enable SNMP to run at startup ####
systemctl enable snmpd
systemctl restart snmpd

##### Setup Cron job
cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms
systemctl enable cron

#### Enable the scheduler
cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

##### Setup logrotate config
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

echo " "
echo "###############################################################################################"
echo "Navigate to http://$HOSTNAME/install in your web browser to finish the installation."
echo "Database: librenms   User: librenms   Password: (the one you entered)"
echo "Afterwards run:  su - librenms -c './validate.php'"
echo "###############################################################################################"
echo "Have a nice day! ;)"
#END#
