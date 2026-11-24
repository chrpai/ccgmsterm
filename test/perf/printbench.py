# Cycle count of CCGMS's receive-and-print path, on a simulated C64 (py65).
# Needs the C64 KERNAL and BASIC ROMs (not in the repo):
#   python3 test/perf/printbench.py ROMDIR [build/ccgmsterm.prg]
# ROMDIR holds kernal.bin (901227-03) and basic.bin (901226-01).
# Feeds a byte stream through rs232_get and reports cycles per byte, and
# can dump the screen and color RAM so two builds can be compared.
# Environment:
#   STREAM=text|plain   built-in stream (default text); N=bytes (4000)
#   STREAMFILE=path     feed this file instead
#   DUMP=path           write screen, color RAM, $D0-$F5 (and the 80 column
#                       bitmap with COL80=1) after the stream, cursor shown
#   REU=1               emulate an REU; MODEM=5 selects Ultimate Net
#   COL80=1             start in 80 column mode
# The modem driver is stubbed out, and there are no interrupts, so real
# hardware is slower; compare builds against each other, not against B/s.
import sys, os
from py65.devices.mpu6502 import MPU

romdir = sys.argv[1]
build = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'build')
prgpath = sys.argv[2] if len(sys.argv) > 2 else os.path.join(build, 'ccgmsterm.prg')
sympath = prgpath[:-4] + '.sym'
sym = {}
for l in open(sympath):
    p = l.split()
    if len(p) == 3:
        sym[p[2].lstrip('.')] = int(p[1], 16)
kernal = open(os.path.join(romdir, 'kernal.bin'), 'rb').read()
basic = open(os.path.join(romdir, 'basic.bin'), 'rb').read()

class C64Mem(bytearray):
    """RAM with BASIC/KERNAL ROM overlays (per $01) and a ticking $D012."""
    def __init__(self):
        super().__init__(65536)
        self.ras = 0
    def __getitem__(self, a):
        if isinstance(a, slice):
            return bytes(self[i] for i in range(*a.indices(65536)))
        p = bytearray.__getitem__(self, 1) & 7
        if a >= 0xe000 and p & 2:
            return kernal[a - 0xe000]
        if 0xa000 <= a < 0xc000 and (p & 3) == 3:
            return basic[a - 0xa000]
        if a == 0xd012:
            self.ras = (self.ras + 1) % 312
            return self.ras & 0xff
        if a == 0xd011:
            return 0x1b | (0x80 if self.ras > 255 else 0)
        if a == 0xd0bc:
            return 0xff     # no SuperCPU
        if a in (0xdc01,):
            return 0xff     # no key pressed
        return bytearray.__getitem__(self, a)
    def __setitem__(self, a, v):
        bytearray.__setitem__(self, a, v)
        if a == 0xdf01 and v & 0x80 and reu is not None:
            reu_dma(v)

# REU=1: emulate a 512 KB REU (stash and fetch, no FF00 trigger)
reu = bytearray(512 * 1024) if os.environ.get('REU') == '1' else None
def reu_dma(cmd):
    r = lambda a: bytearray.__getitem__(mem, a)
    regs = [r(0xdf02 + i) for i in range(7)]
    c64 = regs[0] | regs[1] << 8
    ra = regs[2] | regs[3] << 8 | (regs[4] & 7) << 16
    n = regs[5] | regs[6] << 8 or 0x10000
    fc, fr = r(0xdf0a) & 0x80, r(0xdf0a) & 0x40
    for i in range(n):
        ci = (c64 + (0 if fc else i)) & 0xffff
        ri = (ra + (0 if fr else i)) & 0x7ffff
        if cmd & 3 == 0:
            reu[ri] = mem[ci]
        elif cmd & 3 == 1:
            bytearray.__setitem__(mem, ci, reu[ri])
        else:
            raise NotImplementedError
    mpu.processorCycles += n
    if not cmd & 0x20:   # no autoload: registers advance
        c64 = (c64 + n) & 0xffff; ra = (ra + n) & 0x7ffff
        for i, b in enumerate([c64 & 255, c64 >> 8, ra & 255, (ra >> 8) & 255, ra >> 16, 1, 0]):
            bytearray.__setitem__(mem, 0xdf02 + i, b)
    bytearray.__setitem__(mem, 0xdf00, 0x40 | 0x10)

mem = C64Mem()
mpu = MPU(memory=mem)
prg = open(prgpath, 'rb').read()
la = prg[0] | prg[1] << 8
for i, b in enumerate(prg[2:]):
    bytearray.__setitem__(mem, la + i, b)
mem[1] = 0x37
mem[0] = 0x2f

stream = b''
pos = 0
got = []            # (cycles at each data byte returned)
done_at = None

def rts():
    lo = mem[0x100 + ((mpu.sp + 1) & 0xff)]
    hi = mem[0x100 + ((mpu.sp + 2) & 0xff)]
    mpu.sp = (mpu.sp + 2) & 0xff
    mpu.pc = ((hi << 8) | lo) + 1
    mpu.processorCycles += 6

def h_get():
    global pos
    if pos < len(stream):
        mpu.a = stream[pos]; pos += 1
        got.append(mpu.processorCycles)
    else:
        mpu.a = 0
        got.append(mpu.processorCycles)
        if pos > len(stream):   # second empty poll: the terminal is idle
            raise StopIteration
        pos += 1                # first empty poll: let it show the cursor
    mem[0x90] = 0
    mpu.p = (mpu.p & ~0x82) | (0x02 if mpu.a == 0 else 0) | (mpu.a & 0x80)
    rts()

def h_rts():
    rts()

def h_nodrive():
    mpu.a = 0x80; mpu.p |= 0x80; rts()

hooks = {}
for name in ('rs232_init', 'rs232_on', 'rs232_off', 'rs232_put', 'rs232_dropdtr',
             'rs232_clear', 'ultimate_detect', 'net_detect', 'bell', 'gong',
             ) + (() if os.environ.get('COL80') == '1' else ('col80_init',)):
    if name in sym: hooks[sym[name]] = h_rts
hooks[sym['rs232_get']] = h_get
hooks[sym['is_drive_present']] = h_nodrive
if reu is None:
    hooks[sym['reu_detect']] = lambda: (setattr(mpu, 'pc', sym['noreu']))
if os.environ.get('COL80') == '1':  # start in 80 column mode
    bytearray.__setitem__(mem, sym['col80_enabled'], 0x80)
if 'MODEM' in os.environ:    # e.g. MODEM=5 for Ultimate Net
    bytearray.__setitem__(mem, sym['modem_type'], int(os.environ['MODEM']))

def run(pc, until=None, limit=200_000_000):
    mpu.pc = pc
    while mpu.processorCycles < limit:
        h = hooks.get(mpu.pc)
        if h:
            h()
            continue
        if until is not None and mpu.pc == until:
            return
        mpu.step()

def kernal_call(addr):
    # push a return to a sentinel
    mpu.sp = 0xff
    sentinel = 0x02ff  # an RTS-free address we stop at
    mem[0x1ff] = (sentinel - 1) >> 8
    mem[0x1fe] = (sentinel - 1) & 0xff
    mpu.sp = 0xfd
    run(addr, until=sentinel)

# KERNAL init: IOINIT, RAMTAS (skipping the slow test), RESTOR, CINT
kernal_call(0xfda3)
# RAMTAS minimal: clear zp/pages 2,3, set memtop/membot and HIBASE
for a in list(range(2, 0x100)) + list(range(0x200, 0x400)):
    bytearray.__setitem__(mem, a, 0)
mem[0x0288] = 0x04
mem[0x0283], mem[0x0284] = 0x00, 0xa0
mem[0x0281], mem[0x0282] = 0x00, 0x08
mem[0xb2], mem[0xb3] = 0x3c, 0x03
kernal_call(0xfd15)
kernal_call(0xff5b)
mem[0xba] = 8

def text_stream(n):
    # BBS-ish PETSCII: colored words, lines of varying length, CRs (scrolls)
    import random
    r = random.Random(1)
    words = [b'hello', b'world', b'ccgms', b'bulletin', b'board', b'the', b'quick',
             b'brown', b'fox', b'jumps', b'over', b'lazy', b'dog', b'MESSAGE', b'BASE']
    colors = [0x05, 0x1c, 0x1e, 0x1f, 0x9c, 0x9e, 0x9f, 0x81, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x90]
    out = bytearray()
    col = 0
    while len(out) < n:
        if r.random() < 0.15:
            out.append(r.choice(colors))
        w = r.choice(words)
        if col + len(w) + 1 > r.choice([38, 39, 40, 60, 79]):
            out.append(0x0d); col = 0
        out += w + b' '; col += len(w) + 1
    return bytes(out[:n])

def plain_stream(n):
    # Lines of 39 printable characters and a CR, like blast.py text
    line = bytes((0x41 + i % 26) for i in range(39)) + b'\r'
    return (line * (n // len(line) + 1))[:n]

def screen():
    return bytes(bytearray.__getitem__(mem, a) for a in range(0x400, 0x7e8)), \
           bytes(bytearray.__getitem__(mem, a) & 15 for a in range(0xd800, 0xdbe8))

if __name__ == '__main__':
    kind = os.environ.get('STREAM', 'text')
    n = int(os.environ.get('N', '4000'))
    stream = {'text': text_stream, 'plain': plain_stream}[kind](n)
    if 'STREAMFILE' in os.environ:
        stream = open(os.environ['STREAMFILE'], 'rb').read()
        kind = os.path.basename(os.environ['STREAMFILE'])
    start = 2061
    mpu.sp = 0xff
    try:
        run(start)
    except StopIteration:
        pass
    # got[0] is the first call; the first data byte arrives after the banner
    data_calls = got[:len(stream)+1]
    cyc = data_calls[-1] - data_calls[0]
    print(f'{prgpath}: {len(stream)} bytes ({kind}), {cyc} cycles, {cyc/len(stream):.0f} cycles/byte, '
          f'{1_000_000*len(stream)/cyc:.0f} B/s at 1 MHz (no IRQ, no network)')
    if 'DUMP' in os.environ:
        s, c = screen()
        extra = bytes(bytearray.__getitem__(mem, a) for a in range(0xe000, 0x10000)) if os.environ.get('COL80') == '1' else b''
        open(os.environ['DUMP'], 'wb').write(s + c + bytes(bytearray.__getitem__(mem, a) for a in range(0xd0, 0xf6)) + extra)
