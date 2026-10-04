#!/usr/bin/env bash
set -Eeuo pipefail

# VPS ARG QuickStart - instalación completa, autorizada por un token de instalación:
#   - PDirect-C:    TCP 80   -> SSH local 127.0.0.1:PUERTO_SSH (22 por defecto)
#   - BadVPN UDPGW: TCP 7300
#   - HCR:          TCP 8880 -> SSH local (binario /opt/hcr/hcr-server, obligatorio)
#   - BHTTP:        TCP 8001 -> 127.0.0.1:18022 -> SSH local (bhttp-shim + bhttp-server)
#   - panel vpsarg y cuentas SSH (vpsarg-usuarios)
# Todo se valida antes de cambiar nada. Si algo falla durante la instalación, se revierte
# al estado anterior y el token queda disponible otra vez. El token se consume solo
# cuando todo quedó funcionando.
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
BHTTP_CONTROLLER="/usr/local/sbin/vpsarg-bhttp"
PANEL="/usr/local/sbin/vpsarg"
USERS_CONTROLLER="/usr/local/sbin/vpsarg-usuarios"
# Verificador del token de versiones anteriores: ya no se usa y se quita.
OLD_TOKEN_LIB="/usr/local/lib/vpsarg/token.sh"
LIB_DIR="/usr/local/lib/vpsarg"
HCR_SOURCE="/opt/hcr/hcr-server"
HCR_CONF="/etc/vpsarg-hcr.conf"
HCR_UNIT="hcr-8880.service"
BHTTP_CONF="/etc/vpsarg-bhttp.conf"
BHTTP_UNITS=(bhttp-server.service bhttp-shim.service)
INSTALL_RECORD="/etc/vpsarg/instalacion"
RUN_MARK="/run/vpsarg-instalacion"
BACKUP_ROOT="/var/backups/vpsarg"
SERVICES_CONF="/etc/vpsarg-servicios.conf"
VALIDATED_UBUNTU="20.04 22.04 24.04"

WORKDIR=""
# 0: todavía no se cambió nada; 1: hay cambios que revertir si algo falla; 2: terminado.
PHASE=0
BUILD_STARTED=0
STEP=""
SNAPSHOT=""

cleanup() {
    local rc=$? phase="$PHASE"
    trap - EXIT INT TERM
    if ((phase == 1)); then
        echo "ERROR: falló la instalación en el paso: ${STEP:-desconocido}." >&2
        rollback
    elif ((phase == 0 && rc != 0 && BUILD_STARTED)); then
        echo "ERROR: falló el paso: $STEP. No se instaló ningún componente de VPS ARG (solo pueden quedar paquetes apt de compilación)." >&2
    fi
    # La instalación no terminó: el token no se consume y vuelve a estar disponible.
    if ((phase < 2)) && declare -F token_release >/dev/null; then
        token_release
    fi
    rm -f -- "$RUN_MARK"
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
trap 'echo "ERROR: falló la línea $LINENO: $BASH_COMMAND" >&2' ERR

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Archivos que puede cambiar la instalación (se guardan antes y se restauran si algo falla).
managed_files() {
    printf '%s\n' "$PDIRECT_BIN" "$PDIRECT_CONF" "$UDPGW_BIN" "$CONTROLLER" "$HCR_CONTROLLER" \
        "$BHTTP_CONTROLLER" "$PANEL" "$USERS_CONTROLLER" "$OLD_TOKEN_LIB" "$SERVICES_CONF" \
        "$HCR_CONF" "$LIB_DIR/hcr-server" "$BHTTP_CONF" "$LIB_DIR/bhttp-server" "$LIB_DIR/bhttp-shim" \
        "$INSTALL_RECORD" "/etc/systemd/system/$PDIRECT_UNIT" "/etc/systemd/system/$UDPGW_UNIT" \
        "/etc/systemd/system/$HCR_UNIT" "/etc/systemd/system/${BHTTP_UNITS[0]}" \
        "/etc/systemd/system/${BHTTP_UNITS[1]}"
}
managed_units() {
    printf '%s\n' "$PDIRECT_UNIT" "$UDPGW_UNIT" "$HCR_UNIT" "${BHTTP_UNITS[@]}"
}
managed_dirs() {
    printf '%s\n' /opt/badvpn "$LIB_DIR" "${INSTALL_RECORD%/*}"
}

# Copia de seguridad del estado anterior: archivos, carpetas y estado de cada unidad.
snapshot() {
    local f i=0 u d
    SNAPSHOT="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-instalacion-$$"
    install -d -o root -g root -m 0700 "$SNAPSHOT/archivos"
    while IFS= read -r f; do
        i=$((i + 1))
        if [[ -e "$f" ]]; then
            cp -p -- "$f" "$SNAPSHOT/archivos/$i"
            printf '%s\t%s\n' "$i" "$f" >> "$SNAPSHOT/existian"
        else
            printf '%s\n' "$f" >> "$SNAPSHOT/no-existian"
        fi
    done < <(managed_files)
    while IFS= read -r d; do
        [[ -d "$d" ]] || printf '%s\n' "$d" >> "$SNAPSHOT/carpetas-nuevas"
    done < <(managed_dirs)
    while IFS= read -r u; do
        printf '%s %s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)" \
            "$(systemctl is-enabled "$u" 2>/dev/null || true)" >> "$SNAPSHOT/unidades"
    done < <(managed_units)
}

# Vuelve todo al estado de la copia: detiene lo instalado en esta corrida, restaura los
# archivos, borra los nuevos y deja cada unidad activa/habilitada como estaba.
rollback() {
    local f i u active enabled problems=0
    echo "Revirtiendo al estado anterior (copia: $SNAPSHOT)..." >&2
    while IFS= read -r u; do
        systemctl stop "$u" >/dev/null 2>&1 || true
    done < <(managed_units)
    if [[ -r "$SNAPSHOT/no-existian" ]]; then
        while IFS= read -r f; do rm -f -- "$f"; done < "$SNAPSHOT/no-existian"
    fi
    if [[ -r "$SNAPSHOT/existian" ]]; then
        while IFS=$'\t' read -r i f; do
            cp -p -- "$SNAPSHOT/archivos/$i" "$f" || problems=1
        done < "$SNAPSHOT/existian"
    fi
    if [[ -r "$SNAPSHOT/carpetas-nuevas" ]]; then
        while IFS= read -r f; do rmdir -- "$f" 2>/dev/null || true; done < "$SNAPSHOT/carpetas-nuevas"
    fi
    systemctl daemon-reload || problems=1
    while read -r u active enabled; do
        systemctl reset-failed "$u" >/dev/null 2>&1 || true
        if [[ "$enabled" == enabled ]]; then
            systemctl enable "$u" >/dev/null 2>&1 || problems=1
        elif systemctl cat "$u" >/dev/null 2>&1; then
            systemctl disable "$u" >/dev/null 2>&1 || true
        fi
        if [[ "$active" == active ]]; then
            systemctl start "$u" >/dev/null 2>&1 || problems=1
        fi
    done < "$SNAPSHOT/unidades"
    while read -r u active enabled; do
        if [[ "$active" == active ]] && ! systemctl is-active --quiet "$u"; then
            echo "ATENCIÓN: $u estaba activo y no volvió a arrancar." >&2
            problems=1
        fi
        if [[ "$active" != active ]] && systemctl is-active --quiet "$u"; then
            echo "ATENCIÓN: $u quedó activo y antes no lo estaba." >&2
            problems=1
        fi
    done < "$SNAPSHOT/unidades"
    if ((problems)); then
        echo "ATENCIÓN: la reversión no quedó completa (ver arriba). Copia de seguridad: $SNAPSHOT" >&2
    else
        echo "Reversión completa: archivos y servicios como estaban antes. Los paquetes apt de compilación no se quitan." >&2
    fi
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

for cmd in apt-get systemctl ss timeout curl sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || fail "No se encontró el comando $cmd."
done
[[ -d /run/systemd/system ]] || fail "systemd no es el sistema de inicio activo."
# El binario de HCR entregado es solo para x86_64 y HCR es obligatorio.
[[ "$(uname -m)" == x86_64 ]] \
    || fail "HCR requerido pero no disponible para $(uname -m) (el binario entregado es x86_64). Instalación abortada sin cambios."

# ---------------------------------------------------------------- token de instalación
# 1) Se valida y se reserva antes de cualquier cambio. Solo autoriza instalar: no
# interviene en el login de los usuarios ni en los servicios instalados.
STEP="validar el token"
WORKDIR="$(mktemp -d)"
fetch vpsarg-token.sh "$WORKDIR/vpsarg-token.sh" \
    || fail "No se pudo obtener el cliente del servicio de autorización. No se realizaron cambios."
bash -n "$WORKDIR/vpsarg-token.sh" || fail "El cliente del servicio de autorización tiene errores de sintaxis. No se realizaron cambios."
# shellcheck source=vpsarg-token.sh
. "$WORKDIR/vpsarg-token.sh"
token_read
unset VPSARG_TOKEN
token_reserve

echo "======================================"
echo "       VPS ARG QuickStart"
echo "======================================"
echo "Sistema: ${PRETTY_NAME:-Ubuntu}"
echo "Se instalará (instalación completa):"
echo "  - PDirect-C     en TCP 80   -> SSH local 127.0.0.1:PUERTO_SSH"
echo "  - BadVPN UDPGW  en TCP 7300"
echo "  - HCR           en TCP 8880 -> SSH local (desde $HCR_SOURCE)"
echo "  - BHTTP         en TCP 8001 -> 127.0.0.1:18022 -> SSH local"
echo "  - panel vpsarg y cuentas SSH"
echo "No se modificará sshd, no se reiniciará SSH y no se tocará el firewall."
echo

if [[ " $VALIDATED_UBUNTU " != *" ${VERSION_ID:-} "* ]]; then
    echo "AVISO: Ubuntu ${VERSION_ID:-desconocido} no está entre las versiones previstas ($VALIDATED_UBUNTU)."
    ask "¿Continuar de todos modos? [s/N]: " "n"
    [[ "$REPLY" =~ ^[sS]$ ]] || fail "Cancelado. No se realizaron cambios."
fi

# Instalación previa: avisar y pedir confirmación antes de sobrescribir.
STEP="comprobar la instalación previa"
existing=()
for path in "$PDIRECT_BIN" "$PDIRECT_CONF" "$UDPGW_BIN" "$CONTROLLER" "$SERVICES_CONF" "$HCR_CONF" "$BHTTP_CONF"; do
    [[ -e "$path" ]] && existing+=("$path")
done
for unit in "$PDIRECT_UNIT" "$UDPGW_UNIT" "$HCR_UNIT" "${BHTTP_UNITS[@]}"; do
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
STEP="comprobar puertos"
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

# Scripts de VPS ARG: se obtienen y se revisan antes de cambiar nada.
STEP="obtener los scripts"
for f in pdirect.c vpsarg-puertos.sh vpsarg-hcr.sh vpsarg-bhttp.sh vpsarg-panel.sh vpsarg-usuarios.sh; do
    fetch "$f" "$WORKDIR/$f" || fail "No se pudo obtener $f. No se realizaron cambios."
    [[ "$f" == *.sh ]] && { bash -n "$WORKDIR/$f" || fail "$f tiene errores de sintaxis. No se realizaron cambios."; }
done

# 2) HCR (obligatorio): las mismas comprobaciones de "vpsarg-hcr instalar", sin cambios.
STEP="validar HCR"
[[ -f "$HCR_SOURCE" ]] || fail "HCR requerido pero no disponible ($HCR_SOURCE no existe; copialo por SFTP). Instalación abortada sin cambios."
bash "$WORKDIR/vpsarg-hcr.sh" verificar --ssh-puerto "$SSH_PORT" \
    || fail "HCR requerido pero no disponible (ver arriba). Instalación abortada sin cambios."
HCR_PORT=8880
if [[ -r "$HCR_CONF" ]]; then
    prev="$(sed -n 's/^HCR_PORT=\([0-9]\{1,5\}\)$/\1/p' "$HCR_CONF" | tail -n 1)"
    [[ -n "$prev" ]] && HCR_PORT="$prev"
fi

# 3) BHTTP (obligatorio): binarios verificados por sha256 y puertos libres, sin cambios.
STEP="validar BHTTP"
current_bhttp=8001
if [[ -r "$BHTTP_CONF" ]]; then
    prev="$(sed -n 's/^BHTTP_PORT=\([0-9]\{1,5\}\)$/\1/p' "$BHTTP_CONF" | tail -n 1)"
    [[ -n "$prev" ]] && current_bhttp="$prev"
fi
ask "Puerto TCP externo de BHTTP [$current_bhttp]: " "$current_bhttp"
BHTTP_PORT="$REPLY"
valid_port "$BHTTP_PORT" || fail "Puerto no válido: $BHTTP_PORT. No se realizaron cambios."
[[ "$BHTTP_PORT" != "$HCR_PORT" ]] || fail "El puerto $BHTTP_PORT ya es el de HCR. No se realizaron cambios."
install -d -m 0700 "$WORKDIR/bhttp"
if [[ -n "$SRC_DIR" && -n "${VPSARG_LAB_BHTTP_DIR:-}" ]]; then
    # Laboratorio: copias locales de los binarios en lugar de descargarlos.
    cp -- "$VPSARG_LAB_BHTTP_DIR"/bhttp-server "$VPSARG_LAB_BHTTP_DIR"/bhttp-shim "$WORKDIR/bhttp/" 2>/dev/null || true
else
    bash "$WORKDIR/vpsarg-bhttp.sh" descargar "$WORKDIR/bhttp" \
        || fail "BHTTP requerido pero no disponible (ver arriba). Instalación abortada sin cambios."
fi
bash "$WORKDIR/vpsarg-bhttp.sh" verificar --desde "$WORKDIR/bhttp" --puerto "$BHTTP_PORT" \
        --ssh-puerto "$SSH_PORT" --reservados "80 7300 $HCR_PORT" \
    || fail "BHTTP requerido pero no disponible (ver arriba). Instalación abortada sin cambios."

# ---------------------------------------------------------------- compilación
# Hasta acá no se cambió nada. apt y la compilación no tocan los servicios: si fallan,
# no queda ningún componente instalado y el token vuelve a estar disponible.
export DEBIAN_FRONTEND=noninteractive

BUILD_STARTED=1
STEP="instalar dependencias (apt)"
echo "[1/7] Instalando dependencias..."
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git cmake make gcc libc6-dev libevent-dev

echo "[2/7] Scripts de VPS ARG obtenidos y revisados."

STEP="compilar PDirect-C"
echo "[3/7] Compilando PDirect-C..."
gcc -O2 -Wall -Wextra -D_FORTIFY_SOURCE=2 -fstack-protector-strong \
    -o "$WORKDIR/pdirect-c" "$WORKDIR/pdirect.c" -levent_core \
    || fail "No se pudo compilar PDirect-C."

STEP="compilar BadVPN UDPGW"
echo "[4/7] Descargando y compilando BadVPN UDPGW..."
git clone --depth 1 "$BADVPN_REPO" "$WORKDIR/badvpn"
cmake -S "$WORKDIR/badvpn" -B "$WORKDIR/badvpn/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1
cmake --build "$WORKDIR/badvpn/build" --parallel 2
[[ -x "$WORKDIR/badvpn/build/udpgw/badvpn-udpgw" ]] || fail "No se encontró el binario compilado de UDPGW."

# ---------------------------------------------------------------- instalación
# Desde acá, cualquier fallo revierte todo al estado anterior.
STEP="guardar el estado anterior"
snapshot
PHASE=1
(umask 077; printf 'reserva=%s\n' "$TOKEN_ID" > "$RUN_MARK")

STEP="instalar PDirect-C, UDPGW, panel y cuentas"
echo "[5/7] Instalando binarios, configuración y unidades systemd..."
for unit in "$PDIRECT_UNIT" "$UDPGW_UNIT"; do
    systemctl stop "$unit" 2>/dev/null || true
done

install -d -o root -g root -m 0755 /opt/badvpn
install -o root -g root -m 0755 "$WORKDIR/pdirect-c" "$PDIRECT_BIN"
install -o root -g root -m 0755 "$WORKDIR/badvpn/build/udpgw/badvpn-udpgw" "$UDPGW_BIN"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-puertos.sh" "$CONTROLLER"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-hcr.sh" "$HCR_CONTROLLER"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-bhttp.sh" "$BHTTP_CONTROLLER"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-panel.sh" "$PANEL"
install -o root -g root -m 0755 "$WORKDIR/vpsarg-usuarios.sh" "$USERS_CONTROLLER"
rm -f -- "$OLD_TOKEN_LIB"

printf 'SSH_PORT=%s\n' "$SSH_PORT" > "$PDIRECT_CONF"
# Se conservan otros servicios ya registrados (hcr-8880, bhttp-server y bhttp-shim los agregan sus controladores).
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

STEP="activar PDirect-C y UDPGW"
echo "[6/7] Activando servicios..."
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
((ok)) || fail "PDirect-C o UDPGW no quedaron activos."

echo "[7/7] Instalando HCR y BHTTP..."
STEP="instalar HCR"
"$HCR_CONTROLLER" instalar --ssh-puerto "$SSH_PORT" || fail "HCR no quedó funcionando (ver arriba)."
STEP="instalar BHTTP"
"$BHTTP_CONTROLLER" instalar --desde "$WORKDIR/bhttp" --puerto "$BHTTP_PORT" --ssh-puerto "$SSH_PORT" \
    || fail "BHTTP no quedó funcionando (ver arriba)."

STEP="verificar la instalación completa"
for unit in "$PDIRECT_UNIT" "$UDPGW_UNIT" "$HCR_UNIT" "${BHTTP_UNITS[@]}"; do
    systemctl is-active --quiet "$unit" || fail "$unit dejó de estar activo."
done
for p in 80 7300 "$HCR_PORT" "$BHTTP_PORT"; do
    port_listening "$p" || fail "Nada escucha en TCP $p."
done

# 4) Todo quedó funcionando: recién ahora se consume el token.
STEP="confirmar el token"
PHASE=2
rm -f -- "$RUN_MARK"
if token_confirm; then
    token_record instalada
    echo "Token $TOKEN_ID consumido: no sirve para otra instalación."
else
    token_record instalada
    echo "AVISO: la instalación terminó, pero no se pudo confirmar el token $TOKEN_ID en el servicio." >&2
    echo "       Confirmalo en el servidor de autorización: vpsarg-autorizacion.py confirmar $TOKEN_ID" >&2
fi

echo
echo "======================================"
echo "Instalación finalizada."
echo "PDirect-C:   TCP 80 -> 127.0.0.1:$SSH_PORT ($PDIRECT_UNIT)"
echo "BadVPN:      TCP 7300 ($UDPGW_UNIT)"
echo "HCR:         TCP $HCR_PORT -> 127.0.0.1:$SSH_PORT ($HCR_UNIT, no validado con un cliente real)"
echo "BHTTP:       TCP $BHTTP_PORT -> bhttp-server -> 127.0.0.1:$SSH_PORT (sudo vpsarg-bhttp status)"
echo "Panel: sudo vpsarg"
echo "Controlador: sudo vpsarg-puertos estado"
echo "Cambiar puerto SSH de destino (todos los protocolos): sudo vpsarg-puertos puerto-ssh PUERTO"
echo
echo "El firewall no se modificó: abrí TCP 80, 7300, $HCR_PORT y $BHTTP_PORT en el proveedor si hace falta."
echo "======================================"
