#!/usr/bin/env bash
# VPS ARG QuickStart - controlador de servicios
set -Eeuo pipefail

CONFIG="/etc/vpsarg-servicios.conf"
PDIRECT_CONF="/etc/vpsarg-pdirect.conf"
PDIRECT_SERVICE="pdirect-80"
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

Servicios: pdirect-80 (TCP 80) y udpgw-7300 (TCP 7300).
Sin [servicio], la acción se aplica a todos los de /etc/vpsarg-servicios.conf.

puerto-ssh solo cambia a qué puerto local 127.0.0.1 reenvía PDirect-C.
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
  echo
  echo "===== Puertos TCP en escucha (80, 7300) ====="
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp '( sport = :80 or sport = :7300 )'
  else
    echo "No está disponible el comando ss (paquete iproute2)."
  fi
}

set_ssh_port() {
  local new="$1" old
  valid_port "$new" || fail "Puerto no válido: $new (usá un número entre 1 y 65535)."
  systemctl cat "$PDIRECT_SERVICE" >/dev/null 2>&1 || fail "No existe la unidad $PDIRECT_SERVICE."
  old="$(ssh_port_current)"

  if [[ "$new" == "$old" ]]; then
    echo "PDirect-C ya reenvía a 127.0.0.1:$new. Sin cambios."
    return 0
  fi

  if ! port_open "$new"; then
    echo "AVISO: no hay ningún servicio escuchando en 127.0.0.1:$new." >&2
    echo "Comprobá el puerto real de SSH con: sudo ss -ltnp | grep -E 'sshd|systemd'" >&2
    confirm "¿Usar igualmente el puerto $new?" || fail "Cancelado. Se mantiene el puerto $old."
  fi

  local tmp
  tmp="$(mktemp "${PDIRECT_CONF}.XXXXXX")"
  printf 'SSH_PORT=%s\n' "$new" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$PDIRECT_CONF"
  echo "Puerto SSH de destino: $old -> $new (archivo $PDIRECT_CONF)."

  if systemctl is-active --quiet "$PDIRECT_SERVICE"; then
    if systemctl restart "$PDIRECT_SERVICE" && sleep 1 && systemctl is-active --quiet "$PDIRECT_SERVICE"; then
      echo "$PDIRECT_SERVICE reiniciado. Sigue escuchando en TCP 80."
    else
      printf 'SSH_PORT=%s\n' "$old" > "$PDIRECT_CONF"
      systemctl restart "$PDIRECT_SERVICE" || true
      fail "$PDIRECT_SERVICE no arrancó con el puerto $new; se restauró $old. Revisá: journalctl -u $PDIRECT_SERVICE -n 50"
    fi
  else
    echo "$PDIRECT_SERVICE está detenido; el cambio se aplicará al iniciarlo."
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
