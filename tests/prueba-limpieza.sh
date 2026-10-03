#!/usr/bin/env bash
# Pruebas de interrupción y limpieza de tests/validacion-vps.sh.
# SOLO para el contenedor de laboratorio: crea la marca /etc/vpsarg-laboratorio
# (y la borra al final), quita y reinstala sshpass, y borra/restaura el grupo
# vpsarg-usuarios para probar que el script se detiene sin él. NUNCA en una VPS real.
# Uso: sudo bash tests/prueba-limpieza.sh /ruta/a/validacion-vps.sh
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT="${1:?Uso: sudo bash tests/prueba-limpieza.sh /ruta/a/validacion-vps.sh}"
[[ "$(systemd-detect-virt 2>/dev/null)" == docker ]] || { echo "Solo en el contenedor de laboratorio." >&2; exit 1; }
TEST_USER=vpsargprueba
PW='Limpieza-2c.Clave'
OUT=/tmp/limpieza
mkdir -p "$OUT"
PASS=0
FAILS=0
ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
pid_of() { systemctl show -p MainPID --value "$1"; }
args_of() { tr '\0' ' ' < "/proc/$(pid_of "$1")/cmdline"; }

# Todo lo que una corrida interrumpida podría dejar distinto.
state() {
  echo "pdirect conf=$(cat /etc/vpsarg-pdirect.conf) activo=$(systemctl is-active pdirect-80) args=$(args_of pdirect-80)"
  if [[ -r /etc/vpsarg-hcr.conf ]]; then
    echo "hcr conf=$(grep HCR_SSH_PORT /etc/vpsarg-hcr.conf) activo=$(systemctl is-active hcr-8880) args=$(args_of hcr-8880)"
  fi
  echo "udpgw PID=$(pid_of udpgw-7300) inicio=$(systemctl show -p ExecMainStartTimestamp --value udpgw-7300)"
  echo "cuentas, grupos y sombras: $(cat /etc/passwd /etc/shadow /etc/group /etc/gshadow | sha256sum | cut -c1-16)"
  echo "sshd_config y shells: $(cat /etc/ssh/sshd_config /etc/shells | sha256sum | cut -c1-16)"
  echo "home de prueba: $(test -e "/home/$TEST_USER" && echo existe || echo no)"
  echo "suspendidos: $(sha256sum /etc/vpsarg/usuarios-suspendidos 2>/dev/null | cut -c1-16)"
  echo "escuchando 2222/2223/19000: $(ss -Hltn '( sport = :2222 or sport = :2223 or sport = :19000 )' | wc -l)"
  echo "clientes ssh de prueba: $(pgrep -fc -- "[ ]$TEST_USER@127\.0\.0\.1\$")"
  echo "sshpass: $(command -v sshpass >/dev/null && echo instalado || echo no)"
}

# corrida NOMBRE ETAPA SEÑAL [s]: corre la validación y la interrumpe en ETAPA.
run() {
  local name="$1" stage="$2" sig="$3" install="${4:-}" input
  input="$(hostname)"$'\n'
  [[ -n "$install" ]] && input+="s"$'\n'
  input+="$PW"$'\n'"$PW"$'\n'
  printf '%s' "$input" | VALIDACION_PARAR_EN="$stage" VALIDACION_SENAL="$sig" \
    timeout 600 bash "$SCRIPT" --sin-cliente-externo > "$OUT/$name.log" 2>&1
  RC=$?
}

scenario() {
  local name="$1" stage="$2" sig="$3" install="${4:-}" before
  echo "### $name: SIG$sig en '$stage'"
  before="$(state)"
  run "$name" "$stage" "$sig" "$install"
  check "$name: terminó con error por la interrupción (rc=$RC)" test "$RC" -ne 0
  check "$name: llegó a la etapa '$stage'" grep -q ">>> prueba de limpieza: SIG$sig en la etapa '$stage'" "$OUT/$name.log"
  check "$name: limpieza completa, sin FALLÓ" bash -c 'grep -q "^Limpieza completa" "$1" && ! grep -q "Limpieza: FALLÓ" "$1"' _ "$OUT/$name.log"
  check "$name: limpieza ejecutada una sola vez" test "$(grep -c '^### Limpieza' "$OUT/$name.log")" = 1
  check "$name: estado igual al inicial" diff <(echo "$before") <(state)
}

echo "### Preparación (contenedor)"
hostname > /etc/vpsarg-laboratorio
command -v sshpass >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null
getent group vpsarg-usuarios >/dev/null || groupadd --system vpsarg-usuarios
check "bash -n del script" bash -n "$SCRIPT"
check "HCR instalado (para probar su restauración)" test -r /etc/vpsarg-hcr.conf
state > "$OUT/estado-base.txt"

echo "### Sin cambios cuando no se debe empezar"
before="$(state)"
printf 'otra-vps\n' | bash "$SCRIPT" --sin-cliente-externo > "$OUT/nombre-incorrecto.log" 2>&1
check "nombre de VPS incorrecto: se detiene" grep -q "No coincide. No se hizo nada." "$OUT/nombre-incorrecto.log"
check "nombre de VPS incorrecto: estado igual" diff <(echo "$before") <(state)
cp -a /etc/group /etc/gshadow "$OUT/"
groupdel vpsarg-usuarios
run sin-grupo ninguna TERM
check "sin grupo vpsarg-usuarios: se detiene" grep -q "No existe el grupo vpsarg-usuarios" "$OUT/sin-grupo.log"
check "sin grupo: no lo crea" bash -c '! getent group vpsarg-usuarios >/dev/null'
check "sin grupo: no creó la cuenta" bash -c '! getent passwd vpsargprueba >/dev/null'
cp -a "$OUT/group" /etc/group; cp -a "$OUT/gshadow" /etc/gshadow
useradd -M -s /usr/sbin/nologin "$TEST_USER"
run usuario-existente ninguna TERM
check "cuenta de prueba ya existente: se detiene" grep -q "Ya existe la cuenta $TEST_USER" "$OUT/usuario-existente.log"
check "cuenta ya existente: no la toca" getent passwd "$TEST_USER"
userdel "$TEST_USER"
check "estado igual tras los casos de parada" diff <(echo "$before") <(state)

echo "### Interrupciones"
scenario antes-usuario   antes-usuario    TERM
scenario despues-usuario despues-usuario  INT
scenario pdirect         pdirect          HUP
scenario tunel-activo    tunel-activo     TERM
scenario suspendida      suspendida       INT
scenario sshd-temporal   sshd-temporal    TERM
scenario destino         destino-cambiado INT
scenario hcr             hcr              HUP
scenario respondedor     respondedor      TERM

echo "### sshpass instalado por la prueba"
DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq sshpass >/dev/null
check "sshpass quitado para la prueba" bash -c '! command -v sshpass >/dev/null'
scenario sshpass-interrumpida destino-cambiado TERM s
check "sshpass-interrumpida: lo instaló y lo desinstaló" bash -c 'grep -q "sshpass instalado por la prueba" "$1" && grep -q "Limpieza: OK      sshpass desinstalado" "$1"' _ "$OUT/sshpass-interrumpida.log"
before="$(state)"
run sshpass-completa ninguna TERM s
check "corrida completa sin sshpass previo: todas sus pruebas pasan" grep -q "Resultado: [0-9]* pasan, 0 fallan" "$OUT/sshpass-completa.log"
check "corrida completa: rc=0" test "$RC" = 0
check "corrida completa: sshpass desinstalado al final" bash -c '! command -v sshpass >/dev/null'
check "corrida completa: estado igual al inicial" diff <(echo "$before") <(state)
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null

echo "### Corrida completa normal (sshpass ya instalado)"
before="$(state)"
run completa ninguna TERM
check "completa: rc=0" test "$RC" = 0
grep -E "^######## Resultado" "$OUT/completa.log"
check "completa: todas sus pruebas pasan" grep -q "Resultado: [0-9]* pasan, 0 fallan" "$OUT/completa.log"
check "completa: limpieza una sola vez (Prueba 9) y sin FALLÓ" bash -c '[[ $(grep -c "^### Limpieza" "$1") == 1 ]] && ! grep -q "Limpieza: FALLÓ" "$1"' _ "$OUT/completa.log"
check "completa: sshpass sigue instalado (estaba al empezar)" command -v sshpass
check "completa: estado igual al inicial" diff <(echo "$before") <(state)

check "las claves de prueba no aparecen en los logs de la validación" bash -c '! grep -rqF -- "$1" /root/validacion-vps-* "$2"' _ "$PW" "$OUT"
rm -f /etc/vpsarg-laboratorio
check "estado final igual a la base" diff "$OUT/estado-base.txt" <(state)
echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
