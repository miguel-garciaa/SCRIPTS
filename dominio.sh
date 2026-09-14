#!/bin/bash
set -e

# ==============================================================================
# LSETUP - Dominio Cloudflare para Ubuntu Server 26.04
#
# Uso:
#   sudo ./dominio.sh midominio.com
#
# El script solicitará:
#   1. Certificado Origin de Cloudflare
#   2. Clave privada del certificado
# ==============================================================================

DOMAIN_NAME="${1:-}"

PROYECTO_DIR="${PROYECTO_DIR:-}"
PROYECTOS_ROOT="/var/www"

LARAVEL_USER="laravel"

CLOUDFLARE_CERT=""
CLOUDFLARE_KEY=""

# ==============================================================================
# DETECTAR PROYECTO LARAVEL
# ==============================================================================

detectar_proyecto_laravel() {
    local octane_dir=""
    local artisan_file
    local -a proyectos=()

    # setup.sh deja la ruta exacta del proyecto en el servicio de Octane.
    # Esta es la fuente más fiable si existen varios proyectos en /var/www.
    if [ -f /etc/systemd/system/octane.service ]; then
        octane_dir="$(
            sed -n 's/^[[:space:]]*WorkingDirectory=//p' \
                /etc/systemd/system/octane.service \
                | tail -n 1
        )"

        if [[ "$octane_dir" == "$PROYECTOS_ROOT"/* ]] && \
           [ -f "$octane_dir/artisan" ]; then
            printf '%s\n' "$octane_dir"
            return 0
        fi
    fi

    while IFS= read -r -d '' artisan_file; do
        proyectos+=("${artisan_file%/artisan}")
    done < <(
        find "$PROYECTOS_ROOT" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name artisan \
            -print0 \
            2>/dev/null
    )

    if [ "${#proyectos[@]}" -eq 1 ]; then
        printf '%s\n' "${proyectos[0]}"
        return 0
    fi

    if [ "${#proyectos[@]}" -eq 0 ]; then
        echo "Error: no se encontró ningún proyecto Laravel en $PROYECTOS_ROOT." >&2
        return 1
    fi

    echo "Error: se encontraron varios proyectos Laravel en $PROYECTOS_ROOT" >&2
    echo "y el servicio Octane no permite saber cuál está activo:" >&2

    printf '  %s\n' "${proyectos[@]}" >&2

    return 1
}

# ==============================================================================
# COMPROBACIONES INICIALES
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Error: ejecuta este script como root o con sudo."
    exit 1
fi

if [ -z "$DOMAIN_NAME" ]; then
    echo
    echo "Error: debes indicar el dominio como primer argumento."
    echo
    echo "Uso:"
    echo "  sudo $0 midominio.com"
    echo
    exit 1
fi

if ! [[ "$DOMAIN_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "Error: el nombre de dominio no es válido: $DOMAIN_NAME"
    exit 1
fi

if [ -z "$PROYECTO_DIR" ]; then
    if ! PROYECTO_DIR="$(detectar_proyecto_laravel)"; then
        exit 1
    fi
fi

if [ ! -f "$PROYECTO_DIR/artisan" ]; then
    echo "Error: no se encontró un proyecto Laravel en $PROYECTO_DIR."
    exit 1
fi

if ! id "$LARAVEL_USER" >/dev/null 2>&1; then
    echo "Error: el usuario '$LARAVEL_USER' no existe."
    exit 1
fi

# ==============================================================================
# FUNCIÓN PARA LEER TEXTO MULTILÍNEA
# ==============================================================================

read_multiline() {
    local mensaje="$1"
    local terminador="$2"
    local variable="$3"
    local linea
    local contenido=""

    echo
    echo "=========================================================================="
    echo "$mensaje"
    echo "=========================================================================="
    echo
    echo "Pega el contenido completo."
    echo "Cuando termines, escribe:"
    echo
    echo "  $terminador"
    echo
    echo "en una línea nueva y pulsa ENTER."
    echo

    while IFS= read -r linea; do
        if [ "$linea" = "$terminador" ]; then
            break
        fi

        contenido+="$linea"$'\n'
    done

    contenido="${contenido%$'\n'}"

    printf -v "$variable" '%s' "$contenido"
}

# ==============================================================================
# SOLICITAR CERTIFICADO CLOUDFLARE
# ==============================================================================

read_multiline \
    "Pega el CERTIFICADO ORIGIN de Cloudflare:" \
    "FIN_CERT" \
    CLOUDFLARE_CERT

if [[ "$CLOUDFLARE_CERT" != *"-----BEGIN CERTIFICATE-----"* ]] || \
   [[ "$CLOUDFLARE_CERT" != *"-----END CERTIFICATE-----"* ]]; then

    echo
    echo "Error: el certificado Origin de Cloudflare no parece válido."
    echo
    echo "Debe contener:"
    echo "  -----BEGIN CERTIFICATE-----"
    echo "  ..."
    echo "  -----END CERTIFICATE-----"
    echo
    exit 1
fi

# ==============================================================================
# SOLICITAR CLAVE PRIVADA CLOUDFLARE
# ==============================================================================

read_multiline \
    "Pega la CLAVE PRIVADA del certificado Origin de Cloudflare:" \
    "FIN_KEY" \
    CLOUDFLARE_KEY

if [[ "$CLOUDFLARE_KEY" != *"-----BEGIN"*"PRIVATE KEY-----"* ]] || \
   [[ "$CLOUDFLARE_KEY" != *"-----END"*"PRIVATE KEY-----"* ]]; then

    echo
    echo "Error: la clave privada de Cloudflare no parece válida."
    echo
    echo "Debe contener algo similar a:"
    echo "  -----BEGIN PRIVATE KEY-----"
    echo "  ..."
    echo "  -----END PRIVATE KEY-----"
    echo
    exit 1
fi

# ==============================================================================
# VARIABLES INTERNAS
# ==============================================================================

LARAVEL_HOME="$(getent passwd "$LARAVEL_USER" | cut -d: -f6)"

CERT_FILE="/etc/ssl/certs/${DOMAIN_NAME}.pem"
KEY_FILE="/etc/ssl/private/${DOMAIN_NAME}.key"

NGINX_SITE="/etc/nginx/sites-available/${DOMAIN_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN_NAME}"
LEGACY_NGINX_SITE="/etc/nginx/conf.d/${DOMAIN_NAME}.conf"

# ==============================================================================
# FUNCIONES
# ==============================================================================

as_laravel() {
    runuser -u "$LARAVEL_USER" -- env \
        HOME="$LARAVEL_HOME" \
        COMPOSER_HOME="$LARAVEL_HOME/.composer" \
        bash -lc "$1"
}

set_env_var() {
    local key="$1"
    local value="$2"
    local env_file="$3"
    local temp_file="${env_file}.lsetup"

    grep -v "^${key}=" "$env_file" > "$temp_file" || true
    printf '%s=%s\n' "$key" "$value" >> "$temp_file"

    mv "$temp_file" "$env_file"

    chown "$LARAVEL_USER:$LARAVEL_USER" "$env_file"
    chmod 640 "$env_file"
}

# ==============================================================================
# INICIO
# ==============================================================================

echo
echo "=========================================================================="
echo " Configurando dominio Cloudflare"
echo "=========================================================================="
echo
echo " Dominio:   $DOMAIN_NAME"
echo " Laravel:   $PROYECTO_DIR"
echo " Usuario:   $LARAVEL_USER"
echo
echo "=========================================================================="
echo

# ==============================================================================
# 1/5 - CERTIFICADO
# ==============================================================================

echo "[1/5] Guardando certificado Origin de Cloudflare..."

install -d -m 755 /etc/ssl/certs
install -d -m 700 /etc/ssl/private

printf '%s\n' "$CLOUDFLARE_CERT" > "$CERT_FILE"
printf '%s\n' "$CLOUDFLARE_KEY" > "$KEY_FILE"

chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

echo "Certificado guardado en:"
echo "  $CERT_FILE"

echo "Clave privada guardada en:"
echo "  $KEY_FILE"

# Limpiar las variables de memoria en cuanto ya no se necesitan
unset CLOUDFLARE_CERT
unset CLOUDFLARE_KEY

# ==============================================================================
# 2/5 - NGINX
# ==============================================================================

echo
echo "[2/5] Sustituyendo la configuración Nginx heredada..."

# El setup anterior definía proxy_cache my_cache sin declarar esa zona.
# No se usa cache de proxy para Laravel porque podría cachear cookies,
# sesiones o paneles autenticados.

if [ -f /etc/nginx/nginx.conf ]; then

    sed -i -E \
        '/^[[:space:]]*proxy_cache[[:space:]]+my_cache;[[:space:]]*$/d' \
        /etc/nginx/nginx.conf

    if ! grep -qE \
        '^[[:space:]]*include /etc/nginx/sites-enabled/\*;' \
        /etc/nginx/nginx.conf; then

        if grep -qE \
            '^[[:space:]]*include /etc/nginx/conf\.d/\*\.conf;' \
            /etc/nginx/nginx.conf; then

            sed -i \
                '/include \/etc\/nginx\/conf\.d\/\*\.conf;/a\    include /etc/nginx/sites-enabled/*;' \
                /etc/nginx/nginx.conf

        else
            echo "Error: nginx.conf no incluye conf.d ni sites-enabled."
            exit 1
        fi
    fi
fi

rm -f "$LEGACY_NGINX_SITE"
rm -f /etc/nginx/conf.d/laravel.conf
rm -f /etc/nginx/sites-enabled/laravel
rm -f /etc/nginx/sites-enabled/default

cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

ln -sfn "$NGINX_SITE" "$NGINX_ENABLED"

echo
echo "Comprobando configuración de Nginx..."

nginx -t

echo "Recargando Nginx..."

systemctl reload nginx

# ==============================================================================
# 3/5 - LARAVEL
# ==============================================================================

echo
echo "[3/5] Actualizando APP_URL, Web Push y proxies de Laravel..."

if [ ! -f "$PROYECTO_DIR/.env" ]; then
    echo "Error: no existe:"
    echo "  $PROYECTO_DIR/.env"
    exit 1
fi

set_env_var \
    "APP_URL" \
    "https://${DOMAIN_NAME}" \
    "$PROYECTO_DIR/.env"

set_env_var \
    "VAPID_SUBJECT" \
    "https://${DOMAIN_NAME}" \
    "$PROYECTO_DIR/.env"

# ==============================================================================
# TRUST PROXIES
# ==============================================================================

TRUST_PATCH="$PROYECTO_DIR/.lsetup-trust-proxies.php"

cat > "$TRUST_PATCH" <<'PHP'
<?php

declare(strict_types=1);

$bootstrap = __DIR__ . '/bootstrap/app.php';

$contents = file_get_contents($bootstrap);

if ($contents === false) {
    throw new RuntimeException(
        'No se pudo leer bootstrap/app.php.'
    );
}

if (str_contains($contents, 'trustProxies')) {
    exit(0);
}

$pattern = '/->withMiddleware\(function \(Middleware \$middleware\)(?:: void)? \{/';

if (
    preg_match(
        $pattern,
        $contents,
        $match,
        PREG_OFFSET_CAPTURE
    ) === 1
) {
    $position = $match[0][1] + strlen($match[0][0]);

    $contents =
        substr($contents, 0, $position)
        . "\n        \$middleware->trustProxies(at: '*');"
        . substr($contents, $position);

} else {

    $needle = '    ->withExceptions(';

    $position = strpos($contents, $needle);

    if ($position === false) {
        throw new RuntimeException(
            'No se encontró un punto válido para configurar TrustProxies.'
        );
    }

    $middleware =
        "    ->withMiddleware(function (Middleware \$middleware): void {\n"
        . "        \$middleware->trustProxies(at: '*');\n"
        . "    })\n";

    $contents =
        substr($contents, 0, $position)
        . $middleware
        . substr($contents, $position);
}

if (file_put_contents($bootstrap, $contents) === false) {
    throw new RuntimeException(
        'No se pudo actualizar bootstrap/app.php.'
    );
}
PHP

chown "$LARAVEL_USER:$LARAVEL_USER" "$TRUST_PATCH"

as_laravel \
    "cd '$PROYECTO_DIR' && php .lsetup-trust-proxies.php"

rm -f "$TRUST_PATCH"

chown \
    "$LARAVEL_USER:$LARAVEL_USER" \
    "$PROYECTO_DIR/bootstrap/app.php"

# ==============================================================================
# 4/5 - CACHE LARAVEL
# ==============================================================================

echo
echo "[4/5] Reconstruyendo caches de Laravel..."

as_laravel \
    "cd '$PROYECTO_DIR' && php artisan optimize:clear"

as_laravel \
    "cd '$PROYECTO_DIR' && php artisan config:cache && php artisan route:cache && php artisan view:cache"

# ==============================================================================
# 5/5 - SERVICIOS
# ==============================================================================

echo
echo "[5/5] Reiniciando Octane y verificando servicios..."

systemctl restart octane

if ! systemctl is-active --quiet nginx; then
    echo "Error: Nginx no está activo."
    exit 1
fi

if ! systemctl is-active --quiet octane; then
    echo "Error: Octane no está activo."
    exit 1
fi

if ! ss -ltn | grep -q '127.0.0.1:8000'; then
    echo "Error: no hay ningún servicio escuchando en 127.0.0.1:8000."
    exit 1
fi

# ==============================================================================
# FINAL
# ==============================================================================

echo
echo "=========================================================================="
echo " CONFIGURACIÓN COMPLETADA"
echo "=========================================================================="
echo
echo " Dominio:"
echo "   https://$DOMAIN_NAME"
echo
echo " Vhost Nginx:"
echo "   $NGINX_SITE"
echo
echo " Certificado:"
echo "   $CERT_FILE"
echo
echo " Clave privada:"
echo "   $KEY_FILE"
echo
echo " Proyecto Laravel:"
echo "   $PROYECTO_DIR"
echo
echo "=========================================================================="
