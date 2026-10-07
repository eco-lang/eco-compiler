#!/usr/bin/env python3
# Usage: measure.py <cfg...> : binary/section sizes + census counters per x3 config (JSON lines)
import sys, os, re, subprocess, json, hashlib
for cfg in sys.argv[1:]:
    V=f"/tmp/inc-exp/variants/x3-{cfg}"; B=f"{V}/bin/eco"
    secs={}
    for line in subprocess.run(["readelf","-SW",B],capture_output=True,text=True).stdout.splitlines():
        m=re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+[0-9a-f]+\s+[0-9a-f]+\s+([0-9a-f]+)",line)
        if m: secs[m.group(1)]=int(m.group(2),16)
    r={"cfg":cfg,"file":os.path.getsize(B),"obj":os.path.getsize(f"{V}/bin/eco.o"),
       "text":secs.get(".text"),"stackmaps":secs.get(".llvm_stackmaps"),
       "rodata":secs.get(".rodata"),"data.rel.ro":secs.get(".data.rel.ro"),
       "mlir_md5":hashlib.md5(open(f"{V}/bin/eco.mlir","rb").read()).hexdigest()[:12]}
    for f in ("fe.log","lower.log"):
        p=f"{V}/{f}"
        if not os.path.exists(p): continue
        for line in open(p,errors="replace"):
            if line.startswith("[x3-census]"):
                for kv in line.split()[2:]:
                    k,v=kv.split("=",1); r[k]=int(v)
            m=re.match(r"\[(caphoist-plan|gcfree-plan)\] (.*)",line)
            if m:
                for kv in m.group(2).split():
                    k,v=kv.split("=",1)
                    if k!="time": r[m.group(1)+"."+k]=v
            m=re.search(r"cross-module-referenced defined functions=(\d+)",line)
            if m: r["xmodExported"]=int(m.group(1))
    print(json.dumps(r))
