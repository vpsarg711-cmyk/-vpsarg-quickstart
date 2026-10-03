#!/usr/bin/env bash
# VPS ARG QuickStart - panel de administración (terminal)
# Solo administra los servicios de /etc/vpsarg-servicios.conf a través de
# vpsarg-puertos y vpsarg-hcr. No modifica sshd, el firewall, PDirect-C ni UDPGW
# (más allá de iniciarlos, detenerlos o reiniciarlos cuando se pide).
# No queda ningún proceso en segundo plano: es un script interactivo.
set -Euo pipefail

SERVICES_CONF="/etc/vpsarg-servicios.conf"
PDIRECT_CONF="/etc/vpsarg-pdirect.conf"
HCR_CONF="/etc/vpsarg-hcr.conf"
PUERTOS="/usr/local/sbin/vpsarg-puertos"
HCR="/usr/local/sbin/vpsarg-hcr"
BACKUP_ROOT="/var/backups/vpsarg"
LOG_TAG="vpsarg-panel"
DEFAULT_SERVICES=(pdirect-80 udpgw-7300)

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
  sudo vpsarg conexiones      conexiones TCP activas por servicio
  sudo vpsarg recursos        consumo de memoria y CPU
  sudo vpsarg trafico         tráfico total del servidor
EOF
}

# ------------------------------------------------------------------ utilidades
log_action() {
  # Registra en el journal toda acción que cambia algo: journalctl -t vpsarg-panel
  logger -t "$LOG_TAG" -- "admin=${SUDO_USER:-root} $*" 2>/dev/null || true
}

pause() {
  local _
  echo
  read -r -p "Enter para continuar..." _ || true
}

ask() {
  # ask "texto" -> REPLY (vacío si se cierra la entrada)
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
  # conf_value ARCHIVO CLAVE: solo valores numéricos o simples, sin ejecutar el archivo
  [[ -r "$1" ]] || return 1
  sed -n "s/^$2=\([A-Za-z0-9.:_-]*\)$/\1/p" "$1" | tail -n 1
}

load_services() {
  SERVICES=()
  local line
  if [[ -r "$SERVICES_CONF" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"
      [[ "$line" =~ ^[a-zA-Z0-9_.@-]+$ ]] && SERVICES+=("$line")
    done < "$SERVICES_CONF"
  fi
  ((${#SERVICES[@]})) || SERVICES=("${DEFAULT_SERVICES[@]}")
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
  # Puertos donde escucha SSH según la configuración efectiva (solo lectura).
  sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' '
}

conn_count() {
  ss -Htn state established "( sport = :$1 )" 2>/dev/null | wc -l
}

banner() {
  [[ -t 1 ]] && clear
  echo "${C}${B}============================================${N}"
  echo "${C}${B}            VPS ARG QuickStart${N}"
  echo "${C}${B}============================================${N}"
  echo "$(hostname) · $(date '+%Y-%m-%d %H:%M')"
  echo
}

# ------------------------------------------------------------------ vistas
show_estado() {
  load_services
  local all=(pdirect-80 udpgw-7300 hcr-8880) unit st port
  printf '%-14s %-14s %-8s %s\n' SERVICIO ESTADO PUERTO UNIDAD
  for unit in "${all[@]}"; do
    st="$(service_state "$unit")"
    port="$(service_port "$unit" 2>/dev/null || true)"
    printf '%-14s %-25s %-8s %s\n' "$(service_name "$unit")" "$(paint_state "$st")" "${port:--}" "$unit"
  done
  for unit in "${SERVICES[@]}"; do
    [[ " ${all[*]} " == *" $unit "* ]] && continue
    printf '%-14s %-25s %-8s %s\n' "$unit" "$(paint_state "$(service_state "$unit")")" - "$unit"
  done
}

show_puertos() {
  local ssh_ports pd hcr_port hcr_ssh p
  ssh_ports="$(ssh_listen_ports)"
  pd="$(conf_value "$PDIRECT_CONF" SSH_PORT || true)"
  printf '%-24s %s\n' "SSH (sshd, solo lectura)" "${ssh_ports:-desconocido}"
  printf '%-24s %s\n' "PDirect-C" "TCP 80 -> 127.0.0.1:${pd:-?}"
  if hcr_installed; then
    hcr_port="$(conf_value "$HCR_CONF" HCR_PORT)"
    hcr_ssh="$(conf_value "$HCR_CONF" HCR_SSH_PORT)"
    printf '%-24s %s\n' "HCR" "TCP $hcr_port -> 127.0.0.1:$hcr_ssh"
  else
    printf '%-24s %s\n' "HCR" "no instalado"
  fi
  printf '%-24s %s\n' "BadVPN UDPGW" "TCP 7300"
  if [[ -n "$pd" && -n "$ssh_ports" && " $ssh_ports " != *" $pd "* ]]; then
    echo "${Y}AVISO: PDirect-C apunta a $pd, pero SSH escucha en: $ssh_ports${N}"
  fi
  if [[ -n "${hcr_ssh:-}" && -n "$pd" && "$hcr_ssh" != "$pd" ]]; then
    echo "${Y}AVISO: HCR ($hcr_ssh) y PDirect-C ($pd) apuntan a puertos SSH distintos.${N}"
  fi
  echo
  echo "En escucha:"
  for p in 80 7300 ${hcr_port:-}; do
    if listening "$p"; then echo "  TCP $p: sí"; else echo "  TCP $p: ${R}no${N}"; fi
  done
}

show_conexiones() {
  local p hcr_port max
  printf '%-14s %-8s %s\n' SERVICIO PUERTO "CONEXIONES TCP ESTABLECIDAS"
  printf '%-14s %-8s %s\n' "PDirect-C" 80 "$(conn_count 80)"
  if hcr_installed; then
    hcr_port="$(conf_value "$HCR_CONF" HCR_PORT)"
    max="$(conf_value "$HCR_CONF" HCR_MAX_CONNECTIONS)"
    printf '%-14s %-8s %s\n' "HCR" "$hcr_port" "$(conn_count "$hcr_port") de un máximo de $max conexiones TCP"
  fi
  printf '%-14s %-8s %s\n' "BadVPN UDPGW" 7300 "$(conn_count 7300) (máx. de clientes según la unidad)"
  for p in $(ssh_listen_ports); do
    printf '%-14s %-8s %s\n' "SSH" "$p" "$(conn_count "$p")"
  done
  echo
  echo "Son conexiones TCP, no usuarios: una persona puede abrir varias, y todo lo que"
  echo "pasa por PDirect-C o HCR llega a SSH desde 127.0.0.1."
  if hcr_installed; then
    echo "HCR: límites de sesiones -max-sessions $(conf_value "$HCR_CONF" HCR_MAX_SESSIONS)," \
      "-max-sessions-per-ip $(conf_value "$HCR_CONF" HCR_MAX_SESSIONS_PER_IP) (no hay contador de sesiones disponible)."
  fi
  echo "Conexiones por usuario: pendiente (gestión de usuarios)."
}

show_recursos() {
  local unit pid rss thr cpu fds
  printf '%-14s %-8s %-10s %-8s %-6s %s\n' SERVICIO PID "RAM(kB)" "CPU(s)" HILOS DESCRIPTORES
  for unit in pdirect-80 udpgw-7300 hcr-8880; do
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

show_trafico() {
  local dev rx1 tx1 rx2 tx2
  dev="$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [[ -n "$dev" && -r "/sys/class/net/$dev/statistics/rx_bytes" ]] || { echo "No se encontró la interfaz de salida."; return; }
  rx1="$(cat "/sys/class/net/$dev/statistics/rx_bytes")"; tx1="$(cat "/sys/class/net/$dev/statistics/tx_bytes")"
  sleep 1
  rx2="$(cat "/sys/class/net/$dev/statistics/rx_bytes")"; tx2="$(cat "/sys/class/net/$dev/statistics/tx_bytes")"
  echo "Interfaz: $dev (total del servidor, desde el arranque)"
  awk -v r="$rx2" -v t="$tx2" 'BEGIN{printf "  Recibido: %.1f MB\n  Enviado:  %.1f MB\n", r/1048576, t/1048576}'
  awk -v r="$((rx2 - rx1))" -v t="$((tx2 - tx1))" 'BEGIN{printf "  Ahora:    %.1f KB/s recibidos, %.1f KB/s enviados\n", r/1024, t/1024}'
  echo
  echo "Es el tráfico de todo el servidor, no el de cada usuario."
  echo "El consumo por usuario se agregará en una etapa posterior."
}

show_config() {
  local pa
  echo "Archivos de configuración:"
  for f in "$PDIRECT_CONF" "$SERVICES_CONF" "$HCR_CONF"; do
    [[ -e "$f" ]] && echo "  $f"
  done
  echo
  pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
  case "$pa" in
    yes) echo "SSH acepta contraseñas (PasswordAuthentication yes)." ;;
    no) echo "${Y}SSH NO acepta contraseñas (PasswordAuthentication no).${N}"
        echo "Las cuentas no podrán entrar con usuario y contraseña. El panel no cambia esto." ;;
    *) echo "No se pudo leer la configuración efectiva de SSH (sshd -T)." ;;
  esac
}

# ------------------------------------------------------------------ acciones
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
    echo "${R}La operación falló (código $rc). No se aplicaron cambios parciales.${N}"
  fi
  return 0
}

pick_service() {
  # Muestra los servicios instalados y deja la unidad elegida en PICKED.
  local units=() unit i=1
  PICKED=""
  for unit in pdirect-80 udpgw-7300 hcr-8880; do
    unit_exists "$unit" && units+=("$unit")
  done
  for unit in "${units[@]}"; do
    echo "  $i) $(service_name "$unit") ($unit)"
    i=$((i + 1))
  done
  echo "  0) Volver"
  ask "Servicio: "
  [[ "$REPLY" =~ ^[0-9]+$ ]] || { echo "Opción inválida."; return 1; }
  ((REPLY >= 1 && REPLY <= ${#units[@]})) || return 1
  PICKED="${units[$((REPLY - 1))]}"
}

menu_protocolos() {
  while true; do
    banner
    echo "${B}PROTOCOLOS${N}"; echo
    show_estado; echo
    echo "  1) Iniciar   2) Detener   3) Reiniciar   4) Habilitar al arranque   5) Deshabilitar al arranque"
    echo "  6) Instalar HCR   7) Desinstalar HCR   0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1|2|3|4|5)
        local action
        case "$REPLY" in 1) action=iniciar ;; 2) action=detener ;; 3) action=reiniciar ;; 4) action=habilitar ;; 5) action=deshabilitar ;; esac
        pick_service || continue
        if [[ "$action" == detener || "$action" == deshabilitar ]]; then
          confirm "¿$action $(service_name "$PICKED")? Los clientes conectados se desconectarán." || continue
        fi
        if [[ "$PICKED" == hcr-8880 && "$action" =~ ^(iniciar|detener|reiniciar)$ ]]; then
          run_logged "accion=$action servicio=$PICKED" "$HCR" "$action"
        else
          run_logged "accion=$action servicio=$PICKED" "$PUERTOS" "$action" "$PICKED"
        fi
        pause
        ;;
      6)
        if hcr_installed; then
          echo "HCR ya está instalado. Para reinstalarlo con el mismo puerto y destino, confirmá."
        else
          echo "Se usará /opt/hcr/hcr-server (copialo antes por SFTP), puerto 8880 y el destino SSH de PDirect-C."
        fi
        confirm "¿Instalar HCR?" && run_logged "accion=instalar servicio=hcr-8880" "$HCR" instalar
        pause
        ;;
      7)
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

menu_puertos() {
  while true; do
    banner
    echo "${B}PUERTOS${N}"; echo
    show_puertos; echo
    echo "  1) Cambiar el puerto SSH de destino (PDirect-C y HCR)"
    echo "  2) Cambiar el puerto de HCR"
    echo "  0) Volver"
    echo "El puerto 80 de PDirect-C y el 7300 de UDPGW no se cambian desde el panel."
    ask "Opción: "
    case "$REPLY" in
      1)
        echo "Indicá el puerto donde YA escucha SSH. El panel no cambia el puerto de sshd."
        ask "Puerto SSH (1-65535): "
        valid_port "$REPLY" || { echo "Puerto no válido."; pause; continue; }
        local p="$REPLY"
        confirm "¿Apuntar PDirect-C${HCR_SUFFIX:-} a 127.0.0.1:$p?" \
          && run_logged "accion=puerto-ssh valor=$p" "$PUERTOS" puerto-ssh "$p"
        pause
        ;;
      2)
        hcr_installed || { echo "HCR no está instalado."; pause; continue; }
        ask "Nuevo puerto de HCR (1024-65535, por ejemplo 8880 u 8080): "
        valid_port "$REPLY" || { echo "Puerto no válido."; pause; continue; }
        local q="$REPLY"
        confirm "¿Cambiar el puerto de HCR a $q? Los clientes deberán usar el nuevo puerto." \
          && run_logged "accion=puerto-hcr valor=$q" "$HCR" puerto "$q"
        pause
        ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

make_backup() {
  local dir files=()
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

menu_mantenimiento() {
  while true; do
    banner
    echo "${B}CONFIGURACIÓN Y MANTENIMIENTO${N}"; echo
    show_config; echo
    echo "  1) Guardar copia de la configuración   2) Ver copias guardadas"
    echo "  3) Ver registro de un servicio          4) Ver registro del panel"
    echo "  0) Volver"
    ask "Opción: "
    case "$REPLY" in
      1) make_backup; pause ;;
      2) ls -1 "$BACKUP_ROOT" 2>/dev/null || echo "No hay copias."; pause ;;
      3) pick_service && journalctl -u "$PICKED" -n 40 --no-pager; pause ;;
      4) journalctl -t "$LOG_TAG" -n 40 --no-pager; pause ;;
      0|"") return ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

view() {
  banner
  echo "${B}$1${N}"; echo
  "$2"
  pause
}

main_menu() {
  while true; do
    banner
    show_estado
    echo
    echo "  1) Usuarios                 5) Consumo de recursos"
    echo "  2) Protocolos               6) Consumo de ancho de banda"
    echo "  3) Puertos                  7) Estado de servicios"
    echo "  4) Conexiones activas       8) Configuración y mantenimiento"
    echo "  0) Salir"
    ask "Opción: " || true
    case "$REPLY" in
      1) banner; echo "La gestión de usuarios se agregará en la próxima etapa."; pause ;;
      2) menu_protocolos ;;
      3) menu_puertos ;;
      4) view "CONEXIONES ACTIVAS" show_conexiones ;;
      5) view "CONSUMO DE RECURSOS" show_recursos ;;
      6) view "CONSUMO DE ANCHO DE BANDA" show_trafico ;;
      7) view "ESTADO DE SERVICIOS" show_estado ;;
      8) menu_mantenimiento ;;
      0|"") [[ -t 1 ]] && clear; return 0 ;;
      *) echo "Opción inválida."; sleep 1 ;;
    esac
  done
}

main() {
  [[ ${EUID} -eq 0 ]] || { echo "Usá sudo: sudo vpsarg" >&2; exit 1; }
  if hcr_installed; then HCR_SUFFIX=" y HCR"; else HCR_SUFFIX=""; fi
  case "${1:-}" in
    "") main_menu ;;
    estado) show_estado ;;
    puertos) show_puertos ;;
    conexiones) show_conexiones ;;
    recursos) show_recursos ;;
    trafico) show_trafico ;;
    -h|--help|ayuda) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
