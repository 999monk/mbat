#!/usr/bin/env python3
import glob
import os
import select
import sys
import time

TIMEOUT = 55


def find_node() -> str | None:
    for u in glob.glob("/sys/class/hidraw/hidraw*/device/uevent"):
        try:
            with open(u) as f:
                t = f.read()
        except OSError:
            continue
        if "258A" in t.upper() and "input1" in t:
            return "/dev/" + u.split("/")[4]
    return None


def stamp() -> str:
    return time.strftime("%H:%M:%S")


def listen(fd: int, once: bool) -> bool:
    skip_placeholder = False
    deadline = time.monotonic() + TIMEOUT
    while True:
        left = None
        if once:
            left = deadline - time.monotonic()
            if left <= 0:
                print("sin reporte de batería (¿mouse dormido?)", file=sys.stderr)
                sys.exit(1)
        r, _, _ = select.select([fd], [], [], left)
        if not r:
            continue
        d = os.read(fd, 64)
        if len(d) < 5 or d[0] != 9 or d[1] != 0x0A:
            continue
        if d[2] == 2:
            skip_placeholder = bool(d[3])
            print(stamp(), "enlace:", "conectado" if d[3] else "desconectado")
        elif d[2] == 3:
            print(stamp(), f"DPI etapa {d[3]} (valor {d[4]})")
        elif d[2] == 5:
            if skip_placeholder and d[3] == 0x64:
                skip_placeholder = False
                continue
            skip_placeholder = False
            print(stamp(), f"batería: {d[3]}% (flag {d[4]})")
            if once:
                return True


def main() -> None:
    once = "--once" in sys.argv
    while True:
        node = find_node()
        if node is None:
            if once:
                sys.exit("No encontré el mouse (258a:0138, interfaz input1).")
            time.sleep(2)
            continue
        try:
            fd = os.open(node, os.O_RDONLY)
        except OSError:
            if once:
                sys.exit("No pude abrir el dispositivo.")
            time.sleep(2)
            continue
        try:
            if listen(fd, once):
                return
        except OSError:
            if once:
                sys.exit("El receptor se desconectó.")
            print(stamp(), "receptor desconectado, esperando...")
            time.sleep(2)
        finally:
            os.close(fd)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
