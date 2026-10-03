#!/usr/bin/env bash
# VPS ARG QuickStart - panel de administración (terminal)
# Es un script interactivo: no deja ningún proceso en segundo plano.
# Todas las acciones pasan por vpsarg-puertos, vpsarg-hcr y vpsarg-usuarios, que validan y revierten.
# No modifica sshd ni /etc/ssh/sshd_config, el firewall, el código, los argumentos
# ni el puerto de PDirect-C, ni la configuración o los límites de UDPGW.
set -Euo pipefail

SERVICES_CONF="/etc/vpsarg-servicios.conf"
PDIRECT_CONF="/etc/vpsarg-pdirect.conf"
HCR_CONF="/etc/vpsarg-hcr.conf"
PUERTOS="/usr/local/sbin/vpsarg-puertos"
HCR="/usr/local/sbin/vpsarg-hcr"
USUARIOS="/usr/local/sbin/vpsarg-usuarios"
BACKUP_ROOT="/var/backups/vpsarg"
LOG_TAG="vpsarg-panel"
KNOWN_UNITS=(pdirect-80 udpgw-7300 hcr-8880)
# Protocolos que muestra el panel. SSH es solo de lectura.
PROTOCOLS=(pdirect-80 udpgw-7300 hcr-8880 ssh)
USERS_GROUP="vpsarg-usuarios"
# AUTO: cuentas que abren el panel al iniciar sesión y el disparador que lo hace.
LIMITS_FILE="/etc/vpsarg/limites"
AUTO_CONF="/etc/vpsarg-auto.conf"
AUTO_HOOK="/etc/profile.d/vpsarg-auto.sh"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
else
  B=""; G=""; R=""; Y=""; C=""; N=""
fi

usage() {
  cat <<'EOF'
VPS ARG QuickStart - panel

Uso:
  sudo vpsarg                 menú interactivo
  sudo vpsarg estado          estado de los servicios
  sudo vpsarg protocolos      estado, puerto y PID de cada protocolo (incluye SSH)
  sudo vpsarg sistema         CPU, RAM, disco, uptime, protocolos y usuarios conectados
  sudo vpsarg puertos         puertos configurados y en escucha
  sudo vpsarg conexiones      conexiones TCP establecidas por servicio
  sudo vpsarg recursos        memoria, CPU y descriptores de cada servicio
  sudo vpsarg ssh             autenticación de SSH (solo lectura)
  sudo vpsarg usuarios        cuentas SSH de los usuarios
  sudo vpsarg auto [on|off]   abrir el panel al iniciar sesión con esta cuenta (AUTO)
EOF
}

# ------------------------------------------------------------------ utilidades
log_action() {
  # Toda acción que cambia algo queda en el journal: journalctl -t vpsarg-panel
  logger -t "$LOG_TAG" -- "admin=${SUDO_USER:-root} $*" 2>/dev/null || true
}

pause() {
  local _
  echo
  read -r -p "Enter para continuar..." _ || true
}

ask() {
  REPLY=""
  read -r -p "$1" REPLY || REPLY=""
}

confirm() {
  ask "$1 [s/N]: "
  [[ "$REPLY" =~ ^[sS]$ ]]
}

valid_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

conf_value() {
  # conf_value ARCHIVO CLAVE: lee un valor simple sin ejecutar el archivo
  [[ -r "$1" ]] || return 1
  sed -n "s/^$2=\([A-Za-z0-9.:_-]*\)$/\1/p" "$1" | tail -n 1
}

unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

hcr_installed() {
  [[ -x "$HCR" && -r "$HCR_CONF" ]] && unit_exists hcr-8880
}

service_name() {
  case "$1" in
    pdirect-80) echo "PDirect-C" ;;
    udpgw-7300) echo "BadVPN UDPGW" ;;
    hcr-8880) echo "HCR" ;;
    *) echo "$1" ;;
  esac
}

service_port() {
  case "$1" in
    pdirect-80) echo 80 ;;
    udpgw-7300) echo 7300 ;;
    hcr-8880) conf_value "$HCR_CONF" HCR_PORT ;;
    *) return 1 ;;
  esac
}

listening() {
  [[ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]]
}

# ACTIVO, DETENIDO, ERROR, INICIANDO o NO INSTALADO.
service_state() {
  local unit="$1" state port
  unit_exists "$unit" || { echo "NO INSTALADO"; return; }
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$state" in
    active)
      port="$(service_port "$unit" || true)"
      if [[ -n "$port" ]] && ! listening "$port"; then echo "ERROR"; else echo "ACTIVO"; fi
      ;;
    inactive) echo "DETENIDO" ;;
    activating|reloading) echo "INICIANDO" ;;
    *) echo "ERROR" ;;
  esac
}

paint_state() {
  case "$1" in
    ACTIVO) printf '%s%s%s' "$G" "$1" "$N" ;;
    ERROR) printf '%s%s%s' "$R" "$1" "$N" ;;
    *) printf '%s%s%s' "$Y" "$1" "$N" ;;
  esac
}

ssh_listen_ports() {
  # Puertos de la configuración efectiva de sshd (solo lectura).
  sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ' | sed 's/ $//'
}

conn_count() {
  ss -Htn state established "( sport = :$1 )" 2>/dev/null | wc -l
}

unit_pid() {
  local pid
  pid="$(systemctl show -p MainPID --value "$1" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && echo "$pid"
  return 0
}

# SSH (solo lectura). En Ubuntu 24.04 puede arrancar por socket (ssh.socket):
# ssh.service queda inactivo hasta la primera conexión.
ssh_mode() {
  if [[ "$(systemctl is-active ssh.socket 2>/dev/null)" == active ]]; then
    echo "ssh.socket (activación por socket)"
  else
    echo "ssh.service"
  fi
}

# ACTIVO, DETENIDO, ERROR o NO INSTALADO.
ssh_state() {
  local svc sock p ports any=0
  unit_exists ssh.service || unit_exists ssh.socket || { echo "NO INSTALADO"; return; }
  svc="$(systemctl is-active ssh.service 2>/dev/null || true)"
  sock="$(systemctl is-active ssh.socket 2>/dev/null || true)"
  if [[ "$svc" == active || "$sock" == active ]]; then
    ports="$(ssh_listen_ports)"
    for p in $ports; do listening "$p" && any=1; done
    if [[ -n "$ports" ]] && ((any == 0)); then echo "ERROR"; else echo "ACTIVO"; fi
  elif [[ "$svc" == failed || "$sock" == failed ]]; then
    echo "ERROR"
  else
    echo "DETENIDO"
  fi
}

udpgw_arg() {
  # Lee un argumento de la unidad de UDPGW sin modificarla.
  systemctl show -p ExecStart --value udpgw-7300 2>/dev/null \
    | tr ' ' '\n' | grep -A1 -x -- "$1" | sed -n 2p
}

banner() {
  [[ -t 1 ]] && clear
  echo "${C}${B}VPS ARG QUICKSTART${N}"
  echo "${C}────────────────────${N}"
  echo "$(hostname) · $(date '+%Y-%m-%d %H:%M')"
  echo
}

run_logged() {
  # run_logged "descripción" comando...
  local desc="$1" rc
  shift
  "$@"
  rc=$?
  if ((rc == 0)); then
    log_action "$desc resultado=ok"
    echo "${G}Hecho.${N}"
  else
    log_action "$desc resultado=error($rc)"
    echo "${R}La operación falló (código $rc). Revisá el estado antes de reintentar.${N}"
  fi
  return 0
}

# ------------------------------------------------------------------ vistas
show_estado() {
  local unit st port
  printf '%-14s %-14s %-8s %s\n' SERVICIO ESTADO PUERTO UNIDAD
  for unit in "${KNOWN_UNITS[@]}"; do
    st="$(service_state "$unit")"
    port="$(service_port "$unit" 2>/dev/null || true)"
    printf '%-14s %s%*s %-8s %s\n' "$(service_name "$unit")" "$(paint_state "$st")" $((14 - ${#st})) "" "${port:--}" "$unit"
  done
}

show_puertos() {
  local ssh_ports pd hcr_port="" hcr_ssh="" p
  ssh_ports="$(ssh_listen_ports)"
  pd="$(conf_value "$PDIRECT_CONF" SSH_PORT || true)"
  printf '%-26s %s\n' "SSH (sshd, solo lectura)" "${ssh_ports:-desconocido}"
  printf '%-26s %s\n' "PDirect-C" "TCP 80 -> 127.0.0.1:${pd:-?}"
  if hcr_installed; then
    hcr_port="$(conf_value "$HCR_CONF" HCR_PORT)"
    hcr_ssh="$(conf_value "$HCR_CONF" HCR_SSH_PORT)"
    printf '%-26s %s\n' "HCR" "TCP $hcr_port -> 127.0.0.1:$hcr_ssh"
  else
    printf '%-26s %s\n' "HCR" "no instalado"
  fi
  printf '%-26s %s\n' "BadVPN UDPGW" "TCP 7300"
  if [[ -n "$pd" && -n "$ssh_ports" && " $ssh_ports " != *" $pd "* ]]; then
    echo "${Y}AVISO: PDirect-C apunta a $pd, pero SSH escucha en: $ssh_ports${N}"
  fi
  if [[ -n "$hcr_ssh" && -n "$pd" && "$hcr_ssh" != "$pd" ]]; then
    echo "${Y}AVISO: HCR ($hcr_ssh) y PDirect-C ($pd) apuntan a puertos SSH distintos.${N}"
  fi
  echo
  echo "En escucha:"
  for p in 80 7300 $hcr_port; do
    if listening "$p"; then echo "  TCP $p: sí"; else echo "  TCP $p: ${R}no${N}"; fi
  done
}

show_conexiones() {
  local p hcr_port mc mcc
  printf '%-14s %-8s %s\n' SERVICIO PUERTO "CONEXIONES TCP ESTABLECIDAS"
  printf '%-14s %-8s %s\n' "PDirect-C" 80 "$(conn_count 80)"
  if hcr_installed; then
    hcr_port="$(conf_value "$HCR_CONF" HCR_PORT)"
    printf '%-14s %-8s %s\n' "HCR" "$hcr_port" \
      "$(conn_count "$hcr_port") (límite: $(conf_value "$HCR_CONF" HCR_MAX_CONNECTIONS) conexiones TCP)"
  fi
  mc="$(udpgw_arg --max-clients)"
  printf '%-14s %-8s %s\n' "BadVPN UDPGW" 7300 "$(conn_count 7300) (límite --max-clients: ${mc:-?} conexiones TCP)"
  for p in $(ssh_listen_ports); do
    printf '%-14s %-8s %s\n' "SSH" "$p" "$(conn_count "$p")"
  done
  echo
  echo "Son conexiones TCP, no usuarios: una persona puede abrir varias, y todo lo que"
  echo "pasa por PDirect-C o HCR llega a SSH desde 127.0.0.1."
  mcc="$(udpgw_arg --max-connections-for-client)"
  echo "UDPGW: --max-connections-for-client ${mcc:-?} = conexiones UDP por cada conexión TCP al 7300."
  if hcr_installed; then
    echo "HCR: -max-sessions $(conf_value "$HCR_CONF" HCR_MAX_SESSIONS)," \
      "-max-sessions-per-ip $(conf_value "$HCR_CONF" HCR_MAX_SESSIONS_PER_IP) (sesiones HCR; no hay contador disponible)."
  fi
}

show_recursos() {
  local unit pid rss thr cpu fds
  printf '%-14s %-8s %-10s %-8s %-6s %s\n' SERVICIO PID "RAM(kB)" "CPU(s)" HILOS DESCRIPTORES
  for unit in "${KNOWN_UNITS[@]}"; do
    unit_exists "$unit" || continue
    pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
    if [[ ! "$pid" =~ ^[1-9][0-9]*$ || ! -r "/proc/$pid/status" ]]; then
      printf '%-14s %s\n' "$(service_name "$unit")" "detenido"
      continue
    fi
    rss="$(awk '/^VmRSS/{print $2}' "/proc/$pid/status")"
    thr="$(awk '/^Threads/{print $2}' "/proc/$pid/status")"
    cpu="$(awk -v hz="$(getconf CLK_TCK)" '{printf "%.1f", ($14+$15)/hz}' "/proc/$pid/stat")"
    fds="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    printf '%-14s %-8s %-10s %-8s %-6s %s\n' "$(service_name "$unit")" "$pid" "$rss" "$cpu" "$thr" "$fds"
  done
  echo
  free -m | awk 'NR==2{printf "RAM: %s MB total, %s MB usados, %s MB disponibles\n", $2, $3, $7}'
  df -Pm / | awk 'NR==2{printf "Disco /: %s MB libres de %s MB\n", $4, $2}'
  echo "Carga (1/5/15 min): $(cut -d' ' -f1-3 /proc/loadavg) · CPUs: $(nproc)"
}

show_ssh() {
  local pa
  echo "Configuración efectiva de sshd (solo lectura, el panel no la modifica):"
  pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
  case "$pa" in
    yes) echo "  PasswordAuthentication yes: SSH acepta usuario y contraseña." ;;
    no) echo "  ${Y}PasswordAuthentication no: SSH NO acepta contraseñas.${N}"
        echo "  Las cuentas no podrán entrar con usuario y contraseña."
        echo "  Cambiarlo es una decisión del administrador; el panel no toca sshd_config." ;;
    *) echo "  No se pudo leer (sshd -T falló)." ;;
  esac
  echo "  Puertos: $(ssh_listen_ports)"
}

# ------------------------------------------------------------------ menús
# ------------------------------------------------------------------ protocolos
protocol_name() {
  case "$1" in
    ssh) echo "SSH" ;;
    udpgw-7300) echo "UDPGW" ;;
    *) service_name "$1" ;;
  esac
}

protocol_state() {
  if [[ "$1" == ssh ]]; then ssh_state; else service_state "$1"; fi
}

protocol_port() {
  local port
  if [[ "$1" == ssh ]]; then port="$(ssh_listen_ports)"; else port="$(service_port "$1" 2>/dev/null || true)"; fi
  echo "${port:--}"
}

protocol_pid() {
  local pid
  if [[ "$1" == ssh ]]; then pid="$(unit_pid ssh)"; else pid="$(unit_pid "$1")"; fi
  echo "${pid:--}"
}

show_protocolos() {
  local p st
  printf '%-12s %-14s %-12s %s\n' PROTOCOLO ESTADO PUERTO PID
  for p in "${PROTOCOLS[@]}"; do
    st="$(protocol_state "$p")"
    printf '%-12s %s%*s %-12s %s\n' "$(protocol_name "$p")" "$(paint_state "$st")" $((14 - ${#st})) "" \
      "$(protocol_port "$p")" "$(protocol_pid "$p")"
  done
}

status_line() {
  local p st out=""
  for p in "${PROTOCOLS[@]}"; do
    st="$(protocol_state "$p")"
    if [[ "$st" == ACTIVO ]]; then
      out+="$(protocol_name "$p") ${G}●${N} $(paint_state "$st")   "
    else
      out+="$(protocol_name "$p") ○ $(paint_state "$st")   "
    fi
  done
  echo "${out%   }"
}

# Datos comunes de la ficha de un servicio systemd.
show_unit_details() {
  local unit="$1" st
  st="$(protocol_state "$unit")"
  if [[ "$st" == "NO INSTALADO" ]]; then
    echo "Instalado:   no"
    return
  fi
  echo "Instalado:   sí (unidad $unit)"
  echo "Estado:      $(paint_state "$st")"
  echo "Puerto:      $(protocol_port "$unit")"
  echo "PID:         $(protocol_pid "$unit")"
  echo "Arranque:    $(systemctl is-enabled "$unit" 2>/dev/null || echo desconocido)"
  echo "Activo desde: $(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null | sed 's/^$/-/')"
  echo "Reinicios automáticos: $(systemctl show -p NRestarts --value "$unit" 2>/dev/null | sed 's/^$/-/')"
}

show_recent_errors() {
  local out
  out="$(journalctl -u "$1" -p warning -n 5 --no-pager -o short 2>/dev/null | grep -v '^-- ' || true)"
  echo "Últimas advertencias o errores:"
  if [[ -n "$out" ]]; then printf '  %s\n' "${out//$'\n'/$'\n'  }"; else echo "  ninguno"; fi
}

ficha_header() {
  banner
  echo "${B}PROTOCOLOS › $(protocol_name "$1")${N}"; echo
}

# Acciones permitidas sobre PDirect-C, UDPGW y HCR. Nunca sobre SSH.
service_action() {
  local unit="$1" action="$2"
  if [[ "$action" =~ ^(detener|reiniciar|deshabilitar)$ ]]; then
    confirm "¿$action $(protocol_name "$unit")? Las conexiones abiertas de ese servicio se cortan." || return 0
  fi
  if [[ "$unit" == hcr-8880 && "$action" =~ ^(iniciar|detener|reiniciar)$ ]]; then
    run_logged "accion=$action servicio=$unit" "$HCR" "$action"
  else
    run_logged "accion=$action servicio=$unit" "$PUERTOS" "$action" "$unit"
  fi
  pause
}

menu_ficha_servicio() {
  local unit="$1" mc mcc
  while true; do
    ficha_header "$unit"
    show_unit_details "$unit"
    case "$unit" in
      pdirect-80)
        echo "Destino:     127.0.0.1:$(conf_value "$PDIRECT_CONF" SSH_PORT || echo '?') (SSH)"
        echo "Conexiones TCP establecidas: $(conn_count 80)"
        ;;
      udpgw-7300)
        mc="$(udpgw_arg --max-clients)"
        mcc="$(udpgw_arg --max-connections-for-client)"
        echo "Conexiones TCP al 7300: $(conn_count 7300) de --max-clients ${mc:-?}"
        echo "  (es el total del servidor, no por usuario; una conexión puede llevar varios flujos UDP)"
        echo "Flujos UDP por conexión (--max-connections-for-client): ${mcc:-?}"
        echo "El panel no cambia los límites ni la escucha de UDPGW."
        ;;
      hcr-8880)
        if hcr_installed; then
          echo "Conexiones TCP establecidas: $(conn_count "$(service_port hcr-8880)")"
        fi
        echo "${Y}HCR todavía no está validado para producción: falta una prueba con un cliente HCR,"
        echo "verificar IPv6 y repetir las pruebas en una VPS de laboratorio.${N}"
        ;;
    esac
    echo
    if [[ "$unit" == hcr-8880 ]] && ! hcr_installed; then
      echo "  1) Instalar   0) Volver"
      ask "Opción: "
      case "$REPLY" in
        1)
          echo "Se usa /opt/hcr/hcr-server (copialo antes por SFTP), el puerto configurado"
          echo "(8880 si es la primera vez) y el destino SSH de PDirect-C."
          confirm "¿Instalar HCR?" && run_logged "accion=instalar servicio=hcr-8880" "$HCR" instalar
          pause
          ;;
        0|"") return ;;
        *) echo "Opción inválida."; sleep 1 ;;
      esac
      continue
    fi
    if ! unit_exists "$unit"; then
      echo "No está instalado. Se instala con el instalador de VPS ARG QuickStart."
      pause
      return
    fi
    echo "  1) Iniciar     2) Detener     3) Reiniciar"
    echo "  4) Habilitar al arranque      5) Deshabilitar al arranque"
    echo "  6) Ver registro               7) Ver errores recientes"
    [[ "$unit" == hcr-8880 ]] && echo "  8) Desinstalar HCR"
    echo "  0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1) service_action "$unit" iniciar ;;
      2) service_action "$unit" detener ;;
      3) service_action "$unit" reiniciar ;;
      4) service_action "$unit" habilitar ;;
      5) service_action "$unit" deshabilitar ;;
      6) echo; journalctl -u "$unit" -n 40 --no-pager; pause ;;
      7) echo; show_recent_errors "$unit"; pause ;;
      8)
        if [[ "$unit" == hcr-8880 ]]; then
          confirm "¿Desinstalar HCR? No se tocan PDirect-C, UDPGW ni /opt/hcr." \
            && run_logged "accion=desinstalar servicio=hcr-8880" "$HCR" desinstalar
          pause
        else
          echo "Opción inválida."; sleep 1
        fi
        ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

menu_ficha_ssh() {
  local pa ports
  while true; do
    ficha_header ssh
    echo "Estado:      $(paint_state "$(ssh_state)")"
    echo "Unidad:      $(ssh_mode)"
    ports="$(ssh_listen_ports)"
    echo "Puertos:     ${ports:-desconocido}"
    echo "PID:         $(protocol_pid ssh)"
    pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
    echo "Acepta usuario y contraseña: ${pa:-no se pudo leer (sshd -T falló)}"
    echo "Sesiones SSH de cuentas VPS ARG: $(managed_sessions_total)"
    echo
    echo "SSH es solo de lectura: el panel no lo detiene, no lo reinicia y no modifica sshd_config."
    echo
    echo "  1) Ver registro   2) Ver errores recientes   0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1) echo; journalctl -u ssh -n 40 --no-pager; pause ;;
      2) echo; show_recent_errors ssh; pause ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

menu_protocolos() {
  while true; do
    banner
    echo "${B}PROTOCOLOS${N}"; echo
    show_protocolos; echo
    echo "  1) PDirect-C   2) UDPGW   3) HCR   4) SSH"
    echo "  5) Actualizar estados      0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1) menu_ficha_servicio pdirect-80 ;;
      2) menu_ficha_servicio udpgw-7300 ;;
      3) menu_ficha_servicio hcr-8880 ;;
      4) menu_ficha_ssh ;;
      5) ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

# ------------------------------------------------------------------ estado
# Una sola lectura de procesos: cuenta las sesiones SSH (sshd o sshd-session con el UID
# de la cuenta) de cada cuenta administrada. Deja "usuario sesiones" por línea.
managed_sessions() {
  local members user uid uids=""
  members="$(getent group "$USERS_GROUP" 2>/dev/null | cut -d: -f4 | tr ',' ' ')"
  for user in $members; do
    uid="$(id -u "$user" 2>/dev/null)" || continue
    ((uid >= 1000 && uid != 65534)) && uids+="$uid=$user "
  done
  [[ -n "$uids" ]] || return 0
  ps -e -o uid=,comm= 2>/dev/null | awk -v map="$uids" '
    BEGIN { n = split(map, a, " "); for (i = 1; i <= n; i++) { split(a[i], kv, "="); name[kv[1]] = kv[2]; cnt[kv[1]] = 0 } }
    ($2 == "sshd" || $2 == "sshd-session") && ($1 in name) { cnt[$1]++ }
    END { for (u in name) print name[u], cnt[u] }' | sort
}

managed_sessions_total() {
  managed_sessions | awk '{t += $2} END {print t + 0}'
}

human_kb() {
  awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GB", k / 1048576; else printf "%d MB", k / 1024 }'
}

cpu_percent() {
  # Dos lecturas de /proc/stat separadas medio segundo.
  local a b
  a="$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat)"
  sleep 0.5
  b="$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat)"
  awk -v a="$a" -v b="$b" 'BEGIN { split(a, x, " "); split(b, y, " "); t = y[1] - x[1]; i = y[2] - x[2];
    if (t > 0) printf "%d %%", (t - i) * 100 / t + 0.5; else print "-" }'
}

uptime_text() {
  awk '{ s = int($1); d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60);
    if (d > 0) printf "%d %s %d %s\n", d, (d == 1 ? "día" : "días"), h, (h == 1 ? "hora" : "horas");
    else printf "%d %s %d %s\n", h, (h == 1 ? "hora" : "horas"), m, (m == 1 ? "minuto" : "minutos") }' /proc/uptime
}

temperature() {
  local f t
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$f" ]] || continue
    t="$(cat "$f" 2>/dev/null)" || continue
    [[ "$t" =~ ^[0-9]+$ ]] && ((t > 0)) && { echo "$((t / 1000)) °C"; return; }
  done
  echo "no disponible"
}

show_sistema() {
  local mt ma st sf
  mt="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
  ma="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
  st="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
  sf="$(awk '/^SwapFree:/{print $2}' /proc/meminfo)"
  printf '%-10s %s (%s núcleos)\n' "CPU:" "$(cpu_percent)" "$(nproc)"
  printf '%-10s %s\n' "CARGA:" "$(cut -d' ' -f1-3 /proc/loadavg) (1, 5 y 15 min)"
  printf '%-10s %s / %s (disponible %s)\n' "RAM:" "$(human_kb $((mt - ma)))" "$(human_kb "$mt")" "$(human_kb "$ma")"
  if ((st > 0)); then
    printf '%-10s %s / %s\n' "SWAP:" "$(human_kb $((st - sf)))" "$(human_kb "$st")"
  else
    printf '%-10s %s\n' "SWAP:" "sin swap"
  fi
  df -Pk / | awk 'NR==2{print $3, $2}' | while read -r used total; do
    printf '%-10s %s / %s\n' "DISCO /:" "$(human_kb "$used")" "$(human_kb "$total")"
  done
  printf '%-10s %s\n' "UPTIME:" "$(uptime_text)"
  printf '%-10s %s\n' "TEMP:" "$(temperature)"
}

# Límites guardados por vpsarg-usuarios (usuario:N; 0 o sin línea = sin límite).
limits_map() {
  [[ -r "$LIMITS_FILE" ]] && grep -E '^[a-z_][a-z0-9_-]*:[0-9]+$' "$LIMITS_FILE" | tr ':' ' ' | tr '\n' ' '
  return 0
}

show_conectados() {
  local list n
  list="$(managed_sessions | awk '$2 > 0')"
  n="$(grep -c . <<<"$list" || true)"
  echo "Usuarios conectados: $n · sesiones SSH: $(awk '{t += $2} END {print t + 0}' <<<"$list")"
  [[ -n "$list" ]] && awk -v map="$(limits_map)" '
    BEGIN { k = split(map, a, " "); for (i = 1; i < k; i += 2) lim[a[i]] = a[i + 1] }
    { l = ($1 in lim && lim[$1] > 0) ? lim[$1] : "-"
      printf "  %-20s %s/%s%s\n", $1, $2, l, (l != "-" && $2 > l) ? "  EXCEDE" : "" }' <<<"$list"
  return 0
}

show_estado_general() {
  echo "${B}Servidor${N}"
  show_sistema
  echo
  echo "${B}Protocolos${N}"
  show_protocolos
  echo
  echo "${B}Conexiones${N}"
  show_conectados
}

menu_estado() {
  while true; do
    banner
    echo "${B}ESTADO${N}"; echo
    show_estado_general; echo
    echo "  1) Actualizar   2) Conexiones TCP por servicio   3) Recursos de cada servicio"
    echo "  0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1) ;;
      2) echo; show_conexiones; pause ;;
      3) echo; show_recursos; pause ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

# ------------------------------------------------------------------ AUTO
# Cuenta del administrador que usa el panel: quien hizo sudo, o root.
admin_account() {
  local u="${SUDO_USER:-root}"
  valid_user "$u" && getent passwd "$u" >/dev/null || return 1
  id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$USERS_GROUP" && return 1
  echo "$u"
}

auto_enabled() {
  [[ -r "$AUTO_CONF" ]] && grep -qx -- "$1" "$AUTO_CONF"
}

write_auto_hook() {
  local tmp
  tmp="$(mktemp "${AUTO_HOOK%/*}/.vpsarg-auto.XXXXXX")" || return 1
  cat > "$tmp" <<'EOF'
# VPS ARG QuickStart - AUTO: abre el panel al iniciar sesión.
# Lo crea y lo borra "vpsarg auto"; las cuentas están en /etc/vpsarg-auto.conf.
# Solo en sesiones interactivas con terminal, una vez por sesión y nunca para las
# cuentas del grupo vpsarg-usuarios. Al salir del panel sigue la consola.
if [ -z "${VPSARG_AUTO_ABIERTO:-}" ] && [ -t 0 ] && [ -t 1 ] \
   && [ -r /etc/vpsarg-auto.conf ] && [ -x /usr/local/sbin/vpsarg ]; then
  case $- in
    *i*)
      vpsarg_auto_u="$(id -un 2>/dev/null)"
      if grep -qx -- "$vpsarg_auto_u" /etc/vpsarg-auto.conf 2>/dev/null \
         && ! id -nG "$vpsarg_auto_u" 2>/dev/null | tr ' ' '\n' | grep -qx vpsarg-usuarios; then
        VPSARG_AUTO_ABIERTO=1
        export VPSARG_AUTO_ABIERTO
        trap ':' INT
        if [ "$(id -u)" -eq 0 ]; then /usr/local/sbin/vpsarg; else sudo /usr/local/sbin/vpsarg; fi
        trap - INT
      fi
      unset vpsarg_auto_u
      ;;
  esac
fi
EOF
  chmod 0644 "$tmp" && mv -f "$tmp" "$AUTO_HOOK"
}

# auto_set CUENTA on|off
auto_set() {
  local user="$1" mode="$2" tmp
  if [[ "$mode" == on ]]; then
    tmp="$(mktemp /etc/.vpsarg-auto.XXXXXX)" || return 1
    { [[ -r "$AUTO_CONF" ]] && grep -vx -- "$user" "$AUTO_CONF"; echo "$user"; } > "$tmp"
    chmod 0644 "$tmp" && mv -f "$tmp" "$AUTO_CONF" && write_auto_hook || return 1
  else
    if [[ -r "$AUTO_CONF" ]]; then
      tmp="$(mktemp /etc/.vpsarg-auto.XXXXXX)" || return 1
      grep -vx -- "$user" "$AUTO_CONF" > "$tmp" || true
      if [[ -s "$tmp" ]]; then
        chmod 0644 "$tmp" && mv -f "$tmp" "$AUTO_CONF" || return 1
      else
        rm -f -- "$tmp" "$AUTO_CONF"
      fi
    fi
    # Sin cuentas con AUTO no queda ningún archivo en /etc/profile.d.
    [[ -s "$AUTO_CONF" ]] || rm -f -- "$AUTO_HOOK"
  fi
  log_action "accion=auto valor=$mode cuenta=$user resultado=ok"
}

show_auto() {
  local u
  u="$(admin_account)" || { echo "AUTO no disponible para la cuenta ${SUDO_USER:-root}."; return 1; }
  if auto_enabled "$u"; then echo "AUTO: ON para $u"; else echo "AUTO: OFF para $u"; fi
}

cmd_auto() {
  local u
  u="$(admin_account)" || { echo "AUTO no disponible para la cuenta ${SUDO_USER:-root}." >&2; return 1; }
  case "${1:-}" in
    "") show_auto ;;
    on|off) auto_set "$u" "$1" && show_auto ;;
    *) usage; return 1 ;;
  esac
}

menu_auto() {
  local u
  banner
  echo "${B}CONFIGURACIÓN › AUTO INICIO${N}"; echo
  u="$(admin_account)" || { echo "AUTO no está disponible para la cuenta ${SUDO_USER:-root}."; pause; return; }
  show_auto
  echo
  echo "Con AUTO en ON, el panel se abre solo al iniciar sesión con $u en una terminal."
  echo "Con 0 (Salir) o Ctrl+C se vuelve a la consola. No afecta a los usuarios SSH del servicio."
  echo
  if auto_enabled "$u"; then
    confirm "¿Desactivar AUTO para $u?" && { auto_set "$u" off && echo "${G}Hecho.${N}"; show_auto; }
  else
    confirm "¿Activar AUTO para $u?" && { auto_set "$u" on && echo "${G}Hecho.${N}"; show_auto; }
  fi
  pause
}

# ------------------------------------------------------------------ configuración
menu_configuracion() {
  local p
  while true; do
    banner
    echo "${B}CONFIGURACIÓN${N}"; echo
    show_puertos; echo
    echo "  1) Cambiar el puerto SSH de destino (PDirect-C y HCR)"
    echo "  2) Cambiar el puerto de HCR"
    echo "  3) Autenticación de SSH (solo lectura)"
    echo "  4) Registro del panel"
    echo "  5) Guardar copia de la configuración   6) Ver copias guardadas"
    echo "  7) Auto inicio ($(show_auto 2>/dev/null | sed 's/ para .*//' || echo 'AUTO: no disponible'))"
    echo "  0) Volver"
    echo "El puerto 80 de PDirect-C, el 7300 de UDPGW y el puerto de sshd no se cambian desde el panel."
    ask "Opción: "
    case "$REPLY" in
      1)
        echo "Indicá el puerto donde YA escucha SSH (actualmente: $(ssh_listen_ports))."
        ask "Puerto SSH: "
        valid_port "$REPLY" || { echo "Puerto no válido."; pause; continue; }
        p="$REPLY"
        confirm "¿Apuntar PDirect-C$(hcr_installed && echo ' y HCR') a 127.0.0.1:$p?" \
          && run_logged "accion=puerto-ssh valor=$p" "$PUERTOS" puerto-ssh "$p"
        pause
        ;;
      2)
        hcr_installed || { echo "HCR no está instalado."; pause; continue; }
        ask "Nuevo puerto de HCR (1024-65535, por ejemplo 8880 u 8080): "
        valid_port "$REPLY" || { echo "Puerto no válido."; pause; continue; }
        p="$REPLY"
        confirm "¿Cambiar el puerto de HCR a $p? Los clientes deberán usar el nuevo puerto." \
          && run_logged "accion=puerto-hcr valor=$p" "$HCR" puerto "$p"
        pause
        ;;
      3) echo; show_ssh; pause ;;
      4) journalctl -t "$LOG_TAG" -n 40 --no-pager; pause ;;
      5) make_backup; pause ;;
      6) ls -1 "$BACKUP_ROOT" 2>/dev/null || echo "No hay copias."; pause ;;
      7) menu_auto ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

menu_usuarios() {
  local u opt days limit
  [[ -x "$USUARIOS" ]] || { pending "USUARIOS SSH" "No está instalado $USUARIOS."; return; }
  while true; do
    banner
    echo "${B}USUARIOS${N}"; echo
    if [[ "$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')" != yes ]]; then
      echo "${Y}AVISO: SSH no acepta contraseñas o no se pudo comprobar (ver Configuración > Autenticación de SSH).${N}"
      echo
    fi
    "$USUARIOS" listar 2>&1 || true
    echo
    echo "  1) Crear              2) Ver                 3) Renovar"
    echo "  4) Cambiar vencimiento 5) Cambiar contraseña  6) Cambiar límite"
    echo "  7) Suspender          8) Reactivar           9) Eliminar"
    echo "  0) Volver"
    ask "Opción: "
    case "$REPLY" in
      [1-9])
        opt="$REPLY"
        ask "Usuario: "
        valid_user "$REPLY" || { echo "Nombre no válido (minúsculas, números, _ o -; máximo 31)."; pause; continue; }
        u="$REPLY"
        case "$opt" in
          1) ask "Días de vigencia (Enter = 30; 0 = no vence): "
             days="${REPLY:-30}"
             [[ "$days" =~ ^[0-9]{1,4}$ ]] || { echo "Días no válidos."; pause; continue; }
             [[ "$days" == 0 ]] && days=""
             echo "Límite de conexiones: [1] [2] [3] [5] [10] o 0 = sin límite."
             ask "Límite (Enter = 1): "
             limit="${REPLY:-1}"
             [[ "$limit" =~ ^[0-9]{1,2}$ ]] || { echo "Límite no válido."; pause; continue; }
             echo "La contraseña no se muestra mientras la escribís (mínimo 6 caracteres)."
             "$USUARIOS" crear "$u" "$days" "$limit" || true ;;
          2) "$USUARIOS" ver "$u" || true ;;
          3) ask "Días a sumar (desde hoy o desde el vencimiento actual, el mayor): "
             [[ "$REPLY" =~ ^[0-9]{1,4}$ ]] || { echo "Días no válidos."; pause; continue; }
             "$USUARIOS" renovar "$u" "$REPLY" || true ;;
          4) ask "Nueva fecha de vencimiento (AAAA-MM-DD) o nunca: "
             [[ "$REPLY" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}|nunca)$ ]] || { echo "Fecha no válida."; pause; continue; }
             "$USUARIOS" vencimiento "$u" "$REPLY" || true ;;
          5) echo "La contraseña no se muestra mientras la escribís (mínimo 6 caracteres)."
             "$USUARIOS" clave "$u" || true ;;
          6) "$USUARIOS" limite "$u" || { pause; continue; }
             echo "Nuevo límite: [1] [2] [3] [5] [10] o 0 = sin límite."
             ask "Límite: "
             [[ "$REPLY" =~ ^[0-9]{1,2}$ ]] || { echo "Límite no válido."; pause; continue; }
             "$USUARIOS" limite "$u" "$REPLY" || true ;;
          7) confirm "¿Suspender $u? Se cierran sus sesiones SSH abiertas." && { "$USUARIOS" suspender "$u" || true; } ;;
          8) "$USUARIOS" reactivar "$u" || true ;;
          9) ask "Para eliminar $u y su directorio personal, escribí el nombre otra vez: "
             if [[ "$REPLY" == "$u" ]]; then "$USUARIOS" eliminar "$u" || true; else echo "No coincide. No se eliminó."; fi ;;
        esac
        pause
        ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}


make_backup() {
  local dir f files=()
  dir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-panel"
  for f in "$PDIRECT_CONF" "$SERVICES_CONF" "$HCR_CONF" \
           /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service \
           /etc/systemd/system/hcr-8880.service; do
    [[ -e "$f" ]] && files+=("$f")
  done
  install -d -m 0700 "$dir"
  cp -p -- "${files[@]}" "$dir/"
  echo "Copia guardada en $dir"
  log_action "accion=copia destino=$dir resultado=ok"
}


pending() {
  banner
  echo "${B}$1${N}"; echo
  echo "$2"
  pause
}


main_menu() {
  while true; do
    banner
    status_line
    echo
    echo "[ 1 ] PROTOCOLOS"
    echo "[ 2 ] USUARIOS"
    echo "[ 3 ] ESTADO"
    echo "[ 4 ] CONFIGURACIÓN"
    echo "[ 0 ] SALIR"
    ask "Opción: "
    case "$REPLY" in
      1) menu_protocolos ;;
      2) menu_usuarios ;;
      3) menu_estado ;;
      4) menu_configuracion ;;
      0|"") return 0 ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

main() {
  [[ ${EUID} -eq 0 ]] || { echo "Usá sudo: sudo vpsarg" >&2; exit 1; }
  case "${1:-}" in
    "") main_menu ;;
    estado) show_estado ;;
    protocolos) show_protocolos ;;
    sistema) show_estado_general ;;
    puertos) show_puertos ;;
    conexiones) show_conexiones ;;
    recursos) show_recursos ;;
    ssh) show_ssh ;;
    usuarios) "$USUARIOS" listar ;;
    auto) (($# <= 2)) || { usage; exit 1; }; cmd_auto "${2:-}" ;;
    -h|--help|ayuda) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
