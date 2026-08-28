#!/bin/bash

USUARIO="laravel"
PASSWORD="laravel"

if [ -z "$1" ]; then
    echo "Uso: $0 <nombre_proyecto>"
    exit 1
fi

PROYECTO_DIR="/var/www/$1"

if id "$USUARIO" &>/dev/null; then
    echo "El usuario '$USUARIO' ya existe. No se realizarán cambios."
else
    echo "Creando el usuario '$USUARIO'..."

    sudo useradd -m -s /bin/bash "$USUARIO"
    echo "$USUARIO:$PASSWORD" | sudo chpasswd    
    sudo usermod -aG sudo "$USUARIO"
    
    echo "Usuario '$USUARIO' creado correctamente."
fi

# 1. ACTUALIZAR SISTEMA Y PAQUETES BASE
# =====================================

sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
sudo DEBIAN_FRONTEND=noninteractive apt install -y curl tar git htop nano nodejs npm

# 2. FIREWALL UFW
# ===============

PORT_SSH=4040

sudo DEBIAN_FRONTEND=noninteractive apt install -y ufw

sudo sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw
sudo ufw --force reset

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

sudo ufw allow from 192.168.1.2 to any port $PORT_SSH proto tcp
sudo ufw allow from 207.66.60.6 to any port $PORT_SSH proto tcp

sudo systemctl enable --now ufw
sudo ufw --force enable

# 3. OPENSSH-SERVER
# =================

sudo tee /etc/ssh/sshd_config.d/99-hardened-ssh.conf > /dev/null << EOF
Port $PORT_SSH

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

PermitRootLogin no
X11Forwarding no
MaxAuthTries 3
EOF

sudo sed -i 's/^Port 22/#Port 22/' /etc/ssh/sshd_config

if sudo sshd -t; then
    echo "Sintaxis de SSH válida. Reiniciando servicio..."
    sudo systemctl restart ssh || sudo systemctl restart sshd
else
    echo "ERROR: La configuración de SSH contiene errores. No se ha cambiado el puerto."
    exit 1
fi


# 4. FAIL2BAN
# ===========

sudo DEBIAN_FRONTEND=noninteractive apt install -y fail2ban

MI_IP_PUBLICA=$(curl -s https://ifconfig.me)

sudo tee /etc/fail2ban/jail.local > /dev/null << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 ${MI_IP_PUBLICA}

bantime  = 1h
findtime = 10m
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ssh
backend  = systemd
maxretry = 3
findtime = 10m
bantime  = 2h
EOF

sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban --no-pager


# 5. POSTGRESQL 18
# ================

sudo DEBIAN_FRONTEND=noninteractive apt install -y postgresql-18 postgresql-client-18 
sudo systemctl enable --now postgresql

sudo -u postgres psql -c "CREATE USER laravel WITH PASSWORD 'laravel';"
sudo -u postgres psql -c "CREATE DATABASE laravel OWNER laravel;"
sudo -u postgres psql -c "ALTER USER laravel WITH PASSWORD 'laravel';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE laravel TO laravel;"


sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/g" /etc/postgresql/18/main/postgresql.conf
sudo sed -i "s/listen_addresses = 'localhost'/listen_addresses = 'localhost'/g" /etc/postgresql/18/main/postgresql.conf
sudo sed -i '$ a\host    all             all             127.0.0.1\/32          scram-sha-256' /etc/postgresql/18/main/pg_hba.conf

sudo systemctl restart postgresql


# 6. PHP 8.5 Y EXTENSIONES
# ========================

sudo DEBIAN_FRONTEND=noninteractive apt install -y php8.5 php8.5-cli php8.5-fpm php8.5-pgsql php8.5-zip php8.5-xml php8.5-curl php8.5-intl php8.5-bcmath php8.5-mbstring php8.5-gd php8.5-redis


# 7. COMPOSER
# ===========

php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php -r "if (hash_file('sha384', 'composer-setup.php') === 'c8b085408188070d5f52bcfe4ecfbee5f727afa458b2573b8eaaf77b3419b0bf2768dc67c86944da1544f06fa544fd47') { echo 'Installer verified'.PHP_EOL; } else { echo 'Installer corrupt'.PHP_EOL; unlink('composer-setup.php'); exit(1); }"
php composer-setup.php
php -r "unlink('composer-setup.php');"

sudo mv composer.phar /usr/local/bin/composer

COMPOSER_ALLOW_SUPERUSER=1 composer --version


# 8. REDIS
# ========

sudo DEBIAN_FRONTEND=noninteractive apt install -y redis-server

sudo cp /etc/redis/redis.conf /etc/redis/redis.conf.bak
sudo cp /etc/redis/redis.conf /etc/redis/redis.conf.bak

sudo tee -a /etc/redis/redis.conf > /dev/null << 'EOF'
bind 127.0.0.1 -::1
port 6379
supervised systemd
maxmemory 2gb
maxmemory-policy allkeys-lru
EOF

sudo systemctl enable --now redis-server
sudo systemctl restart redis-server


# 9. CREAR PROYECTO LARAVEL
# =========================

mkdir -p /var/www
sudo chown -R laravel:laravel /var/www
sudo chmod -R 775 /var/www

COMPOSER_ALLOW_SUPERUSER=1 composer create-project laravel/laravel "$PROYECTO_DIR" --no-interaction

sudo chown -R laravel:laravel "$PROYECTO_DIR"
sudo chmod -R ug+rwX "$PROYECTO_DIR/storage" "$PROYECTO_DIR/bootstrap/cache"


# 10. CONFIGURAR .env
# ===================

sudo tee "$PROYECTO_DIR/.env" > /dev/null << 'EOF'
APP_NAME=Laravel
APP_ENV=production
APP_KEY=
APP_DEBUG=true
APP_URL=http://192.168.1.10

APP_LOCALE=es
APP_FALLBACK_LOCALE=es
APP_FAKER_LOCALE=es_ES

APP_MAINTENANCE_DRIVER=file
# APP_MAINTENANCE_STORE=database

# PHP_CLI_SERVER_WORKERS=4

BCRYPT_ROUNDS=12

LOG_CHANNEL=stack
LOG_STACK=single
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD=laravel

SESSION_DRIVER=redis
SESSION_LIFETIME=120
SESSION_ENCRYPT=false
SESSION_PATH=/
SESSION_DOMAIN=null

BROADCAST_CONNECTION=log
FILESYSTEM_DISK=local
QUEUE_CONNECTION=redis

CACHE_STORE=redis
# CACHE_PREFIX=

MEMCACHED_HOST=127.0.0.1

REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=log
MAIL_SCHEME=null
MAIL_HOST=127.0.0.1
MAIL_PORT=2525
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_FROM_ADDRESS="hello@example.com"
MAIL_FROM_NAME="${APP_NAME}"

AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=
AWS_USE_PATH_STYLE_ENDPOINT=false

VITE_APP_NAME="${APP_NAME}"
OCTANE_SERVER=frankenphp
EOF

php "$PROYECTO_DIR/artisan" key:generate --force --no-interaction


# 11. LARAVEL OCTANE CON FRANKENPHP
# =================================

cd "$PROYECTO_DIR"

COMPOSER_ALLOW_SUPERUSER=1 composer require laravel/octane --no-interaction

php artisan octane:install --server=frankenphp --no-interaction

sudo tee /etc/systemd/system/octane.service > /dev/null << EOF
[Unit]
Description=Laravel Octane Server (FrankenPHP)
After=network.target postgresql.service redis-server.service

[Service]
Type=simple
User=laravel
Group=laravel
WorkingDirectory=$PROYECTO_DIR
ExecStart=/usr/bin/php artisan octane:start --server=frankenphp --host=127.0.0.1 --port=8000 --workers=6 --max-requests=1500
Restart=always
RestartSec=5
Environment=APP_ENV=production

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl restart octane
sudo systemctl enable --now octane

sudo tee /etc/systemd/system/laravel-queue.service > /dev/null << EOF
[Unit]
Description=Laravel Queue Worker
After=network.target postgresql.service redis-server.service

[Service]
Type=simple
User=laravel
Group=laravel
WorkingDirectory=$PROYECTO_DIR
ExecStart=/usr/bin/php artisan queue:work redis --queue=emails,default --sleep=1 --tries=3 --timeout=90
ExecReload=/usr/bin/php artisan queue:restart
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=100
Environment=APP_ENV=production

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/laravel-scheduler.service > /dev/null << EOF
[Unit]
Description=Laravel Scheduler
After=network.target postgresql.service redis-server.service

[Service]
Type=oneshot
User=laravel
Group=laravel
WorkingDirectory=$PROYECTO_DIR
ExecStart=/usr/bin/php artisan schedule:run
Environment=APP_ENV=production
EOF

sudo tee /etc/systemd/system/laravel-scheduler.timer > /dev/null << 'EOF'
[Unit]
Description=Run Laravel Scheduler every minute

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now laravel-queue
sudo systemctl enable --now laravel-scheduler.timer


# 12. NGINX COMO PROXY A OCTANE
# =============================

sudo DEBIAN_FRONTEND=noninteractive apt install -y nginx

sudo tee /etc/nginx/sites-available/laravel > /dev/null << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/laravel /etc/nginx/sites-enabled/laravel
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl restart nginx


# 14. ARRANQUE FINAL
# ==================

sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer bash -lc "cd '$PROYECTO_DIR' && php artisan optimize:clear"
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer bash -lc "cd '$PROYECTO_DIR' && php artisan config:cache"
sudo -u laravel env HOME=/home/laravel COMPOSER_HOME=/home/laravel/.composer bash -lc "cd '$PROYECTO_DIR' && php artisan route:cache"


# 15. COMPROBACIONES RAPIDAS
# ==========================

sudo systemctl is-active postgresql
sudo systemctl is-active redis-server
sudo systemctl is-active octane
sudo systemctl is-active laravel-queue
sudo systemctl is-active laravel-scheduler.timer
sudo systemctl is-active nginx
