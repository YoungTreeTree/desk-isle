#!/usr/bin/env python3
"""Measure the currently applied 3D component over native USB or CH343 (no model in firmware).

The app's CH343 relay is temporarily reserved; the board keeps rendering independently.
Only render precision/replay controls change. Original precision is restored on exit.
"""
import argparse
from collections import deque
from contextlib import nullcontext
import fcntl
import json
from pathlib import Path
import random
import struct
import termios
import time
import zlib

from flash import reserve_ch343

HEADER = struct.Struct("<4sBBHIIIHH")
MODEL = 0x8007


class Link:
    def __init__(self, path, uart):
        import serial
        class AtomicModemSerial(serial.Serial):
            # CH343's automatic-reset circuit reacts to the intermediate state when
            # pyserial clears DTR and RTS in two separate ioctls. Match UARTBridge:
            # clear both together after opening, preserving the resident PSRAM model.
            def _update_dtr_state(self): pass
            def _update_rts_state(self): pass
        self.port = AtomicModemSerial(port=None, baudrate=115200, timeout=0.1, write_timeout=5)
        self.port.port = path
        self.port.open()
        if uart:
            config=termios.tcgetattr(self.port.fileno())
            config[2] &= ~(termios.HUPCL | termios.CRTSCTS)
            termios.tcsetattr(self.port.fileno(),termios.TCSANOW,config)
            fcntl.ioctl(self.port.fileno(),termios.TIOCMBIC,struct.pack('I',termios.TIOCM_DTR | termios.TIOCM_RTS))
            self.port.baudrate=3_000_000
        self.uart = uart
        self.token = random.randrange(65536)
        self.sequence = random.randrange(0x7FFFFFFF)
        self.packet = bytearray()
        self.escaped = False
        self.input = bytearray()
        self.lines = deque()
        self.credits = set()
        if uart:
            self.fragment(b"")

    def close(self):
        self.port.close()

    def pump(self):
        data = self.port.read(max(1, self.port.in_waiting))
        if not self.uart:
            self.input.extend(data)
        else:
            for byte in data:
                if byte == 0xC0:
                    p = self.packet
                    if len(p) >= 12 and p[:3] == b"DS2":
                        channel, token, size = struct.unpack_from("<BHH", p, 3)
                        if len(p) == 12 + size and zlib.crc32(p[:-4]) == struct.unpack_from("<I", p, len(p)-4)[0]:
                            if channel == 2:
                                self.credits.add(token)
                            elif channel == 1:
                                self.input.extend(p[8:-4])
                    self.packet = bytearray()
                    self.escaped = False
                elif self.escaped:
                    self.packet.append({0xDC:0xC0, 0xDD:0xDB}.get(byte, byte))
                    self.escaped = False
                elif byte == 0xDB:
                    self.escaped = True
                elif len(self.packet) < 8192:
                    self.packet.append(byte)
        while b"\n" in self.input:
            line, _, tail = self.input.partition(b"\n")
            self.input = bytearray(tail)
            self.lines.append(line.decode("utf-8", errors="replace").strip())

    def fragment(self, data):
        self.token = (self.token + 1) & 65535
        self.credits.discard(self.token)
        packet = b"DS2" + struct.pack("<BHH", 1, self.token, len(data)) + data
        packet += struct.pack("<I", zlib.crc32(packet))
        wire = b"\xC0" + packet.replace(b"\xDB",b"\xDB\xDD").replace(b"\xC0",b"\xDB\xDC") + b"\xC0"
        for _ in range(4):
            self.port.write(wire)
            deadline = time.monotonic() + 1.5
            while time.monotonic() < deadline:
                if self.token in self.credits:
                    self.credits.remove(self.token)
                    return
                self.pump()
        raise TimeoutError("CH343 fragment acknowledgement timeout")

    def request(self, kind, payload=b"", component=MODEL):
        self.sequence = (self.sequence+1) & 0xFFFFFFFF
        packet = HEADER.pack(b"ISLE",1,kind,component,self.sequence,len(payload),zlib.crc32(payload),0,0)+payload
        if self.uart:
            for offset in range(0,len(packet),2048):
                self.fragment(packet[offset:offset+2048])
        else:
            self.port.write(packet)
        deadline = time.monotonic()+20
        result = []
        while time.monotonic() < deadline:
            while self.lines:
                line=self.lines.popleft()
                parts=line.split()
                if len(parts)>=3 and parts[0] in ("DESKISLE_3D_STATS","DESKISLE_3D_PROFILE","DESKISLE_3D") and parts[2]==str(self.sequence):
                    result.append(line)
                if len(parts)==4 and parts[0]=="DESKISLE_ACK" and parts[1]==str(self.sequence):
                    if parts[2]!="0": raise RuntimeError(f"Board rejected command {kind}: {line}")
                    return result
                if kind==3 and len(parts)>=11 and parts[0]=="DESKISLE_LAYOUT" and parts[2]==str(self.sequence):
                    result.append(line)
                    return result
            self.pump()
        raise TimeoutError(f"Command {kind} timeout")

    def stats(self):
        lines=self.request(20)
        line=next(x for x in lines if x.startswith("DESKISLE_3D_STATS "))
        values=list(map(int,line.split()[3:]))
        keys=["width","height","frames","presented","elapsed_us","render_us","max_us","average_us",
              "triangles","vertices","pack_bytes","renderer_bytes","free_psram","largest_psram","free_internal"]
        if len(values)!=len(keys): raise RuntimeError("Unexpected stats format")
        result=dict(zip(keys,values))
        profile=next((x for x in lines if x.startswith("DESKISLE_3D_PROFILE ")),None)
        if profile:
            fields=list(map(int,profile.split()[3:]))
            if len(fields)==6:
                result.update(zip(["profile_frames","animation_us","clear_us","vertex_us","raster_us","compose_us"],fields))
        return result

    def control(self, action, value=0):
        self.request(19,bytes([action,value]))

    def upload(self, path):
        data=path.read_bytes()
        if data[:4]!=b'D3M1' or not 20<=len(data)<=8*1024*1024:
            raise ValueError("Expected a prepared D3M1 pack of at most 8 MiB")
        started=time.monotonic()
        self.request(16,struct.pack('<II',len(data),zlib.crc32(data)))
        try:
            for offset in range(0,len(data),32768):
                self.request(17,struct.pack('<I',offset)+data[offset:offset+32768])
            self.request(18)
        except Exception:
            self.request(21)
            raise
        print(f'Uploaded {len(data)} bytes in {time.monotonic()-started:.1f} s',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port",required=True)
    parser.add_argument("--native-usb",action="store_true",help="Port is the DeskIsle Layout CDC endpoint")
    parser.add_argument("--seconds",type=int,default=30)
    parser.add_argument("--scales",type=int,nargs="+",choices=[1,2,4],default=[1,2,4])
    parser.add_argument("--stats-only",action="store_true",help="Read current counters and memory without replaying or changing precision")
    parser.add_argument("--pack",type=Path,help="Temporarily upload a prepared D3M1 runtime pack for measurement; app restores its saved model on reconnect")
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    if not 10 <= args.seconds <= 600: parser.error("--seconds must be between 10 and 600")
    report={"transport":"USB" if args.native_usb else "CH343","runs":[]}
    with nullcontext() if args.native_usb else reserve_ch343():
        link=Link(args.port,not args.native_usb)
        try:
            capability=link.request(3,component=0)
            print("\n".join(capability),flush=True)
            if args.pack: link.upload(args.pack)
            initial=link.stats()
            if args.stats_only:
                args.output.parent.mkdir(parents=True,exist_ok=True)
                args.output.write_text(json.dumps(initial,indent=2)+"\n")
                print(json.dumps(initial,indent=2))
                return
            if initial["pack_bytes"]==0: raise RuntimeError("Apply a model from the app before benchmarking")
            original_scale=1280//max(initial["width"],initial["height"])
            try:
                # A corrupt candidate and a misordered fragment must not replace the active model.
                invalid=b"INVALID MODEL PACK!!"
                link.request(16,struct.pack("<II",len(invalid),zlib.crc32(invalid)))
                try:
                    link.request(17,struct.pack("<I",1)+invalid)
                    raise AssertionError("Accepted wrong upload offset")
                except RuntimeError as error:
                    if "Board rejected command 17" not in str(error): raise
                link.request(17,struct.pack("<I",0)+invalid)
                try:
                    link.request(18)
                    raise AssertionError("Accepted corrupt model")
                except RuntimeError as error:
                    if "Board rejected command 18" not in str(error): raise
                link.request(21)
                after=link.stats()
                assert after['pack_bytes']==initial['pack_bytes'] and after['triangles']==initial['triangles']
                report['rejected_upload_preserved_active_model']=True
                for scale in args.scales:
                    link.control(2,scale)
                    samples=[]
                    deadline=time.monotonic()+args.seconds
                    while time.monotonic()<deadline:
                        time.sleep(min(4,max(0,deadline-time.monotonic())))
                        sample=link.stats();samples.append(sample)
                        fps=sample["presented"]*1e6/max(1,sample["elapsed_us"])
                        print(f'{sample["width"]}x{sample["height"]}: {fps:.2f} FPS, render {sample["average_us"]/1000:.1f} ms, free PSRAM {sample["free_psram"]/1048576:.2f} MiB',flush=True)
                    first=next((s for s in samples if s["elapsed_us"]>=6_000_000),samples[0])
                    last=samples[-1];dt=max(1,last["elapsed_us"]-first["elapsed_us"])
                    report["runs"].append({"scale":scale,"samples":samples,
                        "steady_fps":(last["presented"]-first["presented"])*1e6/dt,
                        "render_occupancy_pct":(last["render_us"]-first["render_us"])*100/dt,
                        "psram_change":last["free_psram"]-first["free_psram"]})
                    args.output.parent.mkdir(parents=True,exist_ok=True)
                    args.output.write_text(json.dumps(report,indent=2)+"\n")
            finally:
                link.control(2,original_scale)
        finally:
            link.close()
    print(json.dumps({"runs":[{k:v for k,v in run.items() if k!="samples"} for run in report["runs"]]},indent=2))


if __name__=="__main__":
    main()
