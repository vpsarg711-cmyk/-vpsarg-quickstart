#!/usr/bin/env bash
# Pruebas del servicio de autorización (servicio/vpsarg-autorizacion.py).
# Levanta instancias temporales en 127.0.0.1 (puertos 8091 y 8092) con bases temporales.
# No necesita root ni toca el sistema.
# Uso: bash tests/prueba-servicio.sh /ruta/al/repo
# shellcheck disable=SC2016
set -uo pipefail

REPO="${1:?Uso: bash tests/prueba-servicio.sh /ruta/al/repo}"
SVC="$REPO/servicio/vpsarg-autorizacion.py"
W="$(mktemp -d)"
DB="$W/tokens.db"
URL=http://127.0.0.1:8091
PASS=0
FAILS=0
PIDS=()
ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
adm() { python3 "$SVC" --db "$DB" "$@"; }
# new_token: deja el token en T y su id en ID.
# shellcheck disable=SC2120  # sin argumentos en estas pruebas
new_token() {
  local out
  out="$(adm emitir --nota prueba "$@" 2>&1)"
  T="$(tail -n 1 <<<"$out")"
  ID="$(sed -n 's/^ID: \([^ ]*\) .*/\1/p' <<<"$out")"
}
# post RUTA JSON [URL]: deja el cuerpo en R y el código en H.
post() {
  local out
  out="$(printf '%s' "$2" | curl -sS -m 10 -H 'Content-Type: application/json' --data-binary @- -w '\n%{http_code}' "${3:-$URL}$1")"
  H="${out##*$'\n'}"; R="${out%$'\n'*}"
}
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" <<<"$R"; }
state_of() { adm ver "$1" | awk '$1=="estado"{print $2}'; }
db_exec() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2], sys.argv[3:]); c.commit()' "$DB" "$@"; }
reserve() { post /v1/reservar "{\"token\":\"$1\",\"hostname\":\"${2:-vps-prueba}\"}"; RES="$(field reserva_id)"; }
serve() {  # serve PUERTO [opciones]
  local port="$1"; shift
  python3 "$SVC" --db "$DB" servir --escuchar "127.0.0.1:$port" "$@" 2>>"$W/servidor-$port.log" &
  PIDS+=("$!")
  for _ in $(seq 30); do curl -fsS -m 2 "http://127.0.0.1:$port/v1/salud" >/dev/null 2>&1 && return 0; sleep 0.2; done
  return 1
}
trap 'kill "${PIDS[@]}" 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$W"' EXIT

echo "### Emisión"
check "servidor de prueba arranca (sin proxy, límite alto)" serve 8091 --sin-proxy --limite 100000
new_token
check "token opaco: vpsarg_ + 43 caracteres" bash -c '[[ "$1" =~ ^vpsarg_[A-Za-z0-9_-]{43}$ ]]' _ "$T"
check "emitir muestra el id" test -n "$ID"
check "la base guarda el hash, no el token" bash -c '! grep -qaF "${1#vpsarg_}" "$2"* && grep -qa "$(printf %s "$1" | sha256sum | cut -d" " -f1)" "$2"*' _ "$T" "$DB"
check "listar y ver no muestran el token ni el hash" \
  bash -c 'o="$(python3 "$1" --db "$2" listar; python3 "$1" --db "$2" ver "$3")"; ! grep -qF "${4#vpsarg_}" <<<"$o" && ! grep -q "$(printf %s "$4" | sha256sum | cut -c1-20)" <<<"$o"' _ "$SVC" "$DB" "$ID" "$T"
check "rechaza un vencimiento pasado" bash -c '! python3 "$1" --db "$2" emitir --vence 2000-01-01 >/dev/null 2>&1' _ "$SVC" "$DB"
check "rechaza una nota con caracteres no permitidos" bash -c '! python3 "$1" --db "$2" emitir --nota "\$(id)" >/dev/null 2>&1' _ "$SVC" "$DB"
check "rechaza un id repetido" bash -c '! python3 "$1" --db "$2" emitir --id "$3" >/dev/null 2>&1' _ "$SVC" "$DB" "$ID"

echo "### Reservar, liberar y confirmar"
reserve "$T"
check "reservar: 200 y reserva_id" bash -c '[[ "$1" == 200 && "$2" =~ ^[A-Za-z0-9_-]{22}$ ]]' _ "$H" "$RES"
check "reservar devuelve el id del token" test "$(field token_id)" = "$ID"
check "estado reservado, con el hostname" bash -c 'python3 "$1" --db "$2" ver "$3" | grep -q "^reserva_host *vps-prueba$"' _ "$SVC" "$DB" "$ID"
R1="$RES"
reserve "$T" otra-vps
check "otra VPS no puede reservarlo mientras tanto (403 en_uso)" bash -c '[[ "$1" == 403 && "$2" == en_uso ]]' _ "$H" "$(field motivo)"
post /v1/liberar "{\"token\":\"$T\",\"reserva_id\":\"AAAAAAAAAAAAAAAAAAAAAA\"}"
check "liberar con otra reserva_id se rechaza" test "$H" = 403
post /v1/confirmar "{\"token\":\"$T\",\"reserva_id\":\"AAAAAAAAAAAAAAAAAAAAAA\"}"
check "confirmar con otra reserva_id se rechaza" bash -c '[[ "$1" == 403 && "$2" == reservado ]]' _ "$H" "$(state_of "$ID")"
post /v1/liberar "{\"token\":\"$T\",\"reserva_id\":\"$R1\"}"
check "liberar con su reserva: vuelve a emitido" bash -c '[[ "$1" == 200 && "$2" == emitido ]]' _ "$H" "$(state_of "$ID")"
reserve "$T"
R2="$RES"
check "se puede reservar otra vez" test "$H" = 200
post /v1/confirmar "{\"token\":\"$T\",\"reserva_id\":\"$R2\"}"
check "confirmar: consumido" bash -c '[[ "$1" == 200 && "$2" == consumido ]]' _ "$H" "$(state_of "$ID")"
post /v1/confirmar "{\"token\":\"$T\",\"reserva_id\":\"$R2\"}"
check "confirmar otra vez con la misma reserva: responde consumido (idempotente)" test "$H" = 200
reserve "$T"
check "consumido: no se puede reservar (403 consumido)" bash -c '[[ "$1" == 403 && "$2" == consumido ]]' _ "$H" "$(field motivo)"
post /v1/liberar "{\"token\":\"$T\",\"reserva_id\":\"$R2\"}"
check "consumido: liberar no lo devuelve" bash -c '[[ "$1" == 403 && "$2" == consumido ]]' _ "$H" "$(state_of "$ID")"
check "revocar un consumido se niega" bash -c '! python3 "$1" --db "$2" revocar "$3" >/dev/null 2>&1' _ "$SVC" "$DB" "$ID"

echo "### Reserva vencida"
new_token
reserve "$T"; RA="$RES"
db_exec "UPDATE tokens SET reserva_vence=? WHERE id=?" "$(( $(date +%s) - 10 ))" "$ID"
reserve "$T" otra-vps; RB="$RES"
check "reserva vencida sin confirmar: otra instalación puede tomarlo" bash -c '[[ "$1" == 200 && "$2" != "$3" ]]' _ "$H" "$RB" "$RA"
post /v1/confirmar "{\"token\":\"$T\",\"reserva_id\":\"$RA\"}"
check "la reserva vieja ya no puede confirmar" test "$H" = 403
new_token
reserve "$T"; RA="$RES"
db_exec "UPDATE tokens SET reserva_vence=? WHERE id=?" "$(( $(date +%s) - 10 ))" "$ID"
post /v1/confirmar "{\"token\":\"$T\",\"reserva_id\":\"$RA\"}"
check "la propia reserva vencida se confirma si nadie la tomó" bash -c '[[ "$1" == 200 && "$2" == consumido ]]' _ "$H" "$(state_of "$ID")"

echo "### Revocado, vencido e inválido"
new_token; adm revocar "$ID" >/dev/null
reserve "$T"
check "revocado: 403 revocado" bash -c '[[ "$1" == 403 && "$2" == revocado ]]' _ "$H" "$(field motivo)"
new_token; db_exec "UPDATE tokens SET vence=? WHERE id=?" "$(date -u -d yesterday +%F)" "$ID"
reserve "$T"
check "vencido: 403 vencido" bash -c '[[ "$1" == 403 && "$2" == vencido ]]' _ "$H" "$(field motivo)"
reserve "vpsarg_$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=' | cut -c1-43)"
check "inexistente: 403 invalido" bash -c '[[ "$1" == 403 && "$2" == invalido ]]' _ "$H" "$(field motivo)"
reserve "x' OR 1=1 --"
check "formato inválido: 403 invalido" bash -c '[[ "$1" == 403 && "$2" == invalido ]]' _ "$H" "$(field motivo)"
post /v1/reservar 'no es json'
check "JSON inválido: 400" test "$H" = 400
post /v1/reservar "{\"token\":\"$(head -c 5000 /dev/zero | tr '\0' a)\"}"
check "cuerpo demasiado grande: 400" test "$H" = 400
post "/v1/reservar/$T" '{}'
check "otra ruta (token en la URL): 404" test "$H" = 404
check "GET /v1/salud responde" bash -c 'curl -fsS "$1/v1/salud" | grep -q true' _ "$URL"
new_token; adm revocar "$ID" >/dev/null
check "admin: liberar un token no reservado se niega" bash -c '! python3 "$1" --db "$2" liberar "$3" >/dev/null 2>&1' _ "$SVC" "$DB" "$ID"

echo "### Concurrencia: 20 instalaciones con el mismo token a la vez"
new_token
CPIDS=()
for i in $(seq 20); do
  ( printf '%s' "{\"token\":\"$T\",\"hostname\":\"vps-$i\"}" \
      | curl -sS -m 30 -H 'Content-Type: application/json' --data-binary @- -o "$W/c-$i.json" -w '%{http_code}' "$URL/v1/reservar" > "$W/c-$i.code" ) &
  CPIDS+=("$!")
done
wait "${CPIDS[@]}"
check "exactamente una reserva gana" test "$(grep -l reservado "$W"/c-*.json | wc -l)" = 1
check "las otras 19 reciben en_uso" test "$(grep -l '"en_uso"' "$W"/c-*.json | wc -l)" = 19
check "ningún error del servidor (todas 200 o 403)" bash -c '[[ "$(cat "$1"/c-*.code | fold -w3 | sort | uniq -c | awk "{printf \"%s:%s \", \$2, \$1}")" == "200:1 403:19 " ]]' _ "$W"

echo "### Límite de pedidos por IP y proxy"
check "servidor detrás de proxy con límite 5 por minuto" serve 8092 --limite 5
new_token
for i in 1 2 3 4 5; do post /v1/reservar "{\"token\":\"vpsarg_$(printf 'A%.0s' $(seq 43))\"}" http://127.0.0.1:8092; done
post /v1/reservar "{\"token\":\"$T\"}" http://127.0.0.1:8092
check "el 6.º pedido del minuto recibe 429" test "$H" = 429
check "el 429 no reservó el token" test "$(state_of "$ID")" = emitido
out="$(printf '%s' "{\"token\":\"$T\",\"hostname\":\"tras-proxy\"}" | curl -sS -H 'X-Forwarded-For: 1.2.3.4, 203.0.113.9' -H 'Content-Type: application/json' --data-binary @- -w '\n%{http_code}' http://127.0.0.1:8092/v1/reservar)"
check "con otra IP real (X-Forwarded-For) no lo frena el límite de la primera" test "${out##*$'\n'}" = 200
check "registra la IP real (la última de X-Forwarded-For)" bash -c 'python3 "$1" --db "$2" ver "$3" | grep -q "^reserva_ip *203.0.113.9$"' _ "$SVC" "$DB" "$ID"
check "sin proxy no confía en X-Forwarded-For" \
  bash -c 'printf "%s" "{\"token\":\"vpsarg_$(printf "B%.0s" $(seq 43))\"}" | curl -sS -o /dev/null -H "X-Forwarded-For: 198.51.100.7" -H "Content-Type: application/json" --data-binary @- "$1/v1/reservar"; ! grep -q 198.51.100.7 "$2"/servidor-8091.log' _ "$URL" "$W"

echo "### Registros"
check "los registros del servidor no tienen tokens" bash -c '! grep -q "vpsarg_" "$1"/servidor-*.log' _ "$W"
check "los eventos guardan id, acción, IP y resultado" \
  bash -c 'python3 "$1" --db "$2" ver "$3" | grep -q "reservar *203.0.113.9 *reservado host=tras-proxy"' _ "$SVC" "$DB" "$ID"

echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
