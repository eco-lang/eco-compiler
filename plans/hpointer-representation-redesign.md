# HPointer Representation Redesign

## Status: IMPLEMENTED — full suite green (1555/1555), compiler bootstraps

Design resolved (D1-D11), impacted sites enumerated (§0-§8), empties-merge risk
investigated and closed (assessment section), work sequenced into phases P0-P3
with per-phase gates, testing/validation protocol defined.

### Implementation outcome

The representation flip is complete and validated: `cmake --build build --target
full` passes **1555/1555** tests (the E2E suite requires and exercises a full
compiler bootstrap from Elm source). New layout, absolute addressing, merged
empties, Bool-aligned-with-i1, `CONSTANT_TAG` dispatch, and the type-graph printer
all landed.

Delivered:
- **P0.1–P0.6** — low-address heap reservation (+ AddressSpaceReservationTest),
  centralized bit-access helpers, `CONSTANT_TAG` dispatch convention, type-driven
  printer, JSON restructure, whole-word equality. (Each landed green.)
- **P1.1–P1.6** — the atomic flip: Heap.hpp struct/enum/`PTR_IND_BIT`, resolve /
  from-toPointerRaw / readBarrier / forwarding (D8), all `constant!=0`→`ptr_ind`
  discrimination, builders/predicates, codegen (`value_enc`, box/unbox, case
  detect, PtrIntVerify, Ops.td), `Ops.elm` kinds, both kernel trees. Golden-word
  validation moved to runtime **HPointerLayoutTest** (`std::bit_cast` of a
  bit-field struct is not `constexpr`). Added `EcoPrimKind::Unit` so the typed
  printer renders `()`.
- **Bugs found & fixed during bring-up:** a stale `CONST_TRUE = 3ULL<<40` in
  `BytesExports.cpp::isLittleEndian` (caused endianness byte-swaps) → `boolValueBits`;
  a fusion-loop mis-projection of an unboxed scalar head as `!eco.value` (only
  surfaced because the new `ptr_ind` check rejects `resolve(7)`) → project head as
  `i64`/`f64` in `BytesFusion/Emit.elm`; and a test-only `HPointer{bits}`
  aggregate-init that relied on the old field order.
- **P3 docs** — invariants.csv (HEAP_008/010/012/017, REP_CONSTANT_001/002/003,
  FORBID_HEAP_001 rewritten; new HEAP_028 pointer≡address, HEAP_029 CONSTANT_TAG),
  THEORY.md pointer section + Forward comment, and superseding notes on the three
  theory/*.md files.

Deferred as safe follow-ups (NOT required by the goal; suite is green without
them): **P2.1** wholesale deletion of the heap-base sentinel (now vestigial —
under absolute addressing heap_base ≈ 1 TB ≠ 0, so it merely reserves 8 bytes at
heap_base; deleting it is risky GC surgery across ~8 OldGenSpace sites best done as
its own change), **P2.2** collapsing the `nil()/unit()/…`→`empty()` builder
aliases, and **P2.3** JIT-root/HPointer evacuation-path unification. The
representation-flip diagnostics (a couple of stale `<<40` comments) are the only
cosmetic residue.

## Goal

Change the `HPointer` bitfield layout and the pointer encoding convention so that:

1. **New bitfield layout.** From:

   ```c
   typedef struct {
       u64 ptr : POINTER_BITS;
       u64 constant : 4;  // Embedded constant index (0 = regular pointer, 1-15 encode constants).
       u64 padding : 20;  // Reserved for future use.
   } HPointer;
   ```

   To:

   ```c
   typedef struct {
       u64 constant : 2;  // 0 = False, 1 = True, 2 = Empty; meaningful only when ptr_ind==1.
       u64 ptr_ind : 1;   // FALSE (0) means this is a pointer, TRUE (1) means it is not.
       u64 ptr : POINTER_BITS;
       u64 enum : 10;     // Enum encoding (0 - 1023 enum index). NB: `enum` is a C++ keyword — rename in code.
       u64 padding : 11;  // Reserved for future use.
   } HPointer;
   ```

2. **Pointers are no longer shifted or offset — but the 8 TB reach is kept.**
   Today an `HPointer` stores a heap offset in 8-byte units: physical address =
   `heap_base + (ptr << 3)`, encode = `(obj - heap_base) >> 3`. In the new layout
   the `ptr` bitfield **starts at bit 3** (the `constant` field occupies bits 0-2).
   A heap object is 8-byte aligned, so its address already has bits 0-2 = 0 — those
   low bits coincide with a zero `constant` field, and the low **43 bits** of the
   word (`constant` ++ `ptr`) *are* the raw absolute address, no arithmetic. Decode
   = mask/reinterpret the low 43 bits (no `heap_base`, no shift — the bit-3 field
   offset supplies the ×8 for free); encode = store the raw aligned address and set
   the metadata bits. A 40-bit `ptr` at bit-offset 3 still addresses an 8 TB,
   8-byte-aligned heap.

3. **Elm `True`/`False` are aligned with the SSA/ABI `i1` representation.** Bool
   stays an embedded constant, but is encoded so the **low bit of the word is the
   `i1` value**: `Const_False = 0`, `Const_True = 1` in the `constant` field.
   Unbox to `i1` = read bit 0 (`word & 1`); box from `i1` = `(1 << PTR_IND_BIT) | i1`.
   The SSA (`i1`), ABI, and Heap views of Bool then all carry the same low bit.
   (`PTR_IND_BIT = 2`; see D1.)

4. **`ptr_ind` is the pointer/non-pointer discriminator.** Previously
   `constant != 0` meant "embedded constant"; that no longer works because
   `Const_False == 0`. Now `ptr_ind == 0` ⇒ this is a pointer (resolve it);
   `ptr_ind == 1` ⇒ not a pointer — read `constant` (and/or the new 10-bit `enum`
   field, 0-1023, reserved for user enums). The old `Const_X + 1` storage offset is
   **removed** (it only existed to keep `constant == 0` meaning "pointer").
   `constant` narrows 4→2 bits (0=False, 1=True, 2=Empty).

## Impacted Sites

> Gathered by parallel scan across compiler front end, backend codegen, runtime,
> and both kernel C++ trees. One line per site: location + change needed.

<!-- TABLE:BEGIN -->

### Legend

- **BREAK** = load-bearing; compiles wrong or miscomputes under the new layout.
- **STALE** = still compiles/correct, but comments/asserts/diagnostics reference
  the old `heap_base`/offset semantics and should be updated.
- **BOOL** = tied to the "align True/False with SSA/ABI" change (see D3/D4).

---

### 0. Core definition — `runtime/src/allocator/Heap.hpp`

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| Heap.hpp:64 | `#define POINTER_BITS 40` — width of `HPointer.ptr` and `Forward.forward_ptr` | Keep 40 but it now holds a raw absolute 8-byte-aligned address, not a `>>3` offset; confirm 40 bits still covers the address range unshifted | BREAK |
| Heap.hpp:153-161 | `Constant` enum: Unit,EmptyRec,True,False,Nil,Nothing,EmptyString (7, stored +1) | Replace with bit-flag enum `Const_False=0, Const_True=1, Const_Empty=2` (D3); drop the `+1` offset; collapse the 5 empties into `Const_Empty` | BREAK/BOOL |
| Heap.hpp:164-168 | `HPointer { ptr:40; constant:4; padding:20; }` | Replace with `{ constant:2; ptr_ind:1; ptr:40; enum:10; padding:11; }` (rename `enum` — C++ keyword) | BREAK |
| Heap.hpp:166-167 | Comment "constant 1-15", padding "reserved" | Update: constant is 2-bit (0=False,1=True,2=Empty); document `ptr_ind`, `enum`, 11-bit padding | STALE |
| Heap.hpp:169 | `static_assert(sizeof(HPointer)==8)` | Re-verify 2+1+40+10+11 = 64 bits | BREAK |
| Heap.hpp:472 | `Forward.forward_ptr : POINTER_BITS` stores `>>3` offset | Store raw absolute address (no shift); update all forward_ptr encode/decode | BREAK |
| Heap.hpp:83 / 115-117 | Comment: heap-base sentinel identified by address | Update/remove with sentinel mechanism (see §1) | STALE |

### 1. Runtime allocator / GC — `runtime/src/allocator/`

**Encode/decode core (the shift + heap_base removal):**

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| Allocator.hpp:172-175 | Comment: decode = `heap_base + (ptr<<3)` | Doc: raw absolute address, no base/shift | STALE |
| Allocator.hpp:339-344 | `fromPointerRaw`: assert `constant==0`; `heap_base + (ptr<<3)` | Decode = raw `ptr` (no shift, no base add) | BREAK |
| Allocator.hpp:346-356 | `toPointerRaw`: `(obj-heap_base)>>3`; sets constant/padding=0 | Encode = raw address (no sub/shift); zero new `ptr_ind`/`enum`/`padding` | BREAK |
| Allocator.cpp:793-794 | resolve forward-follow: `forward_ptr<<3` + heap_base | Decode forward_ptr as raw address | BREAK |
| OldGenSpace.cpp:174 | readBarrier: `g_heap_base + (ptr.ptr<<3)` | Decode = raw `ptr.ptr` | BREAK |
| OldGenSpace.cpp:3915-3916 | `installForwardingPointer`: `(new_ptr-g_heap_base)>>3` | Store raw absolute address | BREAK |
| OldGenSpace.cpp:3923 | `getForwardingAddress`: `g_heap_base + (forward_ptr<<3)` | Decode as raw address | BREAK |
| NurserySpace.cpp:1113-1114, 1297-1310, 1759-1760 | forward decode `forward_ptr<<3` + heap_base | Raw absolute decode (3 sites) | BREAK |
| NurserySpace.cpp:1252-1253, 1357-1358, 1835 | forward encode `(new_obj-heap_base)>>3` | Raw absolute encode (3 sites) | BREAK |
| NurserySpace.cpp:2126-2129 | debug `hptr_val=(ptr-heap_base)/8` | Update debug math for raw addressing | STALE |

**JIT-root / bit-packing (old `>>40` / `<<40` / `0xFF..FF` field offsets):**

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| OldGenSpace.cpp:1658-1660 | JIT root const test `(val>>40)&0xF` in 1-7, low-40==0 | Rewrite: constant now bits 0-2, ptr above it | BREAK |
| NurserySpace.cpp:1276-1281 | `evacuateJitPtr` const test: low-40==0 & `(val>>40)&0xF` | Rewrite for new bit layout | BREAK |
| RuntimeExports.cpp:1066-1068 | pack: `ptr=val&0xFF..FF; constant=(val>>40)&0xF` | Rewrite (constant bits 0-2, ptr shifted); zero new fields | BREAK |
| RuntimeExports.cpp:2181-2233, 2262-2263 | `print_if_constant`/`is_nil`: `val&0xFF..FF`, `val>>40`, range 1-7 | Rewrite bit-extraction; remove Bool cases; reindex Nil | BREAK/BOOL |
| RuntimeExports.cpp:2325-2333, 2457-2458, 2778 | head/tail/DynRecord pack `ptr | (constant<<40)` | Rewrite packing for new field offsets (4 sites) | BREAK |
| RuntimeExports.cpp:2758-2760 | const test `&0xFF..FF` / `>>40` range 1-7 | Rewrite for new layout | BREAK |

**Constant enum reindex + Bool-as-constant helpers:**

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| HeapHelpers.hpp:163-235 | `nil/unit/nothing/emptyString/emptyRecord()` set `constant=Const_X+1; padding=0` | **Collapse all 5 into one `empty()` builder**: `ptr_ind=1, constant=Const_Empty(2)`; zero `enum`/`padding` (drop `+1`) | BREAK |
| HeapHelpers.hpp:185-202 | `elmTrue()`/`elmFalse()`: `constant=Const_True/False+1` | Re-encode (Bool stays a constant): `ptr_ind=1, constant=Const_True(1)/Const_False(0)`; zero enum/padding | BOOL |
| HeapHelpers.hpp:247-253 | `isNil`/`isEmptyString`: `constant==Const_X+1` | Collapse to one `isEmpty`: `ptr_ind && (constant & EMPTY_BIT)` | BREAK |
| HeapHelpers.hpp:240-242 | `isConstant`: `constant != 0` | `return h.ptr_ind != 0;` (D2) | BREAK |
| HeapHelpers.hpp:255-258 | `isEmbeddedConstant`: comment "1-7" | Rewrite to `ptr_ind`-based; update comment | BREAK |
| StringOps.hpp:159-160 | `isEmpty`: `constant==Const_EmptyString+1` | Use unified `isEmpty` (ptr_ind + EMPTY_BIT) | BREAK |
| ElmBytesRuntime.cpp:114, 160 | `constant==Const_EmptyString+1` | Use unified `isEmpty` (2 sites) | BREAK |
| ListOps.cpp:521-522 | `member`: compares `value.p.ptr==...` and `.constant==...` for Bool | Compare via new Bool encoding (ptr_ind + bit0); review pointer-identity path | BOOL |
| RuntimeExports.cpp:2170-2176 | `MlirConst_*` enum (True=3..EmptyString=7) | Replace with False=0/True=1/Empty=2 bit-flag scheme | BREAK/BOOL |
| RuntimeExports.cpp:3280-3290 | `eco_get_tag`: hardcoded `constant==6`(Nothing) + Bool-as-constant path | Rewrite: `ptr_ind` gate, decode bit-flags; empties now indistinguishable (see D3 risk) | BREAK/BOOL |
| RuntimeExports.cpp:2155-2156 | prints Bool via `EcoPrimKind::Bool` → "True"/"False" | Confirm aligns with new Bool rep | BOOL |
| TypeInfo.hpp:95 | `EcoPrimKind::Bool` primitive kind | Confirm Bool ABI/SSA rep alignment | BOOL |

**Heap-base sentinel mechanism (exists only because `ptr=0` ≡ `heap_base+0`):**

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| OldGenSpace.hpp:187-202, 874-883 | `HEAP_BASE_SENTINEL_SIZE`, `isHeapBasePage`, `installHeapBaseSentinel` decls/doc | Revisit/remove — rationale invalid under raw addressing | BREAK |
| OldGenSpace.cpp:374-379, 410-424, 1202-1233, 1303-1330, 1478, 2003-2015, 2620-2629, 3251-3254 | Sentinel install/reserve/skip + "avoid heap_base+0" defenses | Revisit/remove entire sentinel mechanism (8 site-clusters) | BREAK |
| ThreadLocalHeap.cpp:717-719 | Comment "resolve(null) dereferences heap_base"; `ptr==0` guard | Comment stale; guard still valid | STALE |

**Struct field-init sites that omit the new `ptr_ind`/`enum` fields:**

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| ThreadLocalHeap.cpp:315-320, 353-355 | large String/ByteBuffer body: `.constant/.ptr/.padding=0` | Zero new `ptr_ind`/`enum` fields too (2 sites) | BREAK |

**Discrimination guards — ALL change `constant`→`ptr_ind` (BREAK, per D2).** Each
`hp.constant != 0` / `== 0` currently means "is/isn't an embedded constant"; because
`Const_False == 0` this must now test `hp.ptr_ind`. Sites: Allocator.cpp:367;
OldGenSpace.cpp:171, 1824, 4097, 4333, 4345; NurserySpace.cpp:745, 858, 1052-1057,
1369, 1547, 1582, 1645, 1741-1750, 1793, 1853, 1891; ThreadLocalHeap.cpp:712;
RuntimeExports.cpp:1393, 1781, 3609; ElmBytesRuntime.cpp:52-57. (The `ptr == 0` null
test stays valid.)

### 2. Runtime codegen backend — `runtime/src/codegen/`

> The MLIR→LLVM lowering does **not** contain the `<<3`/heap_base arithmetic
> (that lives in the runtime allocator). It only manipulates HPointer bits inline
> for the **embedded-constant** path. So change #1 is invisible here; changes #2/#4
> (constant-field position swap + Bool) land in the sites below.

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| Passes/EcoToLLVMInternal.h:172 | `HeapOffsetBits = 40` doubles as const-field shift | Positions swap; split into pointer-width vs `ConstFieldShift=0` | BREAK |
| Passes/EcoToLLVMInternal.h:175 | `ConstFieldShift = 40` | Constant now low 2 bits (bits 0-1) → `ConstFieldShift = 0` | BREAK |
| Passes/EcoToLLVMInternal.h:177-178 | `ConstFieldMask = 0xF` (4-bit) | Narrow to `0x3` (2-bit); constants False/True/Empty | BREAK |
| Passes/EcoToLLVMInternal.h:181-194 | `ConstantKind` enum (1-7) + `encodeConstant(kind)=kind<<40` | Enum → False=0/True=1/Empty=2; `encodeConstant(kind) = kind | (1<<PTR_IND_BIT)` (constant low bits + ptr_ind set) | BREAK/BOOL |
| Passes/EcoToLLVMTypes.cpp:35-39, 72-74 | `eco.constant`/empty-string → `encodeConstant`→inttoptr | Follows new encode; verify bit pattern (2 sites) | BREAK |
| Passes/EcoToLLVMControlFlow.cpp:376 | `emptyStringVal = EmptyString << ConstFieldShift` (open-coded `<<40`) | Use `encodeConstant` (shift now 0) | BREAK |
| Passes/EcoToLLVMControlFlow.cpp:451-455 | string-case truth test builds `True` embedded const, `icmp eq` | Use new Bool rep, not embedded-constant compare | BOOL |
| Passes/EcoToLLVMControlFlow.cpp:625-644 | ADT case const-detect: `lshr scrutinee,40`, `and 0xF`, `icmp ne 0`; Nil=5 map | Detect via `ptr_ind` (bit 2): `(word>>2)&1`; empties → `Const_Empty` (D3) | BREAK |
| Passes/EcoToLLVMHeap.cpp:119-128 | `eco.box` of i1 → embedded `True`/`False` HPointer (select) | `word = (1<<2) | zext(i1)` (D4) | BOOL |
| Passes/EcoToLLVMHeap.cpp:162-171 | `eco.unbox` to i1 → `icmp eq` vs embedded `True` | `i1 = trunc(word & 1)` (D4) | BOOL |
| Passes/EcoPtrIntVerify.cpp:57-67 | `isEmbeddedConstant`: literal == `encodeConstant(kind)` 1..7 | Update comment/loop; follows encode change; True/False may leave | BREAK/BOOL |
| Ops.td:227-239 | `Eco_ConstantKind` I32EnumAttr (1-7) | Doc 2-bit field (False=0/True=1/Empty=2) + position swap | BREAK/BOOL |
| Ops.td:1659-1679 | `Eco_ConstantOp` doc: "constant in bits 40-43", examples `Nil→5<<40` | Rewrite: constant bits 0-2, ptr above, new fields; drop `<<40` | STALE |

### 3. Runtime platform + `main.cpp`

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| main.cpp:220-226 | `createNil()` hand-builds Nil HPointer field-by-field (`.ptr/.constant/.padding`) | Leaves new `ptr_ind`/`enum` uninitialized; zero them or delegate to `alloc::listNil()` | BREAK |
| main.cpp:276 | `while (list.constant != Const_Nil)` end-of-list | Field auto-adjusts; verify Const_Nil value; prefer `alloc::isNil` | STALE |
| platform/Scheduler.cpp:27-34 | `isConstant(h)=h.constant!=0` gates `resolveHP` | Test `h.ptr_ind != 0` (D2) | BREAK |
| platform/PlatformRuntime.cpp:35-42 | `hpIsConstant(h)=h.constant!=0` + resolve | Test `h.ptr_ind != 0` (D2) | BREAK |
| platform/PortRuntime.cpp:56-59 | inline `if (h.constant!=0) return nullptr` | Test `h.ptr_ind != 0` (D2) | BREAK |

> `encodeHP`/`decodeHP` union punning and all `alloc::` helper call sites in platform are bit-preserving / helper-mediated — no change if helpers are updated.

### 4. Runtime embed / jit — `runtime/src/embed/`, `runtime/src/jit/`

**No impacted sites.** Both cross values as pre-serialized JSON / opaque `void*` slots; no HPointer field, `Constant` enum, `POINTER_BITS`, or heap_base arithmetic. (`EcoJIT.cpp` `Constant::` calls are `llvm::Constant`, not the Elm enum.)

### 5. Compiler front end — `compiler/src/` (`.elm`)

> The compiler is **insulated from the physical bit layout**: it emits abstract
> ops (`eco.constant kind=N`, `eco.box`, `eco.unbox`, `eco.bool.*`); no `heap_base`,
> pointer `<<3`, `inttoptr`, or `POINTER_BITS` in codegen. So change #1 needs **zero
> .elm edits**. The coupling is the constant index table + the Bool box/unbox contract.

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| Generate/MLIR/Ops.elm:108-120 | Doc: embedded-constant numbering Unit=1..EmptyString=7 | Rewrite to bit-flag scheme: False=0/True=1/Empty=2 (D3) | BREAK |
| Generate/MLIR/Ops.elm:142-156 | `ecoConstantTrue`=3 / `ecoConstantFalse`=4 | Re-number True=1/False=0 to match new Bool rep (D3/D4) | BOOL |
| Generate/MLIR/Ops.elm:123-186 | `ecoConstantUnit/EmptyRec/Nil/Nothing/EmptyString` (1,2,5,6,7) | All emit the same `Const_Empty=2` kind — collapse the 5 emitters to one (or map all to Empty) | BREAK |
| Generate/MLIR/Types.elm:159-177 | `monoTypeToAbi`: Bool → `!eco.value` at ABI | Contract True/False encoding must satisfy; verify (no code change) | BOOL |
| Generate/MLIR/Types.elm:204-205 | `monoTypeToOperand`: Bool → `i1` in SSA | i1↔eco.value bridge must target new True/False encoding | BOOL |
| Generate/MLIR/Intrinsics.elm:256-272 | `unboxToType` emits `eco.unbox` (Bool) | Runtime lowering must decode new low-bit constant; verify | BOOL |
| Generate/MLIR/Patterns.elm:154-186, 219, 301-307 | `Test.IsBool` + Bool var unbox; pattern EmptyString | Verify Bool test / EmptyString lowering vs new rep | BOOL |
| Generate/MLIR/Expr.elm:1175, 3029, 3094, 3637 | `eco.box`/`eco.unbox` of i1 Bool at boundaries | Verify box path produces new True/False HPointer | BOOL |
| Generate/MLIR/Functions.elm:968-975, 1061-1068 | nullary-ctor: "True"/"False"/"Nothing" → eco.constant* | Where Elm True/False literals get encoded; keep aligned | BOOL |
| Generate/MLIR/{Functions,Expr,Patterns,BytesFusion/Emit}.elm | Many `ecoConstant{Unit,Nil,Nothing,EmptyRec,EmptyString}` emit sites | Verify each against retained constant indices | BREAK |

### 6. elm-kernel-cpp — `elm-kernel-cpp/src/`

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| ExportHelpers.hpp:20 | Comment `[ptr:40 | constant:4 | padding:20]` | Update to new layout | STALE |
| ExportHelpers.hpp:47-83 | `toPtr()` heuristic: `constant 1-7` embedded, `constant!=0`/`padding!=0` ⇒ raw ptr | Rewrite: discriminate on `ptr_ind` (bit 2); constant is low 2 bits; ptr raw absolute; padding 11-bit | BREAK |
| ExportHelpers.hpp:94-105 | `encodeBoxedBool`/`decodeBoxedBool` via True/False embedded const | Emit/read new Bool encoding | BOOL |
| core/UtilsExports.cpp:48-53, 59-109 | `equalRespectingConstants` tests `constant 1..7` + all compare ops return Bool | Update constant-field access; Bool via new rep | BREAK/BOOL |
| core/Utils.cpp:182-189 | `.constant == Const_EmptyString+1` (2 reads) | Constant field moved to low bits | BREAK |
| core/BasicsExports.cpp:213-233 | isInfinite/isNaN/and/or/xor/not encode/decode Bool | New Bool encoding (6 ops) | BOOL |
| core/StringExports.cpp:21, 203; 107-299 | EmptyString const read + comment + Bool results | Reindex; Bool via new rep | BREAK/BOOL |
| parser/ParserExports.cpp:94, 133 | Bool encode/decode | New Bool encoding | BOOL |
| regex/RegexExports.cpp:52, 189-238 | EmptyString read + record Bool fields | Reindex; new Bool rep | BREAK/BOOL |
| bytes/Bytes.cpp:23; BytesExports.cpp:303, 424 | Nothing/EmptyString reads; `constant!=0` guard | Constant field moved (3 sites) | BREAK |
| http/HttpExports.cpp:117, 138; HttpEffectManager.cpp:45 | EmptyString read + `constant!=0` guards | Constant field moved (3 sites) | BREAK |
| core/ListExports.cpp:269, 313; PlatformExports.cpp:90, 112 | `constant!=0` guards | Constant field moved (4 sites) | STALE |
| core/JsArrayExports.cpp:283 | `constant==0 && ptr!=0` reads both fields | Constant moved; `.ptr` now absolute (`!=0` semantics shift) | BREAK |
| json/JsonExports.cpp:103, 202-1589 | Many EmptyString/Nil/Unit reads, Bool reads via `constant==Const_True+1`, elmTrue/elmFalse writes, `constant!=0` guards | Reindex constants; Bool via new rep (~12 sites) | BREAK/BOOL |
| virtual-dom/VirtualDom.hpp:60 | `HPointer jsonValue{0, Const_Nil+1, 0}` positional init in OLD field order | Field reorder breaks positional init; use designated init | BREAK |

> No kernel site does direct `<<3`/heap_base arithmetic — all address resolution
> goes through `resolve()`/`wrap()`. `encode()`/`decode()` union puns are layout-agnostic.

### 7. eco-kernel-cpp — `eco-kernel-cpp/src/`

| Site | Current behavior | Change needed | Kind |
|---|---|---|---|
| eco/ExportHelpers.hpp:39 | `if (h.constant != 0) return nullptr` discrimination | Constant narrows/moves, overlaps low bits of raw ptr; rework via helper | BREAK |
| eco/ExportHelpers.hpp:40 | `assert(h.padding == 0)` | Wrong once `enum`/`ptr_ind` carry data; update to new layout | BREAK |
| eco/ExportHelpers.hpp:52-58 | `encodeBoxedBool`/`decodeBoxedBool` via True/False embedded const | New Bool rep | BOOL |
| eco/KernelHelpers.hpp:40 | `toString`: `constant == Const_EmptyString+1` | Reindex / new predicate | BREAK |
| eco/KernelHelpers.hpp:121 | `taskSucceedBool`: `elmTrue()/elmFalse()` | New Bool rep | BOOL |
| eco/KernelHelpers.hpp:179; Http.cpp:90 | Nil-terminator: `current.constant != Const_Nil+1` | Reindex / new predicate (2 sites) | BREAK |
| eco/TaskBinding.hpp:64; File.cpp:126, 135, 544 | `succeedBool`/`decodeBoxedBool` construct/read Bool | New Bool rep (4 sites) | BOOL |
| eco/KernelExports.h:9, 88, 91, 116 | Docs: "Bool as HPtr True/False constants per REP_ABI_001" | Update ABI docs to new Bool rep | STALE/BOOL |

> No direct `<<3`/heap_base/`.ptr` arithmetic; Unit/Nothing/Nil/EmptyRec construction is fully helper-mediated (re-encoded centrally, call sites unchanged).

### 8. Design docs / invariants

| Invariant / Site | Current statement | Change needed | Kind |
|---|---|---|---|
| invariants.csv:382 (HEAP_008) | ptr is a 40-bit offset from heap_base; logical not raw | Rewrite: ptr is a raw absolute address; no heap_base | BREAK |
| invariants.csv:400 (HEAP_017) | `ptr==0 && constant==0` ⇒ valid ptr to offset 0, not null | Reword: no "offset 0" under absolute addressing | BREAK |
| invariants.csv:390 (HEAP_012) | `isInHeap` O(1) bounds check vs heap_base+reserved | Reword for absolute-address bounds check | STALE |
| invariants.csv:527 (FORBID_HEAP_002) | no HPointer arithmetic except via helpers (cites HEAP_008) | Verify; dependency HEAP_008 rewritten | STALE |
| invariants.csv:386 (HEAP_010) | constants (incl. True/False) as **nonzero** `constant` tags | Discriminator is now `ptr_ind` (False has constant 0); 2-bit set False=0/True=1/Empty=2; the 5 empties merged | BREAK/BOOL |
| invariants.csv:50-54 (REP_CONSTANT_001/002/003) | constants incl. True/False as nonzero constant bits; comparable set = EmptyString/Nil | True/False **stay** (re-encoded 0/1); empties merge to one `Const_Empty`; discriminator is `ptr_ind`; comparable-constant wording now covers merged Empty | BREAK/BOOL |
| invariants.csv:9 (REP_ABI_001) | Bool crosses ABI as `!eco.value` | **Survives** (D10) — Bool stays boxed; update encoding note only | BOOL |
| invariants.csv:27 (REP_CLOSURE_001) | Bool stored as `!eco.value` (kind 00) | **Survives** (D10) — encoding note only | BOOL |
| invariants.csv:238-244 (CGEN_009/012) | Bool = `!eco.value` at ABI/heap/closure; MBool→eco.value | **Survives** (D10) — encoding note only | BOOL |
| invariants.csv:529 (FORBID_CLOSURE_001) | Bool must be `!eco.value` in heap/closures | **Survives** (D10) — the boxed constant's bit pattern changes, not Bool's boxedness | BOOL |
| THEORY.md:144-162 | "Logical Pointers: 40-bit Offsets" + old struct + heap_base | Rewrite wholesale (new struct, raw addressing) | BREAK |
| THEORY.md:116 | `forward_ptr:40 // Logical pointer` (stored `>>3`) | Update to raw absolute | BREAK |
| THEORY.md:158, 83 | Embedded constants incl. True/False; `constant!=0` skip in marking | Re-list constants (False/True/Empty); marking skip test becomes `ptr_ind` | BREAK/BOOL |
| theory/heap_representation_theory.md:26-30, 46-49, 67, 92, 245-270 | Bool = `!eco.value` embedded True/False const; 40-bit tagged word; value table Unit=1..EmptyRec=9 | Rewrite Bool sections (i1 low-bit alignment); replace value table with False=0/True=1/Empty=2; all empties merged | BREAK/BOOL |
| theory/pass_eco_to_llvm_theory.md:69-71, 97-131 | `ConstFieldShift=40`; bit diagram bits 0-39 offset / 40-43 constant 1-15; table `1<<40` | Rewrite: constant bits 0-1 + `ptr_ind` bit 2 + ptr bits 3-42 (no `<<40`), ptr absolute, discriminator `ptr_ind` | BREAK |
| theory/json_heap_representation_theory.md:38-114 | JSON bool stores True/False embedded constants (REP_ABI_001) | Review/rewrite per Bool change | BOOL |

<!-- TABLE:END -->

## Design Decisions (resolved)

### D1. New `HPointer` layout, field offsets, and pointer resolve

```
bit:  0   1 | 2       | 3 ............... 42 | 43 ...... 52 | 53 ...... 63
     [const ]|[ptr_ind]|[      ptr (40)      ]|[  enum (10) ]|[ padding(11) ]
```

- `PTR_IND_BIT = 2` (constant occupies bits 0-1; `ptr_ind` sits just above it,
  below `ptr`).
- **Discriminator:** `ptr_ind == 0` ⇒ pointer; `ptr_ind == 1` ⇒ not a pointer
  (constant and/or enum).
- **Resolve (decode) a pointer:** the low 43 bits (`constant` ++ `ptr_ind` ++
  `ptr`) already *are* the 8-byte-aligned absolute address, because a real
  object's low 3 bits are 0 (`constant==0`, `ptr_ind==0`) and land in those zero
  fields — and since encode also zeroes `enum`/`padding`, **the whole word is the
  address**: decode is a reinterpret, not arithmetic (see D6; the mask
  `word & ((1ULL << 43) - 1)` is the defensive form for debug asserts). **No
  `heap_base`, no `<< 3`.** The bit-3 `ptr` offset supplies the ×8; 40-bit `ptr`
  still reaches 8 TB.
- **Encode (a pointer):** store the raw aligned address into the word (its low 3
  bits are already 0), `ptr_ind = 0`, `enum = 0`, `padding = 0`.
- Same rule applies to `Forward.forward_ptr` (was stored `>> 3` — now raw).

### D2. `ptr_ind` replaces every `constant != 0` discrimination — **global BREAK**

The old idiom "`hp.constant != 0` ⇒ embedded constant, else pointer" is **invalid**
because `Const_False == 0`. Every such test — in the allocator (§1 guard list),
platform (§3), and both kernels (§6/§7) — must become an `hp.ptr_ind` test.
`isConstant(h)` ⇒ `return h.ptr_ind != 0;`. The `ptr == 0` **null** test stays
valid. **Reclassify all "still-compiles" `constant != 0` rows in the tables from
STALE to BREAK.** (The `+1` storage offset on stored constants is also removed,
since it only existed to reserve `constant == 0` for pointers.)

### D3. `constant` is a bit-mask, not an enum index — Bool + unified Empty

The 2-bit `constant` field is interpreted as flags (only meaningful when
`ptr_ind == 1`):

| bit | meaning |
|---|---|
| 0 | **Bool value** — `0 = False`, `1 = True` |
| 1 | **Empty** — the single unified empty/nullary constant |

Concrete values: `Const_False = 0b00 = 0`, `Const_True = 0b01 = 1`,
`Const_Empty = 0b10 = 2`. The new enum:

```c
typedef enum {
    Const_False = 0,   // bit0 clear
    Const_True  = 1,   // bit0 set
    Const_Empty = 2,   // bit1 set — unifies Unit, EmptyRec, Nil, Nothing, EmptyString
} Constant;
```

- **True/False are merged into bit 0** so the word's low bit equals the SSA/ABI
  `i1` value.
- **All five nullary/empty constants collapse into `Const_Empty` (bit 1):** Unit
  `()`, EmptyRec `{}`, Nil `[]`, Nothing, and `""`. The type checker guarantees
  each is only produced/matched where its type is expected, so a shared bit pattern
  is safe. The old `Const_Unit/EmptyRec/Nil/Nothing/EmptyString` names collapse to
  `Const_Empty` (predicates `isNil`/`isEmptyString`/… all become `isEmpty`).
- **RISK — investigated and RESOLVED (viable): see "Assessment: merging the empty
  constants" below.** Runtime consumers that inspect a constant without type context
  were audited: case/decision-tree dispatch is type-directed (fixable, and a
  cleanup — retires the `eco_get_tag` `Nothing→1` hack), the real `Debug.toString`
  path is type-graph driven, structural `==` is homogeneous, and the JSON encoder
  only ever sees `Const_EmptyString`/Bool. The **only** irrecoverable loss is
  display fidelity in the *type-erased fallback* printer (legacy Debug path) — a
  non-semantic, display-only regression. Net: merge is recommended over the
  distinct-enum-index alternative.

### D4. Bool box / unbox (SSA `i1` ↔ boxed constant)

- **unbox → i1:** `i1 = (word & 1)` (bit 0). `False→0`, `True→1`.
- **box i1 →:** `word = (1ULL << PTR_IND_BIT) | (u64)i1`.
- Realized in runtime lowering `EcoToLLVMHeap.cpp` (`eco.box`/`eco.unbox` of i1)
  and the C++ `encode/decodeBoxedBool` helpers. Compiler stays abstract (no change).

### D5. Heap-base sentinel removed entirely

The `installHeapBaseSentinel` / `isHeapBasePage` / "never hand out heap_base+0"
machinery existed *only* because `HPointer{ptr=0}` decoded to `heap_base+0`. Under
raw absolute addressing, address 0 is simply null and never a valid object, so this
mechanism is **deleted wholesale** (§1, ~10 site-clusters in OldGenSpace).

## Assessment: merging the empty constants (deep-dive)

**Verdict: merging Unit/EmptyRec/Nil/Nothing/EmptyString into one `Const_Empty` is
VIABLE and recommended.** It causes **no correctness loss in well-typed code**. The
only genuine regression is *display fidelity in a type-erased debug-printer
fallback*; every other consumer either has static type context, has the type graph,
or is homogeneous. Several of the required edits are net simplifications.

### Why it holds: how nullary constructors are actually represented

The investigation established the load-bearing fact (Utils.cpp:33-49, Functions.elm
:966-981, Ops.elm:112-118):

- **Only the 7 magic built-ins are embedded HPointer constants.** *Every*
  user-defined and library nullary constructor is a heap `Tag_Custom` with a
  distinct `ctor` — e.g. `Order` (`LT|EQ|GT`) is three pre-allocated heap singletons
  with ctor 0/1/2; `type Color = Red|Green|Blue` → three heap objects. Merging
  cannot touch user ADTs.
- **Each of the 5 empties is the *sole* embedded constant of a *distinct* type**
  (`()`, `{}`, `List`, `Maybe`, `String`); the co-constructor (Cons, Just, non-empty
  string) is always a heap object. **Bool is the only type with two embedded
  constants** — handled separately by bit 0. So within any monomorphic non-Bool
  type, "is the scrutinee an embedded constant?" (`ptr_ind`) *uniquely* identifies
  the nullary constructor. Type context always disambiguates *which* empty it is.

### Consumer-by-consumer impact

| Consumer | file:line | Category | Impact under merge | Fix |
|---|---|---|---|---|
| Inlined `eco.case` ctor dispatch | EcoToLLVMControlFlow.cpp:624-671 | type-directed (scrutinee type known; `tags` from `CtorTag.effective`) | Special-cases `Nil==5` to derive a tag from `constField` | Dispatch on constant-vs-heap (`ptr_ind`) → branch to the type's known nullary arm; drop the `Nil==5`/`constField`→tag logic | 
| Decision-tree ctor tests | Patterns.elm:138 (`IsCtor`), 241 (`IsCons`), 263 (`IsNil`); BytesFusion/Emit.elm:694 | type-directed | `eco_get_tag`'s `Nothing→1` vs `Nil→0` can't survive one shared pattern → exactly one of IsNil/IsCtor(Nothing) misdispatches | Emit a type-directed emptiness test (`ptr_ind`) for embedded-constant ctors instead of `eco_get_tag`+numeric compare; **retire `eco_get_tag`'s constant hack** |
| `eco_get_tag` | RuntimeExports.cpp:3285-3290 | — | hardcoded `constant==6`→1 becomes unrecoverable | Retire the embedded-constant branch (callers stop needing it); keep the heap-ctor path |
| **Type-driven** printer (real `Debug.toString`/`log`) | RuntimeExports.cpp:2982 (Custom), 2730 (Prim/String), List@2753, Record | type-graph-driven (`type_id` threaded to every node) | Currently *chooses* to name empties via `print_if_constant`; the graph already has ctor names/field-counts | Name the nullary ctor from the type graph (find the 0-field ctor); List/String/Record already know their empty. ~3 local sites — a cleanup |
| Structural `==` | UtilsExports.cpp:47-56; Utils.cpp:178-197 | homogeneous | Safe: True/False stay distinct (0/1); two empties compare equal only within the same type, which is all Elm allows | none (constant compare still works: Empty==2) |
| Typed kernel isEmpty/isNil checks | String/Bytes/Json/Http/Regex, eco-kernel | type-known at the call | The "which empty" is fixed by the type → collapses to one `isEmpty` predicate | mechanical (already in §1/§6/§7) |
| JSON decode (`JsonValue` ADT) | JsonExports.cpp:412-660 | ctor-typed (CTOR_JSON_*) | Safe — never reads empty-constant identity (only the unmerged Bool) | none |
| JSON encode (`wrap`/`elmToJson`) | JsonExports.cpp:1251-1260, 1555-1590 | untyped, but per-primitive | Only `Const_EmptyString` (from `string ""`) and Bool actually reach it; empty array/object/null are heap `ENC_*` nodes. Empty(2) stays distinct from Bool(0/1) | map merged-empty→`ENC_STRING ""`; delete the unreachable defensive Nil/null multi-way |
| **Type-erased fallback** printer | RuntimeExports.cpp:2181 `print_if_constant`, reached by legacy `eco_print_value` | type-erased | **Genuine, irrecoverable loss**: cannot tell `()`/`{}`/`[]`/`Nothing`/`""` apart | none possible — **display-only**; print a generic token (e.g. `<empty>`). Not reached by the native typed Debug path |

### Key mechanisms in detail

#### (a) The two debug-printer paths

The runtime has **two independent printer families**, and this split is what makes
the merge safe:

1. **Type-driven** — `print_typed_value(value, type_id, depth)` (RuntimeExports.cpp
   :2710), entered via `eco_dbg_print_typed` (:2692) and `eco_value_to_string_typed`
   (:3165). It threads a compile-time `type_id` into a global type graph
   (`g_type_graph`, registered by `eco_register_type_graph` :2657; layout in
   `TypeInfo.hpp`) and recursively carries the static Elm type down through every
   list element, tuple slot, record field, and constructor argument (Records use
   `field->type_id` :2964; Custom names ctors from the graph :3024).
2. **Value-driven** — `print_value` (:2482) / `print_if_constant` (:2181) /
   `print_list`, entered via `eco_print_elm_value` (:3103). **No type**: dispatches
   purely on `Header::tag` and the embedded-constant field.

**Native compiled `Debug.toString`/`Debug.log` reach the TYPE-DRIVEN path.** The
compiler emits a `type_id`: `Debug.toString` at Expr.elm:3065-3127 →
`Elm_Kernel_Debug_toString(value, type_id)` → DebugExports.cpp:56 →
`eco_value_to_string_typed`; `Debug.log` at Expr.elm:2993-3060 emits an `eco.dbg`
op with an `arg_type_ids` attribute → `eco_dbg_print_typed`. The untyped
`eco_print_elm_value` path is the legacy Guida/JS-bootstrap symbol, not what native
Elm reaches.

So the static type is present at every node of the real output — the type-driven
printer *currently chooses* to name empties via `print_if_constant` (:2982, :2730)
purely out of convenience; it already has everything needed to name them from the
graph (the type's zero-field ctor). Retargeting those ~3 sites is a cleanup, not new
machinery.

#### (b) The `eco_get_tag` / `CtorTag` dispatch contract

Decision-tree pattern matching (`Patterns.elm`) tests one constructor at a time:
it emits `%tag = eco.get_tag %val` then `%tag == CtorTag.effective(home,ctor,index)`.
`CtorTag.effective` (CtorTag.elm:60) is the constructor's **zero-based declaration
index** (except reserved Dict/Set markers). `Maybe = Just a | Nothing`, so
`Nothing = index 1` — which is exactly why `eco_get_tag` hardcodes `constant==6 →
1` and every-other-constant → 0 (RuntimeExports.cpp:3285-3290). `IsNil` compares
against 0, `IsCtor(Nothing)` against 1.

**Why merge breaks it:** `eco_get_tag` receives only the value (no type), so one
shared empty bit pattern must return one number — but `Nil`-context needs 0 and
`Nothing`-context needs 1. Exactly one of the two tests misdispatches.

**Why you can't just remap the empty to a fixed tag:** `Just` already occupies heap
ctor 0, so the empty can't also be "tag 0" without colliding — the discrimination
that actually matters is *heap-vs-constant*, not a numeric tag.

**The fix (a net simplification):** all four `eco.get_tag` callers (Patterns.elm:138
`IsCtor`, :241 `IsCons`, :263 `IsNil`; BytesFusion/Emit.elm:694) have **static type
context**. For a constructor that is an embedded constant, the compiler emits a
type-directed emptiness test (`ptr_ind`) — unambiguous within the known monomorphic
type — instead of an `eco_get_tag`+compare. `IsCons`/heap ctors keep reading the
heap `ctor`. The inlined `eco.case` path (CaseOpLowering, EcoToLLVMControlFlow.cpp
:624-671) has the same shape: it also branches on the concrete `value_enc::Nil == 5`
(:640) and must instead dispatch constant-vs-heap. `eco_get_tag`'s `Nothing→1`
special case is then retired.

#### (c) The JSON encode path

JSON *decode* is fully ctor-typed: parsed values are `Tag_Custom` with dedicated
ctors `CTOR_JSON_NULL=100 … CTOR_JSON_OBJECT=106` (JsonExports.cpp:48-54), dispatched
by `jctor`/`c->ctor` (:412-459, :578-660) — it never reads empty-constant identity
(only the unmerged Bool inside a `CTOR_JSON_BOOL` node).

JSON *encode* funnels `Json.Encode.string/int/float/bool` through
`Elm_Kernel_Json_wrap` (:1555) with the element type erased. But **empty array,
empty object, and null are constructed as heap `ENC_ARRAY`/`ENC_OBJECT`/`ENC_NULL`
nodes** (`emptyArray()` :1702, `emptyObject()` :1714, `encodeNull()` :1691), *not*
raw embedded constants. So via the public API the only empties that reach the
untyped `wrap`/`elmToJson` are `Const_EmptyString` (from `string ""`) and the
unmerged Bool — and `Empty(2)` stays distinct from `Bool(0/1)`. The multi-way
Nil/EmptyString/null checks in `elmToJson` (:1256-1260) and the null catch-all in
`wrap` (:1588) are **defensive branches unreachable under well-typed use**; they
must be reconciled/removed because one merged constant can no longer choose among
`[]`/`""`/`null`. Mapping the merged-empty → `ENC_STRING ""` in `wrap` keeps
encoding correct.

### The one real casualty

Only the **type-erased fallback printer** (`print_value`/`print_if_constant`, the
legacy/JIT/pre-type-graph Debug path — *not* what native compiled `Debug.toString`
reaches) genuinely cannot recover which empty a value was. This is **display-only,
non-semantic**, and even it is avoidable in the real path (which is type-graph
driven). Acceptable.

### Architectural answers (for the enum reservation)

**Q: Do we need type info embedded in the constants to tell empties apart?** **No.**
Everywhere it matters, the type is available — statically at compile time for
dispatch, via the type graph for display. Embedding type in the constant is neither
necessary nor sufficient: heap `Custom` ctors (Red/Green/Blue) *already* require the
type graph to be named — you cannot name any value from its bits alone, so the
runtime already commits to "identity = index, type = context."

**Q: Do we need to type-distinguish between different enums and constants?** **No —
and this is the key finding for the reserved `enum` field.** Within the
"not-a-pointer" space, disambiguation is *always* type-directed:
- **Case dispatch** — the scrutinee's static type says whether to read bit 0 (Bool),
  test emptiness, or read the enum index.
- **Display** — the type graph maps `(type, index) → name`, exactly as it must for
  heap ctors.
- **Equality** — homogeneous.
- **GC** — needs only pointer-vs-not (`ptr_ind`).

So enums and constants **never need to be mutually distinguishable from bits alone**,
and cross-type enum collisions (`Color.Red=0` vs `Dir.North=0`) are a non-issue. The
reserved `enum` field can therefore hold a **bare constructor index** with **no
discriminator bit** separating "enum" from "constant" — the type decides which field
is meaningful, mirroring how heap `Custom` ctors already work.

### Recommendation: keep the current plan (merge); do NOT adopt the enum-field alternative

The alternative (keep True/False in bit 0, `ptr_ind` in a low bit, and move the
empties into distinct **enum-field** indices) would preserve fallback-printer
fidelity, but it is **worse**:
- It doesn't generalize — user enums still need type context, so special-casing the
  5 built-ins into self-describing indices is inconsistent with the rest of the model.
- It spends enum-index space + encode/decode complexity on built-ins that don't need
  it.
- It turns the **hot** `Nil`/`Nothing` emptiness test (every list/Maybe traversal)
  from a single dedicated-bit test into a 10-bit enum-field extract+compare.

The current 2-bit split is a principled **hot/cold** design: **Bool (bit 0, aligned
with `i1`) and Empty (bit 1) are the two hottest non-pointer values and get dedicated
low bits; colder user enums get the wide `enum` field with a bare index.** Merge wins.

### Work items this creates (realized as P0.3-P0.6, P1.3-P1.5, P2.2 below)

1. **Compiler** — Patterns.elm (`IsCtor`/`IsCons`/`IsNil`) + CaseOpLowering: replace
   `eco_get_tag`+numeric-compare / `Nil==5` with a type-directed `ptr_ind` emptiness
   test for embedded-constant constructors. Retire `eco.get_tag`'s dispatch role.
2. **Runtime** — `eco_get_tag`: drop the embedded-constant (`Nothing→1`) branch.
3. **Runtime** — `print_typed_value` (Custom@2982, Prim/String@2730): name the empty
   from the type graph's nullary ctor instead of `print_if_constant`.
4. **Runtime** — `print_if_constant`/`print_value` fallback: emit a generic
   `<empty>` token (accepted display loss).
5. **JSON** — `wrap`: map merged-empty → `ENC_STRING ""`; delete the unreachable
   Nil/null defensive multi-way in `elmToJson`.
6. **Kernels** — collapse `isNil`/`isEmptyString`/… to one `isEmpty` predicate
   (already tabled in §1/§6/§7).

## Cross-cutting observations

- **Blast radius is concentrated in the runtime allocator/GC** (§1): the
  resolve/encode helpers, the `>>40`/`<<40` bit-packing, the constant-mask reindex,
  the Bool re-encode, and the sentinel removal all live there and are centralized
  in a handful of helpers (`from/toPointerRaw`, `HeapHelpers`, `encodeConstant`,
  `encode/decodeBoxedBool`).
- **The compiler front end needs almost no code change** — it emits abstract ops;
  change #1 (no shift/base) is entirely runtime-side. Its only coupling is the
  constant table in `Ops.elm` (now False=0/True=1/Empty=2) and the Bool box/unbox
  contract. Note `ecoConstant{Unit,EmptyRec,Nil,Nothing,EmptyString}` all now emit
  the same `Const_Empty` kind — collapse the five emitters or map them to one kind.
- **The `constant != 0` → `ptr_ind` reclassification (D2) is the single largest
  edit by site count** — dozens of guard sites across §1/§3/§6/§7.
- **Two mechanical hazards** from the struct reorder: (i) positional brace-init
  `HPointer{...}` (VirtualDom.hpp:60, main.cpp createNil) silently assigns to the
  wrong fields — must become designated initializers; (ii) field-init sites that
  zero only `.padding` now leave `ptr_ind`/`enum` uninitialized.
- **`enum` is a C++ keyword** — the field must be renamed (e.g. `enom`/`enumIdx`)
  in the actual struct; the plan uses `enum` only to match the spec.

## Additional design details (fixed during implementation-readiness pass)

These were verified against the code and are now decided; the steps below assume
them.

### D6. Canonical bit patterns (golden values)

For a constant, `ptr = 0`, `enum = 0`, `padding = 0`, so the whole 64-bit word is:

| Value | ptr_ind | constant | **word** |
|---|---|---|---|
| null (uninitialized/absent) | 0 | 0 | `0x0` |
| `False` | 1 | 0 | `0x4` |
| `True` | 1 | 1 | `0x5` |
| `Empty` (Unit/{}/[]/Nothing/"") | 1 | 2 | `0x6` |
| heap pointer | 0 | 0 | **the raw address** (low 3 bits 0, bits 43-63 zero) |

Key consequence: **for a heap pointer the HPointer word is bit-identical to the C
pointer.** Decode is a reinterpret (zero instructions), not a mask — guarded by
debug asserts that `ptr_ind/enum/padding == 0` and the address is 8-byte aligned
and `< 2^43`. `null` stays `0x0` and is distinct from `False` (`0x4`).
`isConstant(word) ≡ (word >> 2) & 1`. Boxed Bool's `i1` value ≡ `word & 1`.

### D7. Heap must be reserved below 2^43 — new mandatory work

`reserveAddressSpace` currently calls `mmap(nullptr, …)`
(PlatformVirtualMemory_posix.cpp:16-20); Linux typically returns `0x7f…` (~2^47)
addresses, which **do not fit** the 43-bit address budget. The allocator must
request a low base explicitly (see step P0.1). This lands in Phase 0 because it is
harmless under the old (offset) scheme — de-risking the flip.

### D8. `Forward.forward_ptr` keeps the ÷8 unit, drops the base

`Forward` packs `tag:5 | color:2 | forward_ptr:40 | unused:17` (Heap.hpp:468-476).
`tag` must remain at bits 0-4 (it is how `Tag_Forward` is detected), so the
address field cannot sit at bit 3 like `HPointer.ptr`. `forward_ptr` therefore
stores the **absolute address in 8-byte units** (`addr >> 3`); decode is
`forward_ptr << 3`. Every forwarding site keeps its existing `<<3`/`>>3` and simply
**deletes the `± heap_base`** term. 40 bits × 8 = the same 2^43 budget.

### D9. CONSTANT_TAG — the new ctor-tag convention for embedded constants

Both dispatch paths derive a `u16`-range ctor tag from a scrutinee:

- `eco_get_tag` (decision-tree tests, RuntimeExports.cpp:3275) — currently maps
  constant `Nothing→1`, other constants `→0`.
- Inlined `eco.case` "ctor" lowering (EcoToLLVMControlFlow.cpp:624-671) — currently
  maps constant `Nil(5)→0`, else the raw const field.

The compiler side emits the expected tags via `Patterns.testToTagInt`
(Patterns.elm:920: `IsCtor→CtorTag.effective`, `IsNil→0`, `IsCons→1`) and
`computeFallbackTag` (Patterns.elm:1069).

**New convention:** reserve `CONSTANT_TAG = 0xFFFD` (below the existing Dict
reservations `0xFFFF`/`0xFFFE`; must be added to the reserved-tag comment block in
`CtorTag.elm` and `elm-kernel-cpp/src/core/Utils.cpp:51-59`). Then:

- **Runtime tag derivation** (both paths): if the value is a constant:
  `tag = isEmpty ? CONSTANT_TAG : boolValue` where `boolValue` is 0 for False /
  1 for True. The Bool arm matches `testToTagInt (IsBool False/True) = 0/1`
  exactly, so even a boxed Bool reaching ctor dispatch resolves correctly (it
  normally goes via the `IsBool` i1 path — this is defense-in-depth). Heap values
  keep the existing ctor-field load. Old-layout spelling (P0.3):
  `isEmpty = constField ∉ {0,3,4}`, `boolValue = (constField == 3)`; new-layout
  spelling (P1.3): `isEmpty = word & 2`, `boolValue = word & 1`.
- **Compiler tag emission:** `IsNil → CONSTANT_TAG`; `IsCtor` of an
  embedded-constant ctor (today only `Maybe.Nothing`) → `CONSTANT_TAG`; all heap
  ctors unchanged (`IsCons → 1`, `IsCtor → CtorTag.effective`). Verify
  `computeFallbackTag` can never pick `0xFFFD`.

This is **representation-independent**: under the old layout the runtime constant
test is `constField != 0` and `isEmpty` is `constField ∉ {3,4}`; under the new
layout it is `ptr_ind` and `constant & 2`. So the convention lands in Phase 0 and
is fully tested before the bit flip, and the flip only swaps the two predicates.

### D10. Bool invariants survive — encoding-only change

REP_ABI_001 / REP_CLOSURE_001 / CGEN_009 / CGEN_012 / FORBID_CLOSURE_001 all remain
**true**: Bool still crosses the ABI, heap fields, and closures as a boxed
`!eco.value`. What changes is only the *bit pattern inside that boxed constant*
(bit 0 = the `i1` value). Doc updates are wording/encoding notes, not semantic
rewrites. The 2-bit unboxed bitmap gains no Bool kind.

### D11. `enum` field: reserved, layout decided, mechanism out of scope

Per the assessment: the 10-bit field will hold a **bare constructor index** with no
type/discriminator bits (type context always disambiguates, as it already must for
heap ctors). Nothing in this change reads or writes it except to **zero it** on
every encode. Its encode/decode ops, compiler support, and GC/print integration are
a separate future plan.

---

## Implementation Steps

The work is structured so that **Phase 0 lands entirely under the old
representation** (each step independently buildable + testable), **Phase 1 is the
atomic flip**, and Phases 2-3 are post-flip simplification and documentation.
Run the full gate (see Testing & Validation) after every numbered step in Phase 0
and after Phase 1 as a whole.

> **Build/cache hygiene (applies to every step):** always rebuild with
> `cmake --build build --target full` (never `check` — stale `.mlir` carries old
> constant kinds). After compiler-side constant-numbering changes also purge stale
> package stages: `rm -rf ~/.eco/0.1.0/packages/eco/kernel` and delete
> `~/.eco` typed-artifacts if "no annotation entry" mono crashes appear. Never run
> `build/test/test` and `elm-tests` concurrently (typed-artifacts cache race).

### Phase 0 — Groundwork (old representation; each step lands green)

**P0.1 — Low-address heap reservation.**
- `runtime/src/allocator/PlatformVirtualMemory.hpp/.{posix,win32}.cpp`: add
  `void* reserveAddressSpaceBelow(size_t size, uintptr_t limit)`.
  - POSIX/Linux: iterate candidate bases (`0x0100'0000'0000` = 1 TB, then +1 TB
    steps) with `mmap(hint, …, MAP_FIXED_NOREPLACE)`; on macOS (no
    `MAP_FIXED_NOREPLACE`) pass the hint without `MAP_FIXED` and verify the
    returned range fits `[page, limit)`, unmapping and probing the next candidate
    if not. Final fallback: `mmap(nullptr)` + verify; if the result exceeds
    `limit`, release and `abort()` with an actionable message.
  - Windows: `VirtualAlloc(candidate, size, MEM_RESERVE, PAGE_NOACCESS)` over the
    same candidate list.
- `Allocator.cpp:178-190` (`init`): call it with `limit = 1ULL << 43`; add a
  permanent assert `(uintptr_t)heap_base + heap_reserved <= (1ULL << 43)`. If
  `config_.max_heap_size > 8 TB`, fail configuration with a clear error.
- Test: new `test/allocator/AddressSpaceReservationTest.cpp` — reserve, assert
  range fits; assert commit/decommit still work at the low base.

**P0.2 — Centralize all HPointer bit access behind helpers (pure refactor).**
Introduce in `Heap.hpp`/`HeapHelpers.hpp` (single source of truth):
- `inline u64 hpBits(HPointer)` / `inline HPointer hpFromBits(u64)` (memcpy/
  `std::bit_cast`, mirroring `HPtr`).
- `inline bool isConstantBits(u64)` / existing `alloc::isConstant(HPointer)`;
  `inline bool isEmptyConstBits(u64)` (old impl: `constField ∉ {0,3,4}`… see D9);
  `inline bool isBoolConstBits(u64)`.
- Forwarding: `inline u64 encodeForwardAddr(void* newObj)` /
  `inline char* decodeForwardAddr(u64 forward_ptr)` — old impl keeps
  `± heap_base` inside these two functions only.
Then route every open-coded site through them:
- Bit-packing/unpacking: RuntimeExports.cpp:1066-1068, 2262-2263, 2325-2333,
  2457-2458, 2758-2760, 2778 → `hpBits`/`hpFromBits` + predicates.
- JIT-root constant tests: OldGenSpace.cpp:1658-1660, NurserySpace.cpp:1276-1281
  → `isConstantBits`.
- Forwarding encode/decode (8 sites): Allocator.cpp:793-794; OldGenSpace.cpp:
  3915-3916, 3923; NurserySpace.cpp:1113-1114, 1252-1253, 1297-1310, 1357-1358,
  1759-1760, 1835 → the two forward helpers.
- Positional/brace inits: VirtualDom.hpp:60, main.cpp:220-226 → designated
  initializers or delegate to `alloc::` builders; main.cpp:276 → `alloc::isNil`.
- Kernel `ExportHelpers.hpp` (`elm-` and `eco-` trees): `toPtr`/asserts read
  fields only via the central predicates.
- Gate: full suite green; zero behavior change intended (this is the diff that
  makes Phase 1 small).

**P0.3 — CONSTANT_TAG dispatch convention (D9).**
- Compiler: `CtorTag.elm` — add `constantTag = 0xFFFD` + doc; add
  `isEmbeddedConstantCtor : Canonical -> Name -> Bool` (true for
  `elm/core Maybe.Nothing`). `Patterns.elm`: `testToTagInt`: `IsNil →
  CtorTag.constantTag`; `IsCtor home name _` when embedded-constant →
  `CtorTag.constantTag`. `generateMonoTest` (`Test.IsCtor` at :129-152, `IsNil` at
  :257-277): compare against the same values (they already share `CtorTag.effective`
  / literals — change both). `BytesFusion/Emit.elm:694-710`: nil check becomes
  `tag == CtorTag.constantTag`. Verify `computeFallbackTag` (Patterns.elm:1069)
  cannot produce `0xFFFD`.
- Runtime: `eco_get_tag` (RuntimeExports.cpp:3275): constant branch → D9 formula
  in its **old-layout spelling** (`isEmpty = constField ∉ {0,3,4}`,
  `boolValue = constField == 3`). `CaseOpLowering` constant arm
  (EcoToLLVMControlFlow.cpp:638-646): replace `select(isNil, 0, constField)` with
  the same D9 formula emitted as IR. (P1.3 later swaps only the two predicates to
  the new-layout spelling.)
- Add `CONSTANT_TAG` to the runtime side once (`Heap.hpp` next to `CTOR_BITS`,
  referenced from Utils.cpp reserved-tag block) — keep compiler/runtime in sync by
  a comment cross-reference both ways (same pattern as the Dict tags).
- Verify item (during this step): confirm decision trees route every 2-ctor
  Maybe/List match through if-chain tests (`eco.get_tag`) and that no `eco.case`
  "ctor" FanOut carries a raw constant-kind tag; `TEST_FILTER=elm` +
  `TEST_FILTER=codegen` must stay green. Bool never reaches ctor dispatch via
  `IsBool` (i1) — the D9 Bool arm is defense-in-depth.

**P0.4 — Type-driven printer stops depending on constant identity.**
`RuntimeExports.cpp print_typed_value`:
- Custom arm (:2977-2984): replace `print_if_constant(value)` with: if
  `isConstantBits(value)` → look up this type's **zero-field ctor** in
  `g_type_graph->ctors[first_ctor..]` and print its name (assert exactly one
  nullary ctor exists for a constant-valued scrutinee).
- Primitive arm (:2730-2736): String + constant → print `""`; Bool prints via
  `printPrimitive` already.
- List arm (:2752-2760): constants are only loop terminators — keep, but switch
  the test to `isConstantBits`.
- Record/Tuple/Unit: record-typed constant → `{}`; unit-typed → `()` (drive from
  `typeInfo->kind`, not the constant value).
- Gate: E2E `Debug.toString`/`Debug.log` tests still print `Nothing`, `[]`, `()`,
  `{}`, `""` correctly (they now come from the type graph).

**P0.5 — JSON encoder restructure.**
`elm-kernel-cpp/src/json/JsonExports.cpp`:
- `Elm_Kernel_Json_wrap` (:1555-1590): keep explicit arms for Bool and
  EmptyString; replace the constant catch-all (:1588) with an
  assert-unreachable (comment: only `""` and Bool constants can arrive here —
  see plan assessment (c)).
- `elmToJson` (:1251-1260): the constant multi-way is defensive/unreachable —
  reduce to Bool + EmptyString + assert.
- Gate: JSON E2E roundtrip tests (`TEST_FILTER=elm` json suites).

**P0.6 — Structural equality via whole-word compare.**
`UtilsExports.cpp equalRespectingConstants` (:47-56): if either side
`isConstantBits` → `return aBits == bBits` (valid under both layouts: constants
are canonical words). Delete the per-field compare.

### Phase 1 — The representation flip (one atomic change series)

Everything below changes together; the tree does not build green mid-phase.
Commit as a reviewed series on a branch; merge only with the full gate green.

**P1.1 — Core layout (`Heap.hpp`).**
```c
// Bit layout (LSB first):
//   [0-1] constant : 2   — 0=False, 1=True, 2=Empty (valid only when ptr_ind==1)
//   [2]   ptr_ind  : 1   — 0 = heap pointer, 1 = not a pointer
//   [3-42] ptr     : 40  — absolute 8-byte-aligned address (the word IS the address)
//   [43-52] enum_idx : 10 — reserved: bare ctor index for future enum optimization
//   [53-63] padding : 11
typedef struct {
    u64 constant : 2;
    u64 ptr_ind  : 1;
    u64 ptr      : POINTER_BITS;
    u64 enum_idx : 10;
    u64 padding  : 11;
} HPointer;

typedef enum { Const_False = 0, Const_True = 1, Const_Empty = 2 } Constant;
#define PTR_IND_BIT 2
```
- Field name is **`enum_idx`** (`enum` is a C++ keyword).
- Add **compile-time golden asserts** (also guards MSVC bitfield packing for the
  Windows build): constexpr-construct each constant and `bit_cast` to u64,
  asserting the D6 words (`False==0x4`, `True==0x5`, `Empty==0x6`) and that a
  pointer round-trips bit-identically to its address.
- `Forward` (:468-476): comment change only — semantics per D8.
- Delete the old 7-value `Constant` enum; keep `Tag_*` untouched.

**P1.2 — Helpers (`HeapHelpers.hpp`, `Allocator.hpp/.cpp`).**
- Builders: one `empty()` (word `0x6`); `elmTrue()`/`elmFalse()` (words
  `0x5`/`0x4`). Keep thin aliases `nil() = unit() = nothing() = emptyString() =
  emptyRecord() = empty()` initially so the hundreds of helper call sites don't
  churn; collapse the aliases in Phase 2.
- Predicates: `isConstant → ptr_ind != 0`; new `isEmpty → ptr_ind && (constant &
  2)`; `isTrue/isFalse/boolValue → word & 1` (guarded by `ptr_ind`);
  `isNil`/`isEmptyString` become aliases of `isEmpty` (collapse in Phase 2).
  Update `isConstantBits`/`isEmptyConstBits`/`isBoolConstBits` (from P0.2) to the
  new bit tests — this switches every JIT-root/packing site at once.
- `fromPointerRaw`: `assert(hp.ptr_ind == 0)`; return
  `reinterpret_cast<char*>(hpBits(hp))` (plus debug asserts per D6). Remove
  `heap_base` use.
- `toPointerRaw`: `assert(aligned && (u64)obj < (1ULL<<43))`; return
  `hpFromBits((u64)obj)`. Remove `heap_base` use.
- Forward helpers (from P0.2): delete the `± heap_base` terms (D8).
- `readBarrier` (OldGenSpace.cpp:174) and the disabled validator
  (NurserySpace.cpp:1429-1432): decode via `fromPointerRaw`/`hpBits`.
- Field-init sites (ThreadLocalHeap.cpp:315-320, 353-355): zero the whole word
  (`body = hpFromBits(0)`) instead of per-field zeroing.
- Debug prints (NurserySpace.cpp:1088, 2126-2129; ThreadLocalHeap.cpp:739):
  print the raw word / new fields.

**P1.3 — Codegen lowering (`runtime/src/codegen/`).**
- `EcoToLLVMInternal.h value_enc`: replace with
  `PtrIndBit = 2; ConstFieldMask = 0x3;`
  `enum ConstantKind : uint64_t { False = 0, True = 1, Empty = 2 };`
  `encodeConstant(kind) = (1ULL << PtrIndBit) | kind;`
  Keep `HeapOffsetBits = 40` only if still referenced for width docs; it no longer
  doubles as a shift.
- `EcoToLLVMTypes.cpp` (:35-39, :72-74): no structural change — now emit literals
  4/5/6 via `encodeConstant`.
- `EcoToLLVMControlFlow.cpp`:
  - :376 empty-string literal → `encodeConstant(Empty)`.
  - :451-455 string-case truth test: the boxed result of `Utils_equal` is
    True/False → replace `icmp eq boxedResult, encodeConstant(True)` with
    `trunc(word & 1)` (D4 unbox).
  - :625-671 ADT constant detection: `isConstant = trunc((word >> 2) & 1)`;
    constant-arm tag = D9 formula (`select(word & 2, 0xFFFD, word & 1)` — note
    `word & 2` tests the Empty bit since `constant` is bits 0-1).
- `EcoToLLVMHeap.cpp`:
  - box i1 (:119-128): `word = (1ULL << 2) | zext(i1)`; `inttoptr`.
  - unbox to i1 (:162-171): `i1 = trunc(ptrtoint(v) & 1)`.
- `EcoPtrIntVerify.cpp` (:57-67): recognized literal set = {4, 5, 6}; update
  loop/comment.
- `Ops.td`: `Eco_ConstantKind` values False=0/True=1/Empty=2 (keep the seven MLIR
  enum *names* mapping onto the three values if that reduces churn, or collapse to
  three — implementer's choice, but the **attribute values** must be the new
  ones); rewrite `Eco_ConstantOp` doc (:1659-1679) per D1/D6.
- `RuntimeExports.cpp print_if_constant` (:2181-2228) + `is_nil` (:2231-2234):
  fallback printer per assessment — words `0x4/0x5` → `False/True`, `0x6` →
  `<empty>`; `is_nil` → `isEmptyConstBits` (list-terminator use only).
- `eco_get_tag` (:3275-3308): predicates flip via the shared helpers (D9 formula
  already in place from P0.3).

**P1.4 — Compiler constant table (`compiler/src/Compiler/Generate/MLIR/Ops.elm`).**
- Doc block :108-120 → D6 table.
- Emitters keep their names; values change: `ecoConstantFalse → kind 0`,
  `ecoConstantTrue → kind 1`, `ecoConstantUnit/EmptyRec/Nil/Nothing/EmptyString →
  kind 2`. All call sites unchanged.

**P1.5 — Kernel trees (`elm-kernel-cpp/`, `eco-kernel-cpp/`).**
- Both `ExportHelpers.hpp`:
  - `encodeBoxedBool(b) → HPtr::fromBits((1ULL << 2) | (u64)b)`;
    `decodeBoxedBool(bits) → bits & 1` (assert `ptr_ind`).
  - elm-tree `toPtr` (:47-83): the three-way heuristic collapses — `ptr_ind == 1
    → nullptr` (constant), else the bits are the address (resolve/identity);
    delete the `padding != 0` raw-pointer heuristic.
  - eco-tree (:39-40): same discrimination; replace `assert(h.padding == 0)` with
    asserts on the new invariant (pointer ⇒ `enum_idx/padding == 0`).
- All `Const_X + 1` comparisons (tabled in §6/§7) → `alloc::isEmpty` /
  `alloc::isTrue` via the central predicates. The Bool-reading sites
  (JsonExports.cpp:418, 1276, 1564-1571; UtilsExports/Basics/Parser/Regex/String
  Bool results) go through `encode/decodeBoxedBool` and need no further edits
  once those flip.
- `ListOps.cpp member` (:521-522): constants compare by whole word (P0.6 pattern).

**P1.6 — Full-clean rebuild + gate.**
- Purge `~/.eco` package stages and build-tree MLIR (`--target full` regenerates);
  then run the complete gate (below), including `ECO_HEAP_VALIDATE=1` and the
  small-nursery GC stress pass.

### Phase 2 — Post-flip deletions and simplification

**P2.1 — Heap-base sentinel removal (D5).** Delete
`installHeapBaseSentinel`/`isHeapBasePage`/`HEAP_BASE_SENTINEL_SIZE` and all
call-sites/defenses (OldGenSpace.hpp:187-202, 874-883; OldGenSpace.cpp:374-379,
410-424, 1202-1233, 1303-1330, 1478, 2003-2015, 2620-2629, 3251-3254;
ThreadLocalHeap.cpp:717-719 comment; Heap.hpp:115-117 comment). Delete
`test/allocator/OldGenHeapBaseSentinelTest.*` and remove it from
`test/CMakeLists.txt`. The first old-gen block may now hand out `heap_base + 0`.

**P2.2 — Collapse compatibility aliases.** Replace `nil()/unit()/nothing()/
emptyString()/emptyRecord()` call sites with `empty()`, and
`isNil/isEmptyString` with `isEmpty` (mechanical; both trees + runtime). Delete
the aliases and the dead `MlirConst_*` enum (RuntimeExports.cpp:2167-2177).

**P2.3 — (Optional, separate commit) Unify JIT-pointer and HPointer root
handling.** Since a heap HPointer is now bit-identical to the physical address,
`evacuateJitPtr`-style dual paths (NurserySpace.cpp:1276+, OldGenSpace.cpp:1658+)
can merge with the standard evacuate path. Do this only after Phase 1 has soaked;
it is a simplification, not a requirement.

### Phase 3 — Documentation and invariants

**P3.1 — `design_docs/invariants.csv`.**
- Rewrite HEAP_008 (raw absolute addresses; the word is the address; only
  `from/toPointerRaw` construct/deconstruct), HEAP_010 (constants False=0x4,
  True=0x5, Empty=0x6; discriminator `ptr_ind`; empties merged), HEAP_017 (word
  `0x0` is null; no sentinel; address 0 never mapped).
- REP_CONSTANT_001/002/003: constants never heap-allocated (unchanged); the
  discriminator is `ptr_ind`; the comparable-constants wording covers the single
  merged Empty; True/False compare by bit 0.
- Add a new invariant for D6: *pointer HPointer word ≡ physical address; bits
  43-63 and 0-2 are zero for pointers* (give it the next free HEAP id), and one
  for CONSTANT_TAG (reserved ctor tag 0xFFFD, next to the Dict reservations).
- Per D10: REP_ABI_001, REP_CLOSURE_001, CGEN_009, CGEN_012, FORBID_CLOSURE_001
  keep their meaning — update only encoding notes where they cite `constant != 0`
  or specific kind numbers.

**P3.2 — Theory docs.** THEORY.md:83, 116, 144-162 (rewrite the "Logical
Pointers" section per D1/D6/D8); theory/heap_representation_theory.md (Bool
sections, constant table → D6, empties merged);
theory/pass_eco_to_llvm_theory.md:69-131 (new bit diagram, `encodeConstant`,
CONSTANT_TAG); theory/json_heap_representation_theory.md (Bool encoding note).
Kernel ABI docs: eco-kernel `KernelExports.h:9,88,91,116`, elm-kernel
`ExportHelpers.hpp:20` header comments.

## Testing & Validation

### Existing gates (run after every phase; serially, never concurrently)

1. `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` — full
   compiler rebuild + E2E (1547 tests; includes `TEST_FILTER`-able elm/codegen
   suites). Run ONCE per change; grep the log, do not re-run.
2. `cmake --build build --target elm-tests` — compiler front-end suite
   (elm-test-rs).
3. `cmake --build build --target test && build/test/test` — runtime/allocator C++
   unit tests (includes the MLIR lowering tests under `test/codegen/*.mlir`).
4. Bootstrap convergence: the compiler compiles itself; run the stage2/stage7
   MLIR diff runner (see `plans/stage2-stage7-mlir-diff-runner.md`) to confirm
   stage convergence. Byte-identical golden gates do NOT apply (codegen output
   legitimately changes); convergence does.

### New unit tests (Phase 0/1, `test/allocator/`)

- **`HPointerLayoutTest.cpp`** (P1.1): golden words per D6 (False `0x4`, True
  `0x5`, Empty `0x6`, null `0x0`); pointer encode→decode round-trip is
  bit-identical to the address; alignment/limit asserts fire under debug;
  `isConstant/isEmpty/boolValue` truth tables; forward encode/decode round-trip
  (D8); `hpBits/hpFromBits` inverse.
- **`AddressSpaceReservationTest.cpp`** (P0.1): reserved range ⊆ `[0, 2^43)`;
  commit/decommit at the low base.
- **Update `HeapHelpersTest.cpp`**: new builders/predicates; empties all equal as
  words; True ≠ False ≠ Empty ≠ null.
- **Update `RuntimeExportsTest.cpp`**: `eco_get_tag` D9 contract (heap ctor,
  Empty → `0xFFFD`, True/False → 1/0); fallback printer prints
  `True/False/<empty>`.
- **GC tests**: extend `NurserySpaceTest`/`GCPressureTest` scenarios so list
  spines terminated by Empty and containers holding True/False/Empty in boxed
  slots survive minor+major GC (constants must be skipped by mark/evacuate via
  `ptr_ind`); run key cases with a tiny nursery to force evacuation mid-walk
  (see `eco-listmapn-stale-cursor-gc-bug` for the forcing technique).

### New MLIR lowering tests (`test/codegen/*.mlir`)

- `constant_encoding.mlir`: `eco.constant` for each kind lowers to `inttoptr` of
  4/5/6.
- `bool_box_unbox.mlir`: `eco.box`(i1)/`eco.unbox`(i1) lower to the D4 or/and-mask
  patterns (no compare-with-True).
- `case_constant_dispatch.mlir`: `eco.case` "ctor" lowering contains the
  `ptr_ind` bit test and the D9 select (CONSTANT_TAG).
- Refresh any existing `.mlir` expectations that encode old `<<40` literals.

### New/extended E2E Elm coverage (`test/elm*/src`)

Add a representation-focused module (e.g. `ReprConstants.elm`) exercising, with
result assertions:
- Bool: literals, `not/&&/||/xor`, `==`/`/=`, if/case dispatch, Bool in records/
  tuples/lists/closures, Bool through ports (echo-bounce convention), Bool
  results from all comparison operators (Int/Float/Char/String).
- Each empty in pattern + value position: `[]` vs `x::xs`; `Nothing` vs `Just`;
  `""` vs non-empty string cases; `()`; `{}`; empties nested in containers.
- `Debug.toString` of every constant and of values containing them — expected
  strings `True`, `False`, `Nothing`, `[]`, `()`, `""`, `{}` (validates P0.4's
  type-graph naming end-to-end).
- Equality: `[] == []`, `Nothing == Nothing`, `"" == ""`, mixed
  `Nothing == Just 1 |> not` etc.; `List.member` over Bools and over lists
  containing empties.
- JSON: `Json.Encode` of `""`, `True`/`False`, `null`, empty list/object;
  decode round-trips (validates P0.5).
- Dict/Set smoke (reserved-tag adjacency to CONSTANT_TAG): inserts/folds/equality.

### Stress & validation protocol (Phase 1 exit criteria)

1. Full gate green (all four suites above).
2. Repeat the E2E suite with `ECO_HEAP_VALIDATE=1` (asserts-on build).
3. Repeat key GC-heavy E2E tests with a tiny-nursery heap config (see
   `heap-profile.local.example.json` / eco-config tunables) to force frequent
   minor GC over constant-laden structures.
4. Run the stress-elm suite (`test/stress-elm`).
5. `eco init` scaffold + build + run a hello-world app against the installed
   layout (catches kernel/runtime constant mismatches outside the build tree).

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Heap mmap cannot be placed below 2^43 on some platform/config | P0.1 probes candidates + hard, actionable abort; lands in Phase 0 so it soaks before the flip; config error for >8 TB heaps |
| MSVC/GCC bitfield layout divergence breaks the Windows build | D6 golden-word `static_assert`s via `bit_cast` fail the build at compile time, not at runtime |
| Missed `constant != 0` guard keeps old semantics (False misread as pointer) | D2 site list is exhaustive (§1/§3/§6/§7); P0.2 centralization means the flip happens in single-digit functions; grep-gate before P1.6: no direct `.constant`/`.padding` field reads outside Heap.hpp/HeapHelpers/ExportHelpers |
| Stale caches mix old/new constant kinds (`.mlir`, `.ecot`, `~/.eco` stages) | Hygiene procedure in the phase preamble; P1.6 mandates a purge + `--target full` |
| Decision-tree vs `eco.case` tag contract drift (Nothing/Nil) | P0.3 lands the CONSTANT_TAG convention under the old layout with the full suite as referee; the flip then only swaps predicates |
| `computeFallbackTag` or a user type collides with 0xFFFD | Verify in P0.3; CONSTANT_TAG documented beside Dict's 0xFFFF/0xFFFE reservations in both CtorTag.elm and Utils.cpp |
| A consumer silently depended on distinguishing empties | The deep-dive audit (assessment section) found all of them; E2E `Debug.toString`/JSON/equality tests pin the behavior |
| Forwarding-pointer decode regressions under GC load | D8 keeps the existing shift structure (delete `±heap_base` only); GC stress protocol + `ECO_HEAP_VALIDATE` |

## Acceptance Criteria

- [ ] All Phase 0 steps merged individually with the full gate green each time.
- [ ] Phase 1 series merged with: full E2E (1547) green, elm-tests green, unit
      tests green, MLIR lowering tests green, bootstrap stage convergence, stress
      protocol (ECO_HEAP_VALIDATE + tiny-nursery) clean.
- [ ] Grep-gates: no `heap_base +`/`- heap_base` outside `Allocator.{hpp,cpp}`
      bounds checks; no `<< 40`/`>> 40` HPointer packing anywhere; no direct
      `.constant`/`.padding`/`.enum_idx` field access outside the central helper
      headers; no `Const_Nil`/`Const_Nothing`/`Const_Unit`/`Const_EmptyRec`/
      `Const_EmptyString` identifiers remain.
- [ ] Sentinel machinery and its test deleted (P2.1).
- [ ] invariants.csv + THEORY.md + theory/* updated (P3); new pointer-identity
      and CONSTANT_TAG invariants added.
- [ ] `Debug.toString` still renders `True/False/Nothing/[]/()/""/{}` correctly
      in compiled programs (type-graph path); fallback printer renders
      `True/False/<empty>`.

## Out of scope (explicitly deferred)

- The 10-bit `enum_idx` optimization (encode/decode ops, compiler emission, GC and
  printer integration). Layout + semantics are decided (D11: bare ctor index, no
  discriminator); everything else is a future plan.
- P2.3 JIT-root/HPointer evacuation-path unification (optional simplification;
  soak Phase 1 first).
