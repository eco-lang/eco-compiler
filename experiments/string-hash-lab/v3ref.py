# Reference for value-hash definition v3's String hash, from design_docs/theory/runtime/value-hash.md.
M64=(1<<64)-1
K=0xa0761d6478bd642f
S=[0xe7037ed1a0b428db,0x8ebc6af09c88c6e3,0x589965cc75374cc3,0x1d8e4e27c47d124f]
def mum(a,b):
    r=(a&M64)*(b&M64); return (r&M64)^(r>>64)
def string_hash(s):
    units=list(s.encode('utf-16-le'))
    units=[units[i]|units[i+1]<<8 for i in range(0,len(units),2)]
    n=len(units)
    if n<=8:
        units+=[0]*(8-n)
        w=[sum(units[4*k+j]<<(16*j) for j in range(4)) for k in range(2)]
        h=mum(w[0]^K, w[1]^S[0]); h=mum(h^K, n^S[0])
        x=(h^(h>>32))&0xffffffff
        return x or 1
    units+= [0]*((-len(units))%32)
    lane=S[:]
    for r in range(0,len(units),32):
        w=[sum(units[r+4*k+j]<<(16*j) for j in range(4)) for k in range(8)]
        for j in range(4): lane[j]=mum(w[2*j]^K, w[2*j+1]^lane[j])
    h=mum(lane[0]^S[1],lane[1]^S[2])^mum(lane[2]^S[3],lane[3]^S[0])
    h=mum(h^K, n^S[0])
    x=(h^(h>>32))&0xffffffff
    return x or 1
def fmix32(h):
    h^=h>>16; h=(h*0x85ebca6b)&0xffffffff; h^=h>>13; h=(h*0xc2b2ae35)&0xffffffff; h^=h>>16; return h
def value_hash_string(s):
    if s=="":
        h=2166136261; h=((h^5)*16777619)&0xffffffff
    else:
        h=2166136261
        for x in (4,string_hash(s)): h=((h^x)*16777619)&0xffffffff
    return fmix32(h) or 1
if __name__=="__main__":
    import sys
    for a in sys.argv[1:]: print(a[:20], value_hash_string(a))
