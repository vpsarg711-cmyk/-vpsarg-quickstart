#!/usr/bin/env bash
# VPS ARG QuickStart - componente BHTTP (bhttp-server.service + bhttp-shim.service)
#   cliente -> bhttp-shim (TCP BHTTP_PORT, 8001) -> bhttp-server (127.0.0.1:BHTTP_INTERNAL_PORT, 18022)
#           -> SSH local (127.0.0.1:BHTTP_SSH_PORT)
# Basado en bhttp-install.sh (SuperFlash BHTTP + adaptador bhttp-shim), con los mismos binarios
# verificados por sha256. Servicios sin root. No modifica PDirect-C, UDPGW, HCR, sshd ni el firewall.
set -Eeuo pipefail

SERVER_UNIT="bhttp-server"
SHIM_UNIT="bhttp-shim"
UNITS=("$SERVER_UNIT" "$SHIM_UNIT")
UNIT_DIR="/etc/systemd/system"
CONF="/etc/vpsarg-bhttp.conf"
LIB="/usr/local/lib/vpsarg"
SERVER_BIN="$LIB/bhttp-server"
SHIM_BIN="$LIB/bhttp-shim"
PDIRECT_CONF="/etc/vpsarg-pdirect.conf"
HCR_CONF="/etc/vpsarg-hcr.conf"
SERVICES_CONF="/etc/vpsarg-servicios.conf"
BACKUP_ROOT="/var/backups/vpsarg"
RUN_MARK="/run/vpsarg-instalacion"
INSTALL_RECORD="/etc/vpsarg/instalacion"
MARK="# VPS ARG QuickStart - BHTTP"

# Binarios entregados (bhttp-install.sh): servidor SuperFlash publicado en darnix0/BHTTP con su
# SHA256SUMS.txt, y el adaptador bhttp-shim (archivos entregados por Ema, iguales a los de Zumo).
VERSION="v2.4.1-btun-compat-keepalive"
SERVER_BASE="https://raw.githubusercontent.com/darnix0/BHTTP/main"
SHIM_BASE="https://raw.githubusercontent.com/adri40606941-ui/Zumo/main"
declare -A SHA=(
  [server-amd64]=6c539261249d79dd49f3ef0564bfd08f4c9bfcef7086eea36d645e027200e039
  [server-arm64]=6154c82038496e56973064cd5166642de17313b7f11217991bef9f8805c85b5f
  [shim-amd64]=f4cf6c183a48036519400cf3e8f5625d32248fca6d43d31b6c8401e1e2646d4c
  [shim-arm64]=17b3fafeeb52bdd0a58aa22d38ac3d7bd1ef92d861b1e5c2d9f0cad8c1a518ad
)
DEFAULT_PORT=8001
DEFAULT_INTERNAL=18022

usage() {
  cat <<'EOF'
VPS ARG QuickStart - BHTTP (bhttp-server + bhttp-shim)

Uso:
  sudo vpsarg-bhttp status            estado de ambos servicios y puertos
  sudo vpsarg-bhttp on                inicia BHTTP y lo deja activo al arrancar
  sudo vpsarg-bhttp off               detiene BHTTP y no arranca solo
  sudo vpsarg-bhttp restart           reinicia bhttp-server y bhttp-shim
  sudo vpsarg-bhttp puerto            muestra el puerto externo
  sudo vpsarg-bhttp puerto N          cambia el puerto externo (1024-65535, debe estar libre)
  sudo vpsarg-bhttp logs [N]          últimas N líneas del registro (50 por defecto)
  sudo vpsarg-bhttp recursos          CPU, RAM, PID, tiempo activo y archivos abiertos
  sudo vpsarg-bhttp destino-ssh [N]   muestra o cambia el puerto SSH local de destino
  sudo vpsarg-bhttp instalar          reinstala BHTTP en una VPS ya instalada con token
  sudo vpsarg-bhttp desinstalar       quita BHTTP (no toca PDirect-C, UDPGW, HCR ni SSH)

BHTTP se instala con install.sh, dentro de la instalación completa autorizada por el token.
Para cambiar el destino SSH de todos los protocolos juntos: sudo vpsarg-puertos puerto-ssh N
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

require_root() {
  [[ ${EUID} -eq 0 ]] || { echo "Usá sudo: sudo vpsarg-bhttp $*" >&2; exit 1; }
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

confirm() {
  local answer
  { exec 4</dev/tty; } 2>/dev/null || return 1
  read -r -u 4 -p "$1 [s/N]: " answer || answer=""
  exec 4<&-
  [[ "$answer" =~ ^[sS]$ ]]
}

conf_get() {
  [[ -r "$1" ]] || return 0
  sed -n "s/^$2=\([0-9]\{1,5\}\)$/\1/p" "$1" | tail -n 1
}

installed() {
  [[ -f "$CONF" && -f "$UNIT_DIR/$SERVER_UNIT.service" && -f "$UNIT_DIR/$SHIM_UNIT.service" ]]
}

require_installed() {
  installed || fail "BHTTP no está instalado. Se instala con install.sh (instalación completa)."
}

load_conf() {
  BHTTP_PORT="$(conf_get "$CONF" BHTTP_PORT)"
  BHTTP_INTERNAL_PORT="$(conf_get "$CONF" BHTTP_INTERNAL_PORT)"
  BHTTP_SSH_PORT="$(conf_get "$CONF" BHTTP_SSH_PORT)"
  [[ -n "$BHTTP_PORT" && -n "$BHTTP_INTERNAL_PORT" && -n "$BHTTP_SSH_PORT" ]] \
    || fail "$CONF no contiene BHTTP_PORT, BHTTP_INTERNAL_PORT y BHTTP_SSH_PORT válidos."
}

write_conf() {
  local tmp
  tmp="$(mktemp "${CONF}.XXXXXX")"
  {
    echo "# VPS ARG QuickStart - BHTTP. Editar con: sudo vpsarg-bhttp puerto|destino-ssh"
    printf 'BHTTP_PORT=%s\nBHTTP_INTERNAL_PORT=%s\nBHTTP_SSH_PORT=%s\n' \
      "$BHTTP_PORT" "$BHTTP_INTERNAL_PORT" "$BHTTP_SSH_PORT"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$CONF"
}

main_pid() {
  local pid
  pid="$(systemctl show -p MainPID --value "$1" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && echo "$pid"
}

proc_arg() {
  local pid="$1" opt="$2" prev="" arg
  while IFS= read -r -d '' arg; do
    [[ "$prev" == "$opt" ]] && { echo "$arg"; return 0; }
    prev="$arg"
  done < "/proc/$pid/cmdline"
  return 1
}

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------ binarios
# check_binaries DIR: comprueba DIR/bhttp-server y DIR/bhttp-shim (sha256 fijo y respuesta). No cambia nada.
check_binaries() {
  local dir="$1" a help f out
  a="$(arch)" || fail "Arquitectura no soportada por BHTTP: $(uname -m)."
  for f in server shim; do
    [[ -f "$dir/bhttp-$f" && ! -L "$dir/bhttp-$f" ]] || fail "BHTTP requerido pero falta bhttp-$f."
    [[ "$(sha256sum "$dir/bhttp-$f" | cut -d' ' -f1)" == "${SHA[$f-$a]}" ]] \
      || fail "El sha256 de bhttp-$f no coincide con el entregado (${SHA[$f-$a]})."
    chmod 0755 "$dir/bhttp-$f"
  done
  # Salida en variables: con pipefail, "| grep -q" puede fallar por SIGPIPE si el binario sigue escribiendo.
  out="$(timeout 5 "$dir/bhttp-server" -version 2>&1 || true)"
  grep -qi bhttp <<< "$out" || fail "bhttp-server no responde en esta VPS."
  help="$(timeout 5 "$dir/bhttp-server" -h 2>&1 || true)"
  for f in -listen -port -backend-host -backend-port; do
    grep -q -- "$f" <<< "$help" || fail "bhttp-server no tiene la opción $f."
  done
  out="$(timeout 5 "$dir/bhttp-shim" -h 2>&1 || true)"
  grep -q -- -backend <<< "$out" || fail "bhttp-shim no responde en esta VPS."
}

# descargar DIR: baja los binarios de esta arquitectura a DIR y los verifica. No cambia el sistema.
cmd_descargar() {
  local dir="${1:?Uso: vpsarg-bhttp descargar CARPETA}" a name sums expected
  a="$(arch)" || fail "Arquitectura no soportada por BHTTP: $(uname -m)."
  command -v curl >/dev/null 2>&1 || fail "Falta curl para descargar BHTTP."
  install -d -m 0700 "$dir"
  name="superflash-bhttp-server-${VERSION}-linux-${a}"
  curl -fsSL --retry 3 "$SERVER_BASE/$name" -o "$dir/bhttp-server" \
    || fail "BHTTP requerido pero no se pudo descargar $name."
  curl -fsSL --retry 3 "$SHIM_BASE/bhttp-shim-$a" -o "$dir/bhttp-shim" \
    || fail "BHTTP requerido pero no se pudo descargar bhttp-shim-$a."
  # Verificación original de bhttp-install.sh: el SHA256SUMS.txt publicado debe listar el mismo hash.
  sums="$(curl -fsSL --retry 3 "$SERVER_BASE/SHA256SUMS.txt")" \
    || fail "BHTTP requerido pero no se pudo descargar SHA256SUMS.txt."
  expected="$(awk -v n="$name" '{f=$2; sub(/^\*/,"",f)} f==n{print $1; exit}' <<< "$sums")"
  [[ "$expected" == "${SHA[server-$a]}" ]] \
    || fail "SHA256SUMS.txt publicado no coincide con el hash entregado de $name."
  check_binaries "$dir"
  echo "OK: binarios de BHTTP $VERSION ($a) verificados."
}

# ------------------------------------------------------------------ puertos
ssh_listen_ports() {
  # Puertos de la configuración efectiva de sshd (solo lectura).
  sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un
}

# check_ports EXTERNO INTERNO SSH [RESERVADOS...]: puertos válidos, distintos y libres
# (o usados por los propios servicios de BHTTP). No cambia nada.
check_ports() {
  local ext="$1" int="$2" ssh="$3" r pid hcr
  shift 3
  { valid_port "$ext" && valid_port "$int" && valid_port "$ssh"; } || fail "Puerto no válido."
  (( ext >= 1024 && int >= 1024 )) || fail "Usá puertos entre 1024 y 65535 (BHTTP corre sin privilegios)."
  [[ "$ext" != "$int" ]] || fail "El puerto externo y el interno de BHTTP deben ser distintos."
  hcr="$(conf_get "$HCR_CONF" HCR_PORT)"
  # shellcheck disable=SC2046  # una palabra por puerto
  for r in 80 7300 "$ssh" ${hcr:+"$hcr"} $(ssh_listen_ports) "$@"; do
    [[ "$ext" == "$r" || "$int" == "$r" ]] \
      && fail "El puerto $r ya lo usa otro protocolo (PDirect-C 80, UDPGW 7300, HCR ${hcr:-8880} o SSH). No se cambió nada."
  done
  for r in "$ext:$SHIM_UNIT" "$int:$SERVER_UNIT"; do
    if port_listening "${r%%:*}"; then
      pid="$(main_pid "${r#*:}" || true)"
      if [[ -z "$pid" ]] || ! ss -Hltnp "sport = :${r%%:*}" | grep -q "pid=$pid,"; then
        ss -Hltnp "sport = :${r%%:*}" >&2 || true
        fail "El puerto TCP ${r%%:*} ya está en uso por otro programa. No se cambió nada."
      fi
    fi
  done
}

# Unidades de otro instalador (bhttp-install.sh) con los mismos nombres: no se pisan.
check_foreign_units() {
  local u
  for u in "${UNITS[@]}"; do
    if [[ -f "$UNIT_DIR/$u.service" ]] && ! grep -qxF "$MARK" "$UNIT_DIR/$u.service"; then
      fail "Ya existe $UNIT_DIR/$u.service de otra instalación de BHTTP (bhttp-install.sh). Quitala primero: bash bhttp-install.sh desinstalar"
    fi
  done
}

# ------------------------------------------------------------------ unidades
write_units() {
  local tmp
  tmp="$(mktemp "$UNIT_DIR/$SERVER_UNIT.service.XXXXXX")"
  cat > "$tmp" <<EOF
$MARK
[Unit]
Description=VPS ARG - BHTTP servidor (127.0.0.1, puerto en $CONF -> SSH local)
After=network.target

[Service]
Type=exec
EnvironmentFile=$CONF
ExecStart=$SERVER_BIN -listen 127.0.0.1 -port \${BHTTP_INTERNAL_PORT} -backend-host 127.0.0.1 -backend-port \${BHTTP_SSH_PORT}
Restart=on-failure
RestartSec=2
DynamicUser=yes
NoNewPrivileges=true
LimitNOFILE=65536
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SyslogIdentifier=$SERVER_UNIT

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$UNIT_DIR/$SERVER_UNIT.service"
  tmp="$(mktemp "$UNIT_DIR/$SHIM_UNIT.service.XXXXXX")"
  cat > "$tmp" <<EOF
$MARK
[Unit]
Description=VPS ARG - BHTTP adaptador (TCP externo -> bhttp-server, puertos en $CONF)
After=$SERVER_UNIT.service
Requires=$SERVER_UNIT.service

[Service]
Type=exec
EnvironmentFile=$CONF
ExecStart=$SHIM_BIN -listen 0.0.0.0:\${BHTTP_PORT} -backend 127.0.0.1:\${BHTTP_INTERNAL_PORT}
Restart=on-failure
RestartSec=2
DynamicUser=yes
NoNewPrivileges=true
LimitNOFILE=65536
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SyslogIdentifier=$SHIM_UNIT

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$UNIT_DIR/$SHIM_UNIT.service"
}

services_add() {
  [[ -f "$SERVICES_CONF" ]] || return 0
  local u
  for u in "${UNITS[@]}"; do
    grep -qx "$u" "$SERVICES_CONF" || printf '%s\n' "$u" >> "$SERVICES_CONF"
  done
}

services_remove() {
  [[ -f "$SERVICES_CONF" ]] || return 0
  local tmp
  tmp="$(mktemp "${SERVICES_CONF}.XXXXXX")"
  grep -vx -e "$SERVER_UNIT" -e "$SHIM_UNIT" "$SERVICES_CONF" > "$tmp" || true
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SERVICES_CONF"
}

# Ambos servicios activos, estables y escuchando con la configuración esperada.
health_check() {
  local ext="$1" int="$2" ssh="$3" sp hp sp2 hp2
  sleep 1
  sp="$(main_pid "$SERVER_UNIT" || true)"
  hp="$(main_pid "$SHIM_UNIT" || true)"
  if [[ -z "$sp" || -z "$hp" ]] || ! systemctl is-active --quiet "$SERVER_UNIT" \
     || ! systemctl is-active --quiet "$SHIM_UNIT"; then
    echo "ERROR: bhttp-server o bhttp-shim no está activo." >&2
    return 1
  fi
  sleep 2
  sp2="$(main_pid "$SERVER_UNIT" || true)"
  hp2="$(main_pid "$SHIM_UNIT" || true)"
  [[ "$sp2" == "$sp" && "$hp2" == "$hp" ]] || { echo "ERROR: BHTTP se reinició durante la comprobación." >&2; return 1; }
  ss -Hltnp "src 127.0.0.1 and sport = :$int" | grep -q "pid=$sp," \
    || { echo "ERROR: bhttp-server no escucha en 127.0.0.1:$int." >&2; return 1; }
  ss -Hltnp "sport = :$ext" | grep -q "pid=$hp," || { echo "ERROR: bhttp-shim no escucha en TCP $ext." >&2; return 1; }
  [[ "$(proc_arg "$sp" -backend-port)" == "$ssh" ]] \
    || { echo "ERROR: bhttp-server no apunta a 127.0.0.1:$ssh." >&2; return 1; }
  [[ "$(proc_arg "$hp" -backend)" == "127.0.0.1:$int" ]] \
    || { echo "ERROR: bhttp-shim no apunta a 127.0.0.1:$int." >&2; return 1; }
  return 0
}

show_journal() {
  journalctl -u "$SERVER_UNIT" -u "$SHIM_UNIT" -n 30 --no-pager >&2 || true
}

# ------------------------------------------------------------------ copias de seguridad
FILES=()
set_files() {
  FILES=("$CONF" "$UNIT_DIR/$SERVER_UNIT.service" "$UNIT_DIR/$SHIM_UNIT.service" "$SERVER_BIN" "$SHIM_BIN" "$SERVICES_CONF")
}

backup() {
  local dir f
  dir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-bhttp-$$"
  install -d -m 0700 "$dir"
  set_files
  for f in "${FILES[@]}"; do
    if [[ -e "$f" ]]; then cp -p -- "$f" "$dir/$(basename "$f")"; else : > "$dir/$(basename "$f").no-existia"; fi
  done
  for f in "${UNITS[@]}"; do
    printf '%s %s %s\n' "$f" "$(systemctl is-active "$f" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$f" 2>/dev/null || true)" >> "$dir/estado-unidades"
  done
  echo "$dir"
}

# Vuelve los archivos y las unidades al estado de la copia.
restore() {
  local dir="$1" f u active enabled
  systemctl stop "$SHIM_UNIT" "$SERVER_UNIT" >/dev/null 2>&1 || true
  set_files
  for f in "${FILES[@]}"; do
    if [[ -e "$dir/$(basename "$f").no-existia" ]]; then rm -f -- "$f"
    elif [[ -e "$dir/$(basename "$f")" ]]; then cp -p -- "$dir/$(basename "$f")" "$f"; fi
  done
  systemctl daemon-reload
  while read -r u active enabled; do
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    if [[ "$enabled" == enabled ]]; then
      systemctl enable "$u" >/dev/null 2>&1 || true
    elif [[ -e "$UNIT_DIR/$u.service" ]]; then
      systemctl disable "$u" >/dev/null 2>&1 || true
    fi
    if [[ "$active" == active ]]; then systemctl start "$u" >/dev/null 2>&1 || true; fi
  done < "$dir/estado-unidades"
}

# ------------------------------------------------------------------ comandos
# opciones comunes de verificar e instalar
OPT_DIR="" OPT_PORT="" OPT_INTERNAL="" OPT_SSH="" OPT_RESERVED=()
parse_opts() {
  while (($#)); do
    case "$1" in
      --desde) [[ $# -ge 2 ]] || fail "--desde requiere una carpeta."; OPT_DIR="$2"; shift 2 ;;
      --puerto) [[ $# -ge 2 ]] || fail "--puerto requiere un número."; OPT_PORT="$2"; shift 2 ;;
      --interno) [[ $# -ge 2 ]] || fail "--interno requiere un número."; OPT_INTERNAL="$2"; shift 2 ;;
      --ssh-puerto) [[ $# -ge 2 ]] || fail "--ssh-puerto requiere un número."; OPT_SSH="$2"; shift 2 ;;
      --reservados) [[ $# -ge 2 ]] || fail "--reservados requiere una lista."; read -r -a OPT_RESERVED <<< "$2"; shift 2 ;;
      *) fail "Opción desconocida: $1" ;;
    esac
  done
}

# Valores de la instalación previa o los iniciales, más las opciones. No cambia nada.
prepare() {
  [[ -d /run/systemd/system ]] || fail "systemd no es el sistema de inicio activo."
  local c
  for c in systemctl ss sha256sum timeout install; do
    command -v "$c" >/dev/null 2>&1 || fail "No se encontró el comando $c."
  done
  [[ -n "$OPT_DIR" ]] || fail "Falta --desde CARPETA con los binarios de BHTTP."
  check_binaries "$OPT_DIR"
  check_foreign_units
  if [[ -f "$CONF" ]]; then
    load_conf
  else
    BHTTP_PORT="$DEFAULT_PORT"
    BHTTP_INTERNAL_PORT="$DEFAULT_INTERNAL"
    BHTTP_SSH_PORT="$(conf_get "$PDIRECT_CONF" SSH_PORT)"
    BHTTP_SSH_PORT="${BHTTP_SSH_PORT:-22}"
  fi
  [[ -n "$OPT_PORT" ]] && BHTTP_PORT="$OPT_PORT"
  [[ -n "$OPT_INTERNAL" ]] && BHTTP_INTERNAL_PORT="$OPT_INTERNAL"
  [[ -n "$OPT_SSH" ]] && BHTTP_SSH_PORT="$OPT_SSH"
  # Como bhttp-install.sh: si el externo coincide con el interno predeterminado, el interno pasa a 18023.
  [[ -z "$OPT_INTERNAL" && "$BHTTP_PORT" == "$BHTTP_INTERNAL_PORT" ]] && BHTTP_INTERNAL_PORT=18023
  check_ports "$BHTTP_PORT" "$BHTTP_INTERNAL_PORT" "$BHTTP_SSH_PORT" "${OPT_RESERVED[@]}"
}

cmd_verificar() {
  parse_opts "$@"
  prepare
  echo "OK: BHTTP se puede instalar (TCP $BHTTP_PORT -> 127.0.0.1:$BHTTP_INTERNAL_PORT -> SSH 127.0.0.1:$BHTTP_SSH_PORT). No se cambió nada."
}

# Solo dentro de la instalación autorizada (install.sh) o en una VPS ya instalada con token.
require_authorized() {
  [[ -f "$RUN_MARK" ]] && return 0
  [[ -r "$INSTALL_RECORD" ]] && grep -qx 'estado=instalada' "$INSTALL_RECORD" && return 0
  fail "BHTTP se instala con install.sh y un token de instalación. No se realizaron cambios."
}

cmd_instalar() {
  require_authorized
  local tmp="" bdir
  parse_opts "$@"
  if [[ -z "$OPT_DIR" ]]; then
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$tmp'" EXIT
    cmd_descargar "$tmp"
    OPT_DIR="$tmp"
  fi
  prepare
  bdir="$(backup)"
  echo "Copia de seguridad: $bdir"
  install -d -o root -g root -m 0755 "$LIB"
  install -o root -g root -m 0755 "$OPT_DIR/bhttp-server" "$SERVER_BIN.new"
  install -o root -g root -m 0755 "$OPT_DIR/bhttp-shim" "$SHIM_BIN.new"
  systemctl stop "$SHIM_UNIT" "$SERVER_UNIT" >/dev/null 2>&1 || true
  mv -f "$SERVER_BIN.new" "$SERVER_BIN"
  mv -f "$SHIM_BIN.new" "$SHIM_BIN"
  write_conf
  write_units
  services_add
  systemctl daemon-reload
  systemctl reset-failed "${UNITS[@]}" >/dev/null 2>&1 || true
  if ! systemctl enable --now "${UNITS[@]}" >/dev/null 2>&1 \
     || ! health_check "$BHTTP_PORT" "$BHTTP_INTERNAL_PORT" "$BHTTP_SSH_PORT"; then
    show_journal
    restore "$bdir"
    fail "BHTTP no arrancó correctamente; se restauró el estado anterior."
  fi
  echo "OK: BHTTP activo, sin root: TCP $BHTTP_PORT -> 127.0.0.1:$BHTTP_INTERNAL_PORT -> SSH 127.0.0.1:$BHTTP_SSH_PORT ($VERSION)."
  echo "El firewall no se modificó: abrí TCP $BHTTP_PORT en el proveedor si hace falta."
}

unit_state() {
  local s
  s="$(systemctl is-active "$1" 2>/dev/null || true)"
  echo "${s:-desconocido}"
}

cmd_status() {
  require_installed
  load_conf
  local ok=1 u
  for u in "${UNITS[@]}"; do
    printf '%-13s %-10s arranque: %s\n' "$u" "$(unit_state "$u")" "$(systemctl is-enabled "$u" 2>/dev/null || echo desconocido)"
    systemctl is-active --quiet "$u" || ok=0
  done
  port_listening "$BHTTP_PORT" || ok=0
  echo "Puerto externo:  TCP $BHTTP_PORT (bhttp-shim, todas las interfaces IPv4)"
  echo "Puerto interno:  127.0.0.1:$BHTTP_INTERNAL_PORT (bhttp-server)"
  printf 'Destino SSH:     127.0.0.1:%s (' "$BHTTP_SSH_PORT"
  if port_open "$BHTTP_SSH_PORT"; then echo "responde)"; else echo "NO responde)"; fi
  echo "Conexiones TCP:  $(ss -Htn state established "( sport = :$BHTTP_PORT )" | wc -l)"
  if ((ok)); then echo "BHTTP: ACTIVO"; else echo "BHTTP: INACTIVO"; fi
}

cmd_on() {
  require_installed
  load_conf
  systemctl enable --now "${UNITS[@]}" >/dev/null 2>&1 || true
  if health_check "$BHTTP_PORT" "$BHTTP_INTERNAL_PORT" "$BHTTP_SSH_PORT"; then
    echo "BHTTP: ACTIVO en TCP $BHTTP_PORT (arranca solo al reiniciar)."
  else
    show_journal
    fail "BHTTP no arrancó correctamente."
  fi
}

cmd_off() {
  require_installed
  systemctl disable --now "$SHIM_UNIT" "$SERVER_UNIT" >/dev/null 2>&1 || true
  echo "BHTTP: INACTIVO (no arranca solo al reiniciar)."
}

cmd_restart() {
  require_installed
  load_conf
  systemctl restart "$SERVER_UNIT" "$SHIM_UNIT"
  if health_check "$BHTTP_PORT" "$BHTTP_INTERNAL_PORT" "$BHTTP_SSH_PORT"; then
    echo "BHTTP reiniciado: ACTIVO en TCP $BHTTP_PORT."
  else
    show_journal
    fail "BHTTP no arrancó correctamente."
  fi
}

# apply_change CLAVE NUEVO: escribe la configuración, reinicia solo si estaba activo y restaura si falla.
apply_change() {
  local key="$1" new="$2" old
  old="${!key}"
  printf -v "$key" '%s' "$new"
  write_conf
  if ! systemctl is-active --quiet "$SERVER_UNIT" && ! systemctl is-active --quiet "$SHIM_UNIT"; then
    echo "BHTTP está detenido; el cambio se aplicará al iniciarlo."
    return 0
  fi
  if systemctl restart "$SERVER_UNIT" "$SHIM_UNIT" \
     && health_check "$BHTTP_PORT" "$BHTTP_INTERNAL_PORT" "$BHTTP_SSH_PORT"; then
    return 0
  fi
  show_journal
  printf -v "$key" '%s' "$old"
  write_conf
  systemctl reset-failed "${UNITS[@]}" >/dev/null 2>&1 || true
  systemctl restart "$SERVER_UNIT" "$SHIM_UNIT" || true
  fail "BHTTP no funcionó con $key=$new; se restauró $old."
}

cmd_puerto() {
  require_installed
  load_conf
  if (($# == 0)); then
    echo "BHTTP escucha en TCP $BHTTP_PORT"
    return 0
  fi
  local new="$1"
  valid_port "$new" || fail "Puerto no válido: $new"
  [[ "$new" == "$BHTTP_PORT" ]] && { echo "BHTTP ya escucha en TCP $new. Sin cambios."; return 0; }
  check_ports "$new" "$BHTTP_INTERNAL_PORT" "$BHTTP_SSH_PORT"
  local old="$BHTTP_PORT"
  apply_change BHTTP_PORT "$new"
  echo "Puerto de BHTTP: $old -> $new. Abrí TCP $new en el proveedor si hace falta."
}

cmd_destino_ssh() {
  require_installed
  load_conf
  if (($# == 0)); then
    echo "BHTTP reenvía a 127.0.0.1:$BHTTP_SSH_PORT"
    return 0
  fi
  local new="$1" old="$BHTTP_SSH_PORT"
  valid_port "$new" || fail "Puerto no válido: $new"
  [[ "$new" == "$old" ]] && { echo "BHTTP ya reenvía a 127.0.0.1:$new. Sin cambios."; return 0; }
  [[ "$new" == "$BHTTP_PORT" || "$new" == "$BHTTP_INTERNAL_PORT" || "$new" == 80 || "$new" == 7300 ]] \
    && fail "El puerto $new no puede ser el destino SSH."
  apply_change BHTTP_SSH_PORT "$new"
  echo "Destino SSH de BHTTP: 127.0.0.1:$old -> 127.0.0.1:$new."
}

cmd_logs() {
  local n="${1:-50}"
  [[ "$n" =~ ^[1-9][0-9]{0,3}$ ]] || fail "Cantidad de líneas no válida: $n"
  journalctl -u "$SERVER_UNIT" -u "$SHIM_UNIT" -n "$n" --no-pager
}

cmd_recursos() {
  require_installed
  local u pid
  printf '%-13s %-8s %-6s %-6s %-10s %-12s %s\n' SERVICIO PID CPU% MEM% "RSS(kB)" ACTIVO ARCHIVOS
  for u in "${UNITS[@]}"; do
    pid="$(main_pid "$u" || true)"
    if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then
      printf '%-13s %s\n' "$u" "detenido"
      continue
    fi
    printf '%-13s %-8s %-6s %-6s %-10s %-12s %s\n' "$u" "$pid" \
      "$(ps -o %cpu= -p "$pid" | tr -d ' ')" "$(ps -o %mem= -p "$pid" | tr -d ' ')" \
      "$(ps -o rss= -p "$pid" | tr -d ' ')" "$(ps -o etime= -p "$pid" | tr -d ' ')" \
      "$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
  done
}

cmd_desinstalar() {
  if ! [[ -e "$CONF" || -e "$SERVER_BIN" || -e "$SHIM_BIN" ]] \
     && ! grep -qxF "$MARK" "$UNIT_DIR/$SERVER_UNIT.service" 2>/dev/null; then
    echo "BHTTP no está instalado. Nada que hacer."
    return 0
  fi
  check_foreign_units
  local bdir
  bdir="$(backup)"
  echo "Copia de seguridad: $bdir"
  systemctl disable --now "$SHIM_UNIT" "$SERVER_UNIT" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_DIR/$SERVER_UNIT.service" "$UNIT_DIR/$SHIM_UNIT.service" "$SERVER_BIN" "$SHIM_BIN" "$CONF"
  services_remove
  systemctl daemon-reload
  systemctl reset-failed "${UNITS[@]}" >/dev/null 2>&1 || true
  echo "BHTTP desinstalado. No se tocaron PDirect-C, UDPGW, HCR ni SSH."
}

main() {
  local action="${1:-}"
  case "$action" in
    status|estado) (($# == 1)) || { usage; exit 1; }; require_root "$@"; cmd_status ;;
    on) (($# == 1)) || { usage; exit 1; }; require_root "$@"; cmd_on ;;
    off) (($# == 1)) || { usage; exit 1; }; require_root "$@"; cmd_off ;;
    restart) (($# == 1)) || { usage; exit 1; }; require_root "$@"; cmd_restart ;;
    puerto) (($# <= 2)) || { usage; exit 1; }; require_root "$@"; shift; cmd_puerto "$@" ;;
    destino-ssh) (($# <= 2)) || { usage; exit 1; }; require_root "$@"; shift; cmd_destino_ssh "$@" ;;
    logs) (($# <= 2)) || { usage; exit 1; }; require_root "$@"; shift; cmd_logs "$@" ;;
    recursos) (($# == 1)) || { usage; exit 1; }; require_root "$@"; cmd_recursos ;;
    descargar) (($# == 2)) || { usage; exit 1; }; cmd_descargar "$2" ;;
    verificar) require_root "$@"; shift; cmd_verificar "$@" ;;
    instalar) require_root "$@"; shift; cmd_instalar "$@" ;;
    desinstalar) (($# == 1)) || { usage; exit 1; }; require_root "$@"; cmd_desinstalar ;;
    -h|--help|ayuda) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
