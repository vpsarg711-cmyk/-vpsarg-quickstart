# VPS ARG QuickStart

Instalador inicial para Ubuntu que compila e instala **BadVPN UDPGW** y agrega un controlador sencillo para administrar su servicio systemd.

## Alcance de esta versión

- Instala BadVPN UDPGW y crea `udpgw-7300.service`.
- Configura el controlador `vpsarg-puertos`.
- El servicio escucha en **TCP/7300**.
- No modifica SSH, el firewall, usuarios de Servex ni otros servicios.
- Si encuentra ciertos archivos o una unidad del mismo nombre, cancela antes de realizar cambios para evitar sobrescribirlos.
- No instala PDirect-C, HCR, VT Proxy ni BHTTP.

El instalador requiere acceso root y conexión a Internet. Descarga el código fuente de BadVPN desde su repositorio upstream y lo compila en la VPS. Revisá el código y las licencias de los componentes antes de utilizarlo.

## Instalación

Revisá el contenido de `install.sh` antes de ejecutarlo. Desde una VPS Ubuntu nueva, ejecutá:

```bash
curl -fsSL https://raw.githubusercontent.com/vpsarg711-cmyk/-vpsarg-quickstart/main/install.sh -o /tmp/vpsarg-install.sh
sudo bash /tmp/vpsarg-install.sh
```

El instalador no debe ejecutarse en una VPS que ya tenga configurado `udpgw-7300.service`, `/opt/badvpn/badvpn-udpgw`, `/etc/vpsarg-servicios.conf` o `/usr/local/sbin/vpsarg-puertos`: en esos casos se cancela para evitar sobrescribirlos.

## Comandos del controlador

```bash
sudo vpsarg-puertos estado
sudo vpsarg-puertos iniciar
sudo vpsarg-puertos detener
sudo vpsarg-puertos reiniciar
sudo vpsarg-puertos habilitar
sudo vpsarg-puertos deshabilitar
```

- `estado`: muestra el estado del servicio y los puertos en escucha.
- `iniciar`: inicia el servicio.
- `detener`: detiene el servicio.
- `reiniciar`: reinicia el servicio.
- `habilitar`: habilita el inicio automático y lo inicia ahora.
- `deshabilitar`: lo detiene y desactiva el inicio automático.

La lista de unidades administradas está en `/etc/vpsarg-servicios.conf`, con una unidad por línea. Solo agregá servicios que realmente estén instalados y cuya administración quieras delegar al controlador.

## Seguridad y limitaciones

- No ejecutes scripts remotos como root sin revisar su contenido.
- El instalador instala paquetes del sistema y crea una unidad systemd.
- No abre puertos en el firewall del sistema ni en el panel del proveedor.
- Un servicio activo no garantiza que sea accesible desde Internet; revisá escucha, firewall y reglas del proveedor.
- Si el instalador se interrumpe a mitad del proceso, revisá los archivos y servicios antes de volver a ejecutarlo.
- BadVPN upstream puede estar archivado o sin mantenimiento activo; evaluá ese riesgo antes de usarlo en producción.
