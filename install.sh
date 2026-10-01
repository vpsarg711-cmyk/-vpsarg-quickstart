
#!/usr/bin/env bash
set -Eeuo pipefail

# VPS ARG QuickStart
# Instalador base para Ubuntu 22.04/24.04.
# Instala BadVPN UDPGW y el controlador VPS ARG.
# No modifica SSH ni reinicia servicios existentes.

RAW="https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main"
BADVPN_REPO="https://github.com/ambrop72/badvpn.git"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if [[ $EUID -ne 0 ]]; then
    echo "Ejecutá: sudo bash install.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "No se pudo identificar el sistema operativo."
    exit 1
fi

. /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    echo "Este instalador requiere Ubuntu."
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "No se encontró apt-get."
    exit 1
fi

echo "======================================"
echo "       VPS ARG QuickStart"
echo "======================================"
echo "Sistema: $PRETTY_NAME"
echo
echo "Se instalará BadVPN UDPGW en TCP/7300."
echo "No se modificará la configuración SSH."
echo

export DEBIAN_FRONTEND=noninteractive

echo "[1/5] Instalando dependencias..."
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    cmake \
    make \
    gcc \
    libc6-dev

echo "[2/5] Descargando BadVPN..."
git clone --depth 1 "$BADVPN_REPO" "$WORKDIR/badvpn"

echo "[3/5] Compilando únicamente UDPGW..."
cmake -S "$WORKDIR/badvpn" -B "$WORKDIR/badvpn/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1

cmake --build "$WORKDIR/badvpn/build" --parallel 2

BINARY="$WORKDIR/badvpn/build/udpgw/badvpn-udpgw"

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: no se encontró el binario compilado de UDPGW."
    exit 1
fi

echo "[4/5] Instalando el binario..."
install -d -o root -g root -m 0755 /opt/badvpn
install -o root -g root -m 0755 \
    "$BINARY" /opt/badvpn/badvpn-udpgw

echo "[5/5] Configurando el servicio..."

if systemctl cat udpgw-7300.service >/dev/null 2>&1; then
    echo "Ya existe udpgw-7300.service."
    echo "No se sobrescribirá ni reiniciará el servicio existente."
    echo "Revisá su configuración antes de habilitar el servicio nuevo."
else
    cat > /etc/systemd/system/udpgw-7300.service <<'EOF'
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

    systemctl daemon-reload
    systemctl enable --now udpgw-7300.service
fi

echo
echo "BadVPN UDPGW: instalación completada."
echo "Puerto configurado: TCP/7300"
echo
echo "El controlador VPS ARG se instalará por separado."
echo "PDirect-C, HCR, VT Proxy y BHTTP quedan pendientes."
echo "Revisá las reglas del firewall de tu proveedor."
