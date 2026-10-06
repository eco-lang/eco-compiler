#!/usr/bin/env python3
"""Generates the wide Custom/Record JIT fixtures of plans/wide-object-tail-kind-words-phase-3.md
(3B.F.1-3B.F.3): wide_record_40_jit.mlir, wide_custom_60_jit.mlir, wide_record_600_jit.mlir.
Run from test/codegen: python3 gen_wide_fixtures.py"""
import sys
KIND_TY={0:'!eco.value',1:'i64',2:'f64',3:'i16'}
def kind_of(i): return [1,2,3,0][i%4]
def ext_words(n,hdr): return (n-hdr+31)//32 if n>hdr else 0
def pack(kinds,hdr):
    h=0
    for i,k in enumerate(kinds[:hdr]): h|=k<<(2*i)
    ext=[]
    for j in range(ext_words(len(kinds),hdr)):
        w=0
        for i,k in enumerate(kinds[hdr+32*j:hdr+32*j+32]): w|=k<<(2*i)
        ext.append(w)
    return h,ext
def expected(i):
    k=kind_of(i)
    if k==1: return str(1000+i)
    if k==2: return f"{i}.5"
    if k==3: return "'"+chr(65+i%26)+"'"
    return str(2000+i)
def gen(kind,n,probe,name,tag=None,group_tail=False):
    hdr=24 if kind=='custom' else 32
    kinds=[kind_of(i) for i in range(n)]
    L=[]
    L.append(f"// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s")
    L.append("//")
    L.append(f"// Phase 3B (plans/wide-object-tail-kind-words-phase-3.md): a {n}-field {kind} with")
    L.append(f"// mixed kinds (i64, f64, i16, boxed) built by eco.construct.{kind}, kept live across")
    L.append("// forced minor + major GCs, then projected. Slots >= %d have their kinds in an" % hdr)
    L.append("// extension kind word (HEAP_019); a wrong ext word makes the GC trace a raw value")
    L.append("// (crash under ECO_HEAP_VALIDATE) or lose a boxed one (stale value).")
    L.append("")
    L.append("module {")
    L.append("  llvm.func @eco_minor_gc()")
    L.append("  llvm.func @eco_major_gc()")
    L.append("")
    L.append("  func.func @main() -> i64 {")
    ops=[];tys=[]
    for i,k in enumerate(kinds):
        if k==1: L.append(f"    %v{i} = arith.constant {1000+i} : i64")
        elif k==2: L.append(f"    %v{i} = arith.constant {i}.5 : f64")
        elif k==3: L.append(f"    %v{i} = arith.constant {65+i%26} : i16")
        else:
            L.append(f"    %r{i} = arith.constant {2000+i} : i64")
            L.append(f"    %v{i} = eco.box %r{i} : i64 -> !eco.value")
        ops.append(f"%v{i}"); tys.append(KIND_TY[k])
    sk=", ".join(str(k) for k in kinds)
    if kind=='record':
        L.append(f"    %obj = eco.construct.record({', '.join(ops)}) {{field_count = {n} : i64, slot_kinds = array<i8: {sk}>}} : ({', '.join(tys)}) -> !eco.value")
    else:
        L.append(f"    %obj = eco.construct.custom({', '.join(ops)}) {{tag = {tag} : i64, size = {n} : i64, slot_kinds = array<i8: {sk}>}} : ({', '.join(tys)}) -> !eco.value")
    if group_tail:
        # An allocation right after the construct that does not consume it, so
        # EcoGCPrepare puts both in one allocation GROUP (the construct depends
        # on the boxes before it, which closes their run): the group path
        # (eco_init_*_at + merge-block field and ext-word stores, RD6/F5/F6).
        L.append("    %gtail = eco.box %v0 : i64 -> !eco.value")
    L.append("    llvm.call @eco_minor_gc() : () -> ()")
    L.append("    llvm.call @eco_minor_gc() : () -> ()")
    L.append("    llvm.call @eco_major_gc() : () -> ()")
    proj='record' if kind=='record' else 'custom'
    checks=[]
    for i in probe:
        k=kinds[i]
        if k==0:
            L.append(f"    %p{i} = eco.project.{proj} %obj[{i}] : !eco.value -> !eco.value")
            L.append(f"    %u{i} = eco.unbox %p{i} : !eco.value -> i64")
            L.append(f"    eco.dbg %u{i} : i64")
        else:
            L.append(f"    %p{i} = eco.project.{proj} %obj[{i}] : !eco.value -> {KIND_TY[k]}")
            L.append(f"    eco.dbg %p{i} : {KIND_TY[k]}")
        checks.append(f"// CHECK{'' if not checks else '-NEXT'}: {expected(i)}")
    if group_tail:
        L.append("    %ugtail = eco.unbox %gtail : !eco.value -> i64")
        L.append("    eco.dbg %ugtail : i64")
        checks.append("// CHECK-NEXT: 1000")
    L.append("    %z = arith.constant 0 : i64")
    L.append("    return %z : i64")
    L.append("  }")
    L.append("}")
    L.append("")
    L+=checks
    h,ext=pack(kinds,hdr)
    return "\n".join(L)+"\n", h, ext
if __name__=='__main__':
    r,h,e=gen('record',40,[0,1,2,3,31,32,33,34,35,38,39],'wide_record_40')
    open('wide_record_40_jit.mlir','w').write(r); print('record hdr',hex(h),'ext',[hex(x) for x in e])
    c,h,e=gen('custom',60,[0,1,2,3,23,24,25,26,27,55,56,59],'wide_custom_60',tag=3)
    open('wide_custom_60_jit.mlir','w').write(c); print('custom hdr',hex(h),'ext',[hex(x) for x in e])
    r,h,e=gen('record',600,[0,31,32,63,64,599],'wide_record_600')
    open('wide_record_600_jit.mlir','w').write(r); print('rec600 ext count',len(e))
    r,h,e=gen('record',600,[0,31,32,63,64,599],'wide_record_600_group',group_tail=True)
    open('wide_record_600_group_jit.mlir','w').write(r)
    c,h,e=gen('custom',600,[0,23,24,27,56,599],'wide_custom_600_group',tag=5,group_tail=True)
    open('wide_custom_600_group_jit.mlir','w').write(c)
    for nm,n,hdr,tag in (('record',40,32,8),('custom',60,24,7),('record',600,32,8)):
        K=(n-hdr+31)//32
        print(nm,n,'K',K,'header word',hex(tag | (K<<10) | (n<<32)), 'bytes',16+8*(n+K))
