#!/usr/bin/env bash
# VPS ARG QuickStart - controlador de servicios
set -Eeuo pipefail

CONFIG="/etc/vpsarg-servicios.conf"
PDIRECT_CONF="/etc/vpsarg-pdirect.conf"
PDIRECT_SERVICE="pdirect-80"
HCR_SERVICE="hcr-8880"
HCR_CONF="/etc/vpsarg-hcr.conf"
HCR_CTL="/usr/local/sbin/vpsarg-hcr"
BHTTP_CONF="/etc/vpsarg-bhttp.conf"
BHTTP_CTL="/usr/local/sbin/vpsarg-bhttp"
DEFAULT_SERVICES=(pdirect-80 udpgw-7300)

usage() {
  cat <<'EOF'
VPS ARG QuickStart - controlador de servicios

Uso:
  sudo vpsarg-puertos estado       [servicio]
  sudo vpsarg-puertos iniciar      [servicio]
  sudo vpsarg-puertos detener      [servicio]
  sudo vpsarg-puertos reiniciar    [servicio]
  sudo vpsarg-puertos habilitar    [servicio]
  sudo vpsarg-puertos deshabilitar [servicio]
  sudo vpsarg-puertos puerto-ssh           (muestra el puerto SSH de destino)
  sudo vpsarg-puertos puerto-ssh PUERTO    (cambia el puerto SSH de destino)

Servicios: pdirect-80 (TCP 80), udpgw-7300 (TCP 7300) y, si están instalados,
hcr-8880 (puerto en /etc/vpsarg-hcr.conf), bhttp-server y bhttp-shim (/etc/vpsarg-bhttp.conf).
Sin [servicio], la acción se aplica a todos los de /etc/vpsarg-servicios.conf.

puerto-ssh solo cambia a qué puerto local 127.0.0.1 reenvían PDirect-C, HCR y BHTTP
(si están instalados). Debe ser el puerto donde ya escucha SSH.
No modifica sshd, el puerto 80 ni el firewall.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

require_root() {
  [[ ${EUID} -eq 0 ]] || { echo "Usá sudo: sudo vpsarg-puertos $*" >&2; exit 1; }
}

load_services() {
  SERVICES=()
  if [[ -f "$CONFIG" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^[a-zA-Z0-9_.@-]+$ ]] || fail "Nombre de servicio no válido en $CONFIG"
      SERVICES+=("$line")
    done < "$CONFIG"
  else
    SERVICES=("${DEFAULT_SERVICES[@]}")
  fi
  ((${#SERVICES[@]} > 0)) || fail "No hay servicios configurados."
}

# Limita la acción a un servicio de la lista, si se indicó uno.
select_service() {
  local wanted="${1:-}" svc
  [[ -z "$wanted" ]] && return 0
  wanted="${wanted%.service}"
  for svc in "${SERVICES[@]}"; do
    if [[ "${svc%.service}" == "$wanted" ]]; then
      SERVICES=("$svc")
      return 0
    fi
  done
  fail "Servicio desconocido: $wanted (disponibles: ${SERVICES[*]})"
}

check_services() {
  local svc missing=()
  for svc in "${SERVICES[@]}"; do
    systemctl cat "$svc" >/dev/null 2>&1 || missing+=("$svc")
  done
  ((${#missing[@]} == 0)) || fail "No se encontraron estas unidades: ${missing[*]}. No se realizaron cambios."
}

ssh_port_current() {
  [[ -r "$PDIRECT_CONF" ]] || fail "No existe $PDIRECT_CONF. ¿Está instalado PDirect-C?"
  local port
  port="$(sed -n 's/^SSH_PORT=\([0-9]\{1,5\}\)$/\1/p' "$PDIRECT_CONF" | tail -n 1)"
  [[ -n "$port" ]] || fail "$PDIRECT_CONF no contiene una línea SSH_PORT=NUMERO válida."
  echo "$port"
}

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

port_open() {
  timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

confirm() {
  local answer
  { exec 4</dev/tty; } 2>/dev/null || return 1
  read -r -u 4 -p "$1 [s/N]: " answer || answer=""
  exec 4<&-
  [[ "$answer" =~ ^[sS]$ ]]
}

show_status() {
  local svc port
  for svc in "${SERVICES[@]}"; do
    echo
    echo "===== $svc ====="
    systemctl --no-pager --full status "$svc" || true
  done
  echo
  if [[ -r "$PDIRECT_CONF" ]]; then
    port="$(ssh_port_current)"
    printf 'PDirect-C reenvía a 127.0.0.1:%s (SSH local): ' "$port"
    if port_open "$port"; then echo "responde"; else echo "NO responde"; fi
  fi
  local ports=(80 7300) filter="" p
  if [[ -r "$HCR_CONF" ]]; then
    port="$(sed -n 's/^HCR_PORT=\([0-9]\{1,5\}\)$/\1/p' "$HCR_CONF" | tail -n 1)"
    [[ -n "$port" ]] && ports+=("$port")
  fi
  if [[ -r "$BHTTP_CONF" ]]; then
    port="$(sed -n 's/^BHTTP_PORT=\([0-9]\{1,5\}\)$/\1/p' "$BHTTP_CONF" | tail -n 1)"
    [[ -n "$port" ]] && ports+=("$port")
  fi
  for p in "${ports[@]}"; do
    filter+="${filter:+ or }sport = :$p"
  done
  echo
  echo "===== Puertos TCP en escucha (${ports[*]}) ====="
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "( $filter )"
  else
    echo "No está disponible el comando ss (paquete iproute2)."
  fi
}

# Lee la primera línea de 127.0.0.1:PUERTO y comprueba que sea un banner SSH.
ssh_banner() {
  # shellcheck disable=SC2016  # el script interno se expande en el bash hijo
  timeout 5 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
    IFS= read -r -t 4 l <&3 && [[ "$l" == SSH-* ]]' _ "$1" 2>/dev/null
}

# Pide una conexión a PDirect-C (TCP 80) y comprueba que detrás responda SSH.
pdirect_reaches_ssh() {
  # shellcheck disable=SC2016  # el script interno se expande en el bash hijo
  timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/80 || exit 1
    printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" >&3
    for _ in 1 2 3 4 5 6 7 8; do
      IFS= read -r -t 4 l <&3 || exit 1
      [[ "$l" == SSH-* ]] && exit 0
    done
    exit 1' 2>/dev/null
}

# Puerto SSH que usa realmente el proceso de PDirect-C (su único argumento).
pdirect_running_port() {
  local pid
  pid="$(systemctl show -p MainPID --value "$PDIRECT_SERVICE")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  tr '\0' '\n' < "/proc/$pid/cmdline" | sed -n 2p
}

hcr_installed() {
  [[ -x "$HCR_CTL" && -r "$HCR_CONF" ]] && systemctl cat "$HCR_SERVICE" >/dev/null 2>&1
}

bhttp_installed() {
  [[ -x "$BHTTP_CTL" && -r "$BHTTP_CONF" ]] && systemctl cat bhttp-server >/dev/null 2>&1
}

bhttp_ssh_port() {
  sed -n 's/^BHTTP_SSH_PORT=\([0-9]\{1,5\}\)$/\1/p' "$BHTTP_CONF" | tail -n 1
}

hcr_ssh_port() {
  sed -n 's/^HCR_SSH_PORT=\([0-9]\{1,5\}\)$/\1/p' "$HCR_CONF" | tail -n 1
}

write_pdirect_conf() {
  local tmp
  tmp="$(mktemp "${PDIRECT_CONF}.XXXXXX")"
  printf 'SSH_PORT=%s\n' "$1" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$PDIRECT_CONF"
}

# Vuelve PDirect-C al puerto anterior después de un fallo y verifica el resultado.
rollback_pdirect() {
  local old="$1" was_active="$2" pid problem="" _
  write_pdirect_conf "$old"
  if ((was_active)); then
    systemctl restart "$PDIRECT_SERVICE" || true
    # Espera hasta 10 s a que systemd y PDirect-C terminen de arrancar.
    for _ in $(seq 20); do
      problem=""
      pid="$(systemctl show -p MainPID --value "$PDIRECT_SERVICE")"
      if ! systemctl is-active --quiet "$PDIRECT_SERVICE"; then
        problem="el servicio no está activo"
      elif [[ "$(pdirect_running_port)" != "$old" ]]; then
        problem="el proceso no usa el puerto $old"
      elif ! ss -Hltnp "sport = :80" 2>/dev/null | grep -q "pid=$pid,"; then
        problem="no escucha en TCP 80"
      elif ssh_banner "$old" && ! pdirect_reaches_ssh; then
        problem="una conexión por TCP 80 no llega a SSH"
      fi
      [[ -z "$problem" ]] && break
      sleep 0.5
    done
  fi
  if [[ "$(ssh_port_current)" != "$old" ]]; then
    problem="$PDIRECT_CONF no quedó en $old"
  fi
  if [[ -n "$problem" ]]; then
    # Solo informa: quien llama termina con su propio mensaje de error.
    echo "ATENCIÓN: la reversión de PDirect-C no se pudo verificar: $problem. Revisá: journalctl -u $PDIRECT_SERVICE -n 50" >&2
    return 0
  fi
  if ((was_active)); then
    if ssh_banner "$old"; then
      echo "Reversión verificada: PDirect-C activo, escucha en TCP 80, apunta a 127.0.0.1:$old y llega a SSH." >&2
    else
      echo "Reversión verificada: PDirect-C activo, escucha en TCP 80 y apunta a 127.0.0.1:$old (SSH no responde en $old, no se pudo probar el flujo)." >&2
    fi
  else
    echo "Reversión verificada: $PDIRECT_CONF vuelve a $old (PDirect-C estaba detenido)." >&2
  fi
}

# Cambia el destino SSH de PDirect-C y, si están instalados, de HCR y BHTTP.
# No cambia el puerto de sshd: el nuevo valor debe ser donde ya escucha SSH.
set_ssh_port() {
  local new="$1" old hcr_old="" bh_old="" ssh_ok=0 pd_active=0
  valid_port "$new" || fail "Puerto no válido: $new (usá un número entre 1 y 65535)."
  systemctl cat "$PDIRECT_SERVICE" >/dev/null 2>&1 || fail "No existe la unidad $PDIRECT_SERVICE."
  old="$(ssh_port_current)"
  hcr_installed && hcr_old="$(hcr_ssh_port)"
  bhttp_installed && bh_old="$(bhttp_ssh_port)"

  if [[ "$new" == "$old" && ( -z "$hcr_old" || "$hcr_old" == "$new" ) && ( -z "$bh_old" || "$bh_old" == "$new" ) ]]; then
    echo "PDirect-C${hcr_old:+, HCR}${bh_old:+, BHTTP} ya reenvía a 127.0.0.1:$new. Sin cambios."
    return 0
  fi

  if ssh_banner "$new"; then
    ssh_ok=1
    echo "OK: SSH responde en 127.0.0.1:$new."
  else
    echo "AVISO: no hay un servidor SSH respondiendo en 127.0.0.1:$new." >&2
    echo "Comprobá el puerto real de SSH con: sudo ss -ltnp | grep -E 'sshd|systemd'" >&2
    confirm "¿Usar igualmente el puerto $new?" || fail "Cancelado. Se mantiene el puerto $old."
  fi

  # 1) PDirect-C: solo cambia su archivo de configuración y se reinicia si estaba activo.
  if [[ "$new" != "$old" ]]; then
    write_pdirect_conf "$new"
    echo "PDirect-C: destino $old -> $new (archivo $PDIRECT_CONF)."
    if systemctl is-active --quiet "$PDIRECT_SERVICE"; then
      pd_active=1
      if ! { systemctl restart "$PDIRECT_SERVICE" && sleep 1 && systemctl is-active --quiet "$PDIRECT_SERVICE" \
             && [[ "$(pdirect_running_port)" == "$new" ]]; } \
         || { ((ssh_ok)) && ! pdirect_reaches_ssh; }; then
        rollback_pdirect "$old" "$pd_active"
        fail "$PDIRECT_SERVICE no funcionó con el puerto $new; se restauró $old. Revisá: journalctl -u $PDIRECT_SERVICE -n 50"
      fi
      echo "$PDIRECT_SERVICE reiniciado: escucha en TCP 80 y apunta a 127.0.0.1:$new."
    else
      echo "$PDIRECT_SERVICE está detenido; el cambio se aplicará al iniciarlo."
    fi
  fi

  # 2) HCR, si está instalado. vpsarg-hcr restaura su propio valor si falla.
  if [[ -n "$hcr_old" && "$hcr_old" != "$new" ]]; then
    if ! "$HCR_CTL" destino-ssh "$new"; then
      [[ "$new" != "$old" ]] && rollback_pdirect "$old" "$pd_active"
      fail "HCR no funcionó con el destino $new; se restauraron PDirect-C ($old) y HCR ($hcr_old)."
    fi
  fi

  # 3) BHTTP, si está instalado. vpsarg-bhttp restaura su propio valor si falla.
  if [[ -n "$bh_old" && "$bh_old" != "$new" ]]; then
    if ! "$BHTTP_CTL" destino-ssh "$new"; then
      [[ -n "$hcr_old" && "$hcr_old" != "$new" ]] && { "$HCR_CTL" destino-ssh "$hcr_old" >/dev/null || true; }
      [[ "$new" != "$old" ]] && rollback_pdirect "$old" "$pd_active"
      fail "BHTTP no funcionó con el destino $new; se restauraron PDirect-C ($old), HCR (${hcr_old:-no instalado}) y BHTTP ($bh_old)."
    fi
  fi

  # 4) SSH sigue respondiendo en el puerto elegido.
  if ((ssh_ok)) && ! ssh_banner "$new"; then
    echo "AVISO: SSH dejó de responder en 127.0.0.1:$new durante el cambio. Revisá: systemctl status ssh" >&2
  fi
}

main() {
  local action="${1:-}"
  case "$action" in
    iniciar|detener|reiniciar|habilitar|deshabilitar|estado)
      (($# <= 2)) || { usage; exit 1; }
      require_root "$@"
      load_services
      select_service "${2:-}"
      check_services
      case "$action" in
        iniciar) systemctl start "${SERVICES[@]}" ;;
        detener) systemctl stop "${SERVICES[@]}" ;;
        reiniciar) systemctl restart "${SERVICES[@]}" ;;
        habilitar) systemctl enable --now "${SERVICES[@]}" ;;
        deshabilitar) systemctl disable --now "${SERVICES[@]}" ;;
        estado)
          show_status
          exit 0
          ;;
      esac
      local svc
      for svc in "${SERVICES[@]}"; do
        printf '%s: ' "$svc"
        systemctl is-active "$svc" || true
      done
      ;;
    puerto-ssh)
      (($# <= 2)) || { usage; exit 1; }
      require_root "$@"
      if (($# == 1)); then
        echo "PDirect-C reenvía a 127.0.0.1:$(ssh_port_current)"
      else
        set_ssh_port "$2"
      fi
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
