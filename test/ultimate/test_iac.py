import sys
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory
import os
root=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','build')+os.sep
sym={}
for l in open(root+'ccgmsterm.sym'):
    p=l.split()
    if len(p)==3: sym[p[2].lstrip('.')]=int(p[1],16)
prg=open(root+'ccgmsterm.prg','rb').read()
def run_get(stream, iac):
    mem=bytearray(65536)
    mem[0x0801:0x0801+len(prg)-2]=prg[2:]
    m=MPU(memory=mem)
    rib=sym['ribuf']
    for i,b in enumerate(stream): mem[rib+i]=b
    mem[0x029b]=len(stream)  # rtail
    mem[0x029c]=0            # rhead
    mem[0x029d]=len(stream)  # rfree
    mem[sym['iac_on']]=0x80 if iac else 0
    mem[sym['iac_state']]=0
    out=[]
    for _ in range(len(stream)+2):
        m.sp=0xfd; m.memory[0x1ff]=0xff; m.memory[0x1fe]=0xfe  # return to $ffff
        m.memory[0xffff]=0
        m.pc=sym['iac_get']
        n=0
        while m.pc!=0xffff:
            m.step(); n+=1
            assert n<100000
        if m.p & 1: break
        out.append(m.a)
    return out
def check(name, stream, want, iac=True):
    got=run_get(stream,iac)
    print(('OK  ' if got==want else 'FAIL'), name, [hex(x) for x in got])
    return got==want
ok=True
ok&=check('plain', [1,2,3],[1,2,3])
ok&=check('escaped ff', [0x41,0xff,0xff,0x42],[0x41,0xff,0x42])
ok&=check('negotiation', [0xff,0xfb,0x01,0xff,0xfd,0x03,0x41],[0x41])
ok&=check('subneg', [0xff,0xfa,0x18,0x01,0xff,0xff,0xff,0xf0,0x42],[0x42])
ok&=check('2-byte cmd', [0xff,0xf1,0x43],[0x43])
ok&=check('ff ff ff ff', [0xff,0xff,0xff,0xff],[0xff,0xff])
ok&=check('off passes through', [0xff,0xff,0xfb],[0xff,0xff,0xfb],iac=False)
sys.exit(0 if ok else 1)
