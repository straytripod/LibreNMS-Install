# LibreNMS Install script
# NOTE: Script wil update and upgrade currently installed packages.
#!/bin/bash
echo "This will install LibreNMS. Developed on Ubuntu 18.04 lts"
echo "###########################################################"
# Installing Required Packages
echo "Updating the repo cache and installing need repos"
echo "###########################################################"
apt install software-properties-common
add-apt-repository universe
echo "###########################################################"
apt update
echo "Upgrading packages in the system"
echo "###########################################################"
apt upgrade -y
echo "Installing dependancies"
echo "###########################################################"
apt install -y curl composer fping git graphviz imagemagick mariadb-client mariadb-server mtr-tiny nginx-full nmap php7.2-cli php7.2-curl php7.2-fpm php7.2-gd php7.2-json php7.2-mbstring php7.2-mysql php7.2-snmp php7.2-xml php7.2-zip python-memcache python-mysqldb rrdtool snmp snmpd whois unzip
# Add librenms user
echo "Creating libreNMS user account"
echo "###########################################################"
useradd librenms -d /opt/librenms -M -r
# Add librenms user to www-data group
echo "Adding libreNMS user to the www-data group"
echo "###########################################################"
usermod -a -G librenms www-data
# Download LibreNMS
echo "Downloading libreNMS to /opt"
echo "###########################################################"
cd /opt
git clone https://github.com/librenms/librenms.git
# Set permissions and access controls
echo "Setting permissions and file access controls"
echo "###########################################################"
chown -R librenms:librenms /opt/librenms
chmod 770 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
### Install PHP dependencies
echo running PHP installer script as librenms user
echo "###########################################################"
# su - librenms
# run php dependencies installer
sudo -u librenms bash -c '/opt/librenms/scripts/composer_wrapper.php install --no-dev'
###Log out of user
##exit
# Configure MySQL (mariadb)
echo "Configuring MySQL (mariadb)"
echo "###########################################################"
systemctl restart mysql
# log in to mysql and create DB, user, and privlages
echo "Setting up the Database"
echo "###########################################################"
echo "######### MySQL DB:librenms Password:librenms #############"
echo "###########################################################"
mysql -uroot -e "CREATE DATABASE librenms CHARACTER SET utf8 COLLATE utf8_unicode_ci; CREATE USER 'librenms'@'localhost' IDENTIFIED BY 'librenms'; GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost'; FLUSH PRIVILEGES;"
##### Within the [mysqld] section of the config file please add: ####
sed -i '/mysqld/ a lower_case_table_names=0' /etc/mysql/mariadb.conf.d/50-server.cnf
sed -i '/mysqld/ a innodb_file_per_table=1' /etc/mysql/mariadb.conf.d/50-server.cnf
innodb_file_per_table=1
lower_case_table_names=0
##### Restart mysql
systemctl restart mysql
# Configure and Start PHP-FPM
#### Change time zone to America/Denver in the following
# /etc/php/7.2/fpm/php.ini
# /etc/php/7.2/cli/php.ini
sed -i '/date.timezone/ a date.timezone = America/Denver' /etc/php/7.2/fpm/php.ini
sed -i '/date.timezone/ a date.timezone = America/Denver' /etc/php/7.2/cli/php.ini
### restart PHP-fpm
systemctl restart php7.2-fpm
####  Config NGINX
### Create .conf file
echo "################################################################################"
echo "We need to change the sever name to the current IP unless the name is resolvable /etc/nginx/conf.d/librenms.conf"
echo "################################################################################"
echo "Enter Hostname [x.x.x.x or serv.examp.com]: "
read ANS
echo "server {"> /etc/nginx/conf.d/librenms.conf 
echo " listen      80;" >>/etc/nginx/conf.d/librenms.conf
echo " server_name $ANS;" >>/etc/nginx/conf.d/librenms.conf
echo " root        /opt/librenms/html;" >>/etc/nginx/conf.d/librenms.conf
echo " index       index.php;" >>/etc/nginx/conf.d/librenms.conf
echo " " >>/etc/nginx/conf.d/librenms.conf
echo " charset utf-8;" >>/etc/nginx/conf.d/librenms.conf
echo " gzip on;" >>/etc/nginx/conf.d/librenms.conf
echo " gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml  text/plain text/xsd text/xsl text/xml image/x-icon;" >>/etc/nginx/conf.d/librenms.conf
echo " location / {" >>/etc/nginx/conf.d/librenms.conf
echo "  try_files $uri $uri/ /index.php?$query_string;" >>/etc/nginx/conf.d/librenms.conf
echo " }" >>/etc/nginx/conf.d/librenms.conf
echo " location /api/v0 {" >>/etc/nginx/conf.d/librenms.conf
echo "  try_files $uri $uri/ /api_v0.php?$query_string;" >>/etc/nginx/conf.d/librenms.conf
echo " }" >>/etc/nginx/conf.d/librenms.conf
echo " location ~ \.php {" >>/etc/nginx/conf.d/librenms.conf
echo "  include fastcgi.conf;" >>/etc/nginx/conf.d/librenms.conf
echo "  fastcgi_split_path_info ^(.+\.php)(/.+)$;" >>/etc/nginx/conf.d/librenms.conf
echo "  fastcgi_pass unix:/var/run/php/php7.2-fpm.sock;" >>/etc/nginx/conf.d/librenms.conf
echo " }" >>/etc/nginx/conf.d/librenms.conf
echo " location ~ /\.ht {" >>/etc/nginx/conf.d/librenms.conf
echo "  deny all;" >>/etc/nginx/conf.d/librenms.conf
echo " }" >>/etc/nginx/conf.d/librenms.conf
echo "}" >>/etc/nginx/conf.d/librenms.conf
##### remove the default site link
rm /etc/nginx/sites-enabled/default
systemctl restart nginx
### Configure snmpd
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
### Edit the text which says RANDOMSTRINGGOESHERE and set your own community string.
echo "We need to change community string"
echo "Enter community name [E.G.: public]: "
read ANS
sed -i 's/RANDOMSTRINGGOESHERE/$ANS/g' /etc/snmp/snmpd.conf
######## get standard MIBs
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl restart snmpd
##### Setup Cron job
cp /opt/librenms/librenms.nonroot.cron /etc/cron.d/librenms
##### Setup logrotate config
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
#### Set permissions and file access control
chown -R librenms:librenms /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
######
echo "###############################################################################################"
echo "Naviagte to http://[IP or Hostname]/install.php in you web browser to finish the installation."
echo "###############################################################################################"
