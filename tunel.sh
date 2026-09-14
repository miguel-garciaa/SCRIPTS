#!/bin/bash
set -Eeuo pipefail

# ==============================================================================
# LSETUP - Cloudflare Tunnel para Laravel Octane
#
# Uso:
#   sudo bash ./tunel.sh midominio.com
#
# Antes de ejecutar el script:
#   1. Crea un túnel administrado desde el panel de Cloudflare.
#   2. Añade las rutas de aplicación publicadas:
#        midominio.com     -> http://localhost:8000
#        www.midominio.com -> http://localhost:8000
#   3. Copia el token del túnel. El script lo solicitará de forma oculta.
#
# No abre puertos HTTP/HTTPS de entrada. Cloudflared inicia una conexión
# saliente hacia Cloudflare y accede a Octane por 127.0.0.1:8000.
# ==============================================================================

DOMAIN_NAME="${1:-}"

PROYECTO_DIR="${PROYECTO_DIR:-}"
PROYECTOS_ROOT="/var/www"
LARAVEL_USER="laravel"

TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
unset CLOUDFLARE_TUNNEL_TOKEN

trap 'TUNNEL_TOKEN=""; unset TUNNEL_TOKEN' EXIT

# ==============================================================================
# FUNCIONES
# ==============================================================================

detectar_proyecto_laravel() {
    local octane_dir=""
    local artisan_file
    local -a proyectos=()

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

esperar_servicio() {
    local servicio="$1"
    local intento

    for intento in {1..15}; do
        if systemctl is-active --quiet "$servicio"; then
            return 0
        fi

        sleep 1
    done

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
    echo "  sudo bash $0 midominio.com"
    echo
    exit 1
fi

if ! [[ "$DOMAIN_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "Error: el nombre de dominio no es válido: $DOMAIN_NAME"
    exit 1
fi

for comando in apt-get curl find getent id php runuser sed ss systemctl ufw; do
    if ! command -v "$comando" >/dev/null 2>&1; then
        echo "Error: falta el comando requerido: $comando"
        exit 1
    fi
done

if [ -z "$PROYECTO_DIR" ]; then
    if ! PROYECTO_DIR="$(detectar_proyecto_laravel)"; then
        exit 1
    fi
fi

if [ ! -f "$PROYECTO_DIR/artisan" ]; then
    echo "Error: no se encontró un proyecto Laravel en $PROYECTO_DIR."
    exit 1
fi

if [ ! -f "$PROYECTO_DIR/.env" ]; then
    echo "Error: no existe $PROYECTO_DIR/.env"
    exit 1
fi

if ! id "$LARAVEL_USER" >/dev/null 2>&1; then
    echo "Error: el usuario '$LARAVEL_USER' no existe."
    exit 1
fi

if ! systemctl is-active --quiet octane; then
    echo "Error: Octane no está activo."
    exit 1
fi

if ! ss -ltn | grep -qE '127\.0\.0\.1:8000([[:space:]]|$)'; then
    echo "Error: Octane no está escuchando en 127.0.0.1:8000."
    exit 1
fi

if [ -z "$TUNNEL_TOKEN" ]; then
    echo
    echo "=========================================================================="
    echo " Token del túnel de Cloudflare"
    echo "=========================================================================="
    echo
    echo "En Cloudflare abre Networking > Tunnels, selecciona el túnel y"
    echo "usa 'Add a replica' para obtener el token que empieza por eyJ."
    echo
    echo "Las rutas publicadas del túnel deben ser:"
    echo "  $DOMAIN_NAME -> http://localhost:8000"
    echo "  www.$DOMAIN_NAME -> http://localhost:8000"
    echo
    read -r -s -p "Pega el token: " TUNNEL_TOKEN
    echo
fi

if [ -z "$TUNNEL_TOKEN" ] || [[ "$TUNNEL_TOKEN" =~ [[:space:]] ]]; then
    echo "Error: el token del túnel está vacío o contiene espacios."
    exit 1
fi

LARAVEL_HOME="$(getent passwd "$LARAVEL_USER" | cut -d: -f6)"

echo
echo "=========================================================================="
echo " Configurando Cloudflare Tunnel"
echo "=========================================================================="
echo
echo " Dominio:   $DOMAIN_NAME"
echo " Laravel:   $PROYECTO_DIR"
echo " Origen:    http://127.0.0.1:8000"
echo
echo "=========================================================================="
echo

# ==============================================================================
# 1/6 - INSTALAR CLOUDFLARED
# ==============================================================================

echo "[1/6] Instalando cloudflared desde el repositorio oficial..."

install -d -m 755 /usr/share/keyrings

curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg

chmod 644 /usr/share/keyrings/cloudflare-main.gpg

printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared

# ==============================================================================
# 2/6 - INSTALAR SERVICIO DEL TÚNEL
# ==============================================================================

echo
echo "[2/6] Instalando el túnel como servicio del sistema..."

if systemctl list-unit-files cloudflared.service --no-legend \
    2>/dev/null | grep -q '^cloudflared\.service'; then
    echo "Ya existe un servicio cloudflared; se sustituirá con el token indicado."
    cloudflared service uninstall
    systemctl daemon-reload
fi

cloudflared service install "$TUNNEL_TOKEN"
TUNNEL_TOKEN=""
unset TUNNEL_TOKEN

systemctl enable --now cloudflared

if ! esperar_servicio cloudflared; then
    echo "Error: cloudflared no ha arrancado correctamente."
    echo "Revisa el registro con:"
    echo "  journalctl -u cloudflared --no-pager -n 100"
    exit 1
fi

# ==============================================================================
# 3/6 - CONFIGURAR LARAVEL
# ==============================================================================

echo
echo "[3/6] Actualizando APP_URL, Web Push y proxies de Laravel..."

set_env_var \
    "APP_URL" \
    "https://${DOMAIN_NAME}" \
    "$PROYECTO_DIR/.env"

set_env_var \
    "VAPID_SUBJECT" \
    "https://${DOMAIN_NAME}" \
    "$PROYECTO_DIR/.env"

TRUST_PATCH="$PROYECTO_DIR/.lsetup-trust-proxies.php"

cat > "$TRUST_PATCH" <<'PHP'
<?php

declare(strict_types=1);

$bootstrap = __DIR__ . '/bootstrap/app.php';
$contents = file_get_contents($bootstrap);

if ($contents === false) {
    throw new RuntimeException('No se pudo leer bootstrap/app.php.');
}

if (str_contains($contents, 'trustProxies')) {
    exit(0);
}

$pattern = '/->withMiddleware\(function \(Middleware \$middleware\)(?:: void)? \{/';

if (preg_match($pattern, $contents, $match, PREG_OFFSET_CAPTURE) === 1) {
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
    throw new RuntimeException('No se pudo actualizar bootstrap/app.php.');
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
# 4/6 - CACHE LARAVEL
# ==============================================================================

echo
echo "[4/6] Reconstruyendo caches de Laravel..."

as_laravel \
    "cd '$PROYECTO_DIR' && php artisan optimize:clear"

as_laravel \
    "cd '$PROYECTO_DIR' && php artisan config:cache && php artisan route:cache && php artisan view:cache"

systemctl restart octane

if ! esperar_servicio octane; then
    echo "Error: Octane no ha arrancado después de actualizar Laravel."
    exit 1
fi

# ==============================================================================
# 5/6 - CERRAR ACCESO HTTP/HTTPS DE ENTRADA
# ==============================================================================

echo
echo "[5/6] Cerrando los puertos públicos 80 y 443..."

# El puerto 7844 se permite exclusivamente en salida para Cloudflare Tunnel.
ufw allow out 7844/tcp comment 'Cloudflare Tunnel' >/dev/null
ufw allow out 7844/udp comment 'Cloudflare Tunnel' >/dev/null

# Eliminar las reglas creadas por setup.sh. --force evita preguntas interactivas.
ufw --force delete allow 80/tcp >/dev/null 2>&1 || true
ufw --force delete allow 443/tcp >/dev/null 2>&1 || true

# Cloudflared llega directamente a Octane. Nginx ya no necesita escuchar fuera.
if systemctl list-unit-files nginx.service --no-legend \
    2>/dev/null | grep -q '^nginx\.service'; then
    systemctl disable --now nginx
fi

# ==============================================================================
# 6/6 - VERIFICACIONES FINALES
# ==============================================================================

echo
echo "[6/6] Verificando servicios y exposición local..."

if ! systemctl is-active --quiet cloudflared; then
    echo "Error: cloudflared no está activo."
    exit 1
fi

if ! systemctl is-active --quiet octane; then
    echo "Error: Octane no está activo."
    exit 1
fi

if ! ss -ltn | grep -qE '127\.0\.0\.1:8000([[:space:]]|$)'; then
    echo "Error: Octane no está escuchando en 127.0.0.1:8000."
    exit 1
fi

if ss -ltn | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\[::\]|\*):(80|443)([[:space:]]|$)'; then
    echo "Advertencia: otro proceso sigue escuchando públicamente en 80 o 443."
    echo "Compruébalo con: ss -ltnp"
fi

echo
echo "=========================================================================="
echo " TÚNEL CONFIGURADO"
echo "=========================================================================="
echo
echo " Aplicación:"
echo "   https://$DOMAIN_NAME"
echo
echo " Origen privado:"
echo "   http://127.0.0.1:8000"
echo
echo " Proyecto Laravel:"
echo "   $PROYECTO_DIR"
echo
echo " Estado del túnel:"
echo "   systemctl status cloudflared"
echo
echo " Puertos HTTP/HTTPS de entrada: cerrados en UFW"
echo " Nginx: desactivado"
echo
echo "Nota: elimina también cualquier regla 80/443 del firewall del proveedor"
echo "cloud o del router, si existe."
echo
echo "=========================================================================="
