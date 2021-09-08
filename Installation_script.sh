#!/bin/bash

##### Configure The Server #####
################################

# Define the root user db password 
echo "Please enter the password we should set for the root mysql user: "
read -s DBPASS

# Create RO DB user and grant perms 
echo "Please enter the password we should set for the RO mysql user: "
read -s RODBPASS

# Get Server and Wisp Info 
read -p "Please enter the name for this RO Server: " RO_SERVER
read -p "Please enter the name for this RO WISP Service: " RO_WISP_SERVER

# Update 
echo "Updating the server:"
apt -y update

# Configure some swap since we will most likely 
# consume more memory than we have on this small vm
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile   none    swap    sw    0   0" >> /etc/fstab

# Install Deps
echo "Installing Deps:"
apt -y install \
  gcc \
  gettext \
  git \
  make \
  screen

apt -y install \
  build-essential \
  mysql-server \
  mysql-client \
  zlib1g-dev \
  libmysqlclient-dev \
  libpcre3-dev \
  php-mbstring \
  phpmyadmin

# Enabling mysql at boot
systemctl enable mysql
systemctl start mysql

# Config mbstring php extention
phpenmod mbstring
systemctl restart apache2

# Update mysql root user to require password
echo "Setting root user password for MySQL:" 
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DBPASS}';"
mysql -e "FLUSH PRIVILEGES;" --password="${DBPASS}"

echo "Verifying new password:"
mysql -e "SELECT user,authentication_string,plugin,host FROM mysql.user;" --password="${DBPASS}"

# Output PhpMyAdmin info 
IP=$(wget -qO- http://ipecho.net/plain | xargs echo)
echo "PhpMyAdmin now available: https://${IP}/phpmyadmin"
echo "Login with the root user and password you just created"

# Create RO Databases 
mysql -e "CREATE DATABASE ragnarok;" --password="${DBPASS}"

echo "Creating RO MySQL user and granting full perms on the RO and RO_Log dbs: "

mysql -e "CREATE USER 'ragnarok'@'localhost' IDENTIFIED BY '${RODBPASS}';" --password="${DBPASS}"
mysql -e "GRANT ALL PRIVILEGES ON ragnarok.* TO 'ragnarok'@'localhost';" --password="${DBPASS}"

# Create RO server user 
echo "Creating RO server user: "
useradd --create-home --shell /bin/bash ragnarok
passwd ragnarok

# Create log files
echo "Creating RO server stdout log: /var/log/ragnarok_stdout.log"
touch /var/log/ragnarok_stdout.log
chown ragnarok:ragnarok $_

# Install Hercules Framework
echo "Download Hercules Framework"
su ragnarok 
git clone https://github.com/copeia/Hercules.git ~/Hercules
cd ~/Hercules/sql-files/

# Import DB tables 
echo "Importing DB Tables: "
mysql -u root --password="${DBPASS}" ragnarok < main.sql
mysql -u root --password="${DBPASS}" ragnarok < logs.sql
mysql -u root --password="${DBPASS}" ragnarok < item_db2.sql
mysql -u root --password="${DBPASS}" ragnarok < mob_db2.sql
mysql -u root --password="${DBPASS}" ragnarok < mob_skill_db2.sql
mysql -u root --password="${DBPASS}" ragnarok < item_db.sql
mysql -u root --password="${DBPASS}" ragnarok < mob_db.sql
mysql -u root --password="${DBPASS}" ragnarok < mob_skill_db.sql

# Configure non-default char user
echo "Setting up Service User in DB: "
mysql -u root --password="${DBPASS}" -e "USE ragnarok
UPDATE login 
SET 
    userid = 'ragnarok',
    user_pass = '${RODBPASS}'
WHERE
    account_id = '1';
"

# Update Hercules config with correct database info
cd ~/Hercules/
echo "Updating Server config files: "
# Change DB password 
sed -i "s/db_password: \"ragnarok\"/db_password: \"${RODBPASS}\"/g" conf/global/sql_connection.conf

# Make sure login id is set case_sensitive 
sed -i 's+//case_sensitive: false+case_sensitive: true+g' conf/global/sql_connection.conf

# Update the Charatcher server info
sed -i "s/server_name: \"Hercules\"/server_name: \"${RO_SERVER}\"/g" conf/char/char-server.conf
sed -i "s/wisp_server_name: \"Server\"/wisp_server_name: \"${RO_WISP_SERVER}\"/g" conf/char/char-server.conf
sed -i 's/userid: "s1"/userid: "ragnarok"/g' conf/char/char-server.conf
sed -i "s/passwd: \"p1\"/passwd: \"${RODBPASS}\"/g" conf/char/char-server.conf
sed -i "s+//char_ip: \"127.0.0.1\"+char_ip: \"${IP}\"+g" conf/char/char-server.conf
#sed -i "s+//map_ip: \"127.0.0.1\"+map_ip: \"${IP}\"+g" conf/char/char-server.conf

# Update the Map server
sed -i 's/userid: "s1"/userid: "ragnarok"/g' conf/map/map-server.conf
sed -i "s/passwd: \"p1\"/passwd: \"${RODBPASS}\"/g" conf/map/map-server.conf
sed -i "s+//map_ip: \"127.0.0.1\"+map_ip: \"${IP}\"+g" conf/char/map-server.conf
#sed -i "s+//char_ip: \"127.0.0.1\"+char_ip: \"${IP}\"+g" conf/char/map-server.conf

# Update the server networking 
sed -i "s/\"0.0.0.0:0.0.0.0\"/${IP}:255.255.255.254/g" conf/network.conf
sed -i "s#//\"127.0.0.1:255.0.0.0\"#\"127.0.0.1:255.0.0.0\"#g" conf/network.conf

# Update for the RO version we'd like to run 
sed -i "s/#define PACKETVER 20190530/#define PACKETVER 20150513/g" src/common/mmo.h

# Build the server binary
echo "Building the server binary - This may take a few minutes..." 
bash ./configure --enable-packetver=20150513
make clean
make sql

# Start the server
echo "Starting the server and tailing the logs: "
sh athena-start start >> /var/log/ragnarok_stdout.log
tail -F /var/log/ragnarok_stdout.log