#!/usr/bin/env bash
set -Eeuo pipefail

# VPS ARG QuickStart
# Instala en Ubuntu:
#   - PDirect-C:    TCP 80   -> SSH local 127.0.0.1:PUERTO_SSH (22 por defecto)
#   - BadVPN UDPGW: TCP 7300
# No modifica sshd, no reinicia SSH y no cambia el firewall.

RAW="https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main"
BADVPN_REPO="https://github.com/ambrop72/badvpn.git"
# Para probar con una copia local del repositorio: VPSARG_SRC_DIR=/ruta/al/repo
SRC_DIR="${VPSARG_SRC_DIR:-}"

PDIRECT_BIN="/usr/local/bin/pdirect-c"
PDIRECT_CONF="/etc/vpsarg-pdirect.conf"
PDIRECT_UNIT="pdirect-80.service"
UDPGW_BIN="/opt/badvpn/badvpn-udpgw"
UDPGW_UNIT="udpgw-7300.service"
CONTROLLER="/usr/local/sbin/vpsarg-puertos"
HCR_CONTROLLER="/usr/local/sbin/vpsarg-hcr"
PANEL="/usr/local/sbin/vpsarg"
USERS_CONTROLLER="/usr/local/sbin/vpsarg-usuarios"
HCR_CONF="/etc/vpsarg-hcr.conf"
SERVICES_CONF="/etc/vpsarg-servicios.conf"
VALIDATED_UBUNTU="20.04 22.04 24.04"

WORKDIR=""

cleanup() {
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR"
    fi
}
trap cleanup EXIT
trap 'echo "ERROR: falló la línea $LINENO: $BASH_COMMAND" >&2' ERR

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Lee una respuesta desde la terminal (funciona aunque stdin no sea una TTY).
ask() {
    local prompt="$1" default="$2" answer=""
    if { exec 3</dev/tty; } 2>/dev/null; then
        read -r -u 3 -p "$prompt" answer || answer=""
        exec 3<&-
    else
        echo "$prompt(sin terminal: se usa '$default')" >&2
    fi
    REPLY="${answer:-$default}"
}

valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

port_open() {
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

port_listening() {
    [[ -n "$(ss -Hltn "sport = :$1")" ]]
}

fetch() {
    if [[ -n "$SRC_DIR" ]]; then
        cp -- "$SRC_DIR/$1" "$2"
    else
        curl -fsSL --retry 3 "$RAW/$1" -o "$2"
    fi
}

# ---------------------------------------------------------------- comprobaciones
[[ ${EUID} -eq 0 ]] || fail "Ejecutá como root: sudo bash $0"

[[ -r /etc/os-release ]] || fail "No se pudo identificar el sistema operativo."
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "Este instalador requiere Ubuntu."

for cmd in apt-get systemctl ss timeout; do
    command -v "$cmd" >/dev/null 2>&1 || fail "No se encontró el comando $cmd."
done
[[ -d /run/systemd/system ]] || fail "systemd no es el sistema de inicio activo."

echo "======================================"
echo "       VPS ARG QuickStart"
echo "======================================"
echo "Sistema: ${PRETTY_NAME:-Ubuntu}"
echo "Se instalará:"
echo "  - PDirect-C     en TCP 80   -> SSH local 127.0.0.1:PUERTO_SSH"
echo "  - BadVPN UDPGW  en TCP 7300"
echo "No se modificará sshd, no se reiniciará SSH y no se tocará el firewall."
echo

if [[ " $VALIDATED_UBUNTU " != *" ${VERSION_ID:-} "* ]]; then
    echo "AVISO: Ubuntu ${VERSION_ID:-desconocido} no está entre las versiones previstas ($VALIDATED_UBUNTU)."
    ask "¿Continuar de todos modos? [s/N]: " "n"
    [[ "$REPLY" =~ ^[sS]$ ]] || fail "Cancelado. No se realizaron cambios."
fi

# Instalación previa: avisar y pedir confirmación antes de sobrescribir.
existing=()
for path in "$PDIRECT_BIN" "$PDIRECT_CONF" "$UDPGW_BIN" "$CONTROLLER" "$SERVICES_CONF"; do
    [[ -e "$path" ]] && existing+=("$path")
done
for unit in "$PDIRECT_UNIT" "$UDPGW_UNIT"; do
    systemctl cat "$unit" >/dev/null 2>&1 && existing+=("unidad $unit")
done
if ((${#existing[@]})); then
    echo "AVISO: ya existen estos componentes:"
    printf '  - %s\n' "${existing[@]}"
    echo "Si continuás, se detendrán y se reemplazarán por esta versión."
    ask "Escribí SI para sobrescribirlos: " "no"
    [[ "$REPLY" == "SI" ]] || fail "Cancelado. No se realizaron cambios."
fi

# Puertos 80 y 7300: deben estar libres o en uso por nuestros propios servicios.
for pair in "80:$PDIRECT_UNIT" "7300:$UDPGW_UNIT"; do
    port="${pair%%:*}"
    unit="${pair#*:}"
    if port_listening "$port" && ! systemctl is-active --quiet "$unit"; then
        ss -ltnp "sport = :$port" >&2 || true
        fail "El puerto TCP $port ya está en uso por otro programa. No se realizaron cambios."
    fi
done

# Puerto SSH de destino. Solo se lee: sshd no se modifica.
current_port=22
if [[ -r "$PDIRECT_CONF" ]]; then
    prev="$(sed -n 's/^SSH_PORT=\([0-9]\{1,5\}\)$/\1/p' "$PDIRECT_CONF" | tail -n 1)"
    [[ -n "$prev" ]] && current_port="$prev"
fi
ask "Puerto SSH local al que reenviará PDirect-C [$current_port]: " "$current_port"
SSH_PORT="$REPLY"
valid_port "$SSH_PORT" || fail "Puerto no válido: $SSH_PORT. No se realizaron cambios."

if port_open "$SSH_PORT"; then
    echo "OK: hay un servicio escuchando en 127.0.0.1:$SSH_PORT."
else
    echo "AVISO: no hay ningún servicio escuchando en 127.0.0.1:$SSH_PORT."
    echo "PDirect-C no podrá conectar hasta que SSH escuche en ese puerto."
    echo "Comprobá el puerto real con: sudo ss -ltnp | grep -E 'sshd|systemd'"
    ask "¿Continuar con el puerto $SSH_PORT? [s/N]: " "n"
    [[ "$REPLY" =~ ^[sS]$ ]] || fail "Cancelado. No se realizaron cambios."
fi

# ---------------------------------------------------------------- compilación
export DEBIAN_FRONTEND=noninteractive
WORKDIR="$(mktemp -d)"

echo "[1/6] Instalando dependencias..."
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git cmake make gcc libc6-dev libevent-dev

echo "[2/6] Obteniendo pdirect.c y el controlador..."
fetch pdirect.c "$WORKDIR/pdirect.c"
fetch vpsarg-puertos.sh "$WORKDIR/vpsarg-puertos.sh"
bash -n "$WORKDIR/vpsarg-puertos.sh" || fail "El controlador descargado tiene errores de sintaxis."
fetch vpsarg-hcr.sh "$WORKDIR/vpsarg-hcr.sh"
bash -n "$WORKDIR/vpsarg-hcr.sh" || fail "El controlador de HCR descargado tiene errores de sintaxis."
fetch vpsarg-panel.sh "$WORKDIR/vpsarg-panel.sh"
bash -n "$WORKDIR/vpsarg-panel.sh" || fail "El panel descargado tiene errores de sintaxis."
fetch vpsarg-usuarios.sh "$WORKDIR/vpsarg-usuarios.sh"
bash -n "$WORKDIR/vpsarg-usuarios.sh" || fail "El controlador de usuarios descargado tiene errores de sintaxis."

echo "[3/6] Compilando PDirect-C..."
gcc -O2 -Wall -Wextra -D_FORTIFY_SOURCE=2 -fstack-protector-strong \
    -o "$WORKDIR/pdirect-c" "$WORKDIR/pdirect.c" -levent_core \
    || fail "No se pudo compilar PDirect-C."

echo "[4/6] Descargando y compilando BadVPN UDPGW..."
git clone --depth 1 "$BADVPN_REPO" "$WORKDIR/badvpn"
cmake -S "$WORKDIR/badvpn" -B "$WORKDIR/badvpn/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1
cmake --build "$WORKDIR/badvpn/build" --parallel 2
[[ -x "$WORKDIR/badvpn/build/udpgw/badvpn-udpgw" ]] || fail "No se encontró el binario compilado de UDPGW."

# ---------------------------------------------------------------- instalación
echo "[5/6] Instalando binarios, configuración y unidades systemd..."
for unit in "$PDIRECT_UNIT" "$UDPGW_UNIT"; do
    systemctl stop "$unit" 2>/dev/null || true
done

install -d -o root -g root -m 0755 /opt/badvpn
install -o root -g root -m 0755 "$WORKDIR/pdirect-c" "$PDIRECT_BIN"
install -o root -g root -m 0755 "$WORKDIR/badvpn/build/udpgw/badvpn-udpgw" "$UDPGW_BIN"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-puertos.sh" "$CONTROLLER"
# Solo se copia el controlador: HCR se instala aparte con "sudo vpsarg-hcr instalar".
install -o root -g root -m 0755 "$WORKDIR/vpsarg-hcr.sh" "$HCR_CONTROLLER"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-panel.sh" "$PANEL"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-usuarios.sh" "$USERS_CONTROLLER"

printf 'SSH_PORT=%s\n' "$SSH_PORT" > "$PDIRECT_CONF"
# Se conservan otros servicios ya registrados (por ejemplo hcr-8880).
extra_services=()
if [[ -r "$SERVICES_CONF" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[a-zA-Z0-9_.@-]+$ && "$line" != pdirect-80 && "$line" != udpgw-7300 ]] \
            && extra_services+=("$line")
    done < "$SERVICES_CONF"
fi
printf '%s\n' pdirect-80 udpgw-7300 "${extra_services[@]}" > "$SERVICES_CONF"
chmod 0644 "$PDIRECT_CONF" "$SERVICES_CONF"

cat > "/etc/systemd/system/$PDIRECT_UNIT" <<EOF
[Unit]
Description=VPS ARG - PDirect-C (TCP 80 -> SSH local)
After=network.target

[Service]
Type=simple
EnvironmentFile=$PDIRECT_CONF
ExecStart=$PDIRECT_BIN \${SSH_PORT}
Restart=on-failure
RestartSec=2
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > "/etc/systemd/system/$UDPGW_UNIT" <<EOF
[Unit]
Description=VPS ARG - BadVPN UDPGW (TCP 7300)
After=network.target

[Service]
Type=simple
ExecStart=$UDPGW_BIN --listen-addr 0.0.0.0:7300 --max-clients 3 --max-connections-for-client 256
# badvpn-udpgw termina con código 1 incluso al detenerlo con SIGTERM.
SuccessExitStatus=1
Restart=always
RestartSec=2
DynamicUser=yes
NoNewPrivileges=true
PrivateTmp=true
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "/etc/systemd/system/$PDIRECT_UNIT" "/etc/systemd/system/$UDPGW_UNIT"

echo "[6/6] Activando servicios..."
systemctl daemon-reload
systemctl enable --now "$PDIRECT_UNIT" "$UDPGW_UNIT"

sleep 2
ok=1
for pair in "80:$PDIRECT_UNIT" "7300:$UDPGW_UNIT"; do
    port="${pair%%:*}"
    unit="${pair#*:}"
    if systemctl is-active --quiet "$unit" && port_listening "$port"; then
        echo "OK: $unit activo y escuchando en TCP $port."
    else
        echo "ERROR: $unit no está activo o no escucha en TCP $port. Revisá: journalctl -u $unit -n 50" >&2
        ok=0
    fi
done
((ok)) || fail "La instalación terminó con servicios fallidos."

echo
echo "======================================"
echo "Instalación finalizada."
echo "PDirect-C:   TCP 80 -> 127.0.0.1:$SSH_PORT ($PDIRECT_UNIT)"
echo "BadVPN:      TCP 7300 ($UDPGW_UNIT)"
echo "Panel: sudo vpsarg"
echo "Controlador: sudo vpsarg-puertos estado"
echo "Cambiar puerto SSH de destino: sudo vpsarg-puertos puerto-ssh PUERTO"
echo
echo "El firewall no se modificó: abrí TCP 80 y 7300 en el proveedor si hace falta."
if [[ -r "$HCR_CONF" ]]; then
    hcr_ssh="$(sed -n 's/^HCR_SSH_PORT=\([0-9]\{1,5\}\)$/\1/p' "$HCR_CONF" | tail -n 1)"
    if [[ -n "$hcr_ssh" && "$hcr_ssh" != "$SSH_PORT" ]]; then
        echo "AVISO: HCR apunta a 127.0.0.1:$hcr_ssh y PDirect-C a 127.0.0.1:$SSH_PORT."
        echo "Para unificarlos: sudo vpsarg-puertos puerto-ssh $SSH_PORT"
    fi
fi
echo "HCR (opcional): copiá hcr-server a /opt/hcr/ y ejecutá: sudo vpsarg-hcr instalar"
echo "======================================"
