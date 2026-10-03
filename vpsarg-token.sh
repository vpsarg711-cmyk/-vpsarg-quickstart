# shellcheck shell=bash
# VPS ARG QuickStart - verificador del token de instalación.
# Se carga con "source" desde install.sh y desde vpsarg-hcr; quien lo carga define fail().
# Se instala en /usr/local/lib/vpsarg/token.sh. No ejecuta nada al cargarse.
#
# Token: vpsarg1.<datos en base64url>.<firma ECDSA P-256 / SHA-256 en base64url>
# Datos (una por línea): id=..., vence=AAAA-MM-DD, alcance=base|base,hcr (opcional: base), nota=... (opcional).
# Solo autoriza instalar. No interviene en el login de los usuarios ni en los servicios.
# La clave privada nunca está en el repositorio ni en la VPS (herramientas/emitir-token.sh).

# shellcheck disable=SC2034  # las variables TOKEN_* las usa quien carga este archivo
VPSARG_TOKEN_PUBKEY=""
VPSARG_TOKENS_USED="/etc/vpsarg/tokens-usados"
TOKEN=""
TOKEN_ID=""
TOKEN_EXPIRES=""
TOKEN_SCOPE=""
TOKEN_NOTE=""

token_b64url_decode() {
  local s="${1//-/+}"
  s="${s//_//}"
  while (( ${#s} % 4 )); do s+="="; done
  printf '%s' "$s" | base64 -d 2>/dev/null || true
}

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

token_used() {
  [[ -r "$VPSARG_TOKENS_USED" ]] && grep -q "^id=$1 " "$VPSARG_TOKENS_USED"
}

# token_verify ALCANCE: verifica firma, datos, vencimiento, alcance y que no se haya usado en esta VPS.
# No cambia nada del sistema. Deja TOKEN_ID, TOKEN_EXPIRES, TOKEN_SCOPE y TOKEN_NOTE.
token_verify() {
  local need="$1" payload sig tmp ok=0 data line
  [[ -n "$VPSARG_TOKEN_PUBKEY" ]] || fail "Este instalador no tiene configurada la clave pública de tokens. No se realizaron cambios."
  command -v openssl >/dev/null 2>&1 || fail "Falta openssl para verificar el token. No se realizaron cambios."
  if (( ${#TOKEN} > 1024 )) || [[ ! "$TOKEN" =~ ^vpsarg1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$ ]]; then
    fail "El token no tiene un formato válido. No se realizaron cambios."
  fi
  payload="${BASH_REMATCH[1]}"
  sig="${BASH_REMATCH[2]}"
  tmp="$(mktemp -d)"
  printf '%s\n' "$VPSARG_TOKEN_PUBKEY" > "$tmp/pub.pem"
  printf 'vpsarg1.%s' "$payload" > "$tmp/msg"
  token_b64url_decode "$sig" > "$tmp/sig"
  openssl dgst -sha256 -verify "$tmp/pub.pem" -signature "$tmp/sig" "$tmp/msg" >/dev/null 2>&1 && ok=1
  rm -rf -- "$tmp"
  ((ok)) || fail "La firma del token no es válida. No se realizaron cambios."

  TOKEN_ID="" TOKEN_EXPIRES="" TOKEN_SCOPE="base" TOKEN_NOTE=""
  data="$(token_b64url_decode "$payload")"
  while IFS= read -r line; do
    case "$line" in
      id=*) TOKEN_ID="${line#id=}" ;;
      vence=*) TOKEN_EXPIRES="${line#vence=}" ;;
      alcance=*) TOKEN_SCOPE="${line#alcance=}" ;;
      nota=*) TOKEN_NOTE="${line#nota=}" ;;
      *) fail "El token tiene datos desconocidos. No se realizaron cambios." ;;
    esac
  done <<< "$data"
  [[ "$TOKEN_ID" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || fail "El token no tiene un id válido. No se realizaron cambios."
  [[ "$TOKEN_NOTE" =~ ^[A-Za-z0-9\ ._@-]{0,60}$ ]] || fail "El token tiene una nota no válida. No se realizaron cambios."
  [[ "$TOKEN_SCOPE" == base || "$TOKEN_SCOPE" == base,hcr ]] || fail "El token tiene un alcance no válido. No se realizaron cambios."
  if [[ ! "$TOKEN_EXPIRES" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -u -d "$TOKEN_EXPIRES" >/dev/null 2>&1; then
    fail "El token no tiene una fecha de vencimiento válida. No se realizaron cambios."
  fi
  [[ "$(date -u +%F)" > "$TOKEN_EXPIRES" ]] && fail "El token venció el $TOKEN_EXPIRES. No se realizaron cambios."
  if [[ "$need" == hcr && "$TOKEN_SCOPE" != base,hcr ]]; then
    fail "El token no incluye HCR (alcance: $TOKEN_SCOPE). No se realizaron cambios."
  fi
  token_used "$TOKEN_ID" && fail "El token $TOKEN_ID ya se usó en esta VPS. Pedí uno nuevo. No se realizaron cambios."
  echo "Token válido: $TOKEN_ID${TOKEN_NOTE:+ ($TOKEN_NOTE)}, alcance $TOKEN_SCOPE, vence el $TOKEN_EXPIRES."
}

# token_mark_used USO: registra el id (nunca el token) como usado en esta VPS.
token_mark_used() {
  install -d -o root -g root -m 0700 "${VPSARG_TOKENS_USED%/*}"
  (umask 077; printf 'id=%s uso=%s vence=%s fecha=%s\n' "$TOKEN_ID" "$1" "$TOKEN_EXPIRES" "$(date -u +%FT%TZ)" >> "$VPSARG_TOKENS_USED")
  chmod 0600 "$VPSARG_TOKENS_USED"
  logger -t vpsarg-instalador "token_id=$TOKEN_ID uso=$1 vence=$TOKEN_EXPIRES resultado=instalado" 2>/dev/null || true
}
