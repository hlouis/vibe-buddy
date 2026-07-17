#!/usr/bin/env python3
"""
Validates our Ogg Opus muxer against a real decoder.

Why this exists: the Swift unit tests in OggOpusMuxerTests only check
assertions we wrote ourselves. That is exactly how the EOS page shipped
with one zero-length lacing segment instead of zero segments — every
unit test passed and ffmpeg still rejected the stream, because the tests
encoded the same wrong belief the muxer did.

This closes the loop: take REAL Opus packets, push them through our
muxer, and demand that ffmpeg decode the result and get the tone back.
It exercises the Python port in tools/ble_audio_dump.py, which is a
line-for-line mirror of the Swift muxer — if you change one, change both
and re-run this.

Usage:
  python3 tools/verify_ogg_mux.py     # needs ffmpeg on PATH
"""
import math
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

TOOLS = Path(__file__).resolve().parent


def load_muxer():
    """Pull the muxer out of ble_audio_dump.py without importing bleak."""
    src = (TOOLS / "ble_audio_dump.py").read_text()
    ns = {"struct": struct, "OPUS_FRAME_SAMPLES": 960}
    exec(src[src.index("def _ogg_crc_table"):src.index("class FrameReader")], ns)
    return ns


def demux_ogg(path: Path) -> list[bytes]:
    """Ogg -> the raw packets inside, i.e. what the firmware puts on the wire."""
    data = path.read_bytes()
    packets, i = [], 0
    while i < len(data):
        if data[i:i + 4] != b"OggS":
            raise SystemExit(f"not an Ogg page at offset {i}")
        nsegs = data[i + 26]
        table = data[i + 27:i + 27 + nsegs]
        off, cur = i + 27 + nsegs, b""
        for s in table:
            cur += data[off:off + s]
            off += s
            if s < 255:
                packets.append(cur)
                cur = b""
        if cur:
            packets.append(cur)
        i = off
    return packets


def goertzel(sig, freq, sr) -> float:
    k = 2 * math.cos(2 * math.pi * freq / sr)
    s1 = s2 = 0.0
    for x in sig:
        s0 = x + k * s1 - s2
        s2, s1 = s1, s0
    return s1 * s1 + s2 * s2 - k * s1 * s2


def main() -> int:
    if not subprocess.run(["which", "ffmpeg"], capture_output=True).returncode == 0:
        print("ffmpeg not on PATH; skipping", file=sys.stderr)
        return 0

    ns = load_muxer()
    tone_hz, seconds = 440, 2

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        ref, remuxed, decoded = td / "ref.ogg", td / "remuxed.ogg", td / "decoded.wav"

        # Reference stream in exactly the firmware's configuration:
        # 16 kHz mono, CBR 20 kbps, 60 ms frames.
        subprocess.run([
            "ffmpeg", "-loglevel", "error",
            "-f", "lavfi", "-i",
            f"sine=frequency={tone_hz}:duration={seconds}:sample_rate=16000",
            "-c:a", "libopus", "-b:a", "20k", "-vbr", "off",
            "-frame_duration", "60", "-ac", "1", "-ar", "16000",
            str(ref), "-y",
        ], check=True)

        # Strip the container's own headers: the firmware sends only
        # audio packets, our muxer synthesizes OpusHead/OpusTags itself.
        audio = [p for p in demux_ogg(ref) if not p.startswith(b"Opus")]
        if not audio:
            print("FAIL: no audio packets demuxed from the reference", file=sys.stderr)
            return 1
        print(f"  {len(audio)} real Opus packets "
              f"({min(map(len, audio))}-{max(map(len, audio))} B each)")

        m = ns["OggOpusMuxer"](16000)
        remuxed.write_bytes(b"".join(m.append(p) for p in audio) + m.finish())
        print(f"  remuxed -> {remuxed.stat().st_size} B")

        # -xerror: any decode complaint is a failure, not a warning.
        r = subprocess.run(
            ["ffmpeg", "-loglevel", "error", "-xerror",
             "-i", str(remuxed), "-f", "wav", str(decoded), "-y"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            print("FAIL: ffmpeg rejected our stream\n" + r.stderr, file=sys.stderr)
            return 1
        print("  ffmpeg decoded it without complaint")

        # Structure being valid isn't enough — check the audio survived.
        with wave.open(str(decoded)) as w:
            n, sr, nch = w.getnframes(), w.getframerate(), w.getnchannels()
            frames = struct.unpack(f"<{n * nch}h", w.readframes(n))
        ch = frames[::nch]
        dur = n / sr
        if abs(dur - seconds) > 0.1:
            print(f"FAIL: duration {dur:.2f}s != {seconds}s "
                  f"(granule positions are wrong)", file=sys.stderr)
            return 1

        seg = ch[sr // 2: sr // 2 + 4096]
        signal, control = goertzel(seg, tone_hz, sr), goertzel(seg, 1000, sr)
        ratio = signal / max(control, 1)
        print(f"  {dur:.2f}s decoded, {tone_hz} Hz is {ratio:.0f}x the 1 kHz control")
        if ratio < 50:
            print("FAIL: the tone did not survive the mux", file=sys.stderr)
            return 1

    print("\nOK: our Ogg framing is accepted by a real decoder and the audio is intact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
