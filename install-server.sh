#!/bin/bash

# ==========================================
# AUTO INSTALL SCRIPT V3
# Fitur: Nginx Auto-Config, PHP Check, Auto Swap
# ==========================================

# 1. CEK ROOT USER
if [[ $EUID -ne 0 ]]; then
   echo "Error: Script ini harus dijalankan sebagai root (sudo)." 
   exit 1
fi

# ---------------------------------------------
# 2. CEK RAM & SWAP (Fitur Baru)
# ---------------------------------------------
echo "--- Memeriksa Spesifikasi Server ---"

# Ambil total RAM dalam MB
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
# Ambil total Swap dalam MB
TOTAL_SWAP=$(free -m | awk '/^Swap:/{print $2}')

echo "RAM Terdeteksi: ${TOTAL_RAM}MB"
echo "SWAP Terdeteksi: ${TOTAL_SWAP}MB"

# Jika RAM kurang dari 1000MB (toleransi 1GB)
if [[ $TOTAL_RAM -lt 1000 ]]; then
    echo ""
    echo "⚠️  PERINGATAN: RAM server anda kurang dari 1GB!"
    echo "MySQL dan Web Server mungkin tidak stabil tanpa Memory Swap."
    
    # Jika tidak ada swap sama sekali
    if [[ $TOTAL_SWAP -eq 0 ]]; then
        echo "❌ Tidak ada SWAP terdeteksi."
        echo "Sangat disarankan membuat SWAP sebesar 2GB."
        echo ""
        read -p "Apakah anda ingin membuat file SWAP 2GB sekarang? (y/n): " create_swap_choice
        
        if [[ "$create_swap_choice" == "y" || "$create_swap_choice" == "Y" ]]; then
            echo "--- Membuat Swap 2GB ---"
            
            # 1. Alokasi file 2G
            fallocate -l 2G /swapfile
            
            # 2. Set permission aman
            chmod 600 /swapfile
            
            # 3. Format jadi swap
            mkswap /swapfile
            
            # 4. Aktifkan swap
            swapon /swapfile
            
            # 5. Buat permanen di fstab
            # Cek dulu biar gak double entry
            if ! grep -q "/swapfile" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            
            echo "✅ Swap 2GB berhasil dibuat dan diaktifkan."
            free -h
        else
            echo "⚠️  Anda memilih lanjut tanpa Swap. Risiko server crash tinggi."
        fi
    else
        echo "✅ Swap sudah ada (${TOTAL_SWAP}MB). Lanjut..."
    fi
else
    echo "✅ RAM cukup (>1GB)."
fi

echo ""
echo "--- Update Repository ---"
apt update -y

# ---------------------------------------------
# 3. PILIH WEB SERVER
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
        echo "Menginstall Nginx..."
        apt install -y nginx
        systemctl enable nginx
        systemctl start nginx
        IS_NGINX=1
        ;;
    2)
        echo "Menginstall Apache2..."
        apt install -y apache2
        systemctl enable apache2
        systemctl start apache2
        ;;
    0)
        echo "Instalasi dibatalkan."
        exit 0
        ;;
    *)
        echo "Pilihan tidak valid."
        exit 1
        ;;
esac

# ---------------------------------------------
# 4. INSTALL DEPENDENCIES
# ---------------------------------------------
echo ""
echo "--- Menginstall MySQL, PHP, dan Ekstensi ---"
apt install -y mysql-server unzip wget
# Install paket PHP lengkap
apt install -y php php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip php-json libapache2-mod-php

# ---------------------------------------------
# 5. KONFIGURASI NGINX OTOMATIS
# ---------------------------------------------
if [[ $IS_NGINX -eq 1 ]]; then
    echo ""
    echo "--- Konfigurasi Otomatis Nginx untuk PHP ---"
    
    # Deteksi Versi PHP (misal 8.1, 8.3)
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    
    echo "Versi PHP: $PHP_VERSION | Socket: $FPM_SOCKET"

    # Buat config default Nginx
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
    echo "Nginx direstart dengan config baru."
fi

# ---------------------------------------------
# 6. SETUP DATABASE
# ---------------------------------------------
echo ""
echo "--- Setup Database WordPress ---"
mysql -e "CREATE DATABASE IF NOT EXISTS wordpress1 CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -e "CREATE USER IF NOT EXISTS 'user'@'localhost' IDENTIFIED BY 'User345@';"
mysql -e "GRANT ALL PRIVILEGES ON wordpress1.* TO 'user'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"
echo "Database 'wordpress1' siap."

# ---------------------------------------------
# 7. DOWNLOAD & INSTALL APPS
# ---------------------------------------------
echo ""
echo "=== PILIH APLIKASI (Pisahkan koma, misal: 1,2) ==="
echo "1. phpMyAdmin"
echo "2. WordPress"
echo "0. Batal"
read -p "Masukkan pilihan: " app_choices

cd /var/www/html || exit

# -- Install phpMyAdmin --
if [[ "$app_choices" == *"1"* ]]; then
    echo "--- Setup phpMyAdmin ---"
    # Cek folder dulu biar gak numpuk
    if [ -d "phpmyadmin" ]; then 
        echo "Folder phpmyadmin sudah ada, skip download."
    else
        wget https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.zip -O phpmyadmin.zip
        unzip -q phpmyadmin.zip
        mv phpMyAdmin-5.2.3-all-languages phpmyadmin
        rm phpmyadmin.zip
        echo "phpMyAdmin terinstall."
    fi
fi

# -- Install WordPress --
if [[ "$app_choices" == *"2"* ]]; then
    echo "--- Setup WordPress ---"
    if [ -d "wordpress" ]; then
        echo "Folder wordpress sudah ada, skip download."
    else
        wget https://id.wordpress.org/latest-id_ID.zip -O wordpress.zip
        unzip -q wordpress.zip
        rm wordpress.zip
        echo "WordPress terinstall."
    fi
fi

# ---------------------------------------------
# 8. FINISHING
# ---------------------------------------------
echo ""
echo "--- Mengatur Permissions ---"
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

echo ""
echo "=== INSTALASI SELESAI ==="
echo "RAM Server: ${TOTAL_RAM}MB"
if [[ -f /swapfile ]]; then
    echo "Status Swap: AKTIF (2GB)"
fi
