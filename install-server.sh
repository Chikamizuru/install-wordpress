#!/bin/bash

# ==========================================
# AUTO INSTALL SCRIPT V6 (Final Fix)
# ==========================================

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
log_activity "MULAI SCRIPT INSTALASI V6"

# 1. CEK ROOT
if [[ $EUID -ne 0 ]]; then
   echo "Error: Jalankan sebagai root (sudo)." 
   exit 1
fi

# 2. CEK RAM & SWAP
log_activity "Cek Hardware..."
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_SWAP=$(free -m | awk '/^Swap:/{print $2}')

if [[ $TOTAL_RAM -lt 1000 && $TOTAL_SWAP -eq 0 ]]; then
    read -p "RAM < 1GB. Buat SWAP 2GB? (y/n): " create_swap
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
# 3. HANDLER KONFLIK WEB SERVER
# ---------------------------------------------
echo ""
echo "=== PILIH WEB SERVER ==="
echo "1. Nginx"
echo "2. Apache2"
read -p "Pilihan: " webserver_choice

IS_NGINX=0

case $webserver_choice in
    1)
        # Stop Apache jika jalan
        if systemctl is-active --quiet apache2; then
            systemctl stop apache2
            systemctl disable apache2
        fi
        
        # Install Nginx
        if ! command -v nginx >/dev/null 2>&1; then
            apt install -y nginx
        fi
        systemctl enable nginx
        systemctl start nginx
        IS_NGINX=1
        ;;
    2)
        # Stop Nginx jika jalan
        if systemctl is-active --quiet nginx; then
            systemctl stop nginx
            systemctl disable nginx
        fi
        
        # Install Apache
        if ! command -v apache2 >/dev/null 2>&1; then
            apt install -y apache2
        fi
        systemctl enable apache2
        systemctl start apache2
        ;;
    *)
        echo "Batal."
        exit 0
        ;;
esac

# ---------------------------------------------
# 4. DATABASE & PHP
# ---------------------------------------------
echo ""
log_activity "Cek Database & PHP..."

# Cek DB Konflik
if ! dpkg -l | grep -q mariadb-server && ! command -v mysql >/dev/null 2>&1; then
    apt install -y mysql-server unzip wget
fi

# Install PHP
apt install -y php php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-json libapache2-mod-php > /dev/null 2>&1

# --- PERBAIKAN LOGIC NGINX DI SINI ---
if [[ $IS_NGINX -eq 1 ]]; then
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    
    log_activity "Mengkonfigurasi Nginx untuk PHP $PHP_VERSION..."
    
    # 1. Backup file default bawaan jika belum ada backup
    if [ ! -f /etc/nginx/sites-available/default.bak ]; then
        mv /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak
        log_activity "File default Nginx asli dibackup ke default.bak"
    fi

    # 2. Tulis Ulang Config (Force Overwrite)
    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    # Root folder
    root /var/www/html;
    
    # Index file (PENTING: index.php harus ada)
    index index.php index.html index.htm;
    
    server_name _;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Config PHP agar dibaca
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$FPM_SOCKET;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    # 3. Restart Nginx
    systemctl restart nginx
    log_activity "Config Nginx diperbarui (PHP Socket: $FPM_SOCKET)"
fi

# ---------------------------------------------
# 5. INPUT DATABASE
# ---------------------------------------------
echo ""
echo "--- KONFIGURASI DATABASE ---"
read -p "Nama Database : " DB_NAME
read -p "Username DB   : " DB_USER
read -s -p "Password DB   : " DB_PASS
echo ""

if [[ -n "$DB_NAME" && -n "$DB_USER" ]]; then
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    log_activity "Database $DB_NAME berhasil dibuat."
fi

# ---------------------------------------------
# 6. DOWNLOAD APPS & FIX FOLDER
# ---------------------------------------------
echo ""
echo "=== PILIH APLIKASI (Pisahkan koma, 1,2) ==="
echo "1. phpMyAdmin"
echo "2. WordPress"
read -p "Pilihan: " app_choices

cd /var/www/html || exit

# Clean Install (Hapus index.html bawaan nginx/apache biar gak ganggu)
rm -f index.html index.nginx-debian.html

if [[ "$app_choices" == *"1"* ]]; then
    if [ ! -d "phpmyadmin" ]; then
        wget -q https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.zip -O phpmyadmin.zip
        unzip -q phpmyadmin.zip
        mv phpMyAdmin-5.2.3-all-languages phpmyadmin
        rm phpmyadmin.zip
        log_activity "phpMyAdmin terinstall."
    fi
fi

if [[ "$app_choices" == *"2"* ]]; then
    log_activity "Menginstall WordPress..."
    # Download
    wget -q https://id.wordpress.org/latest-id_ID.zip -O wordpress.zip
    unzip -q wordpress.zip
    rm wordpress.zip
    
    # --- FIX FOLDER NESTING (Script memindahkan isi folder wordpress ke luar) ---
    if [ -d "wordpress" ]; then
        log_activity "Memindahkan file WordPress ke root directory..."
        cp -r wordpress/* .
        rm -rf wordpress
    fi
    log_activity "WordPress siap di /var/www/html."
fi

# Permissions
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

echo ""
log_activity "SELESAI. Silakan akses via Browser."

