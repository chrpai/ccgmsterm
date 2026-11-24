# Ultimate Net driver (rs232lib/rs232_ultimate_net.s) against a fake
# UCI network target. Run after "make": python3 test/ultimate/test_net.py
import sys, os
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'build') + os.sep
sym = {}
for l in open(root + 'ccgmsterm.sym'):
    p = l.split()
    if len(p) == 3:
        sym[p[2].lstrip('.')] = int(p[1], 16)
prg = open(root + 'ccgmsterm.prg', 'rb').read()

RTAIL, RHEAD, RFREE = 0x029b, 0x029c, 0x029d

class FakeNet:
    def __init__(self, busy=2):
        self.state = 0; self.cmd = []; self.data = []; self.stat = []
        self.busy_reads = 0; self.busy = busy
        self.remote = []          # bytes the host will send
        self.closed = False       # host closed the connection
        self.sent = []            # bytes written to the socket
        self.writes = []          # lengths of WRITE commands
        self.reads = []           # lengths requested by READ commands
        self.opens = []           # (host, port)
        self.closes = []
        self.open_ok = True
        self.ip = [192, 168, 1, 64]
        self.hang = False         # commands never finish
        self.aborted = False
    def status(self, a):
        if self.state == 1:
            if self.hang:
                return 0x10
            if self.busy_reads > 0:
                self.busy_reads -= 1
                return 0x10
            self.state = 2
        v = self.state << 4
        if self.data: v |= 0x80
        if self.stat: v |= 0x40
        return v
    def control(self, a, v):
        if v & 4:
            self.aborted = True; self.state = 0; self.data = []; self.stat = []; self.cmd = []
        if v & 1:
            self.run(self.cmd); self.cmd = []
            self.state = 1; self.busy_reads = self.busy
        if v & 2:
            self.state = 0; self.data = []; self.stat = []
    def reply(self, data, stat=b"00,OK"):
        self.data = list(data); self.stat = list(stat)
    def run(self, c):
        assert c[0] == 3, c
        op = c[1]
        if op == 1:
            self.reply(b"ULTIMATE-II NETWORK INTERFACE V1.0")
        elif op == 2:
            self.reply([1])
        elif op == 5:
            self.reply(self.ip + [255, 255, 255, 0, 192, 168, 1, 1])
        elif op == 7:
            port = c[2] | c[3] << 8
            host = bytes(c[4:c.index(0, 4)]).decode('latin1')
            self.opens.append((host, port))
            if self.open_ok:
                self.closed = False
                self.reply([5])
            else:
                self.reply([], b"84,UNRESOLVED HOST")
        elif op == 9:
            self.closes.append(c[2]); self.reply([])
        elif op == 0x10:
            assert c[2] == 5
            n = c[3] | c[4] << 8
            self.reads.append(n)
            if self.remote:
                d = self.remote[:n]; self.remote = self.remote[n:]
                self.reply([len(d) & 255, len(d) >> 8] + d)
            elif self.closed:
                self.reply([0, 0], b"01,CONNECTION CLOSED BY HOST")
            else:
                self.reply([255, 255], b"02,NO DATA: 11")
        elif op == 0x11:
            assert c[2] == 5
            d = c[3:]
            self.sent += d; self.writes.append(len(d))
            self.reply([len(d) & 255, len(d) >> 8])
        else:
            self.reply([], b"21,UNKNOWN COMMAND")

def machine(net, telnet_iac=0, is_ultimate=1):
    mem = ObservableMemory()
    for i, b in enumerate(prg[2:]):
        mem[0x0801 + i] = b
    mem.subscribe_to_read([0xdf1c], net.status)
    mem.subscribe_to_read([0xdf1e], lambda a: net.data.pop(0) if net.data else 0)
    mem.subscribe_to_read([0xdf1f], lambda a: net.stat.pop(0) if net.stat else 0)
    mem.subscribe_to_write([0xdf1c], net.control)
    mem.subscribe_to_write([0xdf1d], lambda a, v: net.cmd.append(v))
    m = MPU(memory=mem)
    mem[sym['telnet_iac']] = telnet_iac
    mem[sym['is_ultimate']] = is_ultimate
    mem[0x91] = 0xff
    return m

def call(m, name, a=0, x=0, y=0, limit=2000000):
    m.sp = 0xfd; m.memory[0x1ff] = 0xff; m.memory[0x1fe] = 0xfe
    m.pc = sym[name]; m.a = a; m.x = x; m.y = y
    n = 0
    while m.pc != 0xffff:
        m.step(); n += 1
        assert n < limit, name + ' did not return'
    return m.a, m.x, m.y, m.p & 1

def put(m, data):
    for b in data:
        a, x, y, c = call(m, 'net_putxfer', b, 0x11, 0x22)
        assert (a, x, y) == (b, 0x11, 0x22), 'registers not preserved'

def get_all(m, polls=50):
    out = []; idle = 0
    while idle < polls:
        a, x, y, c = call(m, 'iac_get')
        if c:
            idle += 1
        else:
            out.append(a); idle = 0
    return bytes(out)

def setup(net, **kw):
    m = machine(net, **kw)
    call(m, 'net_setup', 5)
    return m

ok = True
def check(name, cond, info=''):
    global ok
    print(('OK  ' if cond else 'FAIL'), name, info if not cond else '')
    ok &= bool(cond)

# detection
net = FakeNet(); m = machine(net); call(m, 'net_detect')
check('detect on Ultimate', m.memory[sym['net_available']] == 1)
net = FakeNet(); m = machine(net, is_ultimate=0); call(m, 'net_detect')
check('no detect without Ultimate', m.memory[sym['net_available']] == 0 and net.cmd == [])

# command mode
net = FakeNet(); m = setup(net)
put(m, b"ATV1\r")
check('AT command answers OK with echo', get_all(m) == b"ATV1\r\r\nOK\r\n")
put(m, b"ATE0\r"); get_all(m)
put(m, b"AT\r")
check('ATE0 turns echo off', get_all(m) == b"\r\nOK\r\n")
put(m, b"hello\r")
check('non-AT line is ignored', get_all(m) == b"")
put(m, b"ATI\r")
check('ATI identifies', get_all(m) == b"\r\nULTIMATE-NET MODEM EMULATOR\r\nMADE BY CHRIS PAINTER\r\n\r\nOK\r\n" and net.cmd == [])
put(m, b"ATX\x14I\r")
check('delete key edits the line', get_all(m).endswith(b"MADE BY CHRIS PAINTER\r\n\r\nOK\r\n"))

# dialing
for name, line, want in [
        ('phonebook style', b"ATDTbbs.example.com:6400\r", ('bbs.example.com', 6400)),
        ('empty port defaults to 23', b"ATDTbbs.example.com:\r", ('bbs.example.com', 23)),
        ('no port defaults to 23', b"ATDT10.0.0.2\r", ('10.0.0.2', 23)),
        ('host starting with T', b"ATDTtelnet.org:23\r", ('telnet.org', 23)),
        ('zimodem quote', b'ATD"towel.blinkenlights.nl:23\r', ('towel.blinkenlights.nl', 23)),
        ('PETSCII shifted letters', b"ATDT\xc2\xc2\xd3.org:64128\r", ('bbs.org', 64128)),
        ('lower case at, spaces', b"atdt  host.net:1541  \r", ('host.net', 1541))]:
    net = FakeNet(); m = setup(net)
    put(m, line)
    out = get_all(m)
    check('dial ' + name, net.opens == [want] and out.endswith(b"\r\nCONNECT\r\n")
          and m.memory[sym['net_online']] & 0x80, (net.opens, out))

net = FakeNet(); net.open_ok = False; m = setup(net)
put(m, b"ATDTnowhere.invalid:23\r")
check('failed dial answers NO CARRIER', get_all(m).endswith(b"\r\nNO CARRIER\r\n")
      and not m.memory[sym['net_online']] & 0x80)

net = FakeNet(); net.hang = True; m = setup(net)
m.memory[0x91] = 0x7f   # STOP held
put(m, b"ATDTslow.example.com\r")
check('STOP aborts a dial', net.aborted and get_all(m).endswith(b"\r\nNO CARRIER\r\n"))

# online: receive
def online(**kw):
    net = FakeNet(**{k: v for k, v in kw.items() if k == 'busy'})
    m = setup(net, **{k: v for k, v in kw.items() if k != 'busy'})
    put(m, b"ATDTbbs:23\r"); get_all(m)
    return net, m
net, m = online()
data = [i & 255 for i in range(1000)]
net.remote = list(data)
got = get_all(m)
check('receive 1000 bytes', list(got) == data, len(got))
check('reads fit the buffer', max(net.reads) <= 239, max(net.reads))

net, m = online(busy=200)
net.remote = list(b"slow")
check('receive with a slow Ultimate', get_all(m, polls=400) == b"slow")

net, m = online(telnet_iac=1)
net.remote = [0x41, 0xff, 0xfb, 0x01, 0xff, 0xff, 0x42]
check('telnet IAC filter on receive', get_all(m) == b"A\xffB")

# Y is kept by a get, also when it picks up a read (XMODEM indexes with Y)
for iac in (0, 1):
    net, m = online(telnet_iac=iac)
    net.remote = list(b"\xff\xff" if iac else b"\xff") + list(range(40))
    keep = True; out = []
    for i in range(400):
        a, x, y, c = call(m, 'iac_get', 0, 0, 0x5a)
        keep = keep and y == 0x5a
        if not c: out.append(a)
    check('get keeps Y (IAC %s)' % ('on' if iac else 'off'), keep and out == [0xff] + list(range(40)), out[:4])

# disable (before disk access): the UCI is left idle until enable
net, m = online(busy=200)
call(m, 'iac_get')                          # a read is now running
put(m, b"NAK")
call(m, 'net_disable')
idle = net.state == 0 and m.memory[sym['net_pend']] == 0
check('disable sends the queue and finishes the read', idle and bytes(net.sent) == b"NAK", (net.state, bytes(net.sent)))
n = len(net.reads)
net.remote = list(b"block")
get_all(m)
check('no reads while disabled', len(net.reads) == n and net.state == 0)
call(m, 'net_enable')
check('reads go on after enable', get_all(m, polls=400) == b"block")

# online: send
net, m = online()
put(m, b"hello")
check('bytes are queued', net.sent == [])
get_all(m)
check('queue is sent on the next get', bytes(net.sent) == b"hello" and net.writes == [5])
net.sent = []; net.writes = []
put(m, bytes(range(200)))
get_all(m)
check('long send is split at 128', list(net.sent) == list(range(200)) and net.writes == [128, 72], net.writes)

net, m = online(telnet_iac=1)
offer = b"\xff\xfb\x00\xff\xfd\x00\xff\xfb\x03\xff\xfd\x03"
check('telnet: binary and SGA offered on connect', bytes(net.sent) == offer, bytes(net.sent).hex())
net.sent = []
# server: DO BINARY (already on), DO TTYPE, WILL ECHO, DONT SGA, WILL NAWS, then data
net.remote = list(b"\xff\xfd\x00\xff\xfd\x18\xff\xfb\x01\xff\xfe\x03\xff\xfb\x1fok")
got = get_all(m)
want = b"\xff\xfc\x18\xff\xfd\x01\xff\xfc\x03\xff\xfe\x1f"
check('telnet: options answered like tnproxy', got == b"ok" and bytes(net.sent) == want, bytes(net.sent).hex())
net.sent = []
net.remote = list(b"\xff\xfb\x01\xff\xfc\x01\xff\xfc\x01")
get_all(m)
check('telnet: no reply when nothing changes', bytes(net.sent) == b"\xff\xfe\x01", bytes(net.sent).hex())
net, m = online()
check('no telnet offer with IAC off', net.sent == [])
net, m = online(telnet_iac=1); net.sent = []
put(m, b"\xff\x41"); get_all(m)
check('telnet IAC doubling on send', bytes(net.sent) == b"\xff\xff\x41")
net, m = online()
put(m, b"\xff"); get_all(m)
check('no doubling with IAC off', bytes(net.sent) == b"\xff")

# xmodem's clear_input_buffer moves rhead to rtail without touching rfree
net, m = online()
for _ in range(5):
    net.remote = list(range(200))
    while m.memory[RTAIL] == m.memory[RHEAD] or net.remote:
        call(m, 'net_poll')
    m.memory[RHEAD] = m.memory[RTAIL]     # stale rfree from here on
net.remote = list(b"still here")
check('reads go on after rhead is moved without rfree', get_all(m) == b"still here")

# hang up
net, m = online()
net.remote = list(b"bye"); net.closed = True
out = get_all(m)
check('remote close gives NO CARRIER', out == b"bye\r\nNO CARRIER\r\n" and net.closes == [5]
      and not m.memory[sym['net_online']] & 0x80, out)
put(m, b"AT\r")
check('back in command mode after close', get_all(m) == b"AT\r\r\nOK\r\n")

net, m = online()
call(m, 'iac_get')      # a read is running now
call(m, 'net_dropdtr')
check('hang up closes the socket', net.closes == [5] and get_all(m) == b"\r\nNO CARRIER\r\n"
      and not m.memory[sym['net_online']] & 0x80)

net, m = online()
call(m, 'net_setup', 5)
check('driver init keeps the connection', m.memory[sym['net_online']] & 0x80 and net.closes == [])

# dispatcher: Ultimate Net without an Ultimate falls back to User Port
net = FakeNet(); m = machine(net)
m.memory[sym['modem_type']] = 5; m.memory[sym['net_available']] = 0; m.memory[sym['baud_rate']] = 6
call(m, 'rs232_init')
check('fallback to User Port', m.memory[sym['modem_type']] == 0 and m.memory[sym['baud_rate']] == 2)
net = FakeNet(); m = machine(net)
m.memory[sym['modem_type']] = 5; m.memory[sym['net_available']] = 1
call(m, 'rs232_init')
check('Ultimate Net driver selected', m.memory[sym['modem_type']] == 5
      and m.memory[sym['func_putxfer'] + 1] | m.memory[sym['func_putxfer'] + 2] << 8 == sym['net_putxfer'])

sys.exit(0 if ok else 1)
