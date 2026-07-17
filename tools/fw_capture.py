#!/usr/bin/env python3
"""
Non-interactive firmware serial capture.

`make fw-monitor` (pio device monitor) needs a TTY and dies with a
Console() traceback when backgrounded or piped — which makes it useless
for the one thing you actually want during hardware debugging: leaving a
capture running while you press buttons, then reading it afterwards.

This writes the serial stream to a file, line-buffered, until killed.

Usage:
  make fw-capture                       # -> /tmp/vibebuddy-serial.txt
  python3 tools/fw_capture.py --out x.txt --seconds 30
  python3 tools/fw_capture.py --reset   # reset the chip first, to catch boot

Reading it back (the noise floor is ~2 lines/sec of [pwr]/[tick]):
  grep -vE '^\\[pwr\\]|^\\[tick\\]' /tmp/vibebuddy-serial.txt | tail -40

Needs pyserial. The system python3 usually lacks it; PlatformIO's has it:
  /opt/homebrew/opt/platformio/libexec/bin/python tools/fw_capture.py
The Makefile target resolves this for you.
"""
import argparse
import glob
import sys
import time

try:
    import serial
except ImportError:
    sys.exit(
        "Missing pyserial.\n"
        "Try PlatformIO's interpreter, which bundles it:\n"
        "  /opt/homebrew/opt/platformio/libexec/bin/python tools/fw_capture.py\n"
        "or: pip install pyserial"
    )


def find_port() -> str:
    # ESP32-S3 native USB CDC shows up as usbmodem*; the StickS3 has no
    # separate UART bridge, so there's normally exactly one candidate.
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        sys.exit("no /dev/cu.usbmodem* found — is the StickS3 plugged in?")
    if len(ports) > 1:
        print(f"[warn] multiple ports {ports}, using {ports[0]}", file=sys.stderr)
    return ports[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--out", default="/tmp/vibebuddy-serial.txt")
    ap.add_argument("--seconds", type=float, default=0,
                    help="stop after N seconds (default: run until killed)")
    ap.add_argument("--reset", action="store_true",
                    help="pulse DTR/RTS to reset the chip first — the only way "
                         "to catch [boot] lines and post-crash backtraces")
    ap.add_argument("--echo", action="store_true",
                    help="also print to stdout")
    args = ap.parse_args()

    port = args.port or find_port()
    p = serial.Serial(port, 115200, timeout=0.2)

    if args.reset:
        # ESP32-S3 USB CDC: RTS drives EN. DTR must stay deasserted or the
        # chip enters the ROM bootloader instead of running our firmware.
        p.setDTR(False)
        p.setRTS(True)
        time.sleep(0.15)
        p.setRTS(False)
        time.sleep(0.05)
    p.reset_input_buffer()

    deadline = time.time() + args.seconds if args.seconds else None
    print(f"[capture] {port} -> {args.out}"
          f"{' (reset)' if args.reset else ''}"
          f"{f' for {args.seconds}s' if args.seconds else ' until killed'}",
          file=sys.stderr)

    n = 0
    with open(args.out, "w") as f:
        try:
            while deadline is None or time.time() < deadline:
                ln = p.readline()
                if not ln:
                    continue
                s = ln.decode("utf-8", "replace")
                f.write(s)
                f.flush()          # so another shell can tail it live
                if args.echo:
                    sys.stdout.write(s)
                    sys.stdout.flush()
                n += 1
        except KeyboardInterrupt:
            pass
        finally:
            p.close()
    print(f"[capture] {n} lines -> {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
