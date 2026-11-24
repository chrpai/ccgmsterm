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
def run(present, status=b"00,OK", ident=0xc9):
    mem=ObservableMemory()
    for i,b in enumerate(prg[2:]): mem[0x0801+i]=b
    st={'state':0,'cmd':[],'data':[],'stat':[]}
    def rd_status(a):
        if not present: return 0xff
        v=st['state']<<4
        if st['data']: v|=0x80
        if st['stat']: v|=0x40
        return v
    def wr_ctrl(a,v):
        if not present: return
        if v&1:
            st['got']=list(st['cmd'])
            if st['cmd']==[4,0x28,0]:
                st['data']=list(b"C64 ULTIMATE"); st['stat']=list(status)
            else:
                st['stat']=list(b"21,UNKNOWN COMMAND")
            st['state']=2; st['cmd']=[]
        if v&2: st['state']=0; st['data']=[]; st['stat']=[]
    def wr_cmd(a,v):
        if present: st['cmd'].append(v)
    mem.subscribe_to_read([0xdf1c], rd_status)
    mem.subscribe_to_read([0xdf1d], lambda a: ident if present else 0xff)
    mem.subscribe_to_read([0xdf1e], lambda a: st['data'].pop(0) if st['data'] else 0)
    mem.subscribe_to_read([0xdf1f], lambda a: st['stat'].pop(0) if st['stat'] else 0)
    mem.subscribe_to_write([0xdf1c], wr_ctrl)
    mem.subscribe_to_write([0xdf1d], wr_cmd)
    m=MPU(memory=mem)
    m.sp=0xfd; mem[0x1ff]=0xff; mem[0x1fe]=0xfe
    m.pc=sym['ultimate_detect']
    n=0
    while m.pc!=0xffff:
        m.step(); n+=1
    model=bytes(mem[sym['ultimate_model']+i] for i in range(32)).split(b'\0')[0]
    return mem[sym['is_ultimate']], model, st['state'], n
ok=True
for name,args,want in [('ultimate',dict(present=True),1),('ultimate irq id',dict(present=True,ident=0x49),1),('stock c64',dict(present=False),0),('error status',dict(present=True,status=b"21,ERR"),0)]:
    r=run(**args); good=r[0]==want and r[2]==0
    ok&=good
    print('OK  ' if good else 'FAIL',name,r)
sys.exit(0 if ok else 1)
