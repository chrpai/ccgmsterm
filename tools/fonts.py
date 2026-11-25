import gzip, os, re, struct
# PSF fonts from the Debian/Ubuntu console-data package
D=os.environ.get('CONSOLEFONTS','/usr/share/consolefonts')+'/'
HERE=os.path.dirname(os.path.abspath(__file__))
CP437=[bytes([i]).decode('cp437') for i in range(256)]
# control-range CP437 glyphs
CTRL='\u0000☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼'
for i,c in enumerate(CTRL): CP437[i]=c
CP437[0x7f]='⌂'

def load_psf(name):
    d=gzip.open(D+name).read()
    assert d[:2]==b'\x36\x04'
    mode,h=d[2],d[3]; n=512 if mode&1 else 256
    glyphs=[d[4+i*h:4+(i+1)*h] for i in range(n)]
    umap={}
    if mode&2:
        p=4+n*h; g=0
        while p<len(d) and g<n:
            u=struct.unpack_from('<H',d,p)[0]; p+=2
            if u==0xffff: g+=1; continue
            if u==0xfffe: continue
            umap.setdefault(chr(u),glyphs[g])
    return h,umap,glyphs

def cp437_font(name):
    h,umap,glyphs=load_psf(name)
    out=[]; miss=[]
    for i,c in enumerate(CP437):
        g=umap.get(c) if umap else glyphs[i]
        if name.startswith('cp865') and i in (0x9B,0x9D,0xAF): g=load_psf('LatArCyrHeb-08.psf.gz')[1].get(c,g)
        if g is None: miss.append((i,c)); g=bytes(h)
        out.append([[(row>>(7-x))&1 for x in range(8)] for row in g])
    return out,miss

def ccgms_4x8():
    src=open(os.path.join(HERE,'..','src','charset.s')).read().split('\n')
    m={}; cur=None; rows=[]; patches=[]; section='main'
    for ln in src:
        if ln.startswith('charset_ascii_patches'): section='ascii'
        if ln.startswith('charset_petscii_patches'): section='pet'
        mm=re.match(r';\s*0x[0-9A-F]+\s+0x([0-9A-F]+)',ln)
        if section=='main' and mm: cur=chr(int(mm.group(1),16)); rows=[]
        mp=re.match(r'; ([0-9A-F]{2}): ?(.*)',ln)
        if section=='ascii' and mp: cur=mp.group(2) or '\x7f'; rows=[]
        b=re.search(r'dnyb %([01]{4})',ln)
        if b and section in('main','ascii'):
            rows.append([int(ch) for ch in b.group(1)])
            if len(rows)==8:
                if section=='ascii' or cur not in m: m[cur]=rows
    return m
