#!/bin/bash

# ==========================================
# AUTO INSTALL SCRIPT V3.5 (MODIFIED)
# Fitur: V3 Folder Structure + Logging + Custom DB + Smart Detect
# ==========================================

# 1. SETUP LOGGING (Fitur Baru)
LOG_DIR="/var/log/chikami"
LOG_FILE="$LOG_DIR/hasil.log"

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    chmod 700 "$LOG_DIR"
fi

# Fungsi untuk catat log ke layar & file
log_activity() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

echo "=================================================" >> "$LOG_FILE"
log_activity "MULAI SCRIPT INSTALASI V3.5"

# 2. CEK ROOT USER
if [[ $EUID -ne 0 ]]; then
   echo "Error: Script ini harus dijalankan sebagai root (sudo)." 
   exit 1
fi

# ---------------------------------------------
# 3. CEK RAM & SWAP
# ---------------------------------------------
log_activity "Memeriksa Spesifikasi Server..."

TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_SWAP=$(free -m | awk '/^Swap:/{print $2}')

echo "RAM: ${TOTAL_RAM}MB | SWAP: ${TOTAL_SWAP}MB"

if [[ $TOTAL_RAM -lt 1000 ]]; then
    if [[ $TOTAL_SWAP -eq 0 ]]; then
        log_activity "WARNING: RAM < 1GB & No Swap."
        read -p "Buat SWAP 2GB? (y/n): " create_swap_choice
        
        if [[ "$create_swap_choice" == "y" || "$create_swap_choice" == "Y" ]]; then
            log_activity "Membuat Swap 2GB..."
            fallocate -l 2G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            if ! grep -q "/swapfile" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            log_activity "Swap 2GB berhasil dibuat."
        else
            log_activity "User menolak pembuatan Swap."
        fi
    else
        log_activity "Swap sudah tersedia. Aman."
    fi
fi

echo ""
log_activity "Update Repository..."
apt update -y > /dev/null 2>&1

# ---------------------------------------------
# 4. PILIH WEB SERVER (Dengan Deteksi)
# ---------------------------------------------
echo ""
echo "=== PILIH WEB SERVER ==="
echo "1. Nginx (Otomatis Config PHP)"
echo "2. Apache2"
echo "0. Batal"
read -p "Masukkan pilihan [0-2]: " webserver_choice

IS_NGINX=0

case $webserver_choice in
    1)
        # Deteksi Nginx
        if command -v nginx >/dev/null 2>&1; then
            log_activity "INFO: Nginx sudah terinstall. Skip install package."
        else
            log_activity "Menginstall Nginx..."
            apt install -y nginx
        fi
        systemctl enable nginx
        systemctl start nginx
        IS_NGINX=1
        ;;
    2)
        # Deteksi Apache
        if command -v apache2 >/dev/null 2>&1; then
            log_activity "INFO: Apache2 sudah terinstall. Skip install package."
        else
            log_activity "Menginstall Apache2..."
            apt install -y apache2
        fi
        systemctl enable apache2
        systemctl start apache2
        ;;
    0)
        log_activity "Instalasi dibatalkan user."
        exit 0
        ;;
    *)
        echo "Pilihan tidak valid."
        exit 1
        ;;
esac

# ---------------------------------------------
# 5. INSTALL DEPENDENCIES (Dengan Deteksi)
# ---------------------------------------------
echo ""
log_activity "Cek Dependencies (MySQL & PHP)..."

# Cek Database existing (MySQL atau MariaDB)
if command -v mysql >/dev/null 2>&1; then
    log_activity "INFO: Database Server (MySQL/MariaDB) sudah terinstall."
else
    log_activity "Menginstall MySQL Server..."
    apt install -y mysql-server unzip wget
fi

# Install PHP
log_activity "Memastikan PHP terinstall..."
apt install -y php php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-json libapache2-mod-php > /dev/null 2>&1

# ---------------------------------------------
# 6. KONFIGURASI NGINX OTOMATIS
# ---------------------------------------------
if [[ $IS_NGINX -eq 1 ]]; then
    echo ""
    log_activity "Konfigurasi Nginx..."
    
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    
    log_activity "PHP Versi: $PHP_VERSION | Socket: $FPM_SOCKET"

    # Overwrite default config (PENTING: Agar PHP jalan)
    # Kita overwrite saja agar pasti jalan, karena V3 aslinya juga overwrite.
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

    location ~ /\.ht {
        deny all;
    }
}
EOF
    systemctl restart nginx
    log_activity "Config Nginx diperbarui."
fi

# ---------------------------------------------
# 7. SETUP DATABASE (INPUT MANUAL + LOG)
# ---------------------------------------------
echo ""
echo "--- SETUP DATABASE WORDPRESS ---"
echo "Silakan masukkan detail database baru:"

read -p "Nama Database : " DB_NAME
read -p "Username DB   : " DB_USER
read -s -p "Password DB   : " DB_PASS
echo "" # Enter baris baru

if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
    log_activity "ERROR: Input database kosong. Setup DB dilewati."
else
    log_activity "Membuat Database: $DB_NAME | User: $DB_USER"
    
    # Eksekusi Query
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # --- LOG CREDENTIALS KE FILE (SESUAI REQUEST) ---
    echo "-------------------------------------------------" >> "$LOG_FILE"
    echo "DATABASE CREDENTIALS (SAVED)" >> "$LOG_FILE"
    echo "DB Name : $DB_NAME" >> "$LOG_FILE"
    echo "DB User : $DB_USER" >> "$LOG_FILE"
    echo "DB Pass : $DB_PASS" >> "$LOG_FILE"
    echo "-------------------------------------------------" >> "$LOG_FILE"
    
    log_activity "Database berhasil disetup."
fi

# ---------------------------------------------
# 8. DOWNLOAD & INSTALL APPS
# ---------------------------------------------
echo ""
echo "=== PILIH APLIKASI (Pisahkan koma, misal: 1,2) ==="
echo "1. phpMyAdmin"
echo "2. WordPress"
read -p "Masukkan pilihan: " app_choices

cd /var/www/html || exit

# -- Install phpMyAdmin --
if [[ "$app_choices" == *"1"* ]]; then
    if [ -d "phpmyadmin" ]; then 
        log_activity "Folder phpmyadmin sudah ada, skip download."
    else
        log_activity "Download phpMyAdmin..."
        wget -q https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.zip -O phpmyadmin.zip
        unzip -q phpmyadmin.zip
        mv phpMyAdmin-5.2.3-all-languages phpmyadmin
        rm phpmyadmin.zip
        log_activity "phpMyAdmin selesai."
    fi
fi

# -- Install WordPress --
if [[ "$app_choices" == *"2"* ]]; then
    if [ -d "wordpress" ]; then
        log_activity "Folder wordpress sudah ada, skip download."
    else
        log_activity "Download WordPress..."
        wget -q https://id.wordpress.org/latest-id_ID.zip -O wordpress.zip
        unzip -q wordpress.zip
        rm wordpress.zip
        
        # NOTE: Sesuai request V3, folder 'wordpress' TIDAK DIPINDAH ke root.
        # Struktur tetap: /var/www/html/wordpress
        log_activity "WordPress selesai (Lokasi: /var/www/html/wordpress)."
    fi
fi

# ---------------------------------------------
# 9. FINISHING
# ---------------------------------------------
echo ""
log_activity "Mengatur Permissions..."
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

echo ""
log_activity "INSTALASI SELESAI."
echo "Cek Log Lengkap di: $LOG_FILE"
if [[ -f /swapfile ]]; then
    echo "Status Swap: AKTIF (2GB)"
fi
