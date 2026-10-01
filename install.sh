#!/usr/bin/env bash
set -Eeuo pipefail

# VPS ARG QuickStart
# Instala BadVPN UDPGW y el controlador de servicios en Ubuntu.
# No modifica SSH ni el firewall. No sobrescribe servicios/archivos existentes.

RAW="https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main"
BADVPN_REPO="https://github.com/ambrop72/badvpn.git"
SERVICE="udpgw-7300.service"
BINARY_PATH="/opt/badvpn/badvpn-udpgw"
WORKDIR=""

cleanup() {
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

if [[ ${EUID} -ne 0 ]]; then
    echo "Ejecutá: sudo bash install.sh" >&2
    exit 1
fi

[[ -r /etc/os-release ]] || fail "No se pudo identificar el sistema operativo."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "Este instalador requiere Ubuntu."

command -v apt-get >/dev/null 2>&1 || fail "No se encontró apt-get."
command -v systemctl >/dev/null 2>&1 || fail "No se encontró systemctl."

# Comprobaciones previas: cancelar antes de instalar paquetes o tocar archivos.
if systemctl cat "$SERVICE" >/dev/null 2>&1; then
    fail "Ya existe $SERVICE. No se modificó el sistema. Revisá el servicio existente."
fi
if [[ -e "$BINARY_PATH" ]]; then
    fail "Ya existe $BINARY_PATH. No se sobrescribió."
fi
if [[ -e /etc/vpsarg-servicios.conf ]]; then
    fail "Ya existe /etc/vpsarg-servicios.conf. No se sobrescribió."
fi
if [[ -e /usr/local/sbin/vpsarg-puertos ]]; then
    fail "Ya existe /usr/local/sbin/vpsarg-puertos. No se sobrescribió."
fi

echo "======================================"
echo "       VPS ARG QuickStart"
echo "======================================"
echo "Sistema: ${PRETTY_NAME:-Ubuntu}"
echo "Se instalará BadVPN UDPGW en TCP/7300."
echo "No se modificará SSH ni el firewall."
echo "Si ya existen componentes del mismo nombre, se cancelará."
echo

export DEBIAN_FRONTEND=noninteractive
WORKDIR="$(mktemp -d)"

echo "[1/7] Instalando dependencias..."
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git cmake make gcc libc6-dev

echo "[2/7] Descargando el controlador desde GitHub..."
curl -fsSL --retry 3 "$RAW/vpsarg-puertos.sh" -o "$WORKDIR/vpsarg-puertos.sh"
bash -n "$WORKDIR/vpsarg-puertos.sh" || fail "El controlador descargado tiene errores de sintaxis."

echo "[3/7] Descargando BadVPN..."
git clone --depth 1 "$BADVPN_REPO" "$WORKDIR/badvpn"

echo "[4/7] Compilando únicamente UDPGW..."
cmake -S "$WORKDIR/badvpn" -B "$WORKDIR/badvpn/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1
cmake --build "$WORKDIR/badvpn/build" --parallel 2

BINARY="$WORKDIR/badvpn/build/udpgw/badvpn-udpgw"
[[ -x "$BINARY" ]] || fail "No se encontró el binario compilado de UDPGW."

echo "[5/7] Instalando el binario y el controlador..."
install -d -o root -g root -m 0755 /opt/badvpn
install -o root -g root -m 0755 "$BINARY" "$BINARY_PATH"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-puertos.sh" /usr/local/sbin/vpsarg-puertos

echo "[6/7] Creando la configuración del controlador..."
printf '%s\n' 'udpgw-7300' > /etc/vpsarg-servicios.conf
chown root:root /etc/vpsarg-servicios.conf
chmod 0644 /etc/vpsarg-servicios.conf

echo "[7/7] Configurando y activando UDPGW..."
cat > "/etc/systemd/system/$SERVICE" <<'EOF'
[Unit]
Description=VPS ARG - BadVPN UDPGW
After=network.target

[Service]
Type=simple
ExecStart=/opt/badvpn/badvpn-udpgw --listen-addr 0.0.0.0:7300 --max-clients 3 --max-connections-for-client 256
Restart=on-failure
RestartSec=2
LimitNOFILE=8192
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
chown root:root "/etc/systemd/system/$SERVICE"
chmod 0644 "/etc/systemd/system/$SERVICE"
systemctl daemon-reload
systemctl enable --now "$SERVICE"

echo
echo "======================================"
echo "Instalación finalizada."
echo "Controlador: /usr/local/sbin/vpsarg-puertos"
echo "Servicio: $SERVICE"
echo "Puerto: TCP/7300"
echo "Comprobá el resultado con: sudo vpsarg-puertos estado"
echo
echo "PDirect-C, HCR, VT Proxy y BHTTP no se instalan en esta versión."
echo "Revisá el firewall del proveedor si necesitás acceso desde Internet."
echo "======================================"
