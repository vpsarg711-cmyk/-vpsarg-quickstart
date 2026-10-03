#!/usr/bin/env bash
# Pruebas de AUTO (abrir el panel al iniciar sesión), etapa 3A.
# SOLO para un contenedor de laboratorio con QuickStart instalado: crea cuentas de
# prueba, una clave SSH temporal para root y una línea temporal en /root/.bashrc,
# y las borra al final.
# Uso: sudo bash tests/prueba-auto.sh
# shellcheck disable=SC2016
set -uo pipefail

[[ "$(systemd-detect-virt 2>/dev/null)" == docker ]] || { echo "Solo en el contenedor de laboratorio." >&2; exit 1; }
OUT=/tmp/auto.out
CONF=/etc/vpsarg-auto.conf
HOOK=/etc/profile.d/vpsarg-auto.sh
PASS=0
FAILS=0
ok()   { echo "PASA  $*"; PASS=$((PASS + 1)); }
bad()  { echo "FALLA $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -q -- "$1" "$OUT"; }
panels() { grep -c "\[ 1 \] PROTOCOLOS" "$OUT"; }
pid_of() { systemctl show -p MainPID --value "$1"; }
# Sesión de login en una terminal: login "comando" "entrada".
login() { printf '%b' "$2" | timeout 60 script -qec "$1" /dev/null > "$OUT" 2>&1; }
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i /tmp/auto-key)
sums() {
  sha256sum /etc/ssh/sshd_config /etc/profile /etc/bash.bashrc /root/.profile /etc/passwd /etc/group \
    /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service
  find /etc/ssh/sshd_config.d -type f -exec sha256sum {} + 2>/dev/null
  echo "pdirect=$(pid_of pdirect-80) udpgw=$(pid_of udpgw-7300) ssh=$(pid_of ssh)"
}

echo "### Preparación"
SUMS0="$(sums)"
BASHRC0="$(sha256sum /root/.bashrc)"
cp -p /root/.bashrc /tmp/auto-bashrc
echo 'export VPSARG_PRUEBA_BASHRC=cargado' >> /root/.bashrc
useradd -m -s /bin/bash admin1
echo 'admin1 ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/auto-prueba
chmod 0440 /etc/sudoers.d/auto-prueba
getent group vpsarg-usuarios >/dev/null || groupadd --system vpsarg-usuarios
useradd -m -s /bin/bash -G vpsarg-usuarios servicio1
useradd -m -s /usr/sbin/nologin -G vpsarg-usuarios servicio2
rm -f /tmp/auto-key /tmp/auto-key.pub
ssh-keygen -q -t ed25519 -N '' -f /tmp/auto-key
install -d -m 0700 /root/.ssh
cp -p /root/.ssh/authorized_keys /tmp/auto-authkeys 2>/dev/null || true
cat /tmp/auto-key.pub >> /root/.ssh/authorized_keys
check "AUTO apagado al empezar (sin archivos)" bash -c "test ! -e $CONF && test ! -e $HOOK"
check "vpsarg auto informa OFF para root" bash -c 'vpsarg auto | grep -qx "AUTO: OFF para root"'

echo "### AUTO en OFF"
login "bash -l" 'echo MARCA_SHELL\nexit\n'
check "OFF: el login de root no abre el panel" test "$(panels)" = 0
check "OFF: la consola funciona" has "^MARCA_SHELL"

echo "### Activar"
check "vpsarg auto on" bash -c 'vpsarg auto on | grep -qx "AUTO: ON para root"'
check "la lista tiene root" grep -qx root "$CONF"
check "lista y disparador de root, 0644" bash -c "[[ \$(stat -c '%U %a' $CONF) == 'root 644' && \$(stat -c '%U %a' $HOOK) == 'root 644' ]]"
check "el disparador es sh válido" sh -n "$HOOK"
check "activar dos veces no duplica" bash -c "vpsarg auto on >/dev/null; [[ \$(grep -cx root $CONF) == 1 ]]"
check "registro: auto on" bash -c 'journalctl -t vpsarg-panel -o cat | grep -q "accion=auto valor=on cuenta=root resultado=ok"'

echo "### Login de root con AUTO en ON"
login "bash -l" '0\necho MARCA_SHELL\necho "BASHRC=$VPSARG_PRUEBA_BASHRC"\nexit\n'
check "se abre el panel una vez" test "$(panels)" = 1
check "al salir (0) sigue la consola" has "^MARCA_SHELL"
check "la consola terminó de cargar ~/.bashrc" has "^BASHRC=cargado"
login "bash -l" '0\nbash -l\necho MARCA_ANIDADA\nexit\nexit\n'
check "una shell de login anidada no lo vuelve a abrir" bash -c '[[ $(grep -c "\[ 1 \] PROTOCOLOS" '"$OUT"') == 1 ]] && grep -q "^MARCA_ANIDADA" '"$OUT"''
login "sh -l" '0\necho MARCA_SH\nexit\n'
check "también con sh (dash) como shell de login" bash -c '[[ $(grep -c "\[ 1 \] PROTOCOLOS" '"$OUT"') == 1 ]] && grep -q "^MARCA_SH" '"$OUT"''
check "bash -lc sin terminal: no abre el panel" bash -c '[[ "$(timeout 10 bash -lc "echo X" </dev/null 2>&1)" == X ]]'
login "bash -lc 'echo NOINTERACTIVA'" ''
check "bash -lc con terminal pero sin interacción: no abre el panel" bash -c '[[ $(grep -c "PROTOCOLOS" '"$OUT"') == 0 ]] && grep -q NOINTERACTIVA '"$OUT"''
{ sleep 3; printf '\003'; sleep 1; printf 'echo MARCA_CTRLC\necho "BASHRC=$VPSARG_PRUEBA_BASHRC"\nexit\n'; } \
  | timeout 60 script -qec "bash -l" /dev/null > "$OUT" 2>&1
check "Ctrl+C cierra el panel y sigue la consola" bash -c 'grep -q "PROTOCOLOS" '"$OUT"' && grep -q "^MARCA_CTRLC" '"$OUT"''
check "después de Ctrl+C la consola cargó ~/.bashrc" has "^BASHRC=cargado"
check "no quedan procesos del panel" bash -c 'sleep 1; ! pgrep -f "/usr/local/sbin/vpsarg$" >/dev/null'

echo "### Por SSH"
login "ssh ${SSHOPTS[*]} -tt root@127.0.0.1" '0\necho MARCA_SSH\nexit\n'
check "login SSH interactivo de root: abre el panel y sigue la consola" bash -c '[[ $(grep -c "\[ 1 \] PROTOCOLOS" '"$OUT"') == 1 ]] && grep -q "^MARCA_SSH" '"$OUT"''
check "ssh root@host comando: no abre el panel" bash -c '[[ "$(timeout 20 ssh "${@}" root@127.0.0.1 "echo COMANDO" </dev/null 2>&1)" == COMANDO ]]' _ "${SSHOPTS[@]}"
check "sftp: no abre el panel" bash -c 'out="$(echo "pwd" | timeout 20 sftp -b - "${@}" root@127.0.0.1 2>&1)"; [[ "$out" == *"Remote working directory"* && "$out" != *PROTOCOLOS* ]]' _ "${SSHOPTS[@]}"

echo "### Otra cuenta de administrador (sudo)"
check "AUTO on para admin1 (con sudo)" bash -c 'SUDO_USER=admin1 vpsarg auto on | grep -qx "AUTO: ON para admin1"'
check "la lista tiene root y admin1" bash -c "grep -qx root $CONF && grep -qx admin1 $CONF"
login "su - admin1" '0\necho "MARCA_ADMIN1 $(id -un)"\nexit\n'
check "admin1: abre el panel con sudo y vuelve a su consola" bash -c '[[ $(grep -c "\[ 1 \] PROTOCOLOS" '"$OUT"') == 1 ]] && grep -q "^MARCA_ADMIN1 admin1" '"$OUT"''

echo "### Cuentas del servicio"
check "no se puede activar para una cuenta del grupo vpsarg-usuarios" bash -c '! SUDO_USER=servicio1 vpsarg auto on >/dev/null 2>&1 && ! grep -qx servicio1 '"$CONF"''
echo servicio1 >> "$CONF"
login "su - servicio1" 'echo MARCA_SERVICIO1\nexit\n'
check "cuenta del grupo con bash, aunque esté en la lista: no abre el panel" bash -c '[[ $(grep -c "PROTOCOLOS" '"$OUT"') == 0 ]] && grep -q "^MARCA_SERVICIO1" '"$OUT"''
sed -i '/^servicio1$/d' "$CONF"
login "su - servicio2" ''
check "cuenta del servicio con nologin: sin shell y sin panel" bash -c '[[ $(grep -c "PROTOCOLOS" '"$OUT"') == 0 ]] && grep -q "not available" '"$OUT"''
check "no se puede activar para una cuenta inexistente" bash -c '! SUDO_USER=noexiste vpsarg auto on >/dev/null 2>&1'
check "subcomando auto con valor inválido falla" bash -c '! vpsarg auto quizas >/dev/null 2>&1'

echo "### Desactivar"
check "vpsarg auto off (root)" bash -c 'vpsarg auto off | grep -qx "AUTO: OFF para root"'
check "queda admin1 y el disparador" bash -c "! grep -qx root $CONF && grep -qx admin1 $CONF && test -e $HOOK"
login "bash -l" 'echo MARCA_OFF\nexit\n'
check "root ya no abre el panel" bash -c '[[ $(grep -c "PROTOCOLOS" '"$OUT"') == 0 ]] && grep -q "^MARCA_OFF" '"$OUT"''
check "off para admin1 borra la lista y el disparador" bash -c "SUDO_USER=admin1 vpsarg auto off >/dev/null && test ! -e $CONF && test ! -e $HOOK"
check "off sin nada activado no falla" bash -c 'vpsarg auto off | grep -qx "AUTO: OFF para root"'

echo "### Desde el menú (Configuración → Auto inicio)"
printf '4\n7\ns\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "menú: activar" bash -c "grep -qx root $CONF && test -e $HOOK && grep -q 'AUTO: ON para root' $OUT"
printf '4\n7\nn\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "menú: responder n no desactiva" grep -qx root "$CONF"
printf '4\n7\ns\n\n0\n0\n' | timeout 60 vpsarg > "$OUT" 2>&1
check "menú: desactivar" bash -c "test ! -e $CONF && test ! -e $HOOK"

echo "### Limpieza y lo que no debe cambiar"
cp -p /tmp/auto-bashrc /root/.bashrc
if [[ -e /tmp/auto-authkeys ]]; then cp -p /tmp/auto-authkeys /root/.ssh/authorized_keys; else rm -f /root/.ssh/authorized_keys; fi
rm -f /etc/sudoers.d/auto-prueba /tmp/auto-key /tmp/auto-key.pub /tmp/auto-bashrc /tmp/auto-authkeys
userdel -r admin1 >/dev/null 2>&1; userdel -r servicio1 >/dev/null 2>&1; userdel -r servicio2 >/dev/null 2>&1
check "/root/.bashrc restaurado" test "$(sha256sum /root/.bashrc)" = "$BASHRC0"
check "sshd_config, profile, bash.bashrc, .profile, cuentas, unidades y PID de PDirect-C, UDPGW y SSH iguales" \
  test "$(sums)" = "$SUMS0"
check "sin archivos de AUTO" bash -c "test ! -e $CONF && test ! -e $HOOK"

echo
echo "Resultado: $PASS pasan, $FAILS fallan"
((FAILS == 0))
