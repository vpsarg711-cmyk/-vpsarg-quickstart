#!/usr/bin/env bash
# Emisión de tokens de instalación de VPS ARG QuickStart.
# Se usa en la computadora de quien emite los tokens, NUNCA en una VPS.
# La clave privada no se sube al repositorio ni se copia a ninguna VPS.
#
#   emitir-token.sh clave CARPETA
#       Crea CARPETA/vpsarg-token-privada.pem (0600) y muestra la clave pública,
#       que va en VPSARG_TOKEN_PUBKEY de vpsarg-token.sh.
#   emitir-token.sh emitir CLAVE_PRIVADA ID VENCE ALCANCE [NOTA]
#       Muestra un token. ID: letras, números, _ y - (hasta 40); usá uno distinto por token.
#       VENCE: AAAA-MM-DD (vale hasta ese día inclusive, UTC).
#       ALCANCE: base (PDirect-C, UDPGW, panel) o base,hcr (además HCR). NOTA: opcional, hasta 60.
set -Eeuo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# Fecha válida en GNU (Linux) o BSD (macOS).
valid_date() { date -u -d "$1" >/dev/null 2>&1 || date -u -j -f %F "$1" >/dev/null 2>&1; }

command -v openssl >/dev/null 2>&1 || fail "Falta openssl."

case "${1:-}" in
  clave)
    dir="${2:?Uso: emitir-token.sh clave CARPETA}"
    key="$dir/vpsarg-token-privada.pem"
    [[ -e "$key" ]] && fail "Ya existe $key. No se sobrescribe."
    install -d -m 0700 "$dir"
    (umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$key")
    echo "Clave privada: $key (guardala con respaldo; quien la tenga puede emitir tokens)."
    echo "Clave pública para VPSARG_TOKEN_PUBKEY de vpsarg-token.sh:"
    openssl ec -in "$key" -pubout 2>/dev/null
    ;;
  emitir)
    (($# >= 5 && $# <= 6)) || fail "Uso: emitir-token.sh emitir CLAVE_PRIVADA ID VENCE ALCANCE [NOTA]"
    key="$2" id="$3" vence="$4" alcance="$5" nota="${6:-}"
    [[ -r "$key" ]] || fail "No se puede leer $key."
    [[ "$id" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || fail "ID no válido."
    if [[ ! "$vence" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! valid_date "$vence"; then
      fail "VENCE no válido (AAAA-MM-DD)."
    fi
    [[ "$alcance" == base || "$alcance" == base,hcr ]] || fail "ALCANCE no válido (base o base,hcr)."
    [[ "$nota" =~ ^[A-Za-z0-9\ ._@-]{0,60}$ ]] || fail "NOTA no válida (letras, números, espacio y . _ @ -, hasta 60)."
    data="id=$id"$'\n'"vence=$vence"$'\n'"alcance=$alcance"
    [[ -n "$nota" ]] && data+=$'\n'"nota=$nota"
    payload="$(printf '%s' "$data" | b64url)"
    sig="$(printf 'vpsarg1.%s' "$payload" | openssl dgst -sha256 -sign "$key" | b64url)"
    echo "vpsarg1.$payload.$sig"
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
