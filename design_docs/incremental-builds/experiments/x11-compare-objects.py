# Per-unit object reuse across X1 edits (module-aligned units), and how much reuse
# stable naming would add: compare the MULTISET of section contents, ignoring section
# names, symbol/string tables and relocation sections (renamed symbols only change those).
import struct, hashlib, os, csv, collections
OUT='/tmp/inc-exp/results/x11objs'
def sections(path):
    d=open(path,'rb').read()
    shoff,=struct.unpack_from('<Q',d,0x28); shentsize,shnum,shstrndx=struct.unpack_from('<HHH',d,0x3A)
    hdrs=[struct.unpack_from('<IIQQQQIIQQ',d,shoff+i*shentsize) for i in range(shnum)]
    res=collections.Counter()
    for (name,typ,flags,addr,off,size,link,info,align,entsize) in hdrs:
        if typ in (0,2,3,4,9,8):   # NULL, SYMTAB, STRTAB, RELA, REL, NOBITS
            continue
        res[hashlib.md5(d[off:off+size]).hexdigest()+':'+str(typ)]+=1
    return res
def md5(p): return hashlib.md5(open(p,'rb').read()).hexdigest()
def cpu(tag): return {r['group']:float(r['threadCpu']) for r in csv.DictReader(open(f'{OUT}/{tag}/stats.tsv'),delimiter='\t')}
bc=cpu('base1'); tot=sum(bc.values())
bsec={}
bg=set(f[:-2] for f in os.listdir(f'{OUT}/base1') if f.endswith('.o'))
print(f"{'edit':7} {'bytes-changed':>22} {'content-changed':>24}  content-changed units")
for tag in ['base1b']+[f'e{i}' for i in range(1,11)]:
    gs=set(f[:-2] for f in os.listdir(f'{OUT}/{tag}') if f.endswith('.o'))
    changed=[g for g in sorted(gs|bg) if g not in gs or g not in bg or md5(f'{OUT}/{tag}/{g}.o')!=md5(f'{OUT}/base1/{g}.o')]
    real=[]
    for g in changed:
        if g not in gs or g not in bg: real.append(g); continue
        if g not in bsec: bsec[g]=sections(f'{OUT}/base1/{g}.o')
        if sections(f'{OUT}/{tag}/{g}.o')!=bsec[g]: real.append(g)
    pc=lambda L: 100*sum(bc.get(g,0) for g in L)/tot
    print(f"{tag:7} {len(changed):5} units {pc(changed):5.1f}% CPU   {len(real):5} units {pc(real):5.1f}% CPU  {real[:5]}")
