# LibreNMS Install script
# NOTE: Script wil update and upgrade currently installed packages.
#!/bin/bash
echo "This will install LibreNMS. Developed on Ubuntu 22.04 lts"
echo "###########################################################"
echo "Updating the repo cache and installing needed repos"
echo "###########################################################"
# Set the system timezone
echo "Have you set the system time zone?: [yes/no]"
read ANS
if [ "$ANS" = "N" ] || [ "$ANS" = "No" ] || [ "$ASN" = "NO'" ] || [ "$ANS" = "no" ] || [ "$ANS" = "n" ]; then
  echo "We will list the timezones"
  echo "Use q to quite the list"
  echo "-----------------------------"
  sleep 5
  echo " "
  timedatectl list-timezones
  echo "Enter system time zone:"
  read TZ
  timedatectl set-timezone $TZ
  else 
  TZ="cat /etc/timezone"
fi
apt update
# Installing Required Packages
apt install software-properties-common
add-apt-repository universe
echo "Upgrading installed packages in the system"
echo "###########################################################"
apt upgrade -y
echo "Installing dependancies"
echo "###########################################################"
# Version 8 has moved json into core code and it is no longer a separate module. 
apt install -y acl curl composer fping git graphviz imagemagick mariadb-client \
mariadb-server mtr-tiny nginx-full nmap php8.1-cli php8.1-curl php8.1-fpm \
php8.1-gd php8.1-mbstring php8.1-mysql php8.1-snmp php8.1-xml \
php8.1-zip python3-memcache python3-dev python3-pip python3-mysqldb rrdtool \
snmp snmpd whois unzip
# Download LibreNMS
echo "Downloading libreNMS to /opt"
echo "###########################################################"
cd /opt
git clone https://github.com/librenms/librenms.git
# Add librenms user
echo "Creating libreNMS user account, set the home directory, don't create it."
echo "###########################################################"
# add user link home directory, do not create home directory, system user
useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
# Add librenms user to www-data group
  # echo "Adding libreNMS user to the www-data group"
  # echo "###########################################################"
  # usermod -a -G librenms www-data
# Set permissions and access controls
echo "Setting permissions and file access controls"
echo "###########################################################"
# set owner:group recursively on directory
chown -R librenms:librenms /opt/librenms
# mod permission on directory O=All,G=All, Oth=none
chmod 771 /opt/librenms
# mod default ACL
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
# mod ACL recursively
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
### Install PHP dependencies
echo "running PHP installer script as librenms user"
echo "###########################################################"
# run php dependencies installer
su librenms bash -c '/opt/librenms/scripts/composer_wrapper.php install --no-dev'
# Configure MySQL (mariadb)
echo "Configuring MySQL (mariadb)"
echo "###########################################################"
systemctl restart mysql
# Pass commands to mysql and create DB, user, and privlages
echo "Please enter a password for the Database:"
read ANS
echo "###########################################################"
echo "######### MySQL DB:librenms Password:$ANS #################"
echo "###########################################################"
mysql -uroot -e "CREATE DATABASE librenms CHARACTER SET utf8 COLLATE utf8_unicode_ci;"
mysql -uroot -e "CREATE USER 'librenms'@'localhost' IDENTIFIED BY '$ANS';"
mysql -uroot -e "GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';"
mysql -uroot -e "FLUSH PRIVILEGES;"
##### Within the [mysqld] section of the config file please add: ####
## innodb_file_per_table=1
## lower_case_table_names=0
sed -i '/mysqld]/ a lower_case_table_names=0' /etc/mysql/mariadb.conf.d/50-server.cnf
sed -i '/mysqld]/ a innodb_file_per_table=1' /etc/mysql/mariadb.conf.d/50-server.cnf
##### Restart mysql and enable run at startup
systemctl restart mysql
systemctl enable mariadb
### Configure and Start PHP-FPM ####
## NEW in 20.04 brought forward to 22.04##
cp /etc/php/8.1/fpm/pool.d/www.conf /etc/php/8.1/fpm/pool.d/librenms.conf
# vi /etc/php/8.1/fpm/pool.d/librenms.conf
#line 4
sed -i 's/\[www\]/\[librenms\]/' /etc/php/8.1/fpm/pool.d/librenms.conf
# line 23
sed -i 's/user = www-data/user = librenms/' /etc/php/8.1/fpm/pool.d/librenms.conf
# line 24
sed -i 's/group = www-data/group = librenms/' /etc/php/8.1/fpm/pool.d/librenms.conf
# line 36
sed -i 's/listen = \/run\/php\/php8.1-fpm.sock/listen = \/run\/php-fpm-librenms.sock/' /etc/php/8.1/fpm/pool.d/librenms.conf
#### Change time zone to America/Denver in the following: ####
# /etc/php/8.1/fpm/php.ini
# /etc/php/8.1/cli/php.ini
echo "Timezone is being set to $TZ in /etc/php/8.1/fpm/php.ini and /etc/php/7.2/cli/php.ini change if needed."
echo "Changing to $TZ"
echo "################################################################################"
# Line 969 Appened
sed -i "/;date.timezone =/ a date.timezone = $TZ" /etc/php/8.1/fpm/php.ini
# Line 969 Appended
sed -i "/;date.timezone =/ a date.timezone = $TZ" /etc/php/8.1/cli/php.ini
echo "????????????????????????????????????????????????????????????????????????????????"
read -p "Please review changes in another terminal session then press [Enter] to continue..."
### restart PHP-fpm ###
systemctl restart php8.1-fpm
####  Config NGINX webserver ####
### Create the .conf file ###
echo "################################################################################"
echo "We need to change the sever name to the current IP unless the name is resolvable /etc/nginx/conf.d/librenms.conf"
echo "################################################################################"
echo "Enter Hostname [x.x.x.x or serv.examp.com]: "
read HOSTNAME
echo "server {"> /etc/nginx/conf.d/librenms.conf
echo " listen      80;" >>/etc/nginx/conf.d/librenms.conf
echo " server_name $HOSTNAME;" >>/etc/nginx/conf.d/librenms.conf
echo ' root        /opt/librenms/html;' >>/etc/nginx/conf.d/librenms.conf
echo " index       index.php;" >>/etc/nginx/conf.d/librenms.conf
echo " " >>/etc/nginx/conf.d/librenms.conf
echo " charset utf-8;" >>/etc/nginx/conf.d/librenms.conf
echo " gzip on;" >>/etc/nginx/conf.d/librenms.conf
echo " gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml \
text/plain text/xsd text/xsl text/xml image/x-icon;" >>/etc/nginx/conf.d/librenms.conf
echo ' location / {' >>/etc/nginx/conf.d/librenms.conf
echo '  try_files $uri $uri/ /index.php?$query_string;' >>/etc/nginx/conf.d/librenms.conf
echo " }" >>/etc/nginx/conf.d/librenms.conf
  #echo ' location /api/v0 {' >>/etc/nginx/conf.d/librenms.conf
echo ' location ~ [^/]\.php(/|$) {' >>/etc/nginx/conf.d/librenms.conf
  #echo '  try_files $uri $uri/ /api_v0.php?$query_string;' >>/etc/nginx/conf.d/librenms.conf
  #echo " }" >>/etc/nginx/conf.d/librenms.conf
  #echo ' location ~ \.php {' >>/etc/nginx/conf.d/librenms.conf
echo '  fastcgi_pass unix:/run/php-fpm-librenms.sock;' >>/etc/nginx/conf.d/librenms.conf
echo '  fastcgi_split_path_info ^(.+\.php)(/.+)$;' >>/etc/nginx/conf.d/librenms.conf
echo "  include fastcgi.conf;" >>/etc/nginx/conf.d/librenms.conf
echo " }" >>/etc/nginx/conf.d/librenms.conf
echo ' location ~ /\.(?!well-known).* {' >>/etc/nginx/conf.d/librenms.conf
echo "  deny all;" >>/etc/nginx/conf.d/librenms.conf
echo " }" >>/etc/nginx/conf.d/librenms.conf
echo "}" >>/etc/nginx/conf.d/librenms.conf
##### remove the default site link #####
rm /etc/nginx/sites-enabled/default
systemctl restart nginx
systemctl restart php8.1-fpm
#### Enble LNMS Command completion ####
ln -s /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/
### Configure snmpd
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
### Edit the text which says RANDOMSTRINGGOESHERE and set your own community string.
echo "We need to change community string"
echo "Enter community string for this server [E.G.: public]: "
read ANS
sed -i 's/RANDOMSTRINGGOESHERE/$ANS/g' /etc/snmp/snmpd.conf
######## get standard MIBs
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
#### Enable SNMP to run at startup ####
systemctl enable snmpd
systemctl restart snmpd
##### Setup Cron job
cp /opt/librenms/librenms.nonroot.cron /etc/cron.d/librenms
##### Setup logrotate config
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
<<removed
#### Set permissions and file access control
chown -R librenms:librenms /opt/librenms/config.php
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
chmod -R ug=rwX /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
echo "Select yes to the following or you will get an error during validation"
echo "------------------------------------------------------------------------"
sudo /opt/librenms/scripts/github-remove -d
removed
echo "Installing validation fix"
sudo -H -u librenms bash -c 'pip3 install --user -U -r /opt/librenms/requirements.txt'
######
echo "###############################################################################################"
echo "Naviagte to http://$HOSTNAME/install in you web browser to finish the installation."
echo "###############################################################################################"
