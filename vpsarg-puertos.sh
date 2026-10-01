
#!/usr/bin/env bash
# VPS ARG QuickStart - controlador modular de servicios
set -Eeuo pipefail

CONFIG="/etc/vpsarg-servicios.conf"
DEFAULT_SERVICES=(udpgw-7300)

usage() {
  cat <<'EOF'
VPS ARG QuickStart - controlador de servicios

Uso:
  sudo vpsarg-puertos instalar
  sudo vpsarg-puertos iniciar
  sudo vpsarg-puertos detener
  sudo vpsarg-puertos reiniciar
  sudo vpsarg-puertos estado
  sudo vpsarg-puertos habilitar
  sudo vpsarg-puertos deshabilitar

Configuración:
  /etc/vpsarg-servicios.conf

El instalador podrá agregar servicios a la configuración
sin modificar este controlador.
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Usá sudo: sudo vpsarg-puertos $*" >&2
    exit 1
  fi
}

load_services() {
  SERVICES=()

  if [[ -f "$CONFIG" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"
      [[ -z "$line" ]] && continue

      if [[ ! "$line" =~ ^[a-zA-Z0-9_.@-]+$ ]]; then
        echo "Nombre de servicio no válido en $CONFIG" >&2
        exit 2
      fi

      SERVICES+=("$line")
    done < "$CONFIG"
  else
    SERVICES=("${DEFAULT_SERVICES[@]}")
  fi

  if ((${#SERVICES[@]} == 0)); then
    echo "No hay servicios configurados." >&2
    exit 2
  fi
}

check_services() {
  local svc
  local missing=()

  for svc in "${SERVICES[@]}"; do
    systemctl cat "$svc" >/dev/null 2>&1 || missing+=("$svc")
  done

  if ((${#missing[@]})); then
    echo "No se encontraron estas unidades: ${missing[*]}" >&2
    echo "No se realizaron cambios." >&2
    exit 2
  fi
}

show_status() {
  local svc

  for svc in "${SERVICES[@]}"; do
    echo
    echo "===== $svc ====="
    systemctl --no-pager --full status "$svc" || true
  done

  echo
  echo "===== Puertos TCP/UDP en escucha ====="
  if command -v ss >/dev/null 2>&1; then
    ss -lntup
  else
    echo "No está disponible el comando ss."
  fi
}

main() {
  local action="${1:-}"

  case "$action" in
    instalar)
      require_root "$@"
      install -o root -g root -m 0755 \
        "$(readlink -f "$0")" /usr/local/sbin/vpsarg-puertos
      echo "Controlador instalado."
      echo "Probá: sudo vpsarg-puertos estado"
      ;;

    iniciar|detener|reiniciar|habilitar|deshabilitar|estado)
      require_root "$@"
      load_services
      check_services

      case "$action" in
        iniciar)
          systemctl start "${SERVICES[@]}"
          ;;
        detener)
          systemctl stop "${SERVICES[@]}"
          ;;
        reiniciar)
          systemctl restart "${SERVICES[@]}"
          ;;
        habilitar)
          systemctl enable "${SERVICES[@]}"
          systemctl start "${SERVICES[@]}"
          ;;
        deshabilitar)
          systemctl stop "${SERVICES[@]}"
          systemctl disable "${SERVICES[@]}"
          ;;
        estado)
          show_status
          exit 0
          ;;
      esac

      echo "Estado:"
      for svc in "${SERVICES[@]}"; do
        printf '%s: ' "$svc"
        systemctl is-active "$svc" || true
      done
      ;;

    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
