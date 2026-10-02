# LibreNMS-Install
A batch script to install LibNMS on Ubuntu 18.04 LTS  Originally.</br>
Updated the script to work on Ubuntu 24.04 LTS with help from skender85<br>
Updated for Ubuntu 26.04 LTS (PHP 8.5 from the Ubuntu archive, MariaDB 11.8). On 24.04 it installs PHP 8.5 from the ondrej/php PPA, because LibreNMS now needs PHP 8.4 or newer.<br>
The 26.04 update was tested in an Ubuntu 26.04 container up to the web installer page. It has not been tested on a full VM or hardware install, and the 24.04 path is untested. Please review the script before running and submit errors or changes.<br>
After the web installer finishes, run a validation (`su - librenms -c './validate.php'`) and fix anything it reports, such as the DB tables.<br>

# LibreNMS-Install-v2
A verbose and decorated version of the script submitted by BlwAvg. Developed on Ubuntu 24.04 minimal.<br>
Updated for Ubuntu 26.04 LTS in the same way as LibreNMS-Install (PHP 8.5, MariaDB 11.8), with the same level of testing.

# LibreNMS-PI 
A version of the script that runs on RaspberryPi. submitted by axtonprice.
This script has not been tested. Please review the script before running and submit errors or changes.

# LibreNMS-Docker-Install
A batch script to install LibNMS on docker. Dev</br>
The script uses the default examples compose.yaml</br>
The script uses the default examples librenms.env. Devloped for Ubuntu on 24.04. </br>
Both are located /opt/docker/librenms/docker-master/examples/compose after install</br>
