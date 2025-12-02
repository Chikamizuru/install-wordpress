#!/bin/bash

# ==========================================
# AUTO INSTALL SCRIPT V5 
# (Log, Smart Detect, Conflict Handler, Auto-Swap)
# ==========================================

# 1. SETUP LOGGING
LOG_DIR="/var/log/chikami"
LOG_FILE="$LOG_DIR/hasil.log"

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    chmod 700 "$LOG_DIR"
fi

log_activity() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

echo "=================================================" >> "$LOG_FILE"
log_activity "MULAI SCRIPT INSTALASI V5"

# 2. CEK ROOT
if [[ $EUID -ne 0 ]]; then
   echo "Error: Jalankan sebagai root (sudo)." 
   exit 1
fi

# 3. CEK RAM & SWAP
log_activity "Cek Hardware..."
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_SWAP=$(free -m | awk '/^Swap:/{print $2}')

if [[ $TOTAL_RAM -lt 1000 && $TOTAL_SWAP -eq 0 ]]; then
    log_activity "WARNING: RAM < 1GB, No Swap."
    read -p "Buat SWAP 2GB? (y/n): " create_swap
    if [[ "$create_swap" == "y" ]]; then
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log_activity "Swap 2GB dibuat."
    fi
fi

echo ""
log_activity "Update Repository..."
apt update -y > /dev/null 2>&1

# ---------------------------------------------
# 4. HANDLER KONFLIK WEB SERVER
# ---------------------------------------------
echo ""
echo "=== PILIH WEB SERVER ==="
echo "1. Nginx"
echo "2. Apache2"
echo "0. Batal"
read -p "Pilihan: " webserver_choice

IS_NGINX=0

case $webserver_choice in
    1)
        # --- LOGIC NGINX ---
        # Cek Konflik: Apakah Apache jalan?
        if systemctl is-active --quiet apache2; then
            log_activity "KONFLIK TERDETEKSI: Apache2 sedang berjalan."
            log_activity "Mematikan Apache2 agar Nginx bisa jalan..."
            systemctl stop apache2
            systemctl disable apache2
        fi

        # Cek Install Nginx
        if command -v nginx >/dev/null 2>&1; then
            log_activity "INFO: Nginx sudah terinstall."
        else
            log_activity "Install Nginx..."
            apt install -y nginx
        fi
        
        # Pastikan Nginx start (kadang gagal kalau port 80 masih nyangkut)
        systemctl enable nginx
        systemctl restart nginx
        IS_NGINX=1
        ;;
    2)
        # --- LOGIC APACHE ---
        # Cek Konflik: Apakah Nginx jalan?
        if systemctl is-active --quiet nginx; then
            log_activity "KONFLIK TERDETEKSI: Nginx sedang berjalan."
            log_activity "Mematikan Nginx agar Apache2 bisa jalan..."
            systemctl stop nginx
            systemctl disable nginx
        fi

        # Cek Install Apache
        if command -v apache2 >/dev/null 2>&1; then
            log_activity "INFO: Apache2 sudah terinstall."
        else
            log_activity "Install Apache2..."
            apt install -y apache2
        fi
        systemctl enable apache2
        systemctl restart apache2
        ;;
    0)
        exit 0
        ;;
    *)
        echo "Pilihan salah."
        exit 1
        ;;
esac

# ---------------------------------------------
# 5. HANDLER DATABASE (MySQL vs MariaDB)
# ---------------------------------------------
echo ""
log_activity "Cek Database..."

DB_INSTALLED=0

# Cek MariaDB (Sering bentrok sama MySQL)
if dpkg -l | grep -q mariadb-server; then
    log_activity "INFO: MariaDB Server terdeteksi. Skip install MySQL."
    DB_INSTALLED=1
elif command -v mysql >/dev/null 2>&1; then
    log_activity "INFO: MySQL Server sudah terinstall."
    DB_INSTALLED=1
else
    log_activity "Belum ada database. Menginstall MySQL Server..."
    apt install -y mysql-server unzip wget
    DB_INSTALLED=1
fi

# Install PHP
log_activity "Cek paket PHP..."
apt install -y php php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-json libapache2-mod-php > /dev/null 2>&1

# Config Nginx Auto
if [[ $IS_NGINX -eq 1 ]]; then
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    
    if grep -q "fastcgi_pass" /etc/nginx/sites-available/default; then
         log_activity "Config Nginx sudah ada. Skip."
    else
         log_activity "Setup Nginx config PHP $PHP_VERSION..."
         cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.php index.html index.htm index.nginx-debian.html;
    server_name _;
    location / {
        try_files \$uri \$uri/ =404;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$FPM_SOCKET;
    }
}
EOF
        systemctl restart nginx
    fi
fi

# ---------------------------------------------
# 6. INPUT DATA DATABASE (CUSTOM)
# ---------------------------------------------
echo ""
echo "--- KONFIGURASI DATABASE ---"
read -p "Nama Database : " DB_NAME
read -p "Username DB   : " DB_USER
read -s -p "Password DB   : " DB_PASS
echo ""

if [[ -n "$DB_NAME" && -n "$DB_USER" && -n "$DB_PASS" ]]; then
    log_activity "Setup Database: $DB_NAME..."
    
    # Logic pembuatan DB (Bekerja di MySQL maupun MariaDB)
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # LOG SENSITIF
    echo "--- DB CREDENTIALS ---" >> "$LOG_FILE"
    echo "DB: $DB_NAME | User: $DB_USER | Pass: $DB_PASS" >> "$LOG_FILE"
    
    log_activity "Database siap."
else
    log_activity "Input tidak lengkap. Setup DB dilewati."
fi

# ---------------------------------------------
# 7. DOWNLOAD APPS
# ---------------------------------------------
echo ""
echo "=== PILIH APLIKASI (Pisahkan koma, 1,2) ==="
echo "1. phpMyAdmin"
echo "2. WordPress"
read -p "Pilihan: " app_choices

cd /var/www/html || exit

if [[ "$app_choices" == *"1"* ]]; then
    if [ -d "phpmyadmin" ]; then
        log_activity "phpMyAdmin sudah ada."
    else
        log_activity "Download phpMyAdmin..."
        wget -q https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.zip -O phpmyadmin.zip
        unzip -q phpmyadmin.zip
        mv phpMyAdmin-5.2.3-all-languages phpmyadmin
        rm phpmyadmin.zip
    fi
fi

if [[ "$app_choices" == *"2"* ]]; then
    if [ -d "wordpress" ]; then
         log_activity "WordPress sudah ada."
    else
        log_activity "Download WordPress..."
        wget -q https://id.wordpress.org/latest-id_ID.zip -O wordpress.zip
        unzip -q wordpress.zip
        rm wordpress.zip
    fi
fi

chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

echo ""
log_activity "SCRIPT SELESAI. Cek log: $LOG_FILE"
