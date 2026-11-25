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
def run_put(bytes_, iac):
    mem=ObservableMemory()
    for i,b in enumerate(prg[2:]): mem[0x0801+i]=b
    sent=[]
    mem.subscribe_to_write([0xde00], lambda a,v: sent.append(v))
    mem.subscribe_to_read([0xde01], lambda a: 0x30)
    m=MPU(memory=mem)
    mem[sym['iac_on']]=0x80 if iac else 0
    for b in bytes_:
        m.sp=0xfd; mem[0x1ff]=0xff; mem[0x1fe]=0xfe
        m.pc=sym['sw_putxfer']; m.a=b
        while m.pc!=0xffff: m.step()
        assert m.a==b and not (m.p&1)
    return sent
ok=True
for name,inp,iac,want in [('on',[0x41,0xff,0x42],True,[0x41,0xff,0xff,0x42]),('off',[0x41,0xff,0x42],False,[0x41,0xff,0x42])]:
    got=run_put(inp,iac); r=got==want; ok&=r
    print('OK  ' if r else 'FAIL',name,[hex(x) for x in got])
sys.exit(0 if ok else 1)
