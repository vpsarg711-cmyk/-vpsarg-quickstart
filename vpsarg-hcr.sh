#!/usr/bin/env bash
# VPS ARG QuickStart - componente HCR (hcr-8880.service)
# Instala y administra HCR como servicio independiente, sin root.
# No modifica PDirect-C, UDPGW, sshd ni el firewall.
# Las variables HCR_* se leen indirectamente con ${!key} en write_conf.
# shellcheck disable=SC2034
set -Eeuo pipefail

UNIT="hcr-8880"
UNIT_FILE="/etc/systemd/system/${UNIT}.service"
CONF="/etc/vpsarg-hcr.conf"
BIN="/usr/local/lib/vpsarg/hcr-server"
SOURCE_DEFAULT="/opt/hcr/hcr-server"
# sha256 del hcr-server 0.0.3 Patch 1 entregado (DOC-20260908-WA0023).
SHA256_DEFAULT="68a66ed49750965680315a60ce05260cdbb77c2b86b3a80938844cb4855fa085"
PDIRECT_CONF="/etc/vpsarg-pdirect.conf"
SERVICES_CONF="/etc/vpsarg-servicios.conf"
BACKUP_ROOT="/var/backups/vpsarg"
VENDOR_UNIT="hcr-server.service"
RESERVED_PORTS=(80 7300)

# Valores iniciales. Los límites no se aumentan hasta probar un cliente compatible.
DEFAULT_PORT=8880
DEFAULT_TRANSPORT=plain
DEFAULT_MAX_SESSIONS=32
DEFAULT_MAX_SESSIONS_PER_IP=16
DEFAULT_MAX_CONNECTIONS=2048
DEFAULT_MAX_DOWNLOAD_FRAME=6144
DEFAULT_DOWNLOAD_POLL_TIMEOUT=8s

KEYS=(HCR_PORT HCR_SSH_PORT HCR_TRANSPORT HCR_MAX_SESSIONS HCR_MAX_SESSIONS_PER_IP
      HCR_MAX_CONNECTIONS HCR_MAX_DOWNLOAD_FRAME HCR_DOWNLOAD_POLL_TIMEOUT)

usage() {
  cat <<'EOF'
VPS ARG QuickStart - HCR (servicio hcr-8880)

Uso:
  sudo vpsarg-hcr instalar [--binario RUTA] [--puerto N] [--ssh-puerto N] [--sha256 HASH]
  sudo vpsarg-hcr estado
  sudo vpsarg-hcr iniciar | detener | reiniciar
  sudo vpsarg-hcr puerto              (muestra el puerto de escucha)
  sudo vpsarg-hcr puerto N            (cambia el puerto de escucha, 1024-65535)
  sudo vpsarg-hcr destino-ssh         (muestra el puerto SSH local de destino)
  sudo vpsarg-hcr destino-ssh N       (cambia el destino a 127.0.0.1:N)
  sudo vpsarg-hcr desinstalar

instalar copia el binario (por defecto /opt/hcr/hcr-server, verificado por sha256)
a /usr/local/lib/vpsarg/ y crea hcr-8880.service con un usuario sin privilegios.
Puerto inicial: 8880, transporte plain, 32 sesiones globales y 16 por IP.
destino-ssh no cambia el puerto de sshd: indica dónde escucha SSH realmente.
Para cambiar el destino de PDirect-C y HCR juntos: sudo vpsarg-puertos puerto-ssh N
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

require_root() {
  [[ ${EUID} -eq 0 ]] || { echo "Usá sudo: sudo vpsarg-hcr $*" >&2; exit 1; }
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

installed() {
  [[ -f "$UNIT_FILE" && -f "$CONF" ]]
}

require_installed() {
  installed || fail "HCR no está instalado (falta $UNIT_FILE o $CONF). Usá: sudo vpsarg-hcr instalar"
}

# Lee KEY=valor del archivo de configuración sin ejecutarlo.
conf_get() {
  sed -n "s/^$1=\([A-Za-z0-9.:_-]*\)$/\1/p" "$CONF" | tail -n 1
}

main_pid() {
  local pid
  pid="$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && echo "$pid"
}

# Argumento de una opción en la línea de comandos real del proceso.
proc_arg() {
  local pid="$1" opt="$2" prev="" arg
  while IFS= read -r -d '' arg; do
    if [[ "$prev" == "$opt" ]]; then
      echo "$arg"
      return 0
    fi
    prev="$arg"
  done < "/proc/$pid/cmdline"
  return 1
}

ssh_port_from_pdirect() {
  [[ -r "$PDIRECT_CONF" ]] || return 1
  local p
  p="$(sed -n 's/^SSH_PORT=\([0-9]\{1,5\}\)$/\1/p' "$PDIRECT_CONF" | tail -n 1)"
  [[ -n "$p" ]] && echo "$p"
}

# Puerto libre o usado por el propio hcr-8880.
check_port_available() {
  local port="$1" ssh_port="$2" pid r
  (( port >= 1024 )) || fail "Usá un puerto entre 1024 y 65535 (HCR corre sin privilegios)."
  for r in "${RESERVED_PORTS[@]}" "$ssh_port"; do
    [[ "$port" == "$r" ]] && fail "El puerto $port está reservado (PDirect-C 80, UDPGW 7300, SSH $ssh_port)."
  done
  if port_listening "$port"; then
    pid="$(main_pid || true)"
    if [[ -z "$pid" ]] || ! ss -Hltnp "sport = :$port" | grep -q "pid=$pid,"; then
      ss -Hltnp "sport = :$port" >&2 || true
      fail "El puerto TCP $port ya está en uso por otro programa. No se detuvo nada."
    fi
  fi
}

write_conf() {
  # write_conf ARCHIVO: escribe los valores actuales de las variables HCR_*.
  local dest="$1" tmp key
  tmp="$(mktemp "${dest}.XXXXXX")"
  {
    echo "# VPS ARG QuickStart - HCR. Editar con: sudo vpsarg-hcr puerto|destino-ssh"
    for key in "${KEYS[@]}"; do
      printf '%s=%s\n' "$key" "${!key}"
    done
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dest"
}

load_conf() {
  local key value
  for key in "${KEYS[@]}"; do
    value="$(conf_get "$key")"
    [[ -n "$value" ]] || fail "$CONF no contiene un valor válido para $key."
    printf -v "$key" '%s' "$value"
  done
}

write_unit() {
  local tmp
  tmp="$(mktemp "${UNIT_FILE}.XXXXXX")"
  cat > "$tmp" <<EOF
[Unit]
Description=VPS ARG - HCR (puerto en $CONF)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
EnvironmentFile=$CONF
ExecStart=$BIN -listen :\${HCR_PORT} -target 127.0.0.1:\${HCR_SSH_PORT} -transport \${HCR_TRANSPORT} -max-sessions \${HCR_MAX_SESSIONS} -max-sessions-per-ip \${HCR_MAX_SESSIONS_PER_IP} -max-connections \${HCR_MAX_CONNECTIONS} -max-download-frame \${HCR_MAX_DOWNLOAD_FRAME} -download-poll-timeout \${HCR_DOWNLOAD_POLL_TIMEOUT}
Restart=on-failure
RestartSec=5s
DynamicUser=yes
CapabilityBoundingSet=
AmbientCapabilities=
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LimitNOFILE=4096
TasksMax=512
MemoryMax=384M
SyslogIdentifier=$UNIT

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$UNIT_FILE"
}

backup() {
  local dir
  dir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-hcr"
  install -d -m 0700 "$dir"
  local f
  for f in "$CONF" "$UNIT_FILE" "$SERVICES_CONF"; do
    [[ -e "$f" ]] && cp -p -- "$f" "$dir/"
  done
  echo "$dir"
}

services_add() {
  [[ -f "$SERVICES_CONF" ]] || return 0
  grep -qx "$UNIT" "$SERVICES_CONF" || printf '%s\n' "$UNIT" >> "$SERVICES_CONF"
}

services_remove() {
  [[ -f "$SERVICES_CONF" ]] || return 0
  local tmp
  tmp="$(mktemp "${SERVICES_CONF}.XXXXXX")"
  grep -vx "$UNIT" "$SERVICES_CONF" > "$tmp" || true
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SERVICES_CONF"
}

# Comprueba que el servicio está activo, estable y escuchando con la configuración esperada.
health_check() {
  local port="$1" ssh_port="$2" pid pid2
  sleep 1
  pid="$(main_pid || true)"
  if [[ -z "$pid" ]] || ! systemctl is-active --quiet "$UNIT"; then
    echo "ERROR: $UNIT no está activo." >&2
    return 1
  fi
  sleep 2
  pid2="$(main_pid || true)"
  [[ "$pid2" == "$pid" ]] || { echo "ERROR: $UNIT se reinició durante la comprobación." >&2; return 1; }
  ss -Hltnp "sport = :$port" | grep -q "pid=$pid," || { echo "ERROR: $UNIT no escucha en TCP $port." >&2; return 1; }
  [[ "$(proc_arg "$pid" -target)" == "127.0.0.1:$ssh_port" ]] || { echo "ERROR: $UNIT no apunta a 127.0.0.1:$ssh_port." >&2; return 1; }
  return 0
}

show_journal() {
  journalctl -u "$UNIT" -n 30 --no-pager >&2 || true
}

cmd_instalar() {
  local source="$SOURCE_DEFAULT" sha="$SHA256_DEFAULT" port="" ssh_port="" arch actual version
  while (($#)); do
    case "$1" in
      --binario) [[ $# -ge 2 ]] || fail "--binario requiere una ruta."; source="$2"; shift 2 ;;
      --puerto) [[ $# -ge 2 ]] || fail "--puerto requiere un número."; port="$2"; shift 2 ;;
      --ssh-puerto) [[ $# -ge 2 ]] || fail "--ssh-puerto requiere un número."; ssh_port="$2"; shift 2 ;;
      --sha256) [[ $# -ge 2 ]] || fail "--sha256 requiere un valor."; sha="${2,,}"; shift 2 ;;
      *) fail "Opción desconocida: $1" ;;
    esac
  done

  # ---- comprobaciones (no cambian nada)
  [[ -d /run/systemd/system ]] || fail "systemd no es el sistema de inicio activo."
  for c in systemctl ss sha256sum timeout install; do
    command -v "$c" >/dev/null 2>&1 || fail "No se encontró el comando $c."
  done
  arch="$(uname -m)"
  [[ "$arch" == "x86_64" ]] || fail "El binario HCR entregado es solo para x86_64; este sistema es $arch."
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "--sha256 debe tener 64 caracteres hexadecimales."
  [[ -f "$source" && ! -L "$source" ]] || fail "No existe el binario $source (copialo por SFTP a /opt/hcr/)."
  [[ "$(stat -c %u "$source")" == "0" ]] || fail "$source debe pertenecer a root (chown root:root)."
  (( (8#$(stat -c %a "$source") & 8#022) == 0 )) || fail "$source no debe ser escribible por grupo u otros."
  actual="$(sha256sum "$source" | cut -d' ' -f1)"
  [[ "$actual" == "$sha" ]] || fail "sha256 de $source no coincide (esperado $sha, obtenido $actual). Si es otra versión, indicá --sha256."
  version="$(timeout 5 "$source" -version 2>/dev/null || true)"
  [[ "$version" =~ ^hcr-server\ version\ [0-9]+\.[0-9]+\.[0-9]+(\ -\ Patch\ [1-9][0-9]*)?$ ]] \
    || fail "$source no respondió a -version como hcr-server."
  (( $(df -Pk /usr/local | awk 'NR==2{print $4}') > 20480 )) || fail "Hay menos de 20 MB libres en /usr/local."

  if systemctl cat "$VENDOR_UNIT" >/dev/null 2>&1; then
    echo "AVISO: existe $VENDOR_UNIT (instalador del proveedor). No se modifica."
    echo "       Si usa el mismo puerto, la instalación se detendrá en la comprobación de puerto."
  fi

  # Valores: los de la instalación previa, si existe; si no, los iniciales.
  if [[ -f "$CONF" ]]; then
    load_conf
    echo "Se conserva la configuración existente de $CONF."
  else
    HCR_PORT="$DEFAULT_PORT"
    HCR_SSH_PORT="$(ssh_port_from_pdirect || echo 22)"
    HCR_TRANSPORT="$DEFAULT_TRANSPORT"
    HCR_MAX_SESSIONS="$DEFAULT_MAX_SESSIONS"
    HCR_MAX_SESSIONS_PER_IP="$DEFAULT_MAX_SESSIONS_PER_IP"
    HCR_MAX_CONNECTIONS="$DEFAULT_MAX_CONNECTIONS"
    HCR_MAX_DOWNLOAD_FRAME="$DEFAULT_MAX_DOWNLOAD_FRAME"
    HCR_DOWNLOAD_POLL_TIMEOUT="$DEFAULT_DOWNLOAD_POLL_TIMEOUT"
  fi
  [[ -n "$port" ]] && HCR_PORT="$port"
  [[ -n "$ssh_port" ]] && HCR_SSH_PORT="$ssh_port"
  valid_port "$HCR_PORT" || fail "Puerto no válido: $HCR_PORT"
  valid_port "$HCR_SSH_PORT" || fail "Puerto SSH no válido: $HCR_SSH_PORT"
  check_port_available "$HCR_PORT" "$HCR_SSH_PORT"

  if port_open "$HCR_SSH_PORT"; then
    echo "OK: hay un servicio escuchando en 127.0.0.1:$HCR_SSH_PORT."
  else
    echo "AVISO: no hay ningún servicio escuchando en 127.0.0.1:$HCR_SSH_PORT."
    confirm "¿Continuar con el destino SSH $HCR_SSH_PORT?" || fail "Cancelado. No se realizaron cambios."
  fi

  # ---- instalación
  local bdir
  bdir="$(backup)"
  echo "Copia de seguridad: $bdir"
  install -d -o root -g root -m 0755 "$(dirname "$BIN")"
  install -o root -g root -m 0755 "$source" "${BIN}.new"
  mv -f "${BIN}.new" "$BIN"
  write_conf "$CONF"
  write_unit
  services_add
  systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null 2>&1
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  if ! systemctl restart "$UNIT" || ! health_check "$HCR_PORT" "$HCR_SSH_PORT"; then
    show_journal
    fail "HCR no arrancó correctamente. Para quitarlo: sudo vpsarg-hcr desinstalar"
  fi
  echo "OK: $UNIT activo, sin root, escuchando en TCP $HCR_PORT -> 127.0.0.1:$HCR_SSH_PORT ($version)."
  echo "Límites: $HCR_MAX_SESSIONS sesiones globales, $HCR_MAX_SESSIONS_PER_IP por IP, $HCR_MAX_CONNECTIONS conexiones TCP."
  echo "El firewall no se modificó: abrí TCP $HCR_PORT en el proveedor si hace falta."
}

cmd_estado() {
  require_installed
  load_conf
  echo "===== $UNIT ====="
  systemctl --no-pager --full status "$UNIT" || true
  echo
  local pid
  pid="$(main_pid || true)"
  echo "Puerto de escucha:  TCP $HCR_PORT"
  printf 'Destino SSH:        127.0.0.1:%s (' "$HCR_SSH_PORT"
  if port_open "$HCR_SSH_PORT"; then echo "responde)"; else echo "NO responde)"; fi
  echo "Transporte:         $HCR_TRANSPORT"
  echo "Límites:            -max-sessions $HCR_MAX_SESSIONS, -max-sessions-per-ip $HCR_MAX_SESSIONS_PER_IP, -max-connections $HCR_MAX_CONNECTIONS"
  if [[ -n "$pid" ]]; then
    echo "Usuario del proceso: $(ps -o user= -p "$pid") (PID $pid)"
    echo "Memoria:            $(awk '/VmRSS/{print $2" "$3}' "/proc/$pid/status")"
    echo "Descriptores:       $(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 | wc -l)"
    echo "Conexiones TCP:     $(ss -Htn state established "( sport = :$HCR_PORT )" | wc -l)"
  fi
  echo "Versión:            $("$BIN" -version 2>/dev/null || echo desconocida)"
}

cmd_puerto() {
  require_installed
  load_conf
  if (($# == 0)); then
    echo "HCR escucha en TCP $HCR_PORT"
    return 0
  fi
  local new="$1" old="$HCR_PORT"
  valid_port "$new" || fail "Puerto no válido: $new"
  [[ "$new" == "$old" ]] && { echo "HCR ya escucha en TCP $new. Sin cambios."; return 0; }
  check_port_available "$new" "$HCR_SSH_PORT"
  apply_change HCR_PORT "$new" "$old" "$new" "$HCR_SSH_PORT"
  echo "Puerto de HCR: $old -> $new. Abrí TCP $new en el proveedor si hace falta."
}

cmd_destino_ssh() {
  require_installed
  load_conf
  if (($# == 0)); then
    echo "HCR reenvía a 127.0.0.1:$HCR_SSH_PORT"
    return 0
  fi
  local new="$1" old="$HCR_SSH_PORT"
  valid_port "$new" || fail "Puerto no válido: $new"
  [[ "$new" == "$old" ]] && { echo "HCR ya reenvía a 127.0.0.1:$new. Sin cambios."; return 0; }
  for r in "${RESERVED_PORTS[@]}" "$HCR_PORT"; do
    [[ "$new" == "$r" ]] && fail "El puerto $new no puede ser el destino SSH."
  done
  apply_change HCR_SSH_PORT "$new" "$old" "$HCR_PORT" "$new"
  echo "Destino SSH de HCR: 127.0.0.1:$old -> 127.0.0.1:$new."
}

# apply_change CLAVE NUEVO ANTERIOR PUERTO_ESPERADO SSH_ESPERADO
# Escribe la configuración, reinicia solo hcr-8880 si está activo y restaura el valor anterior si falla.
apply_change() {
  local key="$1" new="$2" old="$3" exp_port="$4" exp_ssh="$5"
  printf -v "$key" '%s' "$new"
  write_conf "$CONF"
  if ! systemctl is-active --quiet "$UNIT"; then
    echo "$UNIT está detenido; el cambio se aplicará al iniciarlo."
    return 0
  fi
  if systemctl restart "$UNIT" && health_check "$exp_port" "$exp_ssh"; then
    return 0
  fi
  show_journal
  printf -v "$key" '%s' "$old"
  write_conf "$CONF"
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  systemctl restart "$UNIT" || true
  fail "$UNIT no funcionó con $key=$new; se restauró $old."
}

cmd_desinstalar() {
  if ! [[ -e "$UNIT_FILE" || -e "$CONF" || -e "$BIN" ]]; then
    echo "HCR no está instalado. Nada que hacer."
    return 0
  fi
  local bdir
  bdir="$(backup)"
  echo "Copia de seguridad: $bdir"
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_FILE" "$BIN" "$CONF"
  rmdir --ignore-fail-on-non-empty "$(dirname "$BIN")" 2>/dev/null || true
  services_remove
  systemctl daemon-reload
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  echo "HCR desinstalado. No se tocaron PDirect-C, UDPGW, SSH ni /opt/hcr."
}

main() {
  local action="${1:-}"
  case "$action" in
    instalar) require_root "$@"; shift; cmd_instalar "$@" ;;
    estado) (($# == 1)) || { usage; exit 1; }; require_root "$@"; cmd_estado ;;
    iniciar|detener|reiniciar)
      (($# == 1)) || { usage; exit 1; }
      require_root "$@"
      require_installed
      load_conf
      case "$action" in
        iniciar) systemctl start "$UNIT" ;;
        detener) systemctl stop "$UNIT" ;;
        reiniciar) systemctl restart "$UNIT" ;;
      esac
      if [[ "$action" == detener ]]; then
        printf '%s: ' "$UNIT"; systemctl is-active "$UNIT" || true
      elif health_check "$HCR_PORT" "$HCR_SSH_PORT"; then
        echo "$UNIT: activo en TCP $HCR_PORT -> 127.0.0.1:$HCR_SSH_PORT"
      else
        show_journal
        fail "$UNIT no arrancó correctamente."
      fi
      ;;
    puerto) (($# <= 2)) || { usage; exit 1; }; require_root "$@"; shift; cmd_puerto "$@" ;;
    destino-ssh) (($# <= 2)) || { usage; exit 1; }; require_root "$@"; shift; cmd_destino_ssh "$@" ;;
    desinstalar) (($# == 1)) || { usage; exit 1; }; require_root "$@"; cmd_desinstalar ;;
    -h|--help|ayuda) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
