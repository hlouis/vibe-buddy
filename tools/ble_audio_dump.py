#!/usr/bin/env python3
"""
Vibe Buddy step-4 audio verification helper.

Scans for VibeBuddy-XXXX, subscribes to the NUS TX characteristic, parses
the binary audio framing (0xFF 0xAA + seq + len + PCM), and dumps the PCM
to out.pcm. Replays on the fly if ffplay is available.

Usage:
  pip install bleak
  python3 tools/ble_audio_dump.py

While it runs, hold BtnA on the device to record. Release to finish. The
script keeps running so you can record multiple sessions; each one
overwrites out.pcm.
"""
import argparse
import asyncio
import struct
import sys
from pathlib import Path

try:
    from bleak import BleakScanner, BleakClient
except ImportError:
    sys.stderr.write("Missing dependency: pip install bleak\n")
    sys.exit(1)

NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
MAGIC = b"\xff\xaa"


class FrameReader:
    def __init__(self, out_path: Path):
        self.out_path = out_path
        self.file = None
        self.expected_seq = 0
        self.dropped_frames = 0
        self.json_buf = b""
        self.last_sample_rate = 16000
        self.start_ts = None
        self.total_bytes = 0

    def on_notify(self, _sender, data: bytearray) -> None:
        data = bytes(data)
        # A single notify is either a full audio frame (starts with FF AA)
        # or ASCII JSON — we never mix them, the firmware ensures that.
        if len(data) >= 2 and data[:2] == MAGIC:
            self._handle_audio(data)
        else:
            self.json_buf += data
            while b"\n" in self.json_buf:
                line, self.json_buf = self.json_buf.split(b"\n", 1)
                self._handle_json(line.decode("utf-8", errors="replace"))

    def _handle_json(self, line: str) -> None:
        line = line.strip()
        if not line:
            return
        print(f"[json] {line}")
        if '"audio"' not in line:
            return
        if '"start"' in line:
            if self.file:
                self.file.close()
            self.file = self.out_path.open("wb")
            self.expected_seq = 0
            self.dropped_frames = 0
            self.total_bytes = 0
            # Extract sample_rate (cheap parse, no json module needed).
            if '"sample_rate"' in line:
                import re
                m = re.search(r'"sample_rate"\s*:\s*(\d+)', line)
                if m:
                    self.last_sample_rate = int(m.group(1))
            print(f"[rec] started at {self.last_sample_rate} Hz -> {self.out_path}")
        elif '"stop"' in line:
            if self.file:
                self.file.close()
                self.file = None
            dur_ms = self.total_bytes / (self.last_sample_rate * 2 / 1000) if self.last_sample_rate else 0
            print(f"[rec] stopped: bytes={self.total_bytes} "
                  f"dur={dur_ms:.0f}ms gaps={self.dropped_frames}")
            print(f"[play] ffplay -autoexit -f s16le -ar {self.last_sample_rate} "
                  f"-ac 1 {self.out_path}")

    def _handle_audio(self, data: bytes) -> None:
        if len(data) < 6:
            print(f"[err] short audio frame: {len(data)} bytes")
            return
        seq, length = struct.unpack("<HH", data[2:6])
        pcm = data[6:6 + length]
        if len(pcm) != length:
            print(f"[err] frame len mismatch: header says {length}, got {len(pcm)}")
            return

        if self.file is None:
            # No start seen yet — dropped heartbeat probably; ignore.
            return

        if seq != self.expected_seq:
            gap = (seq - self.expected_seq) & 0xFFFF
            if gap and gap < 1000:
                # Pad with silence sized like this frame so we keep audio aligned.
                self.file.write(b"\x00\x00" * (length // 2) * gap)
                self.dropped_frames += gap
                self.total_bytes += length * gap
                print(f"[gap] expected seq={self.expected_seq} got={seq} (+{gap})")
        self.file.write(pcm)
        self.total_bytes += length
        self.expected_seq = (seq + 1) & 0xFFFF


async def find_device(name_prefix: str):
    print(f"scanning for '{name_prefix}*'...")
    for attempt in range(10):
        devices = await BleakScanner.discover(timeout=3.0)
        for d in devices:
            if d.name and d.name.startswith(name_prefix):
                print(f"found {d.name} @ {d.address}")
                return d
        print(f"  (attempt {attempt + 1}) nothing yet, retrying")
    raise RuntimeError(f"no device starting with '{name_prefix}' found")


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", default="VibeBuddy-")
    ap.add_argument("--out", default="out.pcm")
    args = ap.parse_args()

    device = await find_device(args.prefix)
    reader = FrameReader(Path(args.out))

    async with BleakClient(device) as client:
        print(f"connected to {device.name}")
        await client.start_notify(NUS_TX, reader.on_notify)
        print("subscribed to TX. Hold device BtnA to record, Ctrl-C to exit.")
        try:
            while True:
                await asyncio.sleep(1)
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass
        finally:
            if reader.file:
                reader.file.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
