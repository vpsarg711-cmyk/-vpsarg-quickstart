#!/usr/bin/env bash
# Validación de la Fase 2C y del ajuste 5.1 en una VPS de LABORATORIO real.
# NO correr en producción ni en VPS de clientes.
#
# Requiere QuickStart instalado desde la rama (vpsarg-usuarios y la reversión
# verificada de vpsarg-puertos) y que sshd acepte contraseñas.
# Qué cambia mientras corre (y se deshace al final):
#   - crea y elimina la cuenta de prueba (por defecto vpsargprueba);
#   - inicia un sshd temporal en 127.0.0.1:2222 y un respondedor de una sola
#     conexión en 127.0.0.1:2223, ambos por línea de comandos (sshd_config no se toca);
#   - cambia el destino SSH de PDirect-C (y HCR si está) a 2222 y lo vuelve atrás;
#   - fuerza una reversión con 2223;
#   - instala sshpass si falta (pregunta antes) y lo desinstala al final.
# La contraseña de prueba se escribe sin eco y nunca se muestra ni se guarda.
# Requiere que el grupo vpsarg-usuarios ya exista: el script no lo crea.
#
# Limpieza: un trap sobre INT, TERM, HUP y EXIT deshace todo lo que la prueba
# creó (túneles, sshd temporal, respondedor, cuenta de prueba, destino de
# PDirect-C y HCR, sshpass si lo instaló el script) usando los valores
# originales guardados antes de cambiar nada. Es idempotente y solo toca
# recursos de la prueba. Si una restauración falla, lo dice y termina con error.
#
# Solo para las pruebas de limpieza en el contenedor de laboratorio:
#   VALIDACION_PARAR_EN=ETAPA [VALIDACION_SENAL=INT|TERM|HUP] hace que el script
#   se envíe esa señal al llegar a ETAPA (ver checkpoint).
#
# Identificación del laboratorio: el script no hace nada si no existe
# /etc/vpsarg-laboratorio con el nombre de la VPS (hostname) en su primera línea.
# Ese archivo lo crea a mano el responsable del laboratorio; el script nunca lo crea:
#   hostname | sudo tee /etc/vpsarg-laboratorio
# Además pide escribir el nombre de la VPS antes de empezar.
#
# Uso:
#   sudo bash tests/validacion-vps.sh --solo-lectura   # solo requisitos y fotografía; no cambia nada
#   sudo bash tests/validacion-vps.sh [--sin-cliente-externo] [--usuario NOMBRE]
# shellcheck disable=SC2016,SC1091
set -uo pipefail

TEST_USER="vpsargprueba"
EXTERNAL=1
READONLY=0
while (($#)); do
  case "$1" in
    --sin-cliente-externo) EXTERNAL=0 ;;
    --solo-lectura) READONLY=1 ;;
    --usuario) TEST_USER="${2:-}"; shift ;;
    *) echo "Uso: sudo bash $0 [--solo-lectura | --sin-cliente-externo] [--usuario NOMBRE]" >&2; exit 1 ;;
  esac
  shift
done
[[ "$TEST_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo "Nombre de usuario no válido." >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || { echo "Usá sudo." >&2; exit 1; }
if [[ "$(head -n 1 /etc/vpsarg-laboratorio 2>/dev/null)" != "$(hostname)" ]]; then
  echo "Esta máquina no está marcada como laboratorio (/etc/vpsarg-laboratorio con el nombre $(hostname))." >&2
  echo "No se hizo nada." >&2
  exit 1
fi

START="$(date '+%Y-%m-%d %H:%M:%S')"
DIR="/root/validacion-vps-$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 0700 "$DIR"
LOG="$DIR/validacion.log"
# tee ignora INT/TERM/HUP para que la limpieza siga quedando en el log tras Ctrl+C.
exec > >(trap '' INT TERM HUP; exec tee -p -a "$LOG") 2>&1

PASS=0
FAILS=0
FAILED=()
TUN=""
PW=""
ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); FAILED+=("$*"); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
ask() { REPLY=""; read -r -p "$1" REPLY || REPLY=""; }
pid_of() { systemctl show -p MainPID --value "$1"; }
pd_port() { tr '\0' '\n' < "/proc/$(pid_of pdirect-80)/cmdline" | sed -n 2p; }
hcr_installed() { systemctl cat hcr-8880 >/dev/null 2>&1 && [[ -r /etc/vpsarg-hcr.conf ]]; }
hcr_target() { tr '\0' '\n' < "/proc/$(pid_of hcr-8880)/cmdline" | grep -A1 -x -- -target | tail -n 1; }
expire() { getent shadow "$TEST_USER" | cut -d: -f8; }
pwhash() { getent shadow "$TEST_USER" | cut -d: -f2; }
sessions() { vpsarg-usuarios listar | awk -v u="$TEST_USER" '$1==u{print $(NF-1)}'; }
pdirect_ssh() {
  timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/80 || exit 1
    printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" >&3
    for _ in 1 2 3 4 5 6 7 8; do IFS= read -r -t 4 l <&3 || exit 1; [[ "$l" == SSH-* ]] && exit 0; done; exit 1' 2>/dev/null
}
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
         -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
         -o ConnectTimeout=10)
tunnel() {
  local via="$1" proxy=()
  [[ "$via" == pdirect ]] && proxy=(-o "ProxyCommand=python3 $DIR/pd-proxy.py")
  SSHPASS="$PW" sshpass -e ssh "${SSHOPTS[@]}" "${proxy[@]}" -p "$SSH_PORT" -N -o ExitOnForwardFailure=yes \
    -L 127.0.0.1:19000:127.0.0.1:"$SSH_PORT" "$TEST_USER@127.0.0.1" >/dev/null 2>&1 &
  TUN=$!
}
login_ok() {
  local _
  tunnel "$1"
  for _ in $(seq 30); do
    if timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/19000 && IFS= read -r -t 2 l <&3 && [[ "$l" == SSH-* ]]' 2>/dev/null; then
      return 0
    fi
    kill -0 "$TUN" 2>/dev/null || return 1
    sleep 0.5
  done
  return 1
}
close_tunnel() { [[ -n "$TUN" ]] && kill "$TUN" 2>/dev/null; wait "$TUN" 2>/dev/null; TUN=""; }
login_fails() {
  local proxy=() rc
  [[ "$1" == pdirect ]] && proxy=(-o "ProxyCommand=python3 $DIR/pd-proxy.py")
  SSHPASS="$PW" timeout 20 sshpass -e ssh "${SSHOPTS[@]}" "${proxy[@]}" -p "$SSH_PORT" -N "$TEST_USER@127.0.0.1" >/dev/null 2>&1
  rc=$?
  ((rc != 0 && rc != 124))
}
external() {
  # external "pedido" "pregunta": pausa para la prueba desde la app; registra la respuesta.
  ((EXTERNAL)) || return 0
  echo
  echo ">>> CLIENTE EXTERNO: $1"
  ask ">>> $2 [s/n]: "
  if [[ "$REPLY" =~ ^[sS]$ ]]; then ok "cliente externo: $2"; else bad "cliente externo: $2"; fi
}
panel() { printf '%b' "$1" | NO_COLOR=1 timeout 120 vpsarg > "$DIR/panel.out" 2>&1; cat "$DIR/panel.out" >> "$DIR/panel-todo.out"; }

# ------------------------------------------------------------------ limpieza
# Recursos creados por la prueba (se marcan ANTES de crearlos).
ORIG_SAVED=0          # 1 cuando ya se guardó el estado original
USER_CREATED=0        # se intentó crear TEST_USER (no existía al empezar)
SSHD_TMP=0            # sshd temporal en 127.0.0.1:2222
ONESHOT=""            # PID del respondedor de 127.0.0.1:2223
DEST_CHANGED=0        # se cambió el destino SSH de PDirect-C/HCR
SSHPASS_BY_US=0       # sshpass lo instaló este script
CLEANED=0
CLEAN_FAILS=0

clean_step() {
  # clean_step "descripción" comando...: ejecuta y registra el resultado sin ocultar fallos.
  local d="$1"; shift
  if "$@"; then echo "Limpieza: OK      $d"; else echo "Limpieza: FALLÓ   $d"; CLEAN_FAILS=$((CLEAN_FAILS + 1)); fi
}

stop_test_clients() {
  # Solo procesos ssh/sshpass de la prueba: los que terminan en TEST_USER@127.0.0.1.
  if [[ -n "$TUN" ]]; then kill "$TUN" 2>/dev/null; wait "$TUN" 2>/dev/null; TUN=""; fi
  pkill -TERM -f -- "[ ]${TEST_USER}@127\.0\.0\.1\$" 2>/dev/null
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f -- "[ ]${TEST_USER}@127\.0\.0\.1\$" >/dev/null || return 0
    sleep 0.5
  done
  return 1
}

stop_tmp_sshd() {
  local _
  [[ -f "$DIR/sshd-2222.pid" ]] && kill "$(cat "$DIR/sshd-2222.pid")" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -z "$(ss -Hltn "sport = :2222")" ]] && { rm -f "$DIR/sshd-2222.pid"; return 0; }
    sleep 0.5
  done
  return 1
}

stop_oneshot() {
  [[ -n "$ONESHOT" ]] && kill "$ONESHOT" 2>/dev/null
  wait "$ONESHOT" 2>/dev/null
  ONESHOT=""
  [[ -z "$(ss -Hltn "sport = :2223")" ]]
}

dest_is_original() {
  [[ "$(sed -n 's/^SSH_PORT=\([0-9]*\)$/\1/p' /etc/vpsarg-pdirect.conf)" == "$ORIG_PD_CONF" ]] || return 1
  if [[ "$ORIG_PD_ACTIVE" == active ]]; then
    systemctl is-active --quiet pdirect-80 && [[ "$(pd_port)" == "$ORIG_PD_RUNNING" ]] || return 1
  fi
  if [[ -n "$ORIG_HCR_SSH" ]]; then
    [[ "$(sed -n 's/^HCR_SSH_PORT=\([0-9]*\)$/\1/p' /etc/vpsarg-hcr.conf)" == "$ORIG_HCR_SSH" ]] || return 1
    if [[ "$ORIG_HCR_ACTIVE" == active ]]; then
      systemctl is-active --quiet hcr-8880 && [[ "$(hcr_target)" == "127.0.0.1:$ORIG_HCR_SSH" ]] || return 1
    fi
  fi
}

restore_dest() {
  dest_is_original && return 0
  # Mismo comando aprobado (con su reversión verificada), al valor original guardado.
  # setsid: sin terminal, puerto-ssh no puede quedarse esperando una confirmación.
  setsid -w /usr/local/sbin/vpsarg-puertos puerto-ssh "$ORIG_PD_CONF" </dev/null
  if [[ "$ORIG_PD_ACTIVE" == active ]] && ! systemctl is-active --quiet pdirect-80; then
    systemctl start pdirect-80
  fi
  sleep 1
  dest_is_original
}

remove_test_user() {
  getent passwd "$TEST_USER" >/dev/null || return 0
  # Solo si es la cuenta de la prueba: del grupo vpsarg-usuarios (no existía al empezar).
  id -nG "$TEST_USER" 2>/dev/null | tr ' ' '\n' | grep -qx vpsarg-usuarios || {
    echo "Limpieza: $TEST_USER existe pero no es del grupo vpsarg-usuarios; no se toca."
    return 1
  }
  vpsarg-usuarios eliminar "$TEST_USER" </dev/null
  ! getent passwd "$TEST_USER" >/dev/null
}

remove_sshpass() {
  command -v sshpass >/dev/null || return 0
  DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq sshpass >/dev/null 2>&1
  ! command -v sshpass >/dev/null
}

cleanup() {
  ((CLEANED)) && return 0
  CLEANED=1
  trap '' INT TERM HUP PIPE
  echo
  echo "### Limpieza"
  if ((!ORIG_SAVED)); then
    echo "Limpieza: no se había cambiado nada (antes de guardar el estado original)."
    return 0
  fi
  clean_step "túneles y clientes ssh de la prueba cerrados" stop_test_clients
  if ((SSHD_TMP)); then clean_step "sshd temporal de 127.0.0.1:2222 detenido" stop_tmp_sshd; fi
  if [[ -n "$ONESHOT" ]]; then clean_step "respondedor de 127.0.0.1:2223 detenido" stop_oneshot; fi
  if ((DEST_CHANGED)); then
    clean_step "destino SSH original (PDirect-C $ORIG_PD_CONF${ORIG_HCR_SSH:+, HCR $ORIG_HCR_SSH})" restore_dest
  fi
  if ((USER_CREATED)); then clean_step "cuenta $TEST_USER eliminada" remove_test_user; fi
  if ((SSHPASS_BY_US)); then clean_step "sshpass desinstalado (no estaba al empezar)" remove_sshpass; fi
  rm -f "$DIR/pd-proxy.py"
  # Comprobación final de todo lo que la prueba pudo dejar, haya o no actuado arriba.
  clean_step "no existe $TEST_USER" bash -c '! getent passwd "$1" >/dev/null' _ "$TEST_USER"
  clean_step "nada escucha en 127.0.0.1:2222, 2223 ni 19000" bash -c '[[ -z "$(ss -Hltn "( sport = :2222 or sport = :2223 or sport = :19000 )")" ]]'
  clean_step "sin procesos ssh de la prueba" bash -c '! pgrep -f -- "[ ]$1@127\.0\.0\.1\$" >/dev/null' _ "$TEST_USER"
  clean_step "destino de PDirect-C${ORIG_HCR_SSH:+ y HCR} igual al original" dest_is_original
  clean_step "sshpass en su estado original ($ORIG_SSHPASS)" bash -c '[[ "$(command -v sshpass >/dev/null && echo instalado || echo "no instalado")" == "$1" ]]' _ "$ORIG_SSHPASS"
  clean_step "grupo vpsarg-usuarios sigue existiendo" bash -c 'getent group vpsarg-usuarios >/dev/null'
  clean_step "UDPGW no se reinició (PID $ORIG_UG_PID)" test "$(pid_of udpgw-7300)" = "$ORIG_UG_PID"
  if ((CLEAN_FAILS)); then
    echo "LIMPIEZA INCOMPLETA: $CLEAN_FAILS paso(s) fallaron. Revisá los FALLÓ de arriba; no se intentó nada más."
  else
    echo "Limpieza completa: el sistema volvió al estado original guardado en $DIR/estado-original.txt."
  fi
}

on_signal() {
  echo
  echo "!!! Interrumpido por SIG$1. Se deshacen los cambios de la prueba."
  exit "$2"
}
on_exit() {
  local rc=$?
  PW=""
  cleanup
  ((CLEAN_FAILS)) && ((rc == 0)) && rc=3
  exit "$rc"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP
trap on_exit EXIT

checkpoint() {
  # Solo para las pruebas de limpieza en el contenedor (ver cabecera).
  [[ "${VALIDACION_PARAR_EN:-}" == "$1" ]] || return 0
  echo ">>> prueba de limpieza: SIG${VALIDACION_SENAL:-TERM} en la etapa '$1'"
  kill -s "${VALIDACION_SENAL:-TERM}" $$
  sleep 2
}

# Fotografía del estado: todo lo que la validación no debe cambiar.
snapshot() {
  local f="$DIR/estado-$1.txt" u
  {
    echo "== sistema"; . /etc/os-release; echo "$PRETTY_NAME"; uname -r
    echo "== sshd -T"; sshd -T 2>/dev/null | grep -Ei '^(port|listenaddress|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|usepam|allowtcpforwarding|permitrootlogin|allowusers|allowgroups|denyusers|denygroups|maxsessions|maxstartups) '
    echo "== sumas"
    sha256sum /etc/ssh/sshd_config /etc/shells /etc/vpsarg-pdirect.conf \
      /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service \
      /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw 2>&1
    find /etc/ssh/sshd_config.d -type f -exec sha256sum {} + 2>/dev/null
    if hcr_installed; then sha256sum /etc/vpsarg-hcr.conf /etc/systemd/system/hcr-8880.service /usr/local/lib/vpsarg/hcr-server; fi
    echo "== /etc/shells"; cat /etc/shells
    echo "== servicios"
    for u in pdirect-80 udpgw-7300 hcr-8880; do
      systemctl cat "$u" >/dev/null 2>&1 || { echo "$u no instalado"; continue; }
      echo "$u active=$(systemctl is-active "$u") enabled=$(systemctl is-enabled "$u") PID=$(pid_of "$u") inicio=$(systemctl show -p ExecMainStartTimestamp --value "$u")"
      echo "$u ExecStart=$(systemctl show -p ExecStart --value "$u" | sed 's/ ; pid=.*//; s/start_time=.*//')"
    done
    echo "== puertos en escucha (TCP)"; ss -Hltnp | awk '{print $4, $6}' | sed 's/,fd=[0-9]*//g' | sort
    echo "== cuentas (sin la de prueba)"
    getent passwd | grep -v "^$TEST_USER:" | cut -d: -f1,3,4,6,7
    echo "== sombra (huella por cuenta, sin la de prueba)"
    getent shadow | grep -v "^$TEST_USER:" | while IFS=: read -r name rest; do echo "$name $(printf '%s' "$rest" | sha256sum | cut -c1-16)"; done
    echo "== grupos (sin el de prueba ni vpsarg-usuarios, que puede crearse en la prueba)"; getent group | grep -v "^$TEST_USER:\|^vpsarg-usuarios:"
  } > "$f" 2>&1
}

echo "######## Validación Fase 2C + ajuste 5.1 en VPS de laboratorio — $START"
echo "Carpeta de resultados: $DIR"
echo
echo "Esta VPS: $(hostname) · $(. /etc/os-release; echo "$PRETTY_NAME")"
ask "Escribí el nombre de esta VPS ($(hostname)) para confirmar que es de LABORATORIO: "
[[ "$REPLY" == "$(hostname)" ]] || { echo "No coincide. No se hizo nada."; exit 1; }

echo
echo "### 0. Requisitos"
for c in vpsarg vpsarg-usuarios vpsarg-puertos python3; do
  command -v "$c" >/dev/null || { echo "Falta $c. No se hizo nada."; exit 1; }
done
grep -q "Reversión verificada" /usr/local/sbin/vpsarg-puertos || { echo "vpsarg-puertos no tiene el ajuste 5.1. Instalá la rama. No se hizo nada."; exit 1; }
systemctl is-active --quiet pdirect-80 || { echo "pdirect-80 no está activo. No se hizo nada."; exit 1; }
SSH_PORT="$(sed -n 's/^SSH_PORT=\([0-9]*\)$/\1/p' /etc/vpsarg-pdirect.conf)"
[[ -n "$SSH_PORT" ]] || { echo "No se pudo leer el puerto SSH de PDirect-C."; exit 1; }
PA="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
if [[ "$PA" != yes ]]; then
  echo "sshd tiene PasswordAuthentication=${PA:-desconocido}: las cuentas no pueden entrar con contraseña."
  echo "Esta validación no cambia sshd_config. Se detiene sin hacer nada (registrado como hallazgo)."
  exit 1
fi
getent passwd "$TEST_USER" >/dev/null && { echo "Ya existe la cuenta $TEST_USER. Usá --usuario OTRO. No se hizo nada."; exit 1; }
getent group "$TEST_USER" >/dev/null && { echo "Ya existe un grupo $TEST_USER. Usá --usuario OTRO. No se hizo nada."; exit 1; }
getent group vpsarg-usuarios >/dev/null || { echo "No existe el grupo vpsarg-usuarios. La prueba no lo crea (el instalador tampoco: lo crea el panel al dar de alta la primera cuenta). No se hizo nada."; exit 1; }
for p in 2222 2223 19000; do
  [[ -z "$(ss -Hltn "sport = :$p")" ]] || { echo "El puerto local $p está en uso. No se hizo nada."; exit 1; }
done
if ((READONLY)); then
  echo "Puerto SSH real: $SSH_PORT · HCR: $(hcr_installed && echo instalado || echo 'no instalado')"
  echo "sshpass: $(command -v sshpass >/dev/null && echo instalado || echo 'no instalado (la validación completa lo pedirá)')"
  snapshot inicial
  {
    echo "CPU: $(nproc) × $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
    free -m | awk 'NR==2{print "RAM: " $2 " MB"}'
    df -Pm / | awk 'NR==2{print "Disco /: " $2 " MB, libres " $4 " MB"}'
    echo "Virtualización: $(systemd-detect-virt 2>/dev/null || echo desconocida)"
    echo "OpenSSH: $(ssh -V 2>&1)"
  } | tee "$DIR/hardware.txt"
  echo
  echo "Modo solo lectura: requisitos cumplidos y fotografía guardada en $DIR. No se cambió nada."
  exit 0
fi
# Estado original: se guarda antes de cualquier cambio y es lo que usa la limpieza.
ORIG_PD_CONF="$SSH_PORT"
ORIG_PD_ACTIVE="$(systemctl is-active pdirect-80)"
ORIG_PD_RUNNING="$(pd_port)"
ORIG_HCR_SSH=""; ORIG_HCR_ACTIVE="no instalado"
if hcr_installed; then
  ORIG_HCR_SSH="$(sed -n 's/^HCR_SSH_PORT=\([0-9]*\)$/\1/p' /etc/vpsarg-hcr.conf)"
  ORIG_HCR_ACTIVE="$(systemctl is-active hcr-8880)"
fi
ORIG_UG_PID="$(pid_of udpgw-7300)"
ORIG_UG_START="$(systemctl show -p ExecMainStartTimestamp --value udpgw-7300)"
ORIG_SSHPASS="$(command -v sshpass >/dev/null && echo instalado || echo "no instalado")"
[[ "$ORIG_PD_RUNNING" == "$ORIG_PD_CONF" ]] || { echo "PDirect-C usa $ORIG_PD_RUNNING pero su configuración dice $ORIG_PD_CONF. No se hizo nada."; exit 1; }
cat > "$DIR/estado-original.txt" <<ORIG_EOF
SSH_PORT (vpsarg-pdirect.conf)=$ORIG_PD_CONF
PDirect-C estado=$ORIG_PD_ACTIVE destino en ejecución=127.0.0.1:$ORIG_PD_RUNNING PID=$(pid_of pdirect-80)
HCR estado=$ORIG_HCR_ACTIVE destino=${ORIG_HCR_SSH:+127.0.0.1:$ORIG_HCR_SSH}
UDPGW estado=$(systemctl is-active udpgw-7300) PID=$ORIG_UG_PID inicio=$ORIG_UG_START
$TEST_USER existe=no
grupo vpsarg-usuarios existe=sí miembros=$(getent group vpsarg-usuarios | cut -d: -f4)
sshpass=$ORIG_SSHPASS
ORIG_EOF
echo "Estado original:"; sed 's/^/  /' "$DIR/estado-original.txt"
ORIG_SAVED=1
if ! command -v sshpass >/dev/null; then
  ask "Falta sshpass (cliente de prueba que escribe la contraseña). ¿Instalarlo con apt? [s/N]: "
  [[ "$REPLY" =~ ^[sS]$ ]] || { echo "Sin sshpass no se puede probar el login automático. No se hizo nada."; exit 1; }
  SSHPASS_BY_US=1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null || { echo "No se pudo instalar sshpass."; exit 1; }
  echo "sshpass instalado por la prueba; se desinstala al final."
fi
echo "Puerto SSH real: $SSH_PORT · HCR: $(hcr_installed && echo instalado || echo 'no instalado')"
echo "Contraseña para la cuenta de prueba $TEST_USER (6 a 128 caracteres, sin ':'; no se muestra ni se guarda)."
read -r -s -p "Contraseña: " PW || PW=""; echo
read -r -s -p "Repetila: " PW2 || PW2=""; echo
[[ -n "$PW" && "$PW" == "$PW2" ]] || { echo "Las contraseñas no coinciden. No se hizo nada."; exit 1; }
unset PW2

echo
echo "### 1. Fotografía inicial"
{
  echo "CPU: $(nproc) × $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  free -m | awk 'NR==2{print "RAM: " $2 " MB"}'
  df -Pm / | awk 'NR==2{print "Disco /: " $2 " MB, libres " $4 " MB"}'
  echo "Virtualización: $(systemd-detect-virt 2>/dev/null || echo desconocida)"
  echo "OpenSSH: $(ssh -V 2>&1)"
} | tee "$DIR/hardware.txt"
snapshot inicial
UG_PID0="$(pid_of udpgw-7300)"
echo "Guardada en $DIR/estado-inicial.txt (UDPGW PID $UG_PID0)."
cat > "$DIR/pd-proxy.py" <<'EOF'
import os, select, socket, sys
s = socket.create_connection(("127.0.0.1", 80))
s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n\r\n")
buf = b""
while buf.count(b"\r\n\r\n") < 2:
    d = s.recv(1)
    if not d:
        sys.exit(1)
    buf += d
while True:
    r, _, _ = select.select([0, s], [], [])
    if 0 in r:
        d = os.read(0, 65536)
        if not d:
            s.shutdown(socket.SHUT_WR)
        else:
            s.sendall(d)
    if s in r:
        d = s.recv(65536)
        if not d:
            break
        os.write(1, d)
EOF

echo
echo "### Prueba 1 — Usuario SSH"
create_user() { printf '%s\n' "$PW" | vpsarg-usuarios crear "$TEST_USER"; }   # printf interno: la clave no va en argumentos
checkpoint antes-usuario
USER_CREATED=1
check "crear $TEST_USER" create_user
checkpoint despues-usuario
check "grupo vpsarg-usuarios" bash -c 'id -nG "$1" | tr " " "\n" | grep -qx vpsarg-usuarios' _ "$TEST_USER"
check "shell /usr/sbin/nologin" test "$(getent passwd "$TEST_USER" | cut -d: -f7)" = /usr/sbin/nologin
HOME_T="$(getent passwd "$TEST_USER" | cut -d: -f6)"
check "HOME $HOME_T existe y es de $TEST_USER" test "$(stat -c %U "$HOME_T" 2>/dev/null)" = "$TEST_USER"
check "contraseña cifrada en shadow" bash -c '[[ "$(getent shadow "$1" | cut -d: -f2)" == \$* ]]' _ "$TEST_USER"
check "listado: ACTIVO" bash -c 'vpsarg-usuarios listar | grep -Eq "^$1 +[0-9]+ +ACTIVO "' _ "$TEST_USER"
check "login SSH con contraseña (directo, puerto $SSH_PORT)" login_ok directo
check "el listado cuenta 1 sesión" test "$(sessions)" = 1
close_tunnel
check "contraseña incorrecta: rechazada" bash -c 'SSHPASS=incorrecta-xyz timeout 20 sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -p "$1" -N "$2@127.0.0.1" >/dev/null 2>&1; rc=$?; ((rc != 0 && rc != 124))' _ "$SSH_PORT" "$TEST_USER"
external "conectate desde tu app (fuera de la VPS) con el usuario $TEST_USER y la contraseña que escribiste, directo por SSH o por el puerto 80, y dejala conectada." \
  "¿La app se conectó?"
if ((EXTERNAL)); then
  check "la conexión externa aparece como sesión de $TEST_USER" bash -c '(( $(vpsarg-usuarios listar | awk -v u="$1" '"'"'$1==u{print $(NF-1)}'"'"') >= 1 ))' _ "$TEST_USER"
fi

echo
echo "### Prueba 2 — PDirect-C (cliente -> TCP 80 -> SSH)"
check "PDirect-C llega a SSH" pdirect_ssh
check "login de $TEST_USER a través de PDirect-C" login_ok pdirect
checkpoint pdirect
close_tunnel

echo
echo "### Prueba 3 — Suspensión (chage -E 0)"
EXP0="$(expire)"
HASH0="$(pwhash)"
echo "Vencimiento anterior: ${EXP0:-nunca}"
check "antes: la cuenta funciona (sesión abierta por PDirect-C)" login_ok pdirect
checkpoint tunel-activo
check "suspender" bash -c 'vpsarg-usuarios suspender "$1" | tee /dev/stderr | grep -q "Sesiones SSH cerradas"' _ "$TEST_USER"
check "la sesión activa se cerró" bash -c "sleep 1; ! kill -0 $TUN 2>/dev/null"
close_tunnel
check "vencimiento = 0" test "$(expire)" = 0
checkpoint suspendida
check "sin sesiones de $TEST_USER" test "$(sessions)" = 0
check "suspendida: no entra directo" login_fails directo
check "suspendida: no entra por PDirect-C" login_fails pdirect
check "la contraseña no se modificó" test "$(pwhash)" = "$HASH0"
check "no se usó usermod -L (contraseña sin '!')" bash -c '[[ "$(getent shadow "$1" | cut -d: -f2)" != !* ]]' _ "$TEST_USER"
external "la app que estaba conectada tuvo que desconectarse. Intentá conectarte de nuevo." \
  "¿La app se desconectó y ahora NO puede entrar?"

echo
echo "### Prueba 4 — Reactivación"
check "reactivar" vpsarg-usuarios reactivar "$TEST_USER"
check "vencimiento restaurado (${EXP0:-nunca})" test "$(expire)" = "$EXP0"
check "la contraseña no se modificó" test "$(pwhash)" = "$HASH0"
check "entra otra vez (directo)" login_ok directo
close_tunnel
check "entra otra vez por PDirect-C" login_ok pdirect
close_tunnel
external "conectate otra vez desde tu app y dejala conectada." "¿La app volvió a entrar?"

echo
echo "### Prueba 5 — Eliminación"
UID_T="$(id -u "$TEST_USER")"
login_ok directo >/dev/null
check "eliminar (con una sesión abierta)" vpsarg-usuarios eliminar "$TEST_USER"
close_tunnel
check "el usuario no existe" bash -c '! getent passwd "$1" >/dev/null' _ "$TEST_USER"
check "acceso SSH rechazado" login_fails directo
check "acceso por PDirect-C rechazado" login_fails pdirect
check "no quedan procesos del UID $UID_T" bash -c "! ps -u $UID_T -o pid= >/dev/null"
check "no queda el HOME $HOME_T" test ! -e "$HOME_T"
check "no queda grupo propio" bash -c '! getent group "$1" >/dev/null' _ "$TEST_USER"
check "vpsarg-usuarios sigue existiendo y no lista a $TEST_USER" bash -c 'getent group vpsarg-usuarios >/dev/null && ! getent group vpsarg-usuarios | cut -d: -f4 | tr , "\n" | grep -qx "$1"' _ "$TEST_USER"
check "sin línea en usuarios-suspendidos" bash -c '! grep -q "^$1:" /etc/vpsarg/usuarios-suspendidos 2>/dev/null' _ "$TEST_USER"
check "sin correo ni crontab residuales" bash -c 'test ! -e "/var/mail/$1" && test ! -e "/var/spool/cron/crontabs/$1"' _ "$TEST_USER"
external "si la app seguía conectada, tuvo que desconectarse." "¿La app quedó desconectada?"

echo
echo "### Prueba 6 — puerto-ssh y reversión verificada (ajuste 5.1)"
mkdir -p /run/sshd
SSHD_TMP=1
/usr/sbin/sshd -p 2222 -o ListenAddress=127.0.0.1 -o PidFile="$DIR/sshd-2222.pid"
sleep 1
checkpoint sshd-temporal
UG_PID6="$(pid_of udpgw-7300)"
DEST_CHANGED=1
panel "4\n1\n2222\ns\n\n0\n0\n"
checkpoint destino-cambiado
check "cambio a 2222 desde el panel" bash -c 'grep -q "^Hecho" "$1"' _ "$DIR/panel.out"
check "PDirect-C usa 2222" test "$(pd_port)" = 2222
check "PDirect-C llega a SSH en 2222" pdirect_ssh
if hcr_installed; then
  check "HCR activo y con destino 127.0.0.1:2222" bash -c 'systemctl is-active --quiet hcr-8880 && [[ "$1" == 127.0.0.1:2222 ]]' _ "$(hcr_target)"
  checkpoint hcr
fi
check "UDPGW sin cambios (PID $UG_PID6)" test "$(pid_of udpgw-7300)" = "$UG_PID6"
panel "4\n1\n$SSH_PORT\ns\n\n0\n0\n"
check "volver a $SSH_PORT" test "$(pd_port)" = "$SSH_PORT"
if hcr_installed; then check "HCR vuelve a 127.0.0.1:$SSH_PORT" test "$(hcr_target)" = "127.0.0.1:$SSH_PORT"; fi
stop_tmp_sshd || echo "AVISO: el sshd temporal no se detuvo; la limpieza final lo reintenta."
# Respondedor de una sola conexión: contesta el primer control de banner y se cierra,
# así PDirect-C no llega a SSH en 2223 y puerto-ssh tiene que revertir.
python3 -c 'import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 2223)); s.listen(1); c,_=s.accept(); c.sendall(b"SSH-2.0-validacion\r\n"); c.close(); s.close()' &
ONESHOT=$!
sleep 1
checkpoint respondedor
PD_PID6="$(pid_of pdirect-80)"
panel "4\n1\n2223\ns\n\n0\n0\n"
echo "--- salida de puerto-ssh 2223:"; grep -E "PDirect-C|Reversión|ATENCIÓN|ERROR|falló" "$DIR/panel.out"
stop_oneshot
check "puerto-ssh 2223 falla" bash -c 'grep -q "La operación falló" "$1"' _ "$DIR/panel.out"
check "informa \"Reversión verificada\"" bash -c 'grep -q "Reversión verificada: PDirect-C activo, escucha en TCP 80, apunta a 127.0.0.1:$2 y llega a SSH" "$1"' _ "$DIR/panel.out" "$SSH_PORT"
check "1. PDirect-C volvió a $SSH_PORT (proceso)" test "$(pd_port)" = "$SSH_PORT"
check "2. servicio activo" systemctl is-active --quiet pdirect-80
check "3. escucha en TCP 80 (PID $(pid_of pdirect-80))" bash -c 'ss -Hltnp "sport = :80" | grep -q "pid=$1,"' _ "$(pid_of pdirect-80)"
check "4. destino configurado $SSH_PORT" grep -qx "SSH_PORT=$SSH_PORT" /etc/vpsarg-pdirect.conf
check "5. TCP 80 llega a SSH" pdirect_ssh
check "PDirect-C se reinició durante la prueba (esperado)" test "$(pid_of pdirect-80)" != "$PD_PID6"
if hcr_installed; then check "HCR sigue con destino 127.0.0.1:$SSH_PORT" test "$(hcr_target)" = "127.0.0.1:$SSH_PORT"; fi

echo
echo "### Prueba 7 — Lo que no debe cambiar"
snapshot final
# Los PID y la hora de inicio se comparan aparte: PDirect-C y HCR se reinician a propósito.
diff <(sed 's/PID=[0-9]* inicio=.*//; s/pid=[0-9]*//g' "$DIR/estado-inicial.txt") \
     <(sed 's/PID=[0-9]* inicio=.*//; s/pid=[0-9]*//g' "$DIR/estado-final.txt") > "$DIR/diferencias.txt"
check "estado final = inicial (sin contar PIDs de PDirect-C/HCR, reiniciados a propósito)" test ! -s "$DIR/diferencias.txt"
check "UDPGW NO se reinició (PID $UG_PID0, mismo inicio)" bash -c '[[ "$(systemctl show -p MainPID --value udpgw-7300)" == "$1" ]] && grep -q "^udpgw-7300 .*PID=$1 inicio=$(systemctl show -p ExecMainStartTimestamp --value udpgw-7300)$" "$2"' _ "$UG_PID0" "$DIR/estado-inicial.txt"
check "puerto 7300 en escucha por UDPGW" bash -c 'ss -Hltnp "sport = :7300" | grep -q "pid=$1,"' _ "$UG_PID0"
for f in /etc/ssh/sshd_config /etc/shells /etc/systemd/system/udpgw-7300.service /opt/badvpn/badvpn-udpgw /usr/local/bin/pdirect-c /etc/vpsarg-pdirect.conf; do
  check "sin cambios: $f" bash -c 'grep -F "  $1" "$2" | cmp -s - <(grep -F "  $1" "$3")' _ "$f" "$DIR/estado-inicial.txt" "$DIR/estado-final.txt"
done
check "cuentas ajenas a vpsarg-usuarios sin cambios" bash -c 'diff <(sed -n "/== cuentas/,/== grupos/p" "$1") <(sed -n "/== cuentas/,/== grupos/p" "$2") >/dev/null' _ "$DIR/estado-inicial.txt" "$DIR/estado-final.txt"

echo
echo "### Prueba 8 — Registro (journalctl -t vpsarg-panel)"
vpsarg-usuarios suspender noexiste-validacion >/dev/null 2>&1   # error provocado
journalctl -t vpsarg-panel --since "$START" -o short-iso --no-pager > "$DIR/journal-vpsarg-panel.txt"
check "operaciones de usuarios registradas" bash -c 'for a in crear suspender reactivar eliminar; do grep -q "accion=$a usuario=$1 resultado=ok" "$2" || exit 1; done' _ "$TEST_USER" "$DIR/journal-vpsarg-panel.txt"
check "errores registrados" grep -q "accion=suspender usuario=noexiste-validacion resultado=error" "$DIR/journal-vpsarg-panel.txt"
check "puerto-ssh y su reversión registrados" bash -c 'grep -q "accion=puerto-ssh valor=2222 resultado=ok" "$1" && grep -q "accion=puerto-ssh valor=2223 resultado=error" "$1"' _ "$DIR/journal-vpsarg-panel.txt"
# grep -F -f lee la clave de una tubería: no aparece en la lista de procesos.
pw_not_in_journal() { ! journalctl --since "$START" -o cat --no-pager | grep -qF -f <(printf '%s\n' "$PW"); }
pw_not_in_files() { ! grep -rqF -f <(printf '%s\n' "$PW") /var/log /etc/vpsarg "$DIR" 2>/dev/null; }
check "la contraseña no aparece en el journal" pw_not_in_journal
check "la contraseña no aparece en /var/log ni /etc/vpsarg ni en los resultados" pw_not_in_files
PW=""

echo
echo "### Prueba 9 — Limpieza final (la misma que corre ante una interrupción)"
cleanup
check "limpieza sin fallos" test "$CLEAN_FAILS" = 0
check "sshpass en su estado original ($ORIG_SSHPASS)" test "$(command -v sshpass >/dev/null && echo instalado || echo "no instalado")" = "$ORIG_SSHPASS"
check "UDPGW: mismo PID y misma hora de inicio que al empezar" bash -c '[[ "$(systemctl show -p MainPID --value udpgw-7300)" == "$1" && "$(systemctl show -p ExecMainStartTimestamp --value udpgw-7300)" == "$2" ]]' _ "$ORIG_UG_PID" "$ORIG_UG_START"

echo
echo "######## Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0)) || printf 'Fallas:\n%s\n' "$(printf '  - %s\n' "${FAILED[@]}")"
echo "Resultados en $DIR (sin contraseñas). Subí esa carpeta comprimida:"
echo "  tar -C /root -czf /root/$(basename "$DIR").tar.gz $(basename "$DIR")"
((FAILS == 0))
