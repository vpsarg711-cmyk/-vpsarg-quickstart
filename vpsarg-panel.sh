#!/usr/bin/env bash
# VPS ARG QuickStart - panel de administración (terminal)
# Es un script interactivo: no deja ningún proceso en segundo plano.
# Todas las acciones pasan por vpsarg-puertos y vpsarg-hcr, que validan y revierten.
# No modifica sshd ni /etc/ssh/sshd_config, el firewall, el código, los argumentos
# ni el puerto de PDirect-C, ni la configuración o los límites de UDPGW.
set -Euo pipefail

SERVICES_CONF="/etc/vpsarg-servicios.conf"
PDIRECT_CONF="/etc/vpsarg-pdirect.conf"
HCR_CONF="/etc/vpsarg-hcr.conf"
PUERTOS="/usr/local/sbin/vpsarg-puertos"
HCR="/usr/local/sbin/vpsarg-hcr"
BACKUP_ROOT="/var/backups/vpsarg"
LOG_TAG="vpsarg-panel"
KNOWN_UNITS=(pdirect-80 udpgw-7300 hcr-8880)

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
  sudo vpsarg puertos         puertos configurados y en escucha
  sudo vpsarg conexiones      conexiones TCP establecidas por servicio
  sudo vpsarg recursos        memoria, CPU y descriptores de cada servicio
  sudo vpsarg ssh             autenticación de SSH (solo lectura)
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

udpgw_arg() {
  # Lee un argumento de la unidad de UDPGW sin modificarla.
  systemctl show -p ExecStart --value udpgw-7300 2>/dev/null \
    | tr ' ' '\n' | grep -A1 -x -- "$1" | sed -n 2p
}

banner() {
  [[ -t 1 ]] && clear
  echo "${C}${B}============================================${N}"
  echo "${C}${B}            VPS ARG QuickStart${N}"
  echo "${C}${B}============================================${N}"
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
pick_service() {
  # Lista los servicios instalados y deja la unidad elegida en PICKED.
  local units=() unit i=1
  PICKED=""
  for unit in "${KNOWN_UNITS[@]}"; do
    unit_exists "$unit" && units+=("$unit")
  done
  for unit in "${units[@]}"; do
    echo "  $i) $(service_name "$unit") ($unit)"
    i=$((i + 1))
  done
  echo "  0) Volver"
  ask "Servicio: "
  [[ "$REPLY" =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= ${#units[@]})) || return 1
  PICKED="${units[$((REPLY - 1))]}"
}

menu_servicios() {
  local action
  while true; do
    banner
    echo "${B}SERVICIOS${N}"; echo
    show_estado; echo
    echo "  1) Iniciar   2) Detener   3) Reiniciar   4) Habilitar al arranque   5) Deshabilitar al arranque"
    echo "  0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1) action=iniciar ;; 2) action=detener ;; 3) action=reiniciar ;;
      4) action=habilitar ;; 5) action=deshabilitar ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1; continue ;;
    esac
    pick_service || continue
    if [[ "$action" != iniciar && "$action" != habilitar ]]; then
      confirm "¿$action $(service_name "$PICKED")? Las conexiones abiertas de ese servicio se cortan." || continue
    fi
    if [[ "$PICKED" == hcr-8880 && "$action" =~ ^(iniciar|detener|reiniciar)$ ]]; then
      run_logged "accion=$action servicio=$PICKED" "$HCR" "$action"
    else
      run_logged "accion=$action servicio=$PICKED" "$PUERTOS" "$action" "$PICKED"
    fi
    pause
  done
}

menu_puertos() {
  local p
  while true; do
    banner
    echo "${B}PUERTOS${N}"; echo
    show_puertos; echo
    echo "  1) Cambiar el puerto SSH de destino (PDirect-C y HCR)"
    echo "  2) Cambiar el puerto de HCR"
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
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

menu_hcr() {
  while true; do
    banner
    echo "${B}HCR${N}"; echo
    if hcr_installed; then
      "$HCR" estado 2>&1 || true
    else
      echo "HCR no está instalado."
    fi
    echo
    echo "${Y}HCR todavía no está validado para producción: falta una prueba con un cliente HCR,"
    echo "verificar IPv6 y repetir las pruebas en una VPS de laboratorio.${N}"
    echo
    echo "  1) Instalar   2) Desinstalar   0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1)
        echo "Se usa /opt/hcr/hcr-server (copialo antes por SFTP), el puerto configurado"
        echo "(8880 si es la primera vez) y el destino SSH de PDirect-C."
        confirm "¿Instalar HCR?" && run_logged "accion=instalar servicio=hcr-8880" "$HCR" instalar
        pause
        ;;
      2)
        hcr_installed || { echo "HCR no está instalado."; pause; continue; }
        confirm "¿Desinstalar HCR? No se tocan PDirect-C, UDPGW ni /opt/hcr." \
          && run_logged "accion=desinstalar servicio=hcr-8880" "$HCR" desinstalar
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

menu_diagnostico() {
  while true; do
    banner
    echo "${B}DIAGNÓSTICO Y RECURSOS${N}"; echo
    echo "  1) Conexiones TCP activas          2) Consumo de recursos"
    echo "  3) Autenticación de SSH            4) Registro de un servicio"
    echo "  5) Registro del panel              6) Guardar copia de la configuración"
    echo "  7) Ver copias guardadas            0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1) echo; show_conexiones; pause ;;
      2) echo; show_recursos; pause ;;
      3) echo; show_ssh; pause ;;
      4) pick_service && journalctl -u "$PICKED" -n 40 --no-pager; pause ;;
      5) journalctl -t "$LOG_TAG" -n 40 --no-pager; pause ;;
      6) make_backup; pause ;;
      7) ls -1 "$BACKUP_ROOT" 2>/dev/null || echo "No hay copias."; pause ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
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
    show_estado
    echo
    echo "  1) Servicios                4) HCR"
    echo "  2) Puertos                  5) Diagnóstico y recursos"
    echo "  3) Usuarios SSH             6) Ancho de banda"
    echo "  0) Salir"
    ask "Opción: "
    case "$REPLY" in
      1) menu_servicios ;;
      2) menu_puertos ;;
      3) pending "USUARIOS SSH" "Pendiente: la gestión de cuentas SSH todavía no está habilitada." ;;
      4) menu_hcr ;;
      5) menu_diagnostico ;;
      6) pending "ANCHO DE BANDA" "Pendiente: la medición de tráfico todavía no está habilitada." ;;
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
    puertos) show_puertos ;;
    conexiones) show_conexiones ;;
    recursos) show_recursos ;;
    ssh) show_ssh ;;
    -h|--help|ayuda) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
