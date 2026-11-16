#!/usr/bin/env bash

TIMEOUT=${TIMEOUT:-55}   # el mouse reporta cada 48 s

node=
for u in /sys/class/hidraw/hidraw*/device/uevent; do
    [ -r "$u" ] || continue
    if grep -qi 'HID_ID=.*258A:00000138' "$u" && grep -q 'HID_PHYS=.*input1' "$u"; then
        n=${u#/sys/class/hidraw/}
        node=/dev/${n%%/*}
        break
    fi
done

[ -n "$node" ] || { echo "No encontré el receptor del mouse." >&2; exit 1; }
[ -r "$node" ] || { echo "Sin permiso para leer $node (usá sudo o la regla udev)." >&2; exit 1; }

exec 3<"$node"
skip=0
end=$((SECONDS + TIMEOUT))
echo "Esperando lectura (hasta ${TIMEOUT}s)..." >&2

while :; do
    left=$((end - SECONDS))
    if [ "$left" -le 0 ]; then
        echo "Sin lectura: ¿mouse dormido? Movelo y probá de nuevo." >&2
        exit 1
    fi

    hex=$(timeout "$left" dd bs=64 count=1 <&3 2>/dev/null | xxd -p | tr -d '\n')
    [ -n "$hex" ] || { sleep 0.1; continue; }

    case ${hex:0:6} in
        090a02)   # estado del enlace
            if [ "${hex:6:2}" = 01 ]; then skip=1; else skip=0; fi ;;
        090a05)   # batería
            pct=$((16#${hex:6:2}))
            if [ "$skip" = 1 ] && [ "$pct" -eq 100 ]; then
                skip=0          # marcador del handshake tras reconectar
                continue
            fi
            echo "${pct}%"
            exit 0 ;;
    esac
done
