#!/usr/bin/env bash

set -u

TIMEOUT=${TIMEOUT:-55}
WATCH=0

usage() {
    cat >&2 <<'EOF'
Uso: mbat [opciones]

  (sin opciones)   espera un reporte y escribe solo el porcentaje
  --watch          sigue escuchando y muestra eventos con hora
  --timeout N      segundos máximos de espera (por defecto: 55)
  --once           igual que sin opciones
  -h, --help       muestra esta ayuda
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --watch) WATCH=1 ;;
        --once) ;;
        --timeout)
            [ $# -ge 2 ] || { usage; exit 2; }
            TIMEOUT=$2
            shift
            ;;
        --timeout=*) TIMEOUT=${1#*=} ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

case "$TIMEOUT" in
    ''|*[!0-9]*) echo "TIMEOUT inválido: $TIMEOUT" >&2; exit 2 ;;
esac
TIMEOUT=$((10#$TIMEOUT))
[ "$TIMEOUT" -gt 0 ] || { echo "TIMEOUT inválido: $TIMEOUT" >&2; exit 2; }

for cmd in dd grep timeout tr xxd date; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Falta el comando: $cmd" >&2
        exit 1
    }
done

find_node() {
    local u n
    for u in /sys/class/hidraw/hidraw*/device/uevent; do
        [ -r "$u" ] || continue
        if grep -qi 'HID_ID=.*258A:00000138' "$u" &&
           grep -q 'HID_PHYS=.*input1' "$u"; then
            n=${u#/sys/class/hidraw/}
            printf '/dev/%s\n' "${n%%/*}"
            return 0
        fi
    done
    return 1
}

stamp() {
    date +%H:%M:%S
}

read_report() {
    local secs=$1
    timeout "$secs" dd if="$NODE" bs=64 count=1 2>/dev/null | xxd -p | tr -d '\n'
}

# Devuelve 0 solo cuando el modo one-shot ya imprimió la batería.
handle_report() {
    local hex=$1 pct flag

    case ${hex:0:6} in
        090a02)
            [ ${#hex} -ge 8 ] || return 1
            flag=$((16#${hex:6:2}))
            if [ "$flag" -eq 1 ]; then
                skip=1
                link_ts=$SECONDS
                [ "$WATCH" -eq 1 ] && echo "$(stamp) enlace: conectado"
            else
                skip=0
                [ "$WATCH" -eq 1 ] && echo "$(stamp) enlace: desconectado"
            fi
            ;;
        090a03)
            [ ${#hex} -ge 10 ] || return 1
            if [ "$WATCH" -eq 1 ]; then
                echo "$(stamp) DPI etapa $((16#${hex:6:2})) (valor $((16#${hex:8:2})))"
            fi
            ;;
        090a05)
            [ ${#hex} -ge 10 ] || return 1
            pct=$((16#${hex:6:2}))
            flag=$((16#${hex:8:2}))
            if [ "$skip" -eq 1 ] && [ "$pct" -eq 100 ] &&
               [ $((SECONDS - link_ts)) -le 3 ]; then
                skip=0
                return 1
            fi
            skip=0
            if [ "$WATCH" -eq 1 ]; then
                echo "$(stamp) batería: ${pct}% (flag ${flag})"
            else
                echo "${pct}%"
                return 0
            fi
            ;;
    esac
    return 1
}

run_once() {
    local deadline left hex
    NODE=$(find_node) || {
        echo "No encontré el mouse (258a:0138, input1)." >&2
        return 1
    }
    [ -r "$NODE" ] || {
        echo "Sin permiso para leer $NODE. Aplicá la regla udev o usá sudo." >&2
        return 1
    }

    skip=0
    link_ts=-100
    deadline=$((SECONDS + TIMEOUT))
    echo "Esperando lectura (hasta ${TIMEOUT}s)..." >&2

    while :; do
        left=$((deadline - SECONDS))
        if [ "$left" -le 0 ]; then
            echo "Sin lectura: ¿mouse dormido? Movelo y probá de nuevo." >&2
            return 1
        fi

        hex=$(read_report "$left")
        if [ -z "$hex" ]; then
            if [ ! -e "$NODE" ]; then
                echo "El receptor se desconectó." >&2
                return 1
            fi
            continue
        fi

        if handle_report "$hex"; then
            return 0
        fi
    done
}

run_watch() {
    local hex
    while :; do
        NODE=$(find_node) || {
            echo "$(stamp) receptor no encontrado, esperando..." >&2
            sleep 2
            continue
        }
        if [ ! -r "$NODE" ]; then
            echo "$(stamp) sin permiso para leer $NODE, esperando..." >&2
            sleep 2
            continue
        fi

        echo "$(stamp) escuchando $NODE (Ctrl+C para salir)" >&2
        skip=0
        link_ts=-100

        while :; do
            hex=$(read_report 5)
            if [ -z "$hex" ]; then
                if [ ! -e "$NODE" ]; then
                    echo "$(stamp) receptor desconectado, esperando..." >&2
                    break
                fi
                continue
            fi
            handle_report "$hex"
        done

        sleep 1
    done
}

if [ "$WATCH" -eq 1 ]; then
    run_watch
else
    run_once
fi
