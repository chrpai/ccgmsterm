import sys
from py65.devices.mpu6502 import MPU
import os
root=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','build')+os.sep
sym={}
for l in open(root+'ccgmsterm.sym'):
    p=l.split()
    if len(p)==3: sym[p[2].lstrip('.')]=int(p[1],16)
prg=open(root+'ccgmsterm.prg','rb').read()
ok=True
for t,u,mt,want in [(1,1,2,0x80),(1,0,2,0),(0,1,3,0),(1,1,4,0x80)]:
    mem=bytearray(65536); mem[0x0801:0x0801+len(prg)-2]=prg[2:]
    mem[sym['telnet_iac']]=t; mem[sym['is_ultimate']]=u; mem[sym['iac_state']]=3
    m=MPU(memory=mem); m.sp=0xfd; mem[0x1ff]=0xff; mem[0x1fe]=0xfe
    m.pc=sym['sw_setup']; m.a=mt; m.x=2
    while m.pc!=0xffff: m.step()
    g=mem[sym['iac_on']]==want and mem[sym['iac_state']]==0
    ok&=g; print('OK  ' if g else 'FAIL',t,u,mt,hex(mem[sym['iac_on']]))
sys.exit(0 if ok else 1)
