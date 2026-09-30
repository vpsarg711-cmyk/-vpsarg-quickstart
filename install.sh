#!/usr/bin/env bash
# VPS ARG QuickStart - control de servicios existentes
set -Eeuo pipefail

SERVICES=(pdirect-c udpgw-7300)

usage() {
  cat <<'EOF'
VPS ARG QuickStart

Uso:
  sudo vpsarg-puertos iniciar
  sudo vpsarg-puertos detener
  sudo vpsarg-puertos reiniciar
  sudo vpsarg-puertos estado
  sudo vpsarg-puertos habilitar
  sudo vpsarg-puertos deshabilitar

Servicios controlados:
  pdirect-c   (configuración esperada para TCP/80)
  udpgw-7300  (configuración esperada para UDPGW/7300)

Este comando administra unidades systemd que ya deben existir.
No instala los binarios ni crea sus configuraciones.
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Usá sudo: sudo vpsarg-puertos $*" >&2
    exit 1
  fi
}

check_services() {
  local missing=()
  for svc in "${SERVICES[@]}"; do
    systemctl cat "$svc" >/dev/null 2>&1 || missing+=("$svc")
  done
  if ((${#missing[@]})); then
    echo "No se encontraron estas unidades systemd: ${missing[*]}" >&2
    echo "No se realizaron cambios. Instalá/configurá los servicios primero." >&2
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
  echo "===== Puertos TCP/UDP 80 y 7300 en escucha ====="
  if command -v ss >/dev/null 2>&1; then
    ss -lntup | awk 'NR == 1 || $5 ~ /:(80|7300)$/'
  else
    echo "No está disponible el comando ss."
  fi
}

main() {
  local action="${1:-}"
  case "$action" in
    instalar)
      require_root "$@"
      install -o root -g root -m 0755 "$(readlink -f "$0")" /usr/local/sbin/vpsarg-puertos
      echo "Instalado: /usr/local/sbin/vpsarg-puertos"
      echo "Probá: sudo vpsarg-puertos estado"
      ;;
    iniciar|detener|reiniciar|habilitar|deshabilitar|estado)
      require_root "$@"
      check_services
      case "$action" in
        iniciar) systemctl start "${SERVICES[@]}" ;;
        detener) systemctl stop "${SERVICES[@]}" ;;
        reiniciar) systemctl restart "${SERVICES[@]}" ;;
        habilitar)
          systemctl enable "${SERVICES[@]}"
          systemctl start "${SERVICES[@]}"
          ;;
        deshabilitar)
          systemctl stop "${SERVICES[@]}"
          systemctl disable "${SERVICES[@]}"
          ;;
        estado) show_status; exit 0 ;;
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
