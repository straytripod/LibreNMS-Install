# LibreNMS installation script for Raspberry Pi

#!/bin/bash
echo "Installing LibreNMS on Raspberry Pi"
echo "###########################################################"

# Set the system timezone
echo "Have you set the system time zone?: [yes/no]"
read ANS
if [[ "$ANS" =~ ^([Nn][Oo]?|NO)$ ]]; then
  echo "Listing available timezones..."
  timedatectl list-timezones
  echo "Enter system time zone:"
  read TZ
  timedatectl set-timezone $TZ
  echo "The timezone $TZ has been set."
else
  TZ="$(cat /etc/timezone)"
fi

echo "Updating package lists and upgrading existing packages..."
sudo apt update && sudo apt upgrade -y

echo "Installing required dependencies..."
sudo apt install -y software-properties-common acl curl fping git graphviz imagemagick mariadb-client mariadb-server \
    nmap php-cli php-curl php-fpm php-gd php-gmp php-mbstring php-mysql php-snmp php-xml php-zip \
    python3-pymysql python3-psutil python3-dotenv python3-redis python3-setuptools python3-systemd python3-pip \
    rrdtool snmp snmpd whois unzip traceroute composer

# Download LibreNMS
echo "Downloading LibreNMS to /opt"
sudo git clone https://github.com/librenms/librenms.git /opt/librenms

# Create LibreNMS user
echo "Creating LibreNMS user..."
sudo useradd -M -r -d /opt/librenms -s /bin/bash librenms
sudo chown -R librenms:librenms /opt/librenms
sudo chmod 771 /opt/librenms

# Set ACL permissions
sudo setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
sudo setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

# Install PHP dependencies
echo "Installing PHP dependencies..."
sudo -u librenms bash -c '/opt/librenms/scripts/composer_wrapper.php install --no-dev'

# Configure MariaDB
echo "Configuring MariaDB..."
sudo systemctl restart mariadb

echo "Enter a password for the LibreNMS database user:"
read -s DB_PASS

sudo mysql -uroot -e "CREATE DATABASE librenms CHARACTER SET utf8 COLLATE utf8_unicode_ci;"
sudo mysql -uroot -e "CREATE USER 'librenms'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -uroot -e "GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';"
sudo mysql -uroot -e "FLUSH PRIVILEGES;"

# Configure PHP-FPM
echo "Configuring PHP-FPM..."
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
sudo cp /etc/php/$PHP_VERSION/fpm/pool.d/www.conf /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf

sudo sed -i 's/\[www\]/\[librenms\]/' /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf
sudo sed -i 's/user = www-data/user = librenms/' /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf
sudo sed -i 's/group = www-data/group = librenms/' /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf
sudo sed -i 's/listen = .*/listen = \/run\/php-fpm-librenms.sock/' /etc/php/$PHP_VERSION/fpm/pool.d/librenms.conf

sudo sed -i "s/;date.timezone =/date.timezone = $TZ/" /etc/php/$PHP_VERSION/fpm/php.ini
sudo sed -i "s/;date.timezone =/date.timezone = $TZ/" /etc/php/$PHP_VERSION/cli/php.ini

sudo systemctl restart php$PHP_VERSION-fpm

# Configure Nginx
echo "Configuring Nginx..."
echo "Enter Hostname (IP or domain):"
read HOSTNAME

sudo bash -c "cat > /etc/nginx/sites-available/librenms <<EOF
server {
    listen 80;
    server_name $HOSTNAME;
    root /opt/librenms/html;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ [^/]\.php(/|$) {
        fastcgi_pass unix:/run/php-fpm-librenms.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        include fastcgi.conf;
    }
    location ~ /\. {
        deny all;
    }
}
EOF"

sudo ln -s /etc/nginx/sites-available/librenms /etc/nginx/sites-enabled/
sudo systemctl restart nginx

# Enable LibreNMS Scheduler and Services
echo "Setting up LibreNMS scheduler and services..."
sudo ln -s /opt/librenms/lnms /usr/bin/lnms
sudo cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/
sudo cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf

# Configure SNMP
echo "Enter SNMP community string (e.g., public):"
read SNMP_COMMUNITY
sudo sed -i "s/RANDOMSTRINGGOESHERE/$SNMP_COMMUNITY/g" /etc/snmp/snmpd.conf
sudo curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
sudo chmod +x /usr/bin/distro
sudo systemctl enable snmpd
sudo systemctl restart snmpd

# Setup cron job and logrotate
echo "Configuring cron job and log rotation..."
sudo cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms
sudo cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

# Finish installation
echo "Navigate to http://$HOSTNAME/install in your web browser to complete the installation."
echo "Installation complete!"
