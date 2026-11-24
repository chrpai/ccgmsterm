# 57600 baud: only kept on an Ultimate with a SwiftLink modem type,
# and the SwiftLink driver writes rate bits 0000 for it.
import sys
from py65.devices.mpu6502 import MPU
import os
root=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','build')+os.sep
sym={}
for l in open(root+'ccgmsterm.sym'):
    p=l.split()
    if len(p)==3: sym[p[2].lstrip('.')]=int(p[1],16)
prg=open(root+'ccgmsterm.prg','rb').read()

def run(pc, setup, a=0, x=0):
    mem=bytearray(65536); mem[0x0801:0x0801+len(prg)-2]=prg[2:]
    setup(mem)
    m=MPU(memory=mem); m.sp=0xfd; mem[0x1ff]=0xff; mem[0x1fe]=0xfe
    m.pc=pc; m.a=a; m.x=x
    n=0
    while m.pc!=0xffff:
        m.step(); n+=1
        assert n<100000
    return mem

ok=True
# baud_failsafe: (is_ultimate, modem_type, baud in) -> baud out
for u,mt,b,want in [
    (1,2,7,7),(1,3,7,7),(1,4,7,7),   # Ultimate + SwiftLink DE/DF/D7: keep 57600
    (0,2,7,6),(0,4,7,6),             # real SwiftLink: back to 38400
    (1,0,7,6),(1,1,7,6),             # Ultimate, User Port / UP9600: back to 38400
    (1,2,8,6),(0,2,0xff,6),          # garbage: 38400
    (0,2,6,6),(0,0,2,2),(1,2,6,6),   # lower rates untouched
]:
    def s(mem):
        mem[sym['is_ultimate']]=u; mem[sym['modem_type']]=mt; mem[sym['baud_rate']]=b
    mem=run(sym['baud_failsafe'], s)
    g=mem[sym['baud_rate']]==want
    ok&=g; print('OK  ' if g else 'FAIL','failsafe',u,mt,b,'->',mem[sym['baud_rate']])

# SwiftLink driver: control register rate bits for 38400 and 57600
base=0xde00
for b,want in [(6,0x1f),(7,0x10)]:
    def s(mem):
        mem[sym['is_ultimate']]=1
    mem=run(sym['sw_setup'], s, a=2, x=b)
    g=mem[base+3]==want
    ok&=g; print('OK  ' if g else 'FAIL','sw_ctrl baud',b,hex(mem[base+3]))

# F7 screen label table
lo=sym['baudrates']+2*7
g=prg[lo-0x0801+2]|prg[lo-0x0801+3]<<8==57600
ok&=g; print('OK  ' if g else 'FAIL','baudrates[7]=57600')
sys.exit(0 if ok else 1)
