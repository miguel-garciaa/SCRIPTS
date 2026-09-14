#!/bin/bash
set -e

# Configuracion
SSH_USER="miguel"
MODO="${1:-}"

PAM_FILE="/etc/pam.d/sshd"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-lsetup-2fa.conf"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/lsetup-2fa-$TIMESTAMP"

if [ "$EUID" -ne 0 ]; then
    echo "Ejecuta este script con sudo."
    exit 1
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
    echo "No existe el usuario SSH: $SSH_USER"
    exit 1
fi

SSH_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"

if [ ! -s "$SSH_HOME/.ssh/authorized_keys" ]; then
    echo "Primero configura una clave SSH para $SSH_USER."
    echo "No se activa 2FA sin una clave publica para evitar perder el acceso."
    exit 1
fi

mkdir -p "$BACKUP_DIR"
cp -a "$PAM_FILE" "$BACKUP_DIR/sshd.pam"
if [ -f "$SSHD_DROPIN" ]; then
    cp -a "$SSHD_DROPIN" "$BACKUP_DIR/00-lsetup-2fa.conf"
fi

if [ "$MODO" = "--off" ]; then
    sed -i '/pam_google_authenticator\.so.*# lsetup-2fa/d' "$PAM_FILE"
    sed -i 's|^# @include common-auth # lsetup-2fa$|@include common-auth|' "$PAM_FILE"
    rm -f "$SSHD_DROPIN"

    if ! /usr/sbin/sshd -t; then
        cp -a "$BACKUP_DIR/sshd.pam" "$PAM_FILE"
        if [ -f "$BACKUP_DIR/00-lsetup-2fa.conf" ]; then
            cp -a "$BACKUP_DIR/00-lsetup-2fa.conf" "$SSHD_DROPIN"
        fi
        echo "Configuracion SSH no valida. Se ha restaurado el backup."
        exit 1
    fi

    systemctl reload ssh
    echo "2FA SSH desactivado. Backup: $BACKUP_DIR"
    exit 0
fi

if [ "$MODO" != "--on" ]; then
    echo "Uso: sudo bash seguridad/2fa.sh [--on|--off]"
    exit 1
fi

apt-get update
apt-get install -y libpam-google-authenticator

if [ ! -f "$SSH_HOME/.google_authenticator" ]; then
    echo "Generando el QR y los codigos de emergencia para $SSH_USER..."
    sudo -u "$SSH_USER" env HOME="$SSH_HOME" \
        google-authenticator -t -d -f -r 3 -R 30 -w 3
fi

chown "$SSH_USER:$SSH_USER" "$SSH_HOME/.google_authenticator"
chmod 600 "$SSH_HOME/.google_authenticator"

sed -i '/pam_google_authenticator\.so.*# lsetup-2fa/d' "$PAM_FILE"
sed -i -E 's|^[[:space:]]*@include[[:space:]]+common-auth[[:space:]]*$|# @include common-auth # lsetup-2fa|' "$PAM_FILE"
printf '\nauth required pam_google_authenticator.so # lsetup-2fa\n' >> "$PAM_FILE"

cat > "$SSHD_DROPIN" <<'EOF'
UsePAM yes
KbdInteractiveAuthentication yes
AuthenticationMethods publickey,keyboard-interactive:pam
EOF

if ! /usr/sbin/sshd -t; then
    cp -a "$BACKUP_DIR/sshd.pam" "$PAM_FILE"
    if [ -f "$BACKUP_DIR/00-lsetup-2fa.conf" ]; then
        cp -a "$BACKUP_DIR/00-lsetup-2fa.conf" "$SSHD_DROPIN"
    else
        rm -f "$SSHD_DROPIN"
    fi
    echo "Configuracion SSH no valida. Se ha restaurado el backup."
    exit 1
fi

systemctl reload ssh

echo "2FA SSH activado para $SSH_USER."
echo "No cierres esta sesion: prueba el acceso en otra terminal."
echo "Para desactivarlo: sudo bash seguridad/2fa.sh --off"
echo "Backup: $BACKUP_DIR"
