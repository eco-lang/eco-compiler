import re,sys,glob,collections
SF=set("worklist nodes inProgress scheduled dirtySpecs dirtyList specCountByGlobal registry ports lambdaCounter superTable nextMVarId lssSignatures lssInProgress lssMemberTable nextMemberId lssStats monoMemo nodeResolution intern env currentGlobal store memo revMemo varEnv numberMulti localMulti derivedDestructors localCanTypes itemAux".split())
groups=collections.Counter(); perfield=collections.Counter(); sites=[]
for f in sorted(glob.glob('compiler/src/Compiler/MonoSolver/*.elm')):
    src=open(f).read()
    for m in re.finditer(r'\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\|',src):
        i=m.end(); depth=1; j=i
        while j<len(src) and depth>0:
            c=src[j]
            if c=='{': depth+=1
            elif c=='}': depth-=1
            j+=1
        body=src[i:j-1]
        # split top-level commas
        parts=[];d=0;cur=''
        for c in body:
            if c in '([{': d+=1
            elif c in ')]}': d-=1
            if c==',' and d==0: parts.append(cur);cur=''
            else: cur+=c
        parts.append(cur)
        fields=[]
        for p in parts:
            mm=re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=',p)
            if mm: fields.append(mm.group(1))
        if fields and all(x in SF for x in fields):
            line=src[:m.start()].count('\n')+1
            key=tuple(sorted(fields))
            groups[key]+=1
            for x in fields: perfield[x]+=1
            sites.append((f.split('/')[-1],line,m.group(1),fields))
print("== sites whose fields are ALL S fields:",len(sites))
for s in sites: print("%s:%d %s {%s}"%(s[0],s[1],s[2],",".join(s[3])))
print("\n== co-update groups (sorted field set -> count)")
for k,v in sorted(groups.items(),key=lambda kv:-kv[1]): print(v, "+".join(k))
print("\n== per-field write counts")
for k,v in sorted(perfield.items(),key=lambda kv:-kv[1]): print(v,k)
print("\n== never-written S fields:", sorted(SF-set(perfield)))
