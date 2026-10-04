# VPS ARG QuickStart

Instalador para Ubuntu que instala, en una sola corrida autorizada por un token, estos servicios, cada uno con su propia unidad systemd y arranque automático:

| Servicio | Unidad systemd | Escucha | Destino |
|---|---|---|---|
| PDirect-C | `pdirect-80.service` | `0.0.0.0:80/TCP` | SSH local `127.0.0.1:PUERTO_SSH` (22 por defecto) |
| BadVPN UDPGW | `udpgw-7300.service` | `0.0.0.0:7300/TCP` | — |
| HCR | `hcr-8880.service` | `:8880/TCP` (configurable) | SSH local `127.0.0.1:PUERTO_SSH` |
| BHTTP (adaptador) | `bhttp-shim.service` | `0.0.0.0:8001/TCP` (configurable) | `bhttp-server` en `127.0.0.1:18022` |
| BHTTP (servidor) | `bhttp-server.service` | `127.0.0.1:18022/TCP` (solo local) | SSH local `127.0.0.1:PUERTO_SSH` |

Incluye el controlador `vpsarg-puertos` para consultar estado, iniciar, detener, reiniciar, habilitar, deshabilitar y cambiar el puerto SSH de destino, `vpsarg-hcr` y `vpsarg-bhttp` para administrar HCR y BHTTP (ver [HCR](#hcr) y [BHTTP](#bhttp)), y el panel `vpsarg` (ver [Panel](#panel)). HCR y BHTTP son obligatorios: si falta alguno, la instalación se detiene sin cambios.

No instala panel web ni base de datos. **No modifica `sshd_config`, no reinicia SSH y no toca el firewall.**

## Requisitos

- Un **token de instalación** válido (ver [Token de instalación](#token-de-instalación)).
- Ubuntu 20.04, 22.04 o 24.04 con systemd, en **x86_64** (el binario de HCR entregado es solo x86_64; en otra arquitectura se detiene sin cambios).
- Acceso root (`sudo`) y conexión a Internet (para el servicio de autorización, apt, BadVPN y los binarios de BHTTP).
- El binario de HCR copiado por SFTP en `/opt/hcr/hcr-server` (ver [HCR](#hcr)).
- Puertos TCP 80, 7300, 8880 (HCR) y 8001 (BHTTP, se puede elegir otro) libres, y `127.0.0.1:18022` libre. Si otro programa usa alguno (por ejemplo nginx o apache en el 80), el instalador se detiene sin hacer cambios y **no cambia solo el puerto de otro protocolo**.
- Un servidor SSH escuchando en `127.0.0.1` en el puerto que vayas a indicar.

## Instalación

Comando único:

```bash
curl -fsSL https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main/install.sh -o /tmp/vpsarg-install.sh && sudo bash /tmp/vpsarg-install.sh
```

Para revisar el script antes de ejecutarlo:

```bash
curl -fsSL https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main/install.sh -o /tmp/vpsarg-install.sh
less /tmp/vpsarg-install.sh
sudo bash /tmp/vpsarg-install.sh
```

El instalador primero **valida todo sin cambiar nada**, en este orden:

1. Root, Ubuntu, systemd, x86_64 y los comandos que necesita.
2. **Token**: lo pide (sin eco) o lo toma de `VPSARG_TOKEN`, y lo **reserva** en el servicio de autorización. Si no es válido, venció, fue revocado, ya se usó o lo está usando otra instalación, se detiene sin cambios.
3. Instalación previa: si la hay, la lista y solo continúa si escribís `SI`.
4. Puertos 80 y 7300, y el puerto SSH local (Enter = 22 o el de una instalación previa; si no hay nada escuchando, avisa y pide confirmación).
5. Descarga y revisa (`bash -n`) `pdirect.c`, `vpsarg-puertos.sh`, `vpsarg-hcr.sh`, `vpsarg-bhttp.sh`, `vpsarg-panel.sh` y `vpsarg-usuarios.sh` de la rama `main`.
6. **HCR**: que exista `/opt/hcr/hcr-server`, su sha256, que responda a `-version`, el espacio libre y que TCP 8880 esté libre (`vpsarg-hcr verificar`). Si falta: `HCR requerido pero no disponible. Instalación abortada sin cambios.`
7. **BHTTP**: pregunta el puerto externo (Enter = 8001), descarga `bhttp-server` y `bhttp-shim`, verifica sus sha256 (ver [BHTTP](#bhttp)) y que ambos puertos estén libres y no choquen con 80, 7300, HCR ni SSH. Si algo falta: `BHTTP requerido pero no disponible`.

Si cualquiera de esos pasos falla, el token **se libera** (no se consume) y no se instala nada. Después:

8. Instala dependencias: `ca-certificates curl git cmake make gcc libc6-dev libevent-dev`, compila PDirect-C:
   `gcc -O2 -Wall -Wextra -D_FORTIFY_SOURCE=2 -fstack-protector-strong -o pdirect-c pdirect.c -levent_core`
   y clona BadVPN (`github.com/ambrop72/badvpn`) para compilar solo UDPGW con CMake. Si falla, no queda ningún componente instalado (solo pueden quedar paquetes de apt) y el token se libera.
9. Guarda una copia de los archivos y del estado de las unidades que va a tocar, instala los archivos y activa PDirect-C, UDPGW, HCR y BHTTP.
10. Comprueba que las 5 unidades estén activas y escuchando. Recién entonces **confirma** el token (queda consumido) y escribe `/etc/vpsarg/instalacion`.

Si algo falla en los pasos 9 o 10, **revierte** lo que instaló en esa corrida (restaura archivos, configuraciones y el estado anterior de cada unidad; no toca componentes que no son de esta instalación), libera el token e informa el paso que falló.

### Archivos instalados

| Ruta | Contenido |
|---|---|
| `/usr/local/bin/pdirect-c` | PDirect-C compilado |
| `/opt/badvpn/badvpn-udpgw` | BadVPN UDPGW compilado |
| `/usr/local/sbin/vpsarg-puertos` | Controlador |
| `/usr/local/sbin/vpsarg-hcr` | Controlador de HCR |
| `/usr/local/sbin/vpsarg-bhttp` | Controlador de BHTTP |
| `/usr/local/sbin/vpsarg` | Panel de administración |
| `/usr/local/sbin/vpsarg-usuarios` | Cuentas SSH de los usuarios |
| `/etc/vpsarg/instalacion` | Id del token, fecha y estado de la instalación (0600; nunca el token) |
| `/etc/vpsarg-pdirect.conf` | `SSH_PORT=22` — única fuente del puerto SSH de destino |
| `/etc/vpsarg-servicios.conf` | Servicios que maneja el controlador |
| `/etc/systemd/system/pdirect-80.service` | Unidad de PDirect-C |
| `/etc/systemd/system/udpgw-7300.service` | Unidad de UDPGW |

Los archivos de HCR y BHTTP están en sus secciones. Todos los servicios corren con un usuario temporal sin privilegios (`DynamicUser=yes`). PDirect-C solo recibe la capacidad `CAP_NET_BIND_SERVICE` para abrir el puerto 80.

## Token de instalación

El token **solo autoriza instalar**. No interviene en el login de los usuarios (siguen entrando con usuario y contraseña SSH) ni en PDirect-C, UDPGW, HCR o BHTTP una vez instalados: si el servicio de autorización se cae, la VPS sigue funcionando igual.

- Hay **un solo token** por instalación completa: no hay tokens ni alcances separados para HCR o BHTTP.
- Formato: `vpsarg_` seguido de 43 caracteres. Se escribe cuando el instalador lo pide (sin eco) o con `VPSARG_TOKEN`. Nunca como argumento.
- Lo controla el **servicio de autorización** (`servicio/vpsarg-autorizacion.py`), que corre en un servidor tuyo, no en las VPS. El instalador lo **reserva** antes de cambiar nada, lo **libera** si la instalación se detiene o falla, y lo **confirma** solo cuando todo quedó funcionando. Un token confirmado no sirve otra vez en **ninguna** VPS.
- El servicio guarda solo el sha256 del token, nunca el token. La VPS guarda solo el id en `/etc/vpsarg/instalacion`.
- `vpsarg-hcr instalar` y `vpsarg-bhttp instalar` solo funcionan dentro de `install.sh` o en una VPS ya instalada con token (para reparar o reinstalar). No piden otro token.

**Servicio de autorización** (en tu servidor):

```bash
sudo python3 servicio/vpsarg-autorizacion.py emitir --vence 2026-12-31 --nota "cliente X"   # muestra el token una sola vez
sudo python3 servicio/vpsarg-autorizacion.py listar | ver ID | revocar ID | liberar ID
sudo python3 servicio/vpsarg-autorizacion.py servir --escuchar 127.0.0.1:8090                 # detrás de un proxy HTTPS
```

La dirección del servicio va en `VPSARG_AUTH_URL` de `vpsarg-token.sh` y tiene que ser `https://`.

**Limitaciones:** el repositorio es público, así que el control se puede quitar copiando el código.

## Administración

```bash
sudo vpsarg-puertos estado                 # estado de ambos servicios, destino SSH y puertos en escucha
sudo vpsarg-puertos iniciar
sudo vpsarg-puertos detener
sudo vpsarg-puertos reiniciar
sudo vpsarg-puertos habilitar              # arranque automático + iniciar ahora
sudo vpsarg-puertos deshabilitar           # detener + quitar arranque automático
sudo vpsarg-puertos reiniciar pdirect-80   # cualquier acción sobre un solo servicio
sudo vpsarg-puertos detener udpgw-7300
```

## Panel

```bash
sudo vpsarg              # menú
sudo vpsarg estado       # ACTIVO / DETENIDO / ERROR / NO INSTALADO por servicio
sudo vpsarg protocolos   # estado, puerto y PID de PDirect-C, UDPGW, HCR, BHTTP y SSH
sudo vpsarg sistema      # CPU, RAM, swap, disco, uptime, protocolos y usuarios conectados
sudo vpsarg puertos      # puerto de sshd, destino de PDirect-C y HCR, puertos en escucha
sudo vpsarg conexiones   # conexiones TCP establecidas por puerto
sudo vpsarg recursos     # RAM, CPU, hilos y descriptores por servicio, RAM y disco del servidor
sudo vpsarg ssh          # si sshd acepta contraseñas (solo lectura)
sudo vpsarg usuarios     # cuentas SSH de los usuarios
sudo vpsarg auto on|off  # AUTO: abrir el panel al iniciar sesión con esta cuenta
```

El menú tiene cuatro secciones:
- **Protocolos**: PDirect-C, UDPGW, HCR, BHTTP y SSH con estado, puerto y PID (por ejemplo `HCR ACTIVO 8880`, `BHTTP ACTIVO 8001`). Cada ficha permite iniciar, detener, reiniciar, habilitar o deshabilitar, y ver el registro y los errores recientes. HCR y BHTTP se instalan (reparan) y desinstalan desde su ficha; la de BHTTP también cambia el puerto y muestra los recursos. **SSH es solo de lectura.**
- **Usuarios**: cuentas SSH (ver [Usuarios SSH](#usuarios-ssh)).
- **Estado**: CPU, carga, RAM, swap, disco, uptime, temperatura (si existe), protocolos y usuarios conectados. También muestra las conexiones TCP por servicio y los recursos de cada servicio.
- **Configuración**: puerto SSH de destino, puerto de HCR, autenticación de SSH, registro del panel, copias y AUTO.

**AUTO** (Configuración → Auto inicio o `sudo vpsarg auto on`): abre el panel al iniciar sesión en una terminal con la cuenta que lo activó. La lista de cuentas queda en `/etc/vpsarg-auto.conf` y el disparador en `/etc/profile.d/vpsarg-auto.sh`, que solo existe mientras haya alguna cuenta con AUTO. No se activa en `ssh host comando`, scp, sftp ni túneles, ni para las cuentas de `vpsarg-usuarios`. Con 0 o Ctrl+C se vuelve a la consola.

- Es un script: no queda ningún proceso corriendo después de salir.
- Todas las acciones usan `vpsarg-puertos`, `vpsarg-hcr`, `vpsarg-bhttp` y `vpsarg-usuarios`; las que cambian algo piden confirmación y quedan registradas (`journalctl -t vpsarg-panel`).
- No modifica `/etc/ssh/sshd_config`, el puerto de sshd, el firewall, el puerto 80 ni los argumentos de PDirect-C, ni la configuración o los límites de UDPGW.
- Los números de conexiones son **conexiones TCP**, no usuarios. Todo lo que entra por PDirect-C, HCR o BHTTP llega a SSH desde 127.0.0.1.
- "Guardar copia de la configuración" copia `/etc/vpsarg-*.conf` y las unidades a `/var/backups/vpsarg/FECHA-panel/`.

## Usuarios SSH

Los usuarios finales son cuentas Linux normales y entran con **usuario y contraseña SSH**. No hay tokens, HWID ni otra autenticación.

```bash
sudo vpsarg-usuarios listar
sudo vpsarg-usuarios ver USUARIO
sudo vpsarg-usuarios crear USUARIO [DÍAS] [LÍMITE]   # pide la contraseña dos veces, sin mostrarla
sudo vpsarg-usuarios renovar USUARIO DÍAS
sudo vpsarg-usuarios vencimiento USUARIO AAAA-MM-DD|nunca
sudo vpsarg-usuarios clave USUARIO        # nueva contraseña, sin mostrarla
sudo vpsarg-usuarios limite USUARIO [N]   # muestra o cambia el máximo de conexiones (0 = sin límite)
sudo vpsarg-usuarios suspender USUARIO
sudo vpsarg-usuarios reactivar USUARIO
sudo vpsarg-usuarios eliminar USUARIO
sudo vpsarg-usuarios control [on|off]     # aplica los límites con PAM (sin argumento: estado)
```

| Acción | Qué hace |
|---|---|
| Crear | `useradd -m -k /dev/null -s /usr/sbin/nologin -G vpsarg-usuarios USUARIO` y la contraseña por la entrada estándar de `chpasswd`. Sin shell: sirve para túneles (`ssh -N`), no para entrar a una consola. Con DÍAS, `chage -E` (hoy + DÍAS). LÍMITE por defecto 1 |
| Renovar | Suma DÍAS desde hoy o desde el vencimiento actual, el que sea mayor. Si está suspendida, actualiza el vencimiento guardado y sigue suspendida |
| Vencimiento | Pone una fecha exacta (posterior a hoy) o `nunca` |
| Cambiar contraseña | `chpasswd` por la entrada estándar. Las sesiones abiertas siguen |
| Límite | Guarda el máximo de conexiones en `/etc/vpsarg/limites` (0600). Se aplica solo con el control de límites activo. Cambiarlo no cierra ninguna sesión |
| Suspender | Guarda el vencimiento actual en `/etc/vpsarg/usuarios-suspendidos` (0600), aplica `chage -E 0` y cierra las sesiones SSH abiertas con SIGTERM. La contraseña no se toca |
| Reactivar | Restaura el vencimiento guardado con `chage -E` (o sin vencimiento si no había) y borra la línea guardada |
| Eliminar | Cierra las sesiones con SIGTERM, espera a que no quede ningún proceso de la cuenta (si solo queda su `systemd --user`, detiene `user@UID.service` de esa cuenta) y ejecuta `userdel -r` |
| Listar / ver | Estado (ACTIVO, SUSPENDIDO, VENCIDO, CONTRASEÑA BLOQUEADA), límite, sesiones SSH abiertas y vencimiento. Nunca muestra contraseñas |

**Vencimiento**: desde el día indicado (inclusive) la cuenta no puede iniciar sesiones nuevas; las que ya están abiertas siguen hasta que se desconectan.

### Límite de conexiones (control con PAM)

Se activa a mano con `sudo vpsarg-usuarios control on` o desde **Configuración › Límite de conexiones por usuario**. El instalador no lo activa.

- Una **conexión** es una sesión SSH autenticada, llegue por SSH directo, PDirect-C, HCR o BHTTP. Si la cuenta ya tiene tantas como su límite, la conexión nueva se **rechaza** después de validar la contraseña. Las conexiones abiertas **nunca se cierran**, ni al rechazar ni al bajar el límite.
- Activar agrega 3 líneas (un comentario y 2 `account`) después de `@include common-account` en `/etc/pam.d/sshd`, con copia previa en `/etc/vpsarg/pam-sshd.antes-del-limite`, y escribe `/usr/local/sbin/vpsarg-limite`. **No reinicia SSH**: PAM se lee en cada conexión nueva.
- Solo se aplica a las cuentas del grupo `vpsarg-usuarios`: root y los administradores no pasan por el control.
- Al activar se verifica con una cuenta temporal (`vpsarg-verif`, límite 1, clave pública a 127.0.0.1): la 2.ª conexión tiene que ser rechazada y la 1.ª seguir. Si falla, se revierte solo y la cuenta temporal se borra. Requiere `UsePAM yes`.
- Las conexiones que ya estaban abiertas al activarlo cuentan para el límite.
- Cada conexión aceptada se registra en `/run/vpsarg/sesiones/USUARIO/` (se vacía al reiniciar el servidor, cuando ya no hay conexiones). Aceptadas y rechazadas quedan en `journalctl -t vpsarg-limite`.
- El cliente OpenSSH muestra `CONEXION RECHAZADA: limite de conexiones alcanzado (N/N)`; una app de túnel puede mostrar solo que la conexión se cerró.
- **PDirect-C y reconexiones**: PDirect-C no detecta enseguida que el cliente se fue. Si el cliente desaparece sin cerrar la sesión SSH (app cerrada a la fuerza, corte de red), la conexión hacia SSH sigue hasta la espera de 60 s sin datos de PDirect-C y cuenta para el límite: con límite 1, una reconexión inmediata por el puerto 80 se rechaza durante ~60 s. Medido igual en Ubuntu 20.04, 22.04 y 24.04. Si el cliente cierra la sesión SSH ordenadamente, en general se libera enseguida, pero en el laboratorio también tardó ~60 s en 2 de 3 intentos en 20.04 y en 1 de 3 en 22.04. Por SSH directo se libera enseguida.
- **BHTTP y reconexiones**: BHTTP no tiene aviso de cierre. Si el cliente desaparece, `bhttp-server` mantiene la conexión hacia SSH hasta su `-session-ttl` (180 s) y cuenta para el límite. Aunque la sesión SSH termine ordenadamente, en el laboratorio casi siempre tardó lo mismo (185 a 195 s, en 20.04, 22.04 y 24.04): con límite 1, una reconexión inmediata puede rechazarse durante ~3 minutos.
- Desactivar (`control off`) quita primero las líneas de `/etc/pam.d/sshd` y después el script. Si `/usr/local/sbin/vpsarg-limite` se borra a mano con el control activo, las cuentas del grupo no pueden entrar (los administradores sí).

- Solo administra cuentas del grupo `vpsarg-usuarios` con UID 1000 o mayor. No toca `root` ni otras cuentas del servidor.
- Nombres: minúsculas, números, `_` o `-`, empiezan con letra o `_`, hasta 31 caracteres. Contraseñas: 6 a 128 caracteres, sin `:`.
- No usa `usermod -L`: no impide entrar con clave pública. No modifica `/etc/ssh/sshd_config` ni `/etc/shells`.
- Si sshd tiene `PasswordAuthentication no`, `crear` y el panel lo avisan, pero no lo cambian.
- Cada operación queda en `journalctl -t vpsarg-panel` con el resultado; nunca la contraseña.

## Puerto SSH de destino

PDirect-C siempre escucha en TCP 80 y reenvía a `127.0.0.1:PUERTO_SSH`. HCR y BHTTP reenvían al mismo puerto. Para ver o cambiar ese puerto:

```bash
sudo vpsarg-puertos puerto-ssh          # muestra el puerto actual
sudo vpsarg-puertos puerto-ssh 2222     # cambia el destino a 127.0.0.1:2222
```

El cambio:

- Valida el número (1-65535) y comprueba que en `127.0.0.1:PUERTO` responda un servidor SSH; si no, avisa y pide confirmación.
- Escribe `SSH_PORT=PUERTO` en `/etc/vpsarg-pdirect.conf`, reinicia solo `pdirect-80` y comprueba que el proceso use el puerto nuevo y que una conexión por TCP 80 llegue a SSH.
- Si HCR está instalado, actualiza `HCR_SSH_PORT` en `/etc/vpsarg-hcr.conf` y reinicia solo `hcr-8880`.
- Si BHTTP está instalado, actualiza `BHTTP_SSH_PORT` en `/etc/vpsarg-bhttp.conf` y reinicia solo `bhttp-server` y `bhttp-shim`.
- Si algo falla, restaura el valor anterior en PDirect-C, HCR y BHTTP, y verifica que PDirect-C quedó activo, escuchando en TCP 80, apuntando al puerto anterior y llegando a SSH.
- No modifica sshd, el puerto 80, UDPGW ni el firewall.

**Importante:** este comando no cambia el puerto en el que escucha SSH. Si cambiás el puerto de sshd por tu cuenta, después ejecutá `puerto-ssh` con el puerto nuevo.

PDirect-C acepta la cabecera `X-Real-Host` solo si vale `127.0.0.1:PUERTO_SSH` o `localhost:PUERTO_SSH` (con el puerto configurado); si la cabecera no está, permite la conexión. Si tu payload incluye `X-Real-Host`, tiene que usar el mismo puerto.

## HCR

HCR es obligatorio y lo instala `install.sh`, como servicio independiente `hcr-8880.service`, a partir del binario `hcr-server` entregado por el proveedor (Go, x86_64, sin código fuente). El binario **no** está en este repositorio.

```bash
# ANTES de install.sh:
sudo mkdir -p /opt/hcr
# Copiá hcr-server por SFTP a /opt/hcr/ y después:
sudo chown root:root /opt/hcr/hcr-server && sudo chmod 755 /opt/hcr/hcr-server
sudo vpsarg-hcr verificar         # comprueba sin cambiar nada
# Después de instalar:
sudo vpsarg-hcr instalar          # reinstala/repara (solo en una VPS ya instalada con token); puerto 8880, transporte plain
sudo vpsarg-hcr estado
sudo vpsarg-hcr iniciar | detener | reiniciar
sudo vpsarg-hcr puerto 8080       # cambiar el puerto (1024-65535, libre); sin número lo muestra
sudo vpsarg-hcr desinstalar
```

`instalar` solo funciona dentro de `install.sh` o en una VPS ya instalada con token, y comprueba x86_64, el sha256 del binario entregado (`68a66ed4…fa085`; otra versión requiere `--sha256 HASH`), que responda a `-version`, el espacio libre y que el puerto esté libre. **No detiene ningún programa** para liberar un puerto. Repetirlo no duplica nada y conserva `/etc/vpsarg-hcr.conf`. No usa ni modifica el `install.sh` del proveedor ni su `hcr-server.service`.

El servicio corre con un usuario temporal sin privilegios (`DynamicUser=yes`), sin capacidades y con el sistema de archivos en solo lectura (`ProtectSystem=strict`). Sus registros van al journal con el nombre `hcr-8880`: `journalctl -u hcr-8880`.

| Archivo | Contenido |
|---|---|
| `/opt/hcr/hcr-server` | Original copiado por SFTP (no se modifica ni se borra) |
| `/usr/local/lib/vpsarg/hcr-server` | Copia que ejecuta el servicio |
| `/etc/vpsarg-hcr.conf` | Puerto, destino SSH, transporte y límites |
| `/etc/systemd/system/hcr-8880.service` | Unidad |

El nombre `hcr-8880` es fijo aunque cambies el puerto; `vpsarg-hcr estado` muestra el puerto real.

### Límites de HCR

Valores iniciales en `/etc/vpsarg-hcr.conf`. No se aumentan hasta probar un cliente HCR compatible.

| Variable | Opción del binario | Valor | Qué limita |
|---|---|---|---|
| `HCR_MAX_SESSIONS` | `-max-sessions` | 32 | Sesiones HCR simultáneas en todo el servidor |
| `HCR_MAX_SESSIONS_PER_IP` | `-max-sessions-per-ip` | 16 | Sesiones HCR simultáneas desde una misma IP |
| `HCR_MAX_CONNECTIONS` | `-max-connections` | 2048 | Conexiones TCP simultáneas al puerto, incluidas las que todavía no se identificaron. **No son usuarios ni sesiones**: una sesión HCR puede usar varias conexiones. Al superarlo, la conexión nueva se cierra al instante (`connection_rejected`, `global_connection_limit` en el journal) |
| `HCR_MAX_DOWNLOAD_FRAME` | `-max-download-frame` | 6144 | Bytes por trama de bajada |
| `HCR_DOWNLOAD_POLL_TIMEOUT` | `-download-poll-timeout` | 8s | Espera máxima de una conexión de bajada |

**CGNAT:** las operadoras móviles hacen salir a muchos clientes por la misma IP pública. Con 16 sesiones por IP, el cliente número 17 detrás de esa IP queda rechazado aunque haya cupos globales libres.

**Sin probar todavía:** no se dispone de un cliente HCR, así que no está verificado que un cliente real se conecte de punta a punta. HCR usa su propio protocolo: no acepta payloads HTTP como PDirect-C. La autenticación de los usuarios sigue siendo la de SSH (usuario y contraseña de la cuenta).

## BHTTP

BHTTP es obligatorio y lo instala `install.sh` con dos servicios: el adaptador `bhttp-shim` recibe a los clientes en el puerto externo y los pasa a `bhttp-server`, que escucha solo en `127.0.0.1:18022` y conecta con SSH local:

```
cliente -> bhttp-shim :8001 -> bhttp-server 127.0.0.1:18022 -> SSH 127.0.0.1:PUERTO_SSH
```

Los binarios no se compilan ni se modifican: se descargan y se verifican con hashes fijos.

| Binario | Origen | sha256 (amd64) |
|---|---|---|
| `bhttp-server` | `darnix0/BHTTP`, `superflash-bhttp-server-v2.4.1-btun-compat-keepalive-linux-amd64` (además debe figurar igual en su `SHA256SUMS.txt`) | `6c539261…e039` |
| `bhttp-shim` | archivo entregado `bhttp-shim-amd64` (publicado en `adri40606941-ui/Zumo`) | `f4cf6c18…6d4c` |

```bash
sudo vpsarg-bhttp status            # estado de ambos servicios y puertos
sudo vpsarg-bhttp on | off | restart
sudo vpsarg-bhttp puerto [N]        # muestra o cambia el puerto externo (1024-65535, libre)
sudo vpsarg-bhttp logs [N]          # registro de ambos servicios
sudo vpsarg-bhttp recursos          # CPU, RAM, PID, tiempo activo y archivos abiertos
sudo vpsarg-bhttp destino-ssh [N]   # puerto SSH de destino (mejor: vpsarg-puertos puerto-ssh N)
sudo vpsarg-bhttp instalar          # reinstala/repara (solo en una VPS ya instalada con token)
sudo vpsarg-bhttp desinstalar       # no toca PDirect-C, UDPGW, HCR ni SSH
```

- Ambos servicios corren con `DynamicUser=yes`, `NoNewPrivileges=true`, sin capacidades, `LimitNOFILE=65536` y `Restart=on-failure`.
- Cambiar el puerto verifica que el nuevo esté libre y no sea 80, 7300, el de HCR ni el de SSH; si el servicio no arranca, vuelve al anterior. No cambia el puerto de ningún otro protocolo.
- Si encuentra unidades `bhttp-server`/`bhttp-shim` de `bhttp-install.sh`, no las toca y pide quitarlas primero.

| Archivo | Contenido |
|---|---|
| `/usr/local/lib/vpsarg/bhttp-server`, `bhttp-shim` | Binarios verificados |
| `/etc/vpsarg-bhttp.conf` | `BHTTP_PORT`, `BHTTP_INTERNAL_PORT`, `BHTTP_SSH_PORT` |
| `/etc/systemd/system/bhttp-server.service`, `bhttp-shim.service` | Unidades |

**Sin probar con una app real:** en el laboratorio se probó con un cliente propio del protocolo (`tests/bhttp-cliente.py`), no con una app de túnel. `bhttp-shim` no tiene código fuente.

## Diagnóstico

```bash
sudo vpsarg-puertos estado
systemctl status pdirect-80 udpgw-7300 --no-pager
journalctl -u pdirect-80 -n 50 --no-pager
journalctl -u udpgw-7300 -n 50 --no-pager
sudo ss -ltnp '( sport = :80 or sport = :7300 )'
sudo ss -ltnp | grep -E 'sshd|systemd'      # puerto real de SSH
cat /etc/vpsarg-pdirect.conf
```

Prueba local de PDirect-C (debe responder `HTTP/1.1 101` seguido del banner `SSH-2.0-...`):

```bash
printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' | timeout 3 nc 127.0.0.1 80
```

## Solución de problemas

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| El instalador dice que TCP 80 está en uso | nginx, apache u otro programa | Liberá el puerto o desinstalá ese programa; el instalador no lo toca. |
| `NO responde` en el destino SSH | SSH escucha en otro puerto | `sudo ss -ltnp \| grep -E 'sshd\|systemd'` y luego `sudo vpsarg-puertos puerto-ssh PUERTO`. |
| El cliente recibe `403 Forbidden` | `X-Real-Host` con otro puerto | Ajustá el payload al puerto configurado. |
| El cliente recibe `431` | Cabeceras de 16 KB o más | Acortá el payload. |
| El servicio está activo pero no hay acceso desde Internet | Firewall del sistema o del proveedor | Abrí TCP 80 y 7300 en el panel del proveedor y, si usás ufw, `sudo ufw allow 80/tcp` y `sudo ufw allow 7300/tcp`. |
| Un servicio aparece `failed` | Ver el log | `journalctl -u pdirect-80 -n 50` o `journalctl -u udpgw-7300 -n 50`. |

## Desinstalación

Quitá primero BHTTP y HCR (no tocan PDirect-C ni UDPGW; HCR conserva `/opt/hcr`): `sudo vpsarg-bhttp desinstalar` y `sudo vpsarg-hcr desinstalar`.

Las cuentas de usuarios no se borran solas: si querés quitarlas, usá `sudo vpsarg-usuarios eliminar USUARIO` antes. `/etc/vpsarg/` guarda los vencimientos de las cuentas suspendidas.

El resto no toca SSH ni el firewall:

```bash
sudo systemctl disable --now pdirect-80 udpgw-7300
sudo rm -f /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw /usr/local/sbin/vpsarg-puertos \
           /usr/local/sbin/vpsarg-hcr /usr/local/sbin/vpsarg-bhttp /usr/local/sbin/vpsarg /usr/local/sbin/vpsarg-usuarios \
           /etc/vpsarg-pdirect.conf /etc/vpsarg-servicios.conf /etc/vpsarg/instalacion
sudo rmdir /opt/badvpn /usr/local/lib/vpsarg
```

Los paquetes de compilación quedan instalados. Si los quitás, no elimines las bibliotecas `libevent` mientras uses PDirect-C.

## Seguridad y limitaciones

- No ejecutes scripts remotos como root sin revisarlos.
- El instalador no guarda ni muestra contraseñas ni credenciales.
- Los binarios de HCR y BHTTP son de terceros y sin código fuente auditado (salvo `bhttp-server`, cuyo código publicado se revisó); se fijan por sha256.
- BadVPN upstream está archivado y sin mantenimiento activo; evaluá ese riesgo.
- UDPGW se configura con `--max-clients 3 --max-connections-for-client 256`. Si necesitás más clientes, editá `ExecStart` en `/etc/systemd/system/udpgw-7300.service` y ejecutá `sudo systemctl daemon-reload && sudo vpsarg-puertos reiniciar udpgw-7300`.
- PDirect-C cierra la conexión si el cliente o el servidor SSH pasan 60 segundos sin enviar datos (comportamiento del código original). Activá el keepalive en el cliente para sesiones inactivas.
