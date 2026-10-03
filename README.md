# VPS ARG QuickStart

Instalador para Ubuntu que compila e instala dos servicios ligeros, cada uno con su propia unidad systemd y arranque automático:

| Servicio | Unidad systemd | Escucha | Destino |
|---|---|---|---|
| PDirect-C | `pdirect-80.service` | `0.0.0.0:80/TCP` | SSH local `127.0.0.1:PUERTO_SSH` (22 por defecto) |
| BadVPN UDPGW | `udpgw-7300.service` | `0.0.0.0:7300/TCP` | — |
| HCR (opcional, se instala aparte) | `hcr-8880.service` | `:8880/TCP` (configurable) | SSH local `127.0.0.1:PUERTO_SSH` |

Incluye el controlador `vpsarg-puertos` para consultar estado, iniciar, detener, reiniciar, habilitar, deshabilitar y cambiar el puerto SSH de destino, `vpsarg-hcr` para instalar y administrar HCR (ver [HCR](#hcr-opcional)), y el panel `vpsarg` (ver [Panel](#panel)).

No instala panel web ni base de datos. **No modifica `sshd_config`, no reinicia SSH y no toca el firewall.**

## Requisitos

- Un **token de instalación** válido (ver [Token de instalación](#token-de-instalación)).
- Ubuntu 20.04, 22.04 o 24.04 con systemd (en otra versión el instalador avisa y pide confirmación).
- Acceso root (`sudo`) y conexión a Internet.
- Puertos TCP 80 y 7300 libres. Si otro programa los usa (por ejemplo nginx o apache en el 80), el instalador se detiene sin hacer cambios.
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

El instalador:

1. Comprueba root, Ubuntu y systemd, y pide el token de instalación (o lo toma de `VPSARG_TOKEN`). Si falta o no es válido, se detiene **sin cambiar nada**. Después comprueba que TCP 80 y 7300 estén libres.
2. Si detecta una instalación previa, la lista y solo continúa si escribís `SI`.
3. Pregunta el puerto SSH local (Enter = 22, o el valor de una instalación previa) y comprueba que haya algo escuchando en `127.0.0.1:PUERTO`. Si no lo hay, avisa y pide confirmación.
4. Instala dependencias: `ca-certificates curl git cmake make gcc libc6-dev libevent-dev`.
5. Descarga `pdirect.c`, `vpsarg-puertos.sh`, `vpsarg-hcr.sh`, `vpsarg-panel.sh` y `vpsarg-usuarios.sh` de la rama `main` (el verificador `vpsarg-token.sh` ya se descargó en el paso 1) y compila PDirect-C:
   `gcc -O2 -Wall -Wextra -D_FORTIFY_SOURCE=2 -fstack-protector-strong -o pdirect-c pdirect.c -levent_core`
6. Clona BadVPN (`github.com/ambrop72/badvpn`) y compila solo UDPGW con CMake.
7. Instala los archivos, crea las unidades systemd, las habilita y comprueba que ambos servicios estén activos y escuchando.
8. Si el token incluye HCR, instala HCR (ver [HCR](#hcr-opcional)). Registra el id del token como usado.

Si cualquier paso crítico falla, se detiene con un mensaje de error. Hasta el paso 7 no se instala ni se reemplaza ningún archivo del sistema (salvo los paquetes de apt).

### Archivos instalados

| Ruta | Contenido |
|---|---|
| `/usr/local/bin/pdirect-c` | PDirect-C compilado |
| `/opt/badvpn/badvpn-udpgw` | BadVPN UDPGW compilado |
| `/usr/local/sbin/vpsarg-puertos` | Controlador |
| `/usr/local/sbin/vpsarg-hcr` | Controlador de HCR (no instala HCR por sí solo) |
| `/usr/local/sbin/vpsarg` | Panel de administración |
| `/usr/local/sbin/vpsarg-usuarios` | Cuentas SSH de los usuarios |
| `/usr/local/lib/vpsarg/token.sh` | Verificador del token (lo usa `vpsarg-hcr instalar`) |
| `/etc/vpsarg/tokens-usados` | Ids de los tokens usados en esta VPS (nunca el token) |
| `/etc/vpsarg-pdirect.conf` | `SSH_PORT=22` — única fuente del puerto SSH de destino |
| `/etc/vpsarg-servicios.conf` | Servicios que maneja el controlador |
| `/etc/systemd/system/pdirect-80.service` | Unidad de PDirect-C |
| `/etc/systemd/system/udpgw-7300.service` | Unidad de UDPGW |

Ambos servicios corren con un usuario temporal sin privilegios (`DynamicUser=yes`). PDirect-C solo recibe la capacidad `CAP_NET_BIND_SERVICE` para abrir el puerto 80.

## Token de instalación

El token **solo autoriza instalar**. No interviene en el login de los usuarios (siguen entrando con usuario y contraseña SSH) ni en PDirect-C, UDPGW o HCR una vez instalados: si vence, la VPS sigue funcionando igual.

- Formato: `vpsarg1.DATOS.FIRMA`. Los datos son `id`, `vence` (AAAA-MM-DD, vale hasta ese día inclusive, UTC), `alcance` (`base` o `base,hcr`) y una `nota` opcional, firmados con ECDSA P-256 por quien emite los tokens.
- Se escribe cuando el instalador lo pide (sin eco) o con `VPSARG_TOKEN`. Nunca como argumento.
- `install.sh` lo verifica **antes de cualquier cambio**: firma, datos, vencimiento, alcance y que no se haya usado en esta VPS. Sin `openssl` también se detiene sin cambios.
- Con alcance `base,hcr`, el instalador exige `/opt/hcr/hcr-server` y comprueba HCR (`vpsarg-hcr verificar`) antes de cambiar nada, y lo instala en la misma corrida.
- Un token usado queda en `/etc/vpsarg/tokens-usados` y no sirve otra vez en esta VPS. Instalar HCR después exige un token **nuevo** con alcance `base,hcr`.

**Limitaciones:** el repositorio es público, así que el control se puede quitar copiando el código. El registro de tokens usados es local: el mismo token sirve en otra VPS hasta que vence (conviene emitirlos con vencimientos cortos), y root puede borrar el registro.

**Emisión** (en tu computadora, nunca en una VPS): `herramientas/emitir-token.sh clave CARPETA` crea la clave privada y muestra la pública, que va en `VPSARG_TOKEN_PUBKEY` de `vpsarg-token.sh`. Después: `herramientas/emitir-token.sh emitir CLAVE_PRIVADA ID VENCE ALCANCE [NOTA]`. La clave privada no se sube al repositorio ni se copia a ninguna VPS.

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
sudo vpsarg protocolos   # estado, puerto y PID de PDirect-C, UDPGW, HCR y SSH
sudo vpsarg sistema      # CPU, RAM, swap, disco, uptime, protocolos y usuarios conectados
sudo vpsarg puertos      # puerto de sshd, destino de PDirect-C y HCR, puertos en escucha
sudo vpsarg conexiones   # conexiones TCP establecidas por puerto
sudo vpsarg recursos     # RAM, CPU, hilos y descriptores por servicio, RAM y disco del servidor
sudo vpsarg ssh          # si sshd acepta contraseñas (solo lectura)
sudo vpsarg usuarios     # cuentas SSH de los usuarios
sudo vpsarg auto on|off  # AUTO: abrir el panel al iniciar sesión con esta cuenta
```

El menú tiene cuatro secciones:
- **Protocolos**: PDirect-C, UDPGW, HCR y SSH con estado, puerto y PID. Cada ficha permite iniciar, detener, reiniciar, habilitar o deshabilitar, y ver el registro y los errores recientes. HCR se instala y desinstala desde su ficha. **SSH es solo de lectura.**
- **Usuarios**: cuentas SSH (ver [Usuarios SSH](#usuarios-ssh)).
- **Estado**: CPU, carga, RAM, swap, disco, uptime, temperatura (si existe), protocolos y usuarios conectados. También muestra las conexiones TCP por servicio y los recursos de cada servicio.
- **Configuración**: puerto SSH de destino, puerto de HCR, autenticación de SSH, registro del panel, copias y AUTO.

**AUTO** (Configuración → Auto inicio o `sudo vpsarg auto on`): abre el panel al iniciar sesión en una terminal con la cuenta que lo activó. La lista de cuentas queda en `/etc/vpsarg-auto.conf` y el disparador en `/etc/profile.d/vpsarg-auto.sh`, que solo existe mientras haya alguna cuenta con AUTO. No se activa en `ssh host comando`, scp, sftp ni túneles, ni para las cuentas de `vpsarg-usuarios`. Con 0 o Ctrl+C se vuelve a la consola.

- Es un script: no queda ningún proceso corriendo después de salir.
- Todas las acciones usan `vpsarg-puertos`, `vpsarg-hcr` y `vpsarg-usuarios`; las que cambian algo piden confirmación y quedan registradas (`journalctl -t vpsarg-panel`).
- No modifica `/etc/ssh/sshd_config`, el puerto de sshd, el firewall, el puerto 80 ni los argumentos de PDirect-C, ni la configuración o los límites de UDPGW.
- Los números de conexiones son **conexiones TCP**, no usuarios. Todo lo que entra por PDirect-C o HCR llega a SSH desde 127.0.0.1.
- "Guardar copia de la configuración" copia `/etc/vpsarg-*.conf` y las unidades a `/var/backups/vpsarg/FECHA-panel/`.

## Usuarios SSH

Los usuarios finales son cuentas Linux normales y entran con **usuario y contraseña SSH**. No hay tokens, HWID ni otra autenticación.

```bash
sudo vpsarg-usuarios listar
sudo vpsarg-usuarios ver USUARIO
sudo vpsarg-usuarios crear USUARIO        # pide la contraseña dos veces, sin mostrarla
sudo vpsarg-usuarios suspender USUARIO
sudo vpsarg-usuarios reactivar USUARIO
sudo vpsarg-usuarios eliminar USUARIO
```

| Acción | Qué hace |
|---|---|
| Crear | `useradd -m -k /dev/null -s /usr/sbin/nologin -G vpsarg-usuarios USUARIO` y la contraseña por la entrada estándar de `chpasswd`. Sin shell: sirve para túneles (`ssh -N`), no para entrar a una consola |
| Suspender | Guarda el vencimiento actual en `/etc/vpsarg/usuarios-suspendidos` (0600), aplica `chage -E 0` y cierra las sesiones SSH abiertas con SIGTERM. La contraseña no se toca |
| Reactivar | Restaura el vencimiento guardado con `chage -E` (o sin vencimiento si no había) y borra la línea guardada |
| Eliminar | Cierra las sesiones con SIGTERM y ejecuta `userdel -r` |
| Listar / ver | Estado (ACTIVO, SUSPENDIDO, VENCIDO, CONTRASEÑA BLOQUEADA), sesiones SSH abiertas y vencimiento. Nunca muestra contraseñas |

- Solo administra cuentas del grupo `vpsarg-usuarios` con UID 1000 o mayor. No toca `root` ni otras cuentas del servidor.
- Nombres: minúsculas, números, `_` o `-`, empiezan con letra o `_`, hasta 31 caracteres. Contraseñas: 6 a 128 caracteres, sin `:`.
- No usa `usermod -L`: no impide entrar con clave pública. No modifica `/etc/ssh/sshd_config` ni `/etc/shells`.
- Si sshd tiene `PasswordAuthentication no`, `crear` y el panel lo avisan, pero no lo cambian.
- Cada operación queda en `journalctl -t vpsarg-panel` con el resultado; nunca la contraseña.

## Puerto SSH de destino

PDirect-C siempre escucha en TCP 80 y reenvía a `127.0.0.1:PUERTO_SSH`. HCR, si está instalado, reenvía al mismo puerto. Para ver o cambiar ese puerto:

```bash
sudo vpsarg-puertos puerto-ssh          # muestra el puerto actual
sudo vpsarg-puertos puerto-ssh 2222     # cambia el destino a 127.0.0.1:2222
```

El cambio:

- Valida el número (1-65535) y comprueba que en `127.0.0.1:PUERTO` responda un servidor SSH; si no, avisa y pide confirmación.
- Escribe `SSH_PORT=PUERTO` en `/etc/vpsarg-pdirect.conf`, reinicia solo `pdirect-80` y comprueba que el proceso use el puerto nuevo y que una conexión por TCP 80 llegue a SSH.
- Si HCR está instalado, actualiza `HCR_SSH_PORT` en `/etc/vpsarg-hcr.conf` y reinicia solo `hcr-8880`.
- Si algo falla, restaura el valor anterior en PDirect-C y en HCR, y verifica que PDirect-C quedó activo, escuchando en TCP 80, apuntando al puerto anterior y llegando a SSH.
- No modifica sshd, el puerto 80, UDPGW ni el firewall.

**Importante:** este comando no cambia el puerto en el que escucha SSH. Si cambiás el puerto de sshd por tu cuenta, después ejecutá `puerto-ssh` con el puerto nuevo.

PDirect-C acepta la cabecera `X-Real-Host` solo si vale `127.0.0.1:PUERTO_SSH` o `localhost:PUERTO_SSH` (con el puerto configurado); si la cabecera no está, permite la conexión. Si tu payload incluye `X-Real-Host`, tiene que usar el mismo puerto.

## HCR (opcional)

HCR se instala aparte, como servicio independiente `hcr-8880.service`, a partir del binario `hcr-server` entregado por el proveedor (Go, x86_64, sin código fuente). El binario **no** está en este repositorio.

```bash
sudo mkdir -p /opt/hcr
# Copiá hcr-server por SFTP a /opt/hcr/ y después:
sudo chown root:root /opt/hcr/hcr-server && sudo chmod 755 /opt/hcr/hcr-server
sudo vpsarg-hcr verificar         # comprueba sin cambiar nada (no pide token)
sudo vpsarg-hcr instalar          # pide un token nuevo con alcance base,hcr; puerto 8880, transporte plain, destino = puerto SSH de PDirect-C
sudo vpsarg-hcr estado
sudo vpsarg-hcr iniciar | detener | reiniciar
sudo vpsarg-hcr puerto 8080       # cambiar el puerto (1024-65535, libre); sin número lo muestra
sudo vpsarg-hcr desinstalar
```

`instalar` exige un token válido con HCR y no usado en esta VPS, y comprueba x86_64, el sha256 del binario entregado (`68a66ed4…fa085`; otra versión requiere `--sha256 HASH`), que responda a `-version`, el espacio libre y que el puerto esté libre. **No detiene ningún programa** para liberar un puerto. Repetirlo (con otro token) no duplica nada y conserva `/etc/vpsarg-hcr.conf`. `estado`, `puerto`, `destino-ssh`, `iniciar`, `detener`, `reiniciar` y `desinstalar` no piden token. No usa ni modifica el `install.sh` del proveedor ni su `hcr-server.service`.

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

Si instalaste HCR, quitalo primero (no toca PDirect-C ni UDPGW y conserva `/opt/hcr`): `sudo vpsarg-hcr desinstalar`.

Las cuentas de usuarios no se borran solas: si querés quitarlas, usá `sudo vpsarg-usuarios eliminar USUARIO` antes. `/etc/vpsarg/` guarda los vencimientos de las cuentas suspendidas.

El resto no toca SSH ni el firewall:

```bash
sudo systemctl disable --now pdirect-80 udpgw-7300
sudo rm -f /etc/systemd/system/pdirect-80.service /etc/systemd/system/udpgw-7300.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/pdirect-c /opt/badvpn/badvpn-udpgw /usr/local/sbin/vpsarg-puertos \
           /usr/local/sbin/vpsarg-hcr /usr/local/sbin/vpsarg /usr/local/sbin/vpsarg-usuarios /etc/vpsarg-pdirect.conf /etc/vpsarg-servicios.conf \
           /usr/local/lib/vpsarg/token.sh
sudo rmdir /opt/badvpn /usr/local/lib/vpsarg
```

Los paquetes de compilación quedan instalados. Si los quitás, no elimines las bibliotecas `libevent` mientras uses PDirect-C.

## Seguridad y limitaciones

- No ejecutes scripts remotos como root sin revisarlos.
- El instalador no guarda ni muestra contraseñas ni credenciales.
- BadVPN upstream está archivado y sin mantenimiento activo; evaluá ese riesgo.
- UDPGW se configura con `--max-clients 3 --max-connections-for-client 256`. Si necesitás más clientes, editá `ExecStart` en `/etc/systemd/system/udpgw-7300.service` y ejecutá `sudo systemctl daemon-reload && sudo vpsarg-puertos reiniciar udpgw-7300`.
- PDirect-C cierra la conexión si el cliente o el servidor SSH pasan 60 segundos sin enviar datos (comportamiento del código original). Activá el keepalive en el cliente para sesiones inactivas.
