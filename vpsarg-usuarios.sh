#!/usr/bin/env bash
# VPS ARG QuickStart - cuentas SSH de los usuarios finales
# Las cuentas son usuarios Linux normales (usuario + contraseña SSH) del grupo
# vpsarg-usuarios. Solo se administran las cuentas de ese grupo con UID >= 1000.
# No modifica /etc/ssh/sshd_config ni /etc/shells. Las contraseñas nunca se
# muestran, no van en la línea de comandos y no se registran.
set -Eeuo pipefail

GROUP="vpsarg-usuarios"
STATE_DIR="/etc/vpsarg"
SUSPENDED="$STATE_DIR/usuarios-suspendidos"   # usuario:vencimiento_anterior
LIMITS="$STATE_DIR/limites"                    # usuario:máximo de conexiones (0 = sin límite)
LOCK="/run/vpsarg-usuarios.lock"
SHELL_NOLOGIN="/usr/sbin/nologin"
LOG_TAG="vpsarg-panel"
NAME_RE='^[a-z_][a-z0-9_-]{0,30}$'
PASS_MIN=6
PASS_MAX=128
DAYS_MAX=3650
LIMIT_DEFAULT=1
LIMIT_MAX=99
# Control del límite (etapa 3C): pam_exec en la fase account de sshd.
PAM_SSHD="/etc/pam.d/sshd"
PAM_BACKUP="$STATE_DIR/pam-sshd.antes-del-limite"
LIMIT_HOOK="/usr/local/sbin/vpsarg-limite"
SESSIONS_DIR="/run/vpsarg/sesiones"
PAM_MARK="# VPS ARG: límite de conexiones por usuario (se quita con: vpsarg-usuarios control off)"
PAM_LINE1="account [success=1 default=ignore] pam_succeed_if.so quiet user notingroup $GROUP"
PAM_LINE2="account required pam_exec.so stdout quiet $LIMIT_HOOK"
VERIFY_USER="vpsarg-verif"

usage() {
  cat <<'EOF'
Uso:
  sudo vpsarg-usuarios listar
  sudo vpsarg-usuarios ver USUARIO
  sudo vpsarg-usuarios crear USUARIO [DÍAS] [LÍMITE]
                                            (pide la contraseña sin mostrarla; sin DÍAS no vence;
                                             LÍMITE por defecto 1, 0 = sin límite)
  sudo vpsarg-usuarios renovar USUARIO DÍAS  (suma DÍAS desde hoy o desde el vencimiento, el mayor)
  sudo vpsarg-usuarios vencimiento USUARIO AAAA-MM-DD|nunca
  sudo vpsarg-usuarios clave USUARIO        (cambia la contraseña; pide la nueva sin mostrarla)
  sudo vpsarg-usuarios limite USUARIO [N]   (muestra o cambia el máximo de conexiones; 0 = sin límite)
  sudo vpsarg-usuarios suspender USUARIO    (chage -E 0 y cierra sus sesiones SSH)
  sudo vpsarg-usuarios reactivar USUARIO    (restaura el vencimiento anterior)
  sudo vpsarg-usuarios eliminar USUARIO     (cierra sus sesiones y userdel -r)
  sudo vpsarg-usuarios control [on|off]     (aplica los límites con PAM; sin argumento muestra el estado)

Vencimiento: la cuenta no puede entrar desde el día indicado (inclusive). Las sesiones ya
abiertas siguen hasta que se desconecten.
Límite: con el control activo, una conexión nueva se rechaza si la cuenta ya tiene su
máximo de conexiones abiertas. Las conexiones existentes nunca se cierran.
EOF
}

log() {
  logger -t "$LOG_TAG" -- "admin=${SUDO_USER:-root} $*" 2>/dev/null || true
}

# fail ACCIÓN USUARIO MENSAJE: registra el error y termina.
fail() {
  log "accion=$1 usuario=$2 resultado=error motivo=\"$3\""
  echo "ERROR: $3" >&2
  exit 1
}

valid_name() {
  [[ "$1" =~ $NAME_RE ]]
}

# Cuenta administrada: existe, UID >= 1000 (no nobody) y es del grupo.
managed() {
  local uid
  uid="$(getent passwd "$1" | cut -d: -f3)" || return 1
  [[ "$uid" =~ ^[0-9]+$ ]] && ((uid >= 1000 && uid != 65534)) || return 1
  id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP"
}

require_managed() {
  local action="$1" user="$2"
  valid_name "$user" || fail "$action" "-" "nombre de usuario no válido"
  getent passwd "$user" >/dev/null || fail "$action" "$user" "el usuario $user no existe"
  managed "$user" || fail "$action" "$user" "$user no es una cuenta administrada por VPS ARG (grupo $GROUP)"
}

shadow_field() {
  getent shadow "$1" | cut -d: -f"$2"
}

today() {
  echo $(( $(date +%s) / 86400 ))
}

# ACTIVO, SUSPENDIDO, VENCIDO o CONTRASEÑA BLOQUEADA.
user_state() {
  local exp pw
  exp="$(shadow_field "$1" 8)"
  pw="$(shadow_field "$1" 2)"
  if [[ "$exp" == 0 ]]; then
    echo "SUSPENDIDO"
  elif [[ -n "$exp" ]] && ((exp <= $(today))); then
    echo "VENCIDO"
  elif [[ "$pw" == '!'* || "$pw" == '*'* ]]; then
    echo "CONTRASEÑA BLOQUEADA"
  else
    echo "ACTIVO"
  fi
}

days_to_date() {
  if [[ -z "$1" ]]; then echo "nunca"; else date -u -d "@$(( $1 * 86400 ))" +%F; fi
}

# PIDs de las sesiones SSH autenticadas del usuario: procesos sshd con su UID.
session_pids() {
  local uid
  uid="$(id -u "$1")"
  { ps -o pid=,comm= -u "$uid" 2>/dev/null || true; } | awk '$2=="sshd" || $2=="sshd-session" {print $1}'
}

# Cierra las sesiones con SIGTERM y espera hasta 5 s. Devuelve 1 si queda alguna.
close_sessions() {
  local user="$1" pids _
  mapfile -t pids < <(session_pids "$user")
  ((${#pids[@]})) || return 0
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for _ in $(seq 10); do
    [[ -z "$(session_pids "$user")" ]] && { echo "Sesiones SSH cerradas: ${#pids[@]}."; return 0; }
    sleep 0.5
  done
  return 1
}

saved_expiry() {
  [[ -r "$SUSPENDED" ]] || return 1
  grep -m1 "^$1:" "$SUSPENDED" | cut -d: -f2
}

# set_saved USUARIO [VALOR]: guarda (o borra, sin VALOR) el vencimiento anterior.
set_saved() {
  local tmp
  install -d -m 0700 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.usuarios.XXXXXX")"
  if [[ -r "$SUSPENDED" ]]; then grep -v "^$1:" "$SUSPENDED" > "$tmp" || true; fi
  (($# == 2)) && printf '%s:%s\n' "$1" "$2" >> "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$SUSPENDED"
}

# get_limit USUARIO: máximo guardado; vacío si no tiene (cuentas anteriores a 3B = sin límite).
get_limit() {
  [[ -r "$LIMITS" ]] || return 0
  sed -n "s/^$1:\([0-9]*\)$/\1/p" "$LIMITS" | tail -n 1
}

# set_limit USUARIO [N]: guarda (o borra, sin N) el máximo de conexiones.
set_limit() {
  local tmp
  install -d -m 0700 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.limites.XXXXXX")"
  if [[ -r "$LIMITS" ]]; then grep -v "^$1:" "$LIMITS" > "$tmp" || true; fi
  (($# == 2)) && printf '%s:%s\n' "$1" "$2" >> "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$LIMITS"
}

limit_text() {
  local l
  l="$(get_limit "$1")"
  if [[ -z "$l" || "$l" == 0 ]]; then echo "sin límite"; else echo "$l"; fi
}

control_active() {
  [[ -r "$PAM_SSHD" ]] && grep -qxF -- "$PAM_LINE2" "$PAM_SSHD"
}

control_text() {
  if control_active; then echo "se aplica"; else echo "no se aplica: control de límites desactivado"; fi
}

valid_days() {
  [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]] && (($1 <= DAYS_MAX))
}

valid_limit() {
  [[ "$1" =~ ^(0|[1-9][0-9]?)$ ]] && (($1 <= LIMIT_MAX))
}

# Días desde 1970 de una fecha AAAA-MM-DD válida (UTC, como /etc/shadow).
date_to_days() {
  local secs
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  secs="$(date -u -d "$1" +%s 2>/dev/null)" || return 1
  [[ "$(date -u -d "@$secs" +%F)" == "$1" ]] || return 1
  echo $((secs / 86400))
}

# Espera a que no quede ningún proceso del UID. Si solo queda el administrador de
# sesión de systemd de esa cuenta (user@UID.service), lo detiene: es exclusivo de la
# cuenta y sigue vivo unos segundos después de cerrar la última sesión.
release_uid() {
  local uid="$1" i
  for i in $(seq 20); do
    pgrep -u "$uid" >/dev/null 2>&1 || return 0
    if ((i == 4)) && systemctl is-active --quiet "user@$uid.service" 2>/dev/null; then
      systemctl stop "user@$uid.service" 2>/dev/null || true
    fi
    sleep 0.5
  done
  ! pgrep -u "$uid" >/dev/null 2>&1
}

ssh_password_note() {
  local pa
  pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
  case "$pa" in
    yes) ;;
    no) echo "AVISO: SSH no acepta contraseñas (PasswordAuthentication no). La cuenta no podrá entrar con usuario y contraseña hasta que el administrador lo cambie; este programa no modifica sshd_config." >&2 ;;
    *) echo "AVISO: no se pudo leer la configuración de SSH (sshd -T)." >&2 ;;
  esac
}

read_password() {
  # Deja la contraseña en PASS. Con terminal la pide dos veces sin eco.
  local again
  PASS=""
  if [[ -t 0 ]]; then
    read -r -s -p "Contraseña: " PASS || PASS=""; echo >&2
    read -r -s -p "Repetila: " again || again=""; echo >&2
    [[ "$PASS" == "$again" ]] || { PASS=""; return 2; }
  else
    IFS= read -r PASS || [[ -n "$PASS" ]] || return 1
  fi
  ((${#PASS} >= PASS_MIN && ${#PASS} <= PASS_MAX)) || return 1
  [[ "$PASS" != *[[:cntrl:]]* && "$PASS" != *:* ]] || return 1
}

# ------------------------------------------------------------------ acciones
cmd_listar() {
  local members user exp
  members="$(getent group "$GROUP" | cut -d: -f4 | tr ',' '\n' | sort || true)"
  printf '%-20s %-7s %-22s %-11s %-8s %s\n' USUARIO UID ESTADO LÍMITE SESIONES VENCE
  [[ -n "$members" ]] || { echo "(no hay cuentas)"; return 0; }
  while IFS= read -r user; do
    managed "$user" || continue
    exp="$(shadow_field "$user" 8)"
    if [[ "$exp" == 0 ]]; then exp="$(saved_expiry "$user" || true)"; fi
    printf '%-20s %-7s %-22s %-11s %-8s %s\n' "$user" "$(id -u "$user")" "$(user_state "$user")" \
      "$(limit_text "$user" | sed 's/sin límite/-/')" "$(session_pids "$user" | wc -l)" "$(days_to_date "$exp")"
  done <<<"$members"
  echo
  echo "SESIONES = sesiones SSH autenticadas (por SSH directo, PDirect-C o HCR)."
  echo "LÍMITE = máximo de conexiones (- = sin límite); $(control_text)."
  echo "VENCE = desde ese día la cuenta no puede entrar. El consumo todavía no se mide."
}

cmd_ver() {
  local user="$1" exp saved pids
  require_managed ver "$user"
  exp="$(shadow_field "$user" 8)"
  echo "Usuario:   $user (UID $(id -u "$user"))"
  echo "Estado:    $(user_state "$user")"
  if [[ "$exp" == 0 ]]; then
    saved="$(saved_expiry "$user" || true)"
    echo "Vence:     suspendida (al reactivar: $(days_to_date "$saved"))"
  else
    echo "Vence:     $(days_to_date "$exp")"
  fi
  echo "Límite:    $(limit_text "$user") ($(control_text))"
  echo "Home:      $(getent passwd "$user" | cut -d: -f6)"
  echo "Shell:     $(getent passwd "$user" | cut -d: -f7)"
  pids="$(session_pids "$user" | tr '\n' ' ')"
  echo "Sesiones:  $(session_pids "$user" | wc -l)${pids:+ (PID $pids)}"
}

cmd_crear() {
  local user="$1" days="${2:-}" limit="${3:-$LIMIT_DEFAULT}" rc=0 exp=""
  valid_name "$user" || fail crear "-" "nombre de usuario no válido (minúsculas, números, _ o -; máximo 31; empieza con letra o _)"
  if [[ -n "$days" ]]; then
    valid_days "$days" || fail crear "$user" "días no válidos (1 a $DAYS_MAX)"
    exp=$(( $(today) + days ))
  fi
  valid_limit "$limit" || fail crear "$user" "límite no válido (0 a $LIMIT_MAX; 0 = sin límite)"
  getent passwd "$user" >/dev/null && fail crear "$user" "el usuario $user ya existe"
  getent group "$user" >/dev/null && fail crear "$user" "ya existe un grupo llamado $user"
  [[ -x "$SHELL_NOLOGIN" ]] || fail crear "$user" "no existe $SHELL_NOLOGIN"
  ssh_password_note
  read_password || rc=$?
  if ((rc == 2)); then fail crear "$user" "las contraseñas no coinciden"; fi
  if ((rc != 0)); then fail crear "$user" "contraseña no válida ($PASS_MIN a $PASS_MAX caracteres, sin ':' ni caracteres de control)"; fi
  if ! getent group "$GROUP" >/dev/null; then
    groupadd --system "$GROUP" || fail crear "$user" "no se pudo crear el grupo $GROUP"
    log "accion=crear-grupo grupo=$GROUP resultado=ok"
  fi
  if ! useradd -m -k /dev/null -s "$SHELL_NOLOGIN" -G "$GROUP" "$user"; then
    PASS=""
    fail crear "$user" "useradd falló"
  fi
  # La contraseña va por la entrada estándar de chpasswd (printf es interno de bash).
  if ! printf '%s:%s\n' "$user" "$PASS" | chpasswd; then
    PASS=""
    userdel -r "$user" >/dev/null 2>&1 || true
    fail crear "$user" "chpasswd falló; se eliminó la cuenta a medio crear"
  fi
  PASS=""
  if [[ -n "$exp" ]] && ! chage -E "$exp" "$user"; then
    userdel -r "$user" >/dev/null 2>&1 || true
    fail crear "$user" "chage -E falló; se eliminó la cuenta a medio crear"
  fi
  set_limit "$user" "$limit"
  log "accion=crear usuario=$user resultado=ok vence=$(days_to_date "$exp") limite=$limit"
  echo "Cuenta $user creada (shell $SHELL_NOLOGIN, grupo $GROUP)."
  echo "Vence: $(days_to_date "$exp") · Límite: $(limit_text "$user")."
}

# set_expiry ACCIÓN USUARIO DÍAS_DESDE_1970|"": aplica el vencimiento, o lo guarda si está suspendida.
set_expiry() {
  local action="$1" user="$2" new="$3"
  if [[ "$(shadow_field "$user" 8)" == 0 ]]; then
    set_saved "$user" "$new"
    log "accion=$action usuario=$user resultado=ok vence=$(days_to_date "$new") suspendida=si"
    echo "$user sigue suspendida. Al reactivarla vencerá: $(days_to_date "$new")."
  else
    chage -E "${new:--1}" "$user" || fail "$action" "$user" "chage -E falló"
    log "accion=$action usuario=$user resultado=ok vence=$(days_to_date "$new")"
    echo "$user vence: $(days_to_date "$new")."
  fi
}

cmd_renovar() {
  local user="$1" days="$2" cur base
  require_managed renovar "$user"
  valid_days "$days" || fail renovar "$user" "días no válidos (1 a $DAYS_MAX)"
  cur="$(shadow_field "$user" 8)"
  [[ "$cur" == 0 ]] && cur="$(saved_expiry "$user" || true)"
  base="$(today)"
  [[ -n "$cur" ]] && ((cur > base)) && base="$cur"
  set_expiry renovar "$user" $((base + days))
}

cmd_vencimiento() {
  local user="$1" when="$2" new=""
  require_managed vencimiento "$user"
  if [[ "$when" != nunca ]]; then
    new="$(date_to_days "$when")" || fail vencimiento "$user" "fecha no válida (AAAA-MM-DD o nunca)"
    ((new > $(today))) || fail vencimiento "$user" "la fecha tiene que ser posterior a hoy (para cortar el acceso, suspendé la cuenta)"
  fi
  set_expiry vencimiento "$user" "$new"
}

cmd_clave() {
  local user="$1" rc=0
  require_managed clave "$user"
  ssh_password_note
  read_password || rc=$?
  if ((rc == 2)); then fail clave "$user" "las contraseñas no coinciden"; fi
  if ((rc != 0)); then fail clave "$user" "contraseña no válida ($PASS_MIN a $PASS_MAX caracteres, sin ':' ni caracteres de control)"; fi
  if ! printf '%s:%s\n' "$user" "$PASS" | chpasswd; then
    PASS=""
    fail clave "$user" "chpasswd falló; la contraseña no cambió"
  fi
  PASS=""
  log "accion=clave usuario=$user resultado=ok"
  echo "Contraseña de $user cambiada. Las sesiones abiertas siguen."
}

cmd_limite() {
  local user="$1" limit="${2:-}"
  require_managed limite "$user"
  if [[ -z "$limit" ]]; then
    echo "$user: límite $(limit_text "$user"), sesiones actuales $(session_pids "$user" | wc -l)."
    return 0
  fi
  valid_limit "$limit" || fail limite "$user" "límite no válido (0 a $LIMIT_MAX; 0 = sin límite)"
  set_limit "$user" "$limit"
  log "accion=limite usuario=$user resultado=ok limite=$limit"
  echo "$user: límite $(limit_text "$user"). No se cierra ninguna sesión abierta."
}

cmd_suspender() {
  local user="$1" exp
  require_managed suspender "$user"
  exp="$(shadow_field "$user" 8)"
  if [[ "$exp" == 0 ]]; then
    log "accion=suspender usuario=$user resultado=sin-cambios motivo=\"ya estaba suspendida\""
    echo "$user ya estaba suspendida. Sin cambios."
  else
    set_saved "$user" "$exp"
    if ! chage -E 0 "$user"; then
      set_saved "$user"
      fail suspender "$user" "chage -E 0 falló"
    fi
    log "accion=suspender usuario=$user resultado=ok vencimiento_anterior=$(days_to_date "$exp")"
    echo "$user suspendida (chage -E 0). Vencimiento anterior guardado: $(days_to_date "$exp")."
  fi
  if ! close_sessions "$user"; then
    fail suspender "$user" "la cuenta quedó suspendida pero siguen sesiones abiertas (PID $(session_pids "$user" | tr '\n' ' '))"
  fi
}

cmd_reactivar() {
  local user="$1" exp saved
  require_managed reactivar "$user"
  exp="$(shadow_field "$user" 8)"
  if [[ "$exp" != 0 ]]; then
    log "accion=reactivar usuario=$user resultado=sin-cambios motivo=\"no estaba suspendida\""
    echo "$user no estaba suspendida. Sin cambios."
    return 0
  fi
  if ! saved="$(saved_expiry "$user")"; then
    saved=""
    echo "AVISO: no hay vencimiento guardado para $user (no se suspendió desde VPS ARG); queda sin vencimiento." >&2
  fi
  chage -E "${saved:--1}" "$user" || fail reactivar "$user" "chage -E falló"
  set_saved "$user"
  log "accion=reactivar usuario=$user resultado=ok vencimiento=$(days_to_date "$saved")"
  echo "$user reactivada. Vence: $(days_to_date "$saved")."
  if [[ -n "$saved" ]] && ((saved <= $(today))); then
    echo "AVISO: ese vencimiento ya pasó; la cuenta sigue sin poder entrar." >&2
  fi
}

cmd_eliminar() {
  local user="$1"
  require_managed eliminar "$user"
  close_sessions "$user" || fail eliminar "$user" "no se pudieron cerrar sus sesiones SSH; no se eliminó"
  release_uid "$(id -u "$user")" \
    || fail eliminar "$user" "siguen procesos de la cuenta (PID $(pgrep -u "$(id -u "$user")" | tr '\n' ' ')); no se eliminó"
  # El aviso de "mail spool not found" es normal: estas cuentas no tienen correo.
  userdel -r "$user" 2> >(grep -v "mail spool" >&2) || fail eliminar "$user" "userdel -r falló"
  set_saved "$user"
  set_limit "$user"
  log "accion=eliminar usuario=$user resultado=ok"
  echo "Cuenta $user eliminada (con su directorio personal)."
}

# ------------------------------------------------------------------ control del límite (3C)
# El script que llama pam_exec. Corre en el proceso monitor de cada conexión SSH nueva
# de las cuentas del grupo, después de validar la contraseña y antes de abrir la sesión.
write_limit_hook() {
  local tmp
  tmp="$(mktemp "${LIMIT_HOOK%/*}/.vpsarg-limite.XXXXXX")" || return 1
  cat > "$tmp" <<'EOF'
#!/bin/bash
# VPS ARG QuickStart - límite de conexiones por usuario (pam_exec, fase account de sshd).
# Lo escribe "vpsarg-usuarios control on" y lo borra "control off". Si la cuenta ya tiene
# su máximo de conexiones, rechaza la nueva; nunca cierra las existentes.
# Cada conexión aceptada queda registrada como /run/vpsarg/sesiones/USUARIO/PID con la hora
# de inicio del proceso monitor de sshd; los registros de monitores terminados se borran.
# Ante cualquier error inesperado deja pasar (solo rechaza por el límite).
LIMITS=/etc/vpsarg/limites
REG=/run/vpsarg/sesiones
u="${PAM_USER:-}"
[[ "${PAM_TYPE:-}" == account && "$u" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || exit 0
max="$(sed -n "s/^$u:\([0-9]\{1,2\}\)$/\1/p" "$LIMITS" 2>/dev/null | tail -n 1)"
[[ -n "$max" && "$max" != 0 ]] || exit 0
# Hora de inicio del proceso (campo 22 de /proc/PID/stat): distingue PID reutilizados.
starttime() {
  local s
  [[ "$1" =~ ^[0-9]+$ ]] && s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"
  set -- $s
  echo "${20}"
}
mon="$PPID"
if [[ "$(cat "/proc/$mon/comm" 2>/dev/null)" != sshd* ]]; then
  logger -t vpsarg-limite "aviso usuario=$u el proceso padre no es sshd; se deja pasar"
  exit 0
fi
mst="$(starttime "$mon")" || exit 0
mkdir -p -m 0700 "$REG/$u" 2>/dev/null || exit 0
exec 8> "$REG/.lock" && flock -w 5 8 || exit 0
n=0
for f in "$REG/$u"/*; do
  [[ -f "$f" ]] || continue
  p="${f##*/}"
  [[ "$p" == "$mon" ]] && continue
  if [[ "$(starttime "$p")" == "$(cat "$f" 2>/dev/null)" ]]; then n=$((n + 1)); else rm -f -- "$f"; fi
done
if ((n >= max)); then
  logger -t vpsarg-limite "rechazada usuario=$u actuales=$n limite=$max"
  echo "CONEXION RECHAZADA: limite de conexiones alcanzado ($n/$max)"
  exit 1
fi
echo "$mst" > "$REG/$u/$mon" || exit 0
logger -t vpsarg-limite "aceptada usuario=$u actuales=$((n + 1)) limite=$max"
exit 0
EOF
  if ! bash -n "$tmp" || ! chmod 0755 "$tmp" || ! mv -f "$tmp" "$LIMIT_HOOK"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Registra las conexiones que ya estaban abiertas al activar el control, para que cuenten.
# Monitor de cada conexión: proceso de root "sshd: USUARIO [priv]".
register_open_sessions() {
  local pid user
  install -d -m 0700 "${SESSIONS_DIR%/*}" "$SESSIONS_DIR"
  while read -r pid user; do
    managed "$user" || continue
    install -d -m 0700 "$SESSIONS_DIR/$user"
    awk '{sub(/.*\) /, ""); print $20}' "/proc/$pid/stat" > "$SESSIONS_DIR/$user/$pid" 2>/dev/null || rm -f -- "$SESSIONS_DIR/$user/$pid"
  done < <(ps -eo pid=,uid=,args= | awk '$2 == 0 && ($3 == "sshd:" || $3 == "sshd-session:") && $5 == "[priv]" && NF == 5 {print $1, $4}')
}

# pam_lines add|remove: escribe /etc/pam.d/sshd con o sin las líneas del control.
pam_lines() {
  local tmp
  tmp="$(mktemp "${PAM_SSHD%/*}/.vpsarg-sshd.XXXXXX")" || return 1
  if [[ "$1" == add ]]; then
    awk -v m="$PAM_MARK" -v l1="$PAM_LINE1" -v l2="$PAM_LINE2" \
      '{print} $0 == "@include common-account" {print m; print l1; print l2}' "$PAM_SSHD" > "$tmp"
  else
    grep -vxF -e "$PAM_MARK" -e "$PAM_LINE1" -e "$PAM_LINE2" "$PAM_SSHD" > "$tmp"
  fi
  if ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$PAM_SSHD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Prueba real: una cuenta temporal del grupo con límite 1 entra por SSH con clave a
# 127.0.0.1; con esa conexión abierta, una segunda tiene que ser rechazada y la primera seguir.
verify_limit() {
  local dir port p1 rc _ ok=1 opts
  port="$(sed -n 's/^SSH_PORT=\([0-9]*\)$/\1/p' /etc/vpsarg-pdirect.conf 2>/dev/null)"
  port="${port:-22}"
  dir="$(mktemp -d /run/vpsarg-verif.XXXXXX)" || return 1
  chmod 0755 "$dir"
  if ! useradd -M -d "$dir/home" -s "$SHELL_NOLOGIN" -G "$GROUP" "$VERIFY_USER" 2>/dev/null; then
    rm -rf -- "$dir"
    VERIFY_ERR="no se pudo crear la cuenta temporal $VERIFY_USER"
    return 1
  fi
  install -d -m 0700 -o "$VERIFY_USER" -g "$VERIFY_USER" "$dir/home" "$dir/home/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C vpsarg-verif -f "$dir/clave" >/dev/null
  install -m 0600 -o "$VERIFY_USER" -g "$VERIFY_USER" "$dir/clave.pub" "$dir/home/.ssh/authorized_keys"
  set_limit "$VERIFY_USER" 1
  opts=(-i "$dir/clave" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -p "$port")
  ssh "${opts[@]}" -N "$VERIFY_USER@127.0.0.1" </dev/null >/dev/null 2>&1 &
  p1=$!
  VERIFY_ERR="la cuenta temporal no pudo entrar por SSH con clave a 127.0.0.1:$port"
  for _ in $(seq 30); do
    if [[ -n "$(session_pids "$VERIFY_USER")" ]]; then ok=0; break; fi
    kill -0 "$p1" 2>/dev/null || break
    sleep 0.5
  done
  if ((ok == 0)); then
    rc=0
    timeout 20 ssh "${opts[@]}" -N "$VERIFY_USER@127.0.0.1" </dev/null >/dev/null 2>&1 || rc=$?
    if ((rc == 0 || rc == 124)); then
      ok=1; VERIFY_ERR="una segunda conexión con límite 1 no fue rechazada"
    elif ! kill -0 "$p1" 2>/dev/null || [[ "$(session_pids "$VERIFY_USER" | wc -l)" != 1 ]]; then
      ok=1; VERIFY_ERR="la primera conexión no siguió abierta después del rechazo"
    fi
  fi
  kill "$p1" 2>/dev/null || true
  wait "$p1" 2>/dev/null || true
  close_sessions "$VERIFY_USER" >/dev/null || true
  release_uid "$(id -u "$VERIFY_USER")" || true
  userdel "$VERIFY_USER" >/dev/null 2>&1 || { ok=1; VERIFY_ERR="no se pudo borrar la cuenta temporal $VERIFY_USER"; }
  set_limit "$VERIFY_USER"
  rm -rf -- "$dir" "${SESSIONS_DIR:?}/$VERIFY_USER"
  return "$ok"
}

control_show() {
  if control_active; then
    echo "Control de límites: ACTIVO (las conexiones nuevas que superan el límite se rechazan)."
  else
    echo "Control de límites: INACTIVO (los límites se guardan pero no se aplican)."
  fi
}

control_on() {
  local n
  if control_active; then control_show; return 0; fi
  [[ -f "$PAM_SSHD" ]] || fail control - "no existe $PAM_SSHD"
  n="$(grep -cx '@include common-account' "$PAM_SSHD" || true)"
  [[ "$n" == 1 ]] || fail control - "$PAM_SSHD no tiene exactamente una línea '@include common-account'; no se modifica"
  grep -qF -e "$PAM_LINE1" -e "$LIMIT_HOOK" "$PAM_SSHD" && fail control - "$PAM_SSHD tiene líneas del control incompletas; revisalo a mano"
  [[ "$(sshd -T 2>/dev/null | awk '$1=="usepam"{print $2}')" == yes ]] || fail control - "SSH no usa PAM (UsePAM) o no se pudo comprobar con sshd -T"
  command -v ssh >/dev/null && command -v ssh-keygen >/dev/null || fail control - "falta el cliente ssh para la verificación"
  getent passwd "$VERIFY_USER" >/dev/null && fail control - "ya existe la cuenta $VERIFY_USER (de una verificación anterior); eliminala antes"
  if ! getent group "$GROUP" >/dev/null; then
    groupadd --system "$GROUP" || fail control - "no se pudo crear el grupo $GROUP"
  fi
  install -d -m 0700 "$STATE_DIR"
  write_limit_hook || fail control - "no se pudo escribir $LIMIT_HOOK"
  cp -p -- "$PAM_SSHD" "$PAM_BACKUP" && chmod 0600 "$PAM_BACKUP" || fail control - "no se pudo copiar $PAM_SSHD"
  if ! pam_lines add || ! control_active; then
    cp -p -- "$PAM_BACKUP" "$PAM_SSHD"
    rm -f -- "$LIMIT_HOOK"
    fail control - "no se pudo modificar $PAM_SSHD; quedó como estaba"
  fi
  register_open_sessions
  echo "Verificando con una cuenta temporal ($VERIFY_USER, límite 1)..."
  if ! verify_limit; then
    pam_lines remove || cp -p -- "$PAM_BACKUP" "$PAM_SSHD"
    rm -f -- "$LIMIT_HOOK"
    rm -rf -- "$SESSIONS_DIR"
    fail control - "verificación fallida: $VERIFY_ERR. Se revirtió: $PAM_SSHD quedó como antes"
  fi
  log "accion=control valor=on resultado=ok copia=$PAM_BACKUP"
  echo "Verificación correcta: la 2.ª conexión fue rechazada y la 1.ª siguió abierta."
  echo "Copia de $PAM_SSHD anterior: $PAM_BACKUP. SSH no se reinició."
  control_show
}

control_off() {
  if ! control_active && ! grep -qF -e "$PAM_LINE1" -e "$LIMIT_HOOK" "$PAM_SSHD" 2>/dev/null; then
    rm -f -- "$LIMIT_HOOK"
    control_show
    return 0
  fi
  # Primero las líneas y después el script: sin el script, las cuentas del grupo no entrarían.
  pam_lines remove || fail control - "no se pudo modificar $PAM_SSHD"
  grep -qF -e "$PAM_LINE1" -e "$LIMIT_HOOK" "$PAM_SSHD" && fail control - "quedaron líneas del control en $PAM_SSHD"
  rm -f -- "$LIMIT_HOOK"
  rm -rf -- "$SESSIONS_DIR"
  log "accion=control valor=off resultado=ok"
  if [[ -r "$PAM_BACKUP" ]] && cmp -s "$PAM_BACKUP" "$PAM_SSHD"; then
    echo "$PAM_SSHD quedó igual que antes de activar el control."
  fi
  echo "Ninguna conexión abierta se cerró. SSH no se reinició."
  control_show
}

main() {
  local action="${1:-}"
  case "$action" in
    listar) (($# == 1)) || { usage; exit 1; } ;;
    ver|suspender|reactivar|eliminar|clave) (($# == 2)) || { usage; exit 1; } ;;
    crear) (($# >= 2 && $# <= 4)) || { usage; exit 1; } ;;
    limite) (($# == 2 || $# == 3)) || { usage; exit 1; } ;;
    renovar|vencimiento) (($# == 3)) || { usage; exit 1; } ;;
    control) (($# == 1)) || [[ $# == 2 && "$2" =~ ^(on|off)$ ]] || { usage; exit 1; } ;;
    -h|--help|ayuda) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  [[ ${EUID} -eq 0 ]] || { echo "Usá sudo: sudo vpsarg-usuarios $action" >&2; exit 1; }
  exec 9>"$LOCK"
  flock -w 10 9 || { echo "ERROR: otra operación de usuarios está en curso." >&2; exit 1; }
  case "$action" in
    listar) cmd_listar ;;
    ver) cmd_ver "$2" ;;
    crear) cmd_crear "$2" "${3:-}" "${4:-}" ;;
    renovar) cmd_renovar "$2" "$3" ;;
    vencimiento) cmd_vencimiento "$2" "$3" ;;
    clave) cmd_clave "$2" ;;
    limite) cmd_limite "$2" "${3:-}" ;;
    suspender) cmd_suspender "$2" ;;
    reactivar) cmd_reactivar "$2" ;;
    eliminar) cmd_eliminar "$2" ;;
    control)
      case "${2:-}" in
        on) control_on ;;
        off) control_off ;;
        *) control_show ;;
      esac ;;
  esac
}

main "$@"
