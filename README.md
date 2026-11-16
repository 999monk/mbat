# mbat

Lectura del nivel de batería del mouse **Aula SC380 Pro** en Linux.

**Estado:** experimental, versión inicial. 

El protocolo se dedujo observando lo que el mouse envía por sí solo. No hay documentación oficial, así que todo lo que figura abajo como "observado" es empírico y puede cambiar.

## Qué hace y qué no hace

**Hace:**

- Escucha los reportes que el mouse manda al receptor 2.4G e imprime el porcentaje de batería.

**No hace:**

- No envía ningún byte al mouse. Los dos scripts solo leen (`os.read` / `dd` sobre el nodo `hidraw`).
- No cambia DPI, iluminación, botones, macros ni perfiles.
- No notifica, no corre en segundo plano y no guarda nada en disco.

## Entorno probado

| Dato | Valor |
|---|---|
| Mouse | Aula SC380 Pro |
| Modo de conexión | Receptor 2.4G |
| USB ID | `258a:0138` (Sinowealth, "Gaming MS") |
| Sistema | CachyOS (Linux 7.3.3), shell fish |
| Dependencias Python | Python 3.10 o superior, solo biblioteca estándar |
| Dependencias bash | `bash`, `grep`, `dd`, `timeout` (coreutils) y `xxd` |

No se probó en modo cable ni en Bluetooth como fuente de lectura. En la única prueba en Bluetooth no llegó ningún reporte por este canal.

## Cómo se obtiene la batería

El receptor aparece en Linux como dos nodos `hidraw`:

- **`input0`**: mouse estándar (movimiento, botones, rueda). No se usa.
- **`input1`**: teclado virtual más un canal propietario del fabricante. **Se usa este.** El mouse emite por acá reportes de entrada con **Report ID 9**.

Formato observado de esos reportes (el primer byte es el Report ID):

| Bytes | Significado | Detalle |
|---|---|---|
| `09 0a 02 XX` | Estado del enlace con el receptor | `XX` = `00` desconectado, `01` conectado. El mouse "desconecta" también cuando entra en modo sleep por inactividad. |
| `09 0a 03 N V` | Cambio de DPI | `N` = etapa (1 a 6), `V` = valor interno. La escala de `V` no está confirmada. |
| `09 0a 05 P F` | Batería | `P` = porcentaje (hipótesis), `F` = flag sin significado conocido (casi siempre `01`, apareció un `02` una sola vez). |

Detalles del reporte de batería:

- El mouse lo envía **solo, cada 48 segundos**. No hay forma conocida de pedirlo a demanda.
- Al reconectarse, primero llega un reporte con `P = 0x64` (100) que **parece un marcador del handshake**, y aproximadamente un segundo después llega el valor real. Los scripts descartan ese primer `100` cuando viene justo después de ver un evento de reconexión.
- Mientras el mouse está cargando, el porcentaje reportado sube de forma aparente (se observó 64% a 71% en 48 s, y volvió a 64% al desenchufar el cargador). Por eso conviene leerlo sin el cargador conectado.

**Qué está confirmado y qué no:** el formato de los reportes de enlace y DPI es consistente en todas las capturas. Que `P` sea el porcentaje real de batería es una **hipótesis**: se comporta como una batería (cambia de forma gradual, se mantiene estable en reposo), pero todavía no se comparó con el valor que muestra el software oficial de Windows.

## Scripts

### `mousectl.py` 

Qué hace, en orden:

1. Busca en `/sys/class/hidraw/hidraw*/device/uevent` el nodo cuyo texto contenga `258A` e `input1`.
2. Abre ese nodo (`/dev/hidrawN`) en solo lectura.
3. Lee reportes de a uno y descarta todo lo que no sea `09 0a ...` (teclado y multimedia del mismo nodo).
4. Imprime una línea por cada evento reconocido, con la hora local:

```
02:14:33 enlace: conectado
02:14:40 DPI etapa 2 (valor 6)
02:15:21 batería: 63% (flag 1)
```

**Modo continuo (por defecto):** sigue escuchando hasta `Ctrl+C`. Si el receptor se desenchufa o no se encuentra, imprime `receptor desconectado, esperando...` y reintenta cada 2 segundos, sin cortarse.

**Modo `--once`:** espera el próximo reporte de batería, lo imprime y termina. Si no llega en 55 segundos, sale con código 1 y el mensaje `sin reporte de batería (¿mouse dormido?)` por stderr. También sale con código 1 si no encuentra el mouse o si el receptor se desconecta durante la espera.

```
sudo python3 mousectl.py          # continuo
sudo python3 mousectl.py --once   # una lectura y sale
```

### `mbat.sh` (bash)

Qué hace, en orden:

1. Busca el nodo `hidraw` cuyo `uevent` tenga `HID_ID` terminado en `258A:00000138` y `HID_PHYS` con `input1`. Es una comprobación más estricta que la del script Python.
2. Verifica que exista y que tenga permiso de lectura. Si no, sale con un mensaje explicando que falta `sudo` o la regla udev.
3. Imprime `Esperando lectura (hasta 55s)...` por **stderr**.
4. Lee reportes de a uno con `dd` y los convierte a hexadecimal con `xxd`.
5. Ignora todo salvo los eventos de enlace (`090a02`, solo para saber si hay que descartar el marcador) y los de batería (`090a05`).
6. Al llegar un reporte de batería válido, imprime **solo el porcentaje por stdout** (por ejemplo `63%`) y termina con código 0.

Si pasan 55 segundos sin lectura, imprime `Sin lectura: ¿mouse dormido? Movelo y probá de nuevo.` por stderr y sale con código 1. El tiempo máximo se cambia con la variable `TIMEOUT`:

```
mbat
TIMEOUT=120 mbat
```

Como el porcentaje sale por stdout y los mensajes por stderr, se puede usar en otros scripts: `pct=$(mbat 2>/dev/null)`.

## Instalación

Para usarlos sin `sudo`, hace falta una regla udev que dé acceso al nodo `hidraw`:

```
echo 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="258a", ATTRS{idProduct}=="0138", TAG+="uaccess"' | sudo tee /etc/udev/rules.d/99-aula.rules
sudo udevadm control --reload
sudo udevadm trigger
```

Después hay que desenchufar y volver a enchufar el receptor.

Para instalar el script bash:

```
sudo install -m755 mbat.sh /usr/local/bin/aula-bat
```

## Limitaciones conocidas

- **Demora de hasta 48 s** en responder, porque se espera el reporte periódico del mouse.
- **Mouse dormido, sin lectura.** Cuando entra en sleep no manda ningún reporte y el receptor lo da por desconectado. Hay que despertarlo (mover o hacer click) y reintentar. En la mayoría de las capturas la lectura llegó 1 o 2 s después de despertarlo, pero dos veces tardó 13 s y 52 s.
- **Valor optimista mientras carga** (ver arriba).
- **Solo receptor 2.4G.** No hay lectura de batería por cable ni por Bluetooth.
- **Valor no verificado contra una fuente externa.** Tomarlo como aproximado.

## Pendiente por verificar

- Prueba de descarga: usar el mouse hasta que se apague solo y anotar con qué porcentaje muere. Dice si el número es optimista o ajustado.
- Significado del byte `F` (flag) del reporte de batería.
- Escala del valor `V` en los reportes de DPI.
- Si hay una consulta a demanda de la batería (requiere capturar el tráfico del software oficial con `usbmon`).
- Comportamiento en modo cable y Bluetooth.
