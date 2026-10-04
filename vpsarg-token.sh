# shellcheck shell=bash
# VPS ARG QuickStart - cliente del servicio de autorización de instalaciones.
# Se carga con "source" desde install.sh; quien lo carga define fail().
# No ejecuta nada al cargarse.
#
# Un token (vpsarg_ + 43 caracteres) autoriza UNA instalación completa:
#   token_reserve  -> el servicio lo reserva para esta VPS (nadie más puede usarlo)
#   token_release  -> la instalación no empezó o se revirtió: el token vuelve a estar disponible
#   token_confirm  -> la instalación terminó bien: el token queda consumido para siempre
# El token viaja solo por HTTPS en el cuerpo del pedido (por stdin de curl, no aparece en ps).
# Nunca se guarda en disco ni en registros. Solo autoriza instalar: no interviene en el
# login de los usuarios ni en los servicios instalados.

# Dirección del servicio de autorización (https://...). Vacía hasta que se configure.
VPSARG_AUTH_URL=""
VPSARG_INSTALL_RECORD="/etc/vpsarg/instalacion"
# shellcheck disable=SC2034  # las variables TOKEN_* las usa quien carga este archivo
TOKEN=""
TOKEN_ID=""
RESERVA_ID=""
TOKEN_RESP=""
TOKEN_HTTP=""

# Lee el token de VPSARG_TOKEN o de la terminal (sin eco). Nunca de un argumento.
token_read() {
  TOKEN="${VPSARG_TOKEN:-}"
  if [[ -z "$TOKEN" ]] && { exec 5</dev/tty; } 2>/dev/null; then
    read -r -s -u 5 -p "Token de instalación: " TOKEN || TOKEN=""
    exec 5<&-
    echo
  fi
  [[ -n "$TOKEN" ]] || fail "Falta el token de instalación (escribilo cuando se pida o usá VPSARG_TOKEN). No se realizaron cambios."
}

token_url() {
  # Laboratorio: solo junto con una copia local del repositorio (VPSARG_SRC_DIR).
  if [[ -n "${VPSARG_SRC_DIR:-}" && -n "${VPSARG_LAB_AUTH_URL:-}" ]]; then
    echo "$VPSARG_LAB_AUTH_URL"
  else
    echo "$VPSARG_AUTH_URL"
  fi
}

# Valor de un campo de texto simple de la respuesta JSON del servicio.
token_field() {
  sed -n "s/.*\"$1\": *\"\([A-Za-z0-9_-]*\)\".*/\1/p" <<< "$TOKEN_RESP" | head -n 1
}

# token_post RUTA JSON: deja la respuesta en TOKEN_RESP y el código HTTP en TOKEN_HTTP.
token_post() {
  local out
  TOKEN_RESP="" TOKEN_HTTP=""
  out="$(printf '%s' "$2" | curl -sS --max-time 20 --proto =https,http -H 'Content-Type: application/json' \
           --data-binary @- -w '\n%{http_code}' "$(token_url)$1" 2>/dev/null)" || return 1
  TOKEN_HTTP="${out##*$'\n'}"
  TOKEN_RESP="${out%$'\n'*}"
}

token_hostname() {
  hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-' | cut -c1-64
}

# Reserva el token para esta instalación. No cambia nada del sistema.
token_reserve() {
  local url motivo
  url="$(token_url)"
  [[ -n "$url" ]] || fail "Este instalador no tiene configurado el servicio de autorización. No se realizaron cambios."
  [[ "$url" == https://* || ( -n "${VPSARG_SRC_DIR:-}" && "$url" == http://127.0.0.1:* ) ]] \
    || fail "El servicio de autorización debe usar https. No se realizaron cambios."
  command -v curl >/dev/null 2>&1 || fail "Falta curl para validar el token (apt-get install curl). No se realizaron cambios."
  [[ "$TOKEN" =~ ^vpsarg_[A-Za-z0-9_-]{43}$ ]] || fail "El token no tiene un formato válido. No se realizaron cambios."
  token_post /v1/reservar "{\"token\":\"$TOKEN\",\"hostname\":\"$(token_hostname)\"}" \
    || fail "No se pudo contactar el servicio de autorización. No se realizaron cambios."
  if [[ "$TOKEN_HTTP" == 200 && "$(token_field resultado)" == reservado ]]; then
    TOKEN_ID="$(token_field token_id)"
    RESERVA_ID="$(token_field reserva_id)"
    [[ "$TOKEN_ID" =~ ^[A-Za-z0-9_-]{1,40}$ && "$RESERVA_ID" =~ ^[A-Za-z0-9_-]{22}$ ]] \
      || fail "Respuesta inesperada del servicio de autorización. No se realizaron cambios."
    echo "Token válido ($TOKEN_ID): reservado para esta instalación."
    return 0
  fi
  motivo="$(token_field motivo)"
  case "$motivo" in
    invalido) fail "El token no es válido. No se realizaron cambios." ;;
    vencido) fail "El token venció. Pedí uno nuevo. No se realizaron cambios." ;;
    revocado) fail "El token fue revocado. No se realizaron cambios." ;;
    consumido) fail "El token ya se usó en otra instalación. Pedí uno nuevo. No se realizaron cambios." ;;
    en_uso) fail "El token está reservado por otra instalación en curso. No se realizaron cambios." ;;
    demasiados_pedidos) fail "Demasiados intentos. Esperá un minuto. No se realizaron cambios." ;;
    *) fail "El servicio de autorización no aceptó el pedido (HTTP ${TOKEN_HTTP:-?}). No se realizaron cambios." ;;
  esac
}

# Devuelve el token al estado disponible (la instalación no empezó o se revirtió).
token_release() {
  [[ -n "$RESERVA_ID" ]] || return 0
  if token_post /v1/liberar "{\"token\":\"$TOKEN\",\"reserva_id\":\"$RESERVA_ID\"}" \
     && [[ "$TOKEN_HTTP" == 200 ]]; then
    echo "El token quedó disponible otra vez."
  else
    echo "AVISO: no se pudo liberar el token; vuelve a estar disponible solo en 30 minutos." >&2
  fi
  RESERVA_ID=""
}

# Marca el token como consumido. Reintenta ante fallos de red.
token_confirm() {
  local _
  for _ in 1 2 3 4 5; do
    if token_post /v1/confirmar "{\"token\":\"$TOKEN\",\"reserva_id\":\"$RESERVA_ID\"}" \
       && [[ "$TOKEN_HTTP" == 200 && "$(token_field resultado)" == consumido ]]; then
      RESERVA_ID=""
      return 0
    fi
    [[ "$TOKEN_HTTP" == 403 ]] && return 1
    sleep 3
  done
  return 1
}

# Registra en esta VPS el id del token (nunca el token) y la fecha.
token_record() {
  install -d -o root -g root -m 0700 "${VPSARG_INSTALL_RECORD%/*}"
  (umask 077; printf 'token_id=%s\nfecha=%s\nestado=%s\n' "$TOKEN_ID" "$(date -u +%FT%TZ)" "$1" \
     > "$VPSARG_INSTALL_RECORD")
  chmod 0600 "$VPSARG_INSTALL_RECORD"
  logger -t vpsarg-instalador "token_id=$TOKEN_ID resultado=$1" 2>/dev/null || true
}
