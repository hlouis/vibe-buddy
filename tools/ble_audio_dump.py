#!/usr/bin/env python3
"""
Vibe Buddy audio verification helper.

Scans for VibeBuddy-XXXX, subscribes to the NUS TX characteristic, parses
the binary audio framing (0xFF 0xAA + seq + len + payload), and dumps the
audio to a file. Bypasses the app and ASR entirely — if this works, the
link works.

The firmware announces its codec in the audio/start JSON:
  • codec=opus (current): payloads are Opus packets. We mux them into an
    Ogg stream, so the dump is a playable .ogg.
  • no codec key (pre-Opus firmware): payloads are raw PCM -> .pcm.
The output extension follows the codec unless --out is given explicitly.

Usage:
  pip install bleak
  python3 tools/ble_audio_dump.py

While it runs, hold BtnA on the device to record. Release to finish. The
script keeps running so you can record multiple sessions; each one
overwrites the output file.
"""
import argparse
import asyncio
import re
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

# Opus frame size the firmware encodes at (OPUS_FRAME_SAMPLES in
# recorder.cpp). Needed to advance Ogg granule positions correctly.
OPUS_FRAME_SAMPLES = 960


def _ogg_crc_table():
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) if (r & 0x80000000) else (r << 1)
        table.append(r & 0xFFFFFFFF)
    return table


_OGG_CRC = _ogg_crc_table()


def ogg_crc(data: bytes) -> int:
    # Ogg's CRC-32 is NOT zlib's: poly 0x04C11DB7, no reflection, zero
    # init, no final xor. Mirrors OggCRC in shared/.../OggOpusMuxer.swift.
    crc = 0
    for b in data:
        crc = ((crc << 8) ^ _OGG_CRC[((crc >> 24) & 0xFF) ^ b]) & 0xFFFFFFFF
    return crc


class OggOpusMuxer:
    """Minimal RFC 7845 muxer, one packet per page.

    Deliberately a port of shared/Sources/VibeBuddyCore/OggOpusMuxer.swift
    rather than a second design — if the two disagree, this tool would
    "prove" a bug the app doesn't have, or hide one it does.
    """

    def __init__(self, sample_rate: int, channels: int = 1,
                 samples_per_packet: int = OPUS_FRAME_SAMPLES):
        self.sample_rate = sample_rate
        self.channels = channels
        self.samples_per_packet = samples_per_packet
        self.serial = 0x56425544  # "VBUD"
        self.sequence = 0
        self.granule = 0
        self.wrote_headers = False

    def append(self, packet: bytes, is_last: bool = False) -> bytes:
        out = b""
        if not self.wrote_headers:
            out += self._header_pages()
        # Granule is always in 48 kHz units regardless of input rate.
        self.granule += self.samples_per_packet * 48000 // self.sample_rate
        out += self._page(packet, self.granule, 0x04 if is_last else 0x00)
        return out

    def finish(self) -> bytes:
        out = b""
        if not self.wrote_headers:
            out += self._header_pages()
        return out + self._page(b"", self.granule, 0x04)

    def _header_pages(self) -> bytes:
        head = (b"OpusHead" + bytes([1, self.channels])
                + struct.pack("<H", 312)              # pre-skip @48k
                + struct.pack("<I", self.sample_rate)  # original input rate
                + struct.pack("<H", 0) + bytes([0]))
        vendor = b"VibeBuddy"
        tags = (b"OpusTags" + struct.pack("<I", len(vendor)) + vendor
                + struct.pack("<I", 0))
        self.wrote_headers = True
        return self._page(head, 0, 0x02) + self._page(tags, 0, 0x00)

    def _page(self, payload: bytes, granule: int, header_type: int) -> bytes:
        # Lacing: floor(L/255) x 255, then L%255. The terminating short
        # segment is mandatory even when it's zero. An EMPTY payload is
        # the exception: zero segments (no packet), not one segment of
        # length zero — the latter declares a zero-byte packet, which
        # Opus has no concept of and ffmpeg rejects outright.
        segs = ([255] * (len(payload) // 255) + [len(payload) % 255]) if payload else []
        page = (b"OggS" + bytes([0, header_type])
                + struct.pack("<Q", granule)
                + struct.pack("<I", self.serial)
                + struct.pack("<I", self.sequence)
                + struct.pack("<I", 0)               # CRC placeholder
                + bytes([len(segs)]) + bytes(segs) + payload)
        crc = ogg_crc(page)
        page = page[:22] + struct.pack("<I", crc) + page[26:]
        self.sequence += 1
        return page


class FrameReader:
    def __init__(self, out_path: Path | None):
        # None = derive from the announced codec on each session start.
        self.out_override = out_path
        self.out_path = out_path or Path("out.pcm")
        self.file = None
        self.expected_seq = 0
        self.dropped_frames = 0
        self.json_buf = b""
        self.last_sample_rate = 16000
        self.codec = "pcm"
        self.muxer = None
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
            # Cheap parses; no json module needed.
            m = re.search(r'"sample_rate"\s*:\s*(\d+)', line)
            if m:
                self.last_sample_rate = int(m.group(1))
            m = re.search(r'"codec"\s*:\s*"([^"]+)"', line)
            # No codec key = firmware predating on-device Opus = raw PCM.
            self.codec = m.group(1) if m else "pcm"
            if self.codec == "opus":
                self.muxer = OggOpusMuxer(self.last_sample_rate)
            else:
                self.muxer = None
                if self.codec != "pcm":
                    print(f"[warn] unknown codec '{self.codec}', writing payloads raw")
            if self.out_override is None:
                self.out_path = Path("out.ogg" if self.codec == "opus" else "out.pcm")
            self.file = self.out_path.open("wb")
            self.expected_seq = 0
            self.dropped_frames = 0
            self.total_bytes = 0
            print(f"[rec] started at {self.last_sample_rate} Hz "
                  f"codec={self.codec} -> {self.out_path}")
        elif '"stop"' in line:
            if self.file:
                # Close the Ogg stream properly, or strict demuxers balk.
                if self.muxer:
                    self.file.write(self.muxer.finish())
                self.file.close()
                self.file = None
            if self.codec == "opus":
                # Payload bytes are compressed, so duration comes from
                # packet count, not byte count.
                frames = self.expected_seq
                dur_ms = frames * OPUS_FRAME_SAMPLES * 1000 / self.last_sample_rate
                print(f"[rec] stopped: opus_bytes={self.total_bytes} frames={frames} "
                      f"dur={dur_ms:.0f}ms gaps={self.dropped_frames}")
                print(f"[play] ffplay -autoexit {self.out_path}")
            else:
                dur_ms = (self.total_bytes / (self.last_sample_rate * 2 / 1000)
                          if self.last_sample_rate else 0)
                print(f"[rec] stopped: bytes={self.total_bytes} "
                      f"dur={dur_ms:.0f}ms gaps={self.dropped_frames}")
                print(f"[play] ffplay -autoexit -f s16le -ar {self.last_sample_rate} "
                      f"-ac 1 {self.out_path}")

    def _handle_audio(self, data: bytes) -> None:
        if len(data) < 6:
            print(f"[err] short audio frame: {len(data)} bytes")
            return
        seq, length = struct.unpack("<HH", data[2:6])
        payload = data[6:6 + length]
        if len(payload) != length:
            print(f"[err] frame len mismatch: header says {length}, got {len(payload)}")
            return

        if self.file is None:
            # No start seen yet — dropped heartbeat probably; ignore.
            return

        if seq != self.expected_seq:
            gap = (seq - self.expected_seq) & 0xFFFF
            if gap and gap < 1000:
                self.dropped_frames += gap
                print(f"[gap] expected seq={self.expected_seq} got={seq} (+{gap})")
                if self.muxer is None:
                    # PCM: pad with silence sized like this frame to keep
                    # the timeline aligned. Opus has no silent packet we
                    # could synthesize, so we just note the loss — same
                    # call AudioStreamer makes.
                    self.file.write(b"\x00\x00" * (length // 2) * gap)
                    self.total_bytes += length * gap

        if self.muxer is not None:
            self.file.write(self.muxer.append(payload))
        else:
            self.file.write(payload)
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
    ap.add_argument("--out", default=None,
                    help="output file; defaults to out.ogg or out.pcm "
                         "depending on the codec the firmware announces")
    args = ap.parse_args()

    device = await find_device(args.prefix)
    reader = FrameReader(Path(args.out) if args.out else None)

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
