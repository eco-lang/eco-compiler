# 07 — Runtime Support Symbol Surface

Third leg of the kernel purity audit. Scope: the C++ symbols that *generated code*
calls directly, as opposed to `Elm_Kernel_*` / `Eco_Kernel_*` kernel functions.

Authoritative sources read:

- `/work/runtime/src/allocator/RuntimeExports.h` (747 lines — the declared surface)
- `/work/runtime/src/allocator/RuntimeExports.cpp` (4678 lines — definitions)
- `/work/runtime/src/codegen/RuntimeSymbols.cpp` (JIT symbol map; 1014 lines)
- `/work/runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` (`EcoRuntime::getOrCreate*` — the
  single locus where every runtime decl is materialised, lines 173–1070; the
  pre-declaration sweep `materializeAllRuntimeDecls` at 1183–1245)
- `/work/runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`, `EcoToLLVMValueAgg.cpp`,
  `EcoToLLVMClosures.cpp`, `EcoToLLVMArith.cpp`, `EcoToLLVMControlFlow.cpp`,
  `EcoToLLVMFunc.cpp`, `EcoToLLVMGlobals.cpp`, `EcoListTemplate.cpp`,
  `EcoListCursor.cpp`, `BFToLLVM.cpp`
- `/work/runtime/src/codegen/EcoBackend.cpp` (the LLVM-IR-level marker expansions)

**Classification key.** ALLOC = heap allocation entry point. GC = GC/root/safepoint
machinery. P / PA / PH = pure / pure-allocating / pure-heap-reading helper.
RT = runtime state. E = effectful. DISPATCH = closure/PAP application machinery.
STATS/DEBUG = counters, validation, tracing.

**"Inline-lowered today?"** = does an MLIR/LLVM pass replace the call with inline IR
on the hot path, or is a real `call` emitted?

---

## Part 1 — The symbol surface

### A. Inline-allocation core (HEAP_034 / HEAP_041 / CGEN_074)

| Symbol | Purpose | Class | Inline-lowered today? | Notes |
|---|---|---|---|---|
| `__eco_alloc_inline(i64) -> as1` | Marker, not a real symbol | ALLOC | **YES — always** | Declared `EcoToLLVMRuntime.cpp:655` (gc-leaf); expanded to the bump diamond by `expandInlineAllocs`, `EcoBackend.cpp:986–1130`. Never survives to codegen. |
| `eco_bump_state()` | Address of this thread's `{bump.ptr, bump.end}` | RT (thread-local read) | Call **survives**, but is the *only* symbol given LLVM purity attributes | `RuntimeExports.cpp:183–193`. Attrs at `EcoBackend.cpp:1013–1019` and `2219–2223`: `memory(none)` + `nounwind` + `willreturn` + `speculatable` + `gc-leaf-function`. Body is call-free inline TLS. |
| `eco_alloc_inline_slow(i64)` | Cold edge of the bump diamond; minor GC, returns uninit storage | ALLOC / GC | N/A (is the slow edge) | `EcoBackend.cpp:1027–1030`: `nounwind` only, deliberately **not** gc-leaf (it is THE statepoint). |
| `eco_ensure_nursery_slow(i64)` | Hoisted capacity guarantee, no allocation (HEAP_041) | ALLOC / GC | N/A (cold edge of ensure diamond) | `EcoBackend.cpp:2226–2235`: `nounwind` only; deliberately non-gc-leaf and an opaque clobber so bump loads are not forwarded across it. |

### B. Unified allocation entry points (the `ECO_INLINE_ALLOC=0` A/B leg + the fallbacks)

All declared in `EcoToLLVMRuntime.cpp:173–258`, all **without** `gcLeaf` (so RS4GC statepoints them).

| Symbol | Purpose | Class | Inline-lowered today? | Notes |
|---|---|---|---|---|
| `eco_alloc_int` / `_float` / `_char` | Box i64 / f64 / i16 | ALLOC | **YES** (inline bump) | `BoxOpLowering`, `EcoToLLVMHeap.cpp:221–235`. Call arm at `:238–255` is the A/B leg only. Bool (i1) never allocates — embedded `True`/`False` constants, `:257–268`. |
| `eco_alloc_cons` | Cons cell | ALLOC | **YES** (inline bump) | `ListConstructOpLowering`, `EcoToLLVMHeap.cpp:445–456`. |
| `eco_alloc_cons_uninit` + `eco_store_cons_head{,_i64,_f64}` + `eco_store_cons_tail` | Alloc-then-store cons | ALLOC / RT | fallback only | `EcoToLLVMHeap.cpp:462–490`. |
| `eco_alloc_tuple2` / `_tuple3` (and `_uninit` + `eco_store_tuple_field*`) | Tuples | ALLOC | **YES** (inline bump) | `EcoToLLVMHeap.cpp:670–681` (T2) and `759–…` (T3); also `EcoToLLVMValueAgg.cpp:237,314`. |
| `eco_alloc_record` (+ `eco_store_record_field*`) | Records | ALLOC | **YES if size ≤ 4096 B** | `EcoToLLVMHeap.cpp:951–967`; `EcoToLLVMValueAgg.cpp:396`. Oversized records keep the call. |
| `eco_alloc_custom` / `eco_allocate` / `eco_alloc_with_roots` | Custom ADTs, generic alloc | ALLOC | **YES if size ≤ 4096 B** (custom) | `EcoToLLVMHeap.cpp:1090–1112`; `EcoToLLVMValueAgg.cpp:478`. `eco.allocate` / `eco.allocate_ctor` (dynamic size) always call — `EcoToLLVMHeap.cpp:337,376`. `eco_alloc_with_roots` is the **kernel-C++** entry, not emitted by codegen. |
| `eco_alloc_closure` / `_closure_k` | Closure / PAP object | ALLOC | **YES if size ≤ 4096 B** | `EcoToLLVMClosures.cpp:756–787`; `EcoToLLVMValueAgg.cpp:805`. |
| `eco_intern_closure0` | Interned zero-capture closure (HEAP_033) | ALLOC / RT | NO — always a call | `EcoToLLVMClosures.cpp:740–746`. Per-thread interning table, epoch-synced. |
| `eco_alloc_closure_group_slow` | Atomic sibling-closure group for let-rec | ALLOC | NO — always a call | `EcoToLLVMRuntime.cpp:380`. |
| `eco_alloc_string`, `_string_literal`, `_string_literal_utf8` | Strings | ALLOC | NO — always a call | Dynamic size / interning; `EcoToLLVMHeap.cpp:404`, globals lowering. |
| `eco_alloc_*_fast` (10 symbols) | Bump-only, return 0 on failure | ALLOC | Dead in practice | Declared gc-leaf, `EcoToLLVMRuntime.cpp:267–312`; superseded by the inline diamond. Declarations only. |
| `eco_alloc_*_slow` (9 symbols) | Always-succeed, may GC | ALLOC | Dead in practice | `EcoToLLVMRuntime.cpp:321–366`. |
| `eco_gc_alloc_region_fast` / `_slow` | Group-region alloc (`eco.gc_group_size ≥ 2`) | ALLOC | N/A — is itself a fast/slow diamond | `EcoToLLVMRuntime.cpp:390,396`; `_fast` gc-leaf, `_slow` not. |
| `eco_init_{int,float,char,cons,tuple2,tuple3,record,custom,string}_at` | Initialise at a pre-allocated pointer | RT (writes fresh object) | Only inside the group-alloc path | All 9 gc-leaf, `EcoToLLVMRuntime.cpp:406–454`. |
| `eco_alloc_{tuple2,tuple3,cons}_uninit` | Forward-compatible alloc-then-store ABI | ALLOC | fallback only | `EcoToLLVMRuntime.cpp:509–519`. |
| `eco_store_field{,_i64,_f64}`, `eco_set_unboxed` | Generic field stores | RT | Superseded by `emitFreshFieldStore` | All gc-leaf, `EcoToLLVMRuntime.cpp:464–500`. Direct AS1 GEP+store is emitted instead (HEAP_031). |

### C. Heap reads / projections

| Symbol | Purpose | Class | Inline-lowered today? | Notes |
|---|---|---|---|---|
| `eco_resolve_hptr(HPtr) -> ptr` | Resolve HPointer, follow forwarding | PH | **YES** via `__eco_resolve_fwd` marker | Marker at `EcoToLLVMRuntime.cpp:630` (gc-leaf); expanded to the header-tag diamond by `expandInlineDerefs`, `EcoBackend.cpp:871–950`. Real `eco_resolve_hptr` calls remain only on the `ECO_INLINE_DEREF_EXT=0` A/B leg (`EcoToLLVMClosures.cpp:126,439,682,1244,1344`; `EcoToLLVMControlFlow.cpp:184,707`; `EcoToLLVMValueAgg.cpp:708,845`) — **and unconditionally in `emitClosureCall` (`EcoToLLVMClosures.cpp:1344`), the `_dispatch_mode="closure"` path.** |
| `eco_follow_forward(HPtr) -> as1` | Cold arm of the deref diamond | PH | is the cold arm | gc-leaf, `EcoToLLVMRuntime.cpp:637`, `EcoBackend.cpp:885–887`. |
| `eco_get_tag(HPtr) -> i32` | Constructor tag incl. embedded constants | PH | **YES** via `__eco_get_tag_inline` marker | `EcoToLLVMControlFlow.cpp:96–117`; expanded by `expandGetTagMarkers`. Call only on the A/B leg. |
| `eco_get_header_tag`, `eco_get_custom_ctor` | Raw header / ctor reads | PH | never emitted by codegen | Kernel/C++ only. |
| `eco_cons_head_i64` / `_f64` / `_i16` | Cons head as an unboxed primitive (dual boxed/unboxed) | PH | **NO — real call** | `EcoToLLVMHeap.cpp:529,536,543`. gc-leaf. This is the one projection family that still costs a call. |
| `eco_list_head_hybrid` / `eco_list_tail_hybrid` | Chunked-list (mixed-spine) projections | PH / PA | Cold arm of a marker diamond | Decls `EcoToLLVMRuntime.cpp:709,716`; calls synthesised at LLVM level by `expandListProjMarkers`, `EcoBackend.cpp:1413–1416`. `_head` gc-leaf; `_tail` **not** (may materialise a successor view ⇒ allocates). |
| `eco_list_pos_view(node, idx)` | Cursor position → list value | PA | NO — real call at loop exits | `EcoListCursor.cpp:52,352,444`. Allocates a `ConsChunk` view unless `idx==0`. |
| `eco_tuple2_get{0,1}_{i64,f64,i16}` (6), `eco_tuple3_get{0,1,2}_*` (9), `eco_record_get_*` (3), `eco_custom_get_*` (3), `eco_array_get_*` (3) | "Pattern C" gc-leaf field reads | PH | **DEAD** — declared but never emitted | Declared `EcoToLLVMRuntime.cpp:722–842` and force-materialised at `:1222–1231`, but **no lowering pattern calls any of them** — projections use `emitInlinePrimLoad`/`emitInlineBoxedLoad` (`EcoToLLVMHeap.cpp:826–910`). GlobalDCE drops them. 24 dead declarations. |
| `eco.project.tuple2/3`, `.record`, `.custom`, `.array.get`, `.list_head`, `.list_tail` | MLIR ops | PH | **YES** — inline GEP+load | All carry the MLIR `Pure` trait (`Ops.td:648,670,757,780,847,924,950`), so MLIR CSE/DCE applies *before* lowering. |

### D. Closure / PAP dispatch

| Symbol | Purpose | Class | Inline-lowered today? | Notes |
|---|---|---|---|---|
| `eco_apply_closure(clo, u64* args, n)` | Generic apply: under/exact/over-saturated | DISPATCH | NO | `EcoToLLVMRuntime.cpp:587`. Not gc-leaf ⇒ statepointed. |
| `eco_apply_closure_typed(clo, i64* args, n, layout)` | Typed-args generic apply (CGEN_059) | DISPATCH | NO | `:593`. Re-boxes per `EvalParamLayout` — the single locus of re-boxing. |
| `eco_apply_closure_eval(..., result_slot, desired_kind)` | Typed-args **and** typed-result apply | DISPATCH | NO | `:604`; emitted `EcoToLLVMClosures.cpp:1669`. |
| `eco_apply_segmentation_unknown` | Unknown-staging apply | DISPATCH | NO | `:611`; `EcoToLLVMClosures.cpp:2189`. |
| `eco_pap_extend(clo, args, n, bitmap)` | Under-saturated PAP extension | DISPATCH / ALLOC | NO | `:564`; `EcoToLLVMClosures.cpp:2248`. |
| `eco_closure_call_saturated(...)` / `_eval(...)` | Saturated evaluator invocation | DISPATCH | NO | `:570,581`; `EcoToLLVMClosures.cpp:1855,1878`. |
| `_dispatch_mode = "fast"` | Known homogeneous closure kind | DISPATCH | **YES — fully inline** | `emitFastClosureCall`, `EcoToLLVMClosures.cpp:1222–1330`: inline resolve + capture loads + **direct call to `@lambda$cap`**. No runtime helper at all. |
| `_dispatch_mode = "closure"` | Known heterogeneous | DISPATCH | Partially | `emitClosureCall`, `:1334–1430`: `eco_resolve_hptr` call + evaluator load + **indirect typed call**. No `eco_apply_*`. |
| `_dispatch_mode = "unknown"` | Analysis gap | DISPATCH | NO | `emitUnknownClosureCall` → the `eco_apply_*` family. |
| `eco_dispatch_stats_fast(ptr)` | LSS dispatch counter | STATS | NO | gc-leaf, `:881`. |
| `eco_closure_stats_dump`, `eco_dispatch_stats_dump`, `eco_cons_site_tally` | Census dumps | STATS | never emitted | Driver/atexit only. |

### E. GC / roots / safepoints

| Symbol | Purpose | Class | Inline-lowered today? | Notes |
|---|---|---|---|---|
| `eco_gc_stack_range_point()` | Save shadow-root stack depth | GC | NO | gc-leaf, `:859`; emitted `EcoToLLVMFunc.cpp:221`. |
| `eco_gc_push_stack_range(base, n, mask)` | Register an alloca as a root range | GC | NO | gc-leaf, `:864`; emitted `EcoToLLVMFunc.cpp:240`. Also forces `frame-pointer=all` (`EcoBackend.cpp:812`). |
| `eco_gc_restore_stack_range_point(p)` | Pop root ranges | GC | NO | gc-leaf, `:869`; emitted `EcoToLLVMFunc.cpp:317`. |
| `eco_gc_add_root` / `_remove_root` / `_add_value_root` / `_remove_value_root` / `_jit_root_count` | JIT-global root registry | GC | `add_root` emitted at init (`:854`, gc-leaf); rest driver-only | — |
| `eco_safepoint`, `__eco_safepoint_poll`, `eco_minor_gc`, `eco_major_gc` | Explicit safepoint / GC triggers | GC | **never emitted** | `emitSafepointMarker` / `emitWrapperSafepointMarker` are **no-ops** (`EcoToLLVMRuntime.cpp:1106–1123`) — RS4GC does all statepoint insertion. |
| `__eco_slot_to_hptr` / `__eco_hptr_to_slot` | Fold-proof slot-cast barriers (REP_LLVM_002) | P (identity) | **YES** — rewritten to bare `inttoptr`/`ptrtoint` post-RS4GC | `:895,901`, gc-leaf **only**; the comment at `:886–891` explicitly forbids adding `memory(none)/speculatable/willreturn` because motion across a statepoint would recreate the raw-i64 crossing the barrier prevents. |
| `eco_validate_nursery_hptr_bits(u64)` | Stale-pointer store tripwire | DEBUG | NO | Inserted by `EcoBoxedStoreVerify` only under `ECO_LOWERING_VALIDATION`. |
| `eco_caf_promote(bits, slot)` | CAF-memo promotion hook (CGEN_068) | RT / ALLOC | NO | Declared with `passthrough = ["gc-leaf-function"]` at `EcoToLLVMGlobals.cpp:590–597`; called `:613`. |

### F. Chunked-list scratch stack (Tier-B templates)

| Symbol | Purpose | Class | Inline-lowered today? | Notes |
|---|---|---|---|---|
| `eco_scratch_mark()` | Push a mark on the scratch stack | RT | NO | gc-leaf stamped at `EcoBackend.cpp:2511–2513`; emitted by `EcoListTemplate.cpp:556–605,798–856`. |
| `eco_scratch_push_boxed(v)` / `_push_scalar(bits, kind)` | Accumulate an element | RT | NO | gc-leaf (same site). Entries are external GC roots. |
| `eco_scratch_finish(mark, next, kind)` / `_finish_fwd(mark, rest, kind)` | Build the chunk/cells, pop to mark | ALLOC / RT | NO | **Not** gc-leaf — allocates and statepoints normally. |
| `eco_scratch_abandon(mark)` | Discard above mark | RT | never emitted by codegen | Kernel-only (`elm-kernel-cpp/src/json/JsonExports.cpp:669`). |

### G. Arithmetic / string / array / order helpers emitted by codegen

| Symbol | Purpose | Class | Inline-lowered today? | Notes |
|---|---|---|---|---|
| `eco_int_pow(base, exp)` | Integer exponentiation | **P (truly pure)** | NO — real call | gc-leaf, `EcoToLLVMRuntime.cpp:907`; emitted `EcoToLLVMArith.cpp:201`. Reads/writes nothing. Prime candidate for `memory(none) willreturn nounwind speculatable`. |
| `asin` / `acos` / `atan` / `atan2` | libm | **P** | NO | gc-leaf, `:1055–1070`. Only LLVM's own `InferFunctionAttrs` (via TargetLibraryInfo, in the Cgu `-O2` leg) can add attrs, and only because the names are recognised libcalls. |
| `Eco_Runtime_getOrderLT/EQ/GT()` | Interned `Order` singletons | **PH (constant after init)** | NO — three real calls per compare | gc-leaf, `:919,924,929`; emitted unconditionally and `select`-ed at `EcoToLLVMArith.cpp:1011–1013`. Defined `elm-kernel-cpp/src/core/UtilsExports.cpp:135–137` as a single global load. |
| `Elm_Kernel_Utils_equal(a,b)` | Structural equality (string-case lowering) | E (may GC) | NO | `:913` — **not** gc-leaf. |
| `elm_string_from_int` / `elm_string_from_double` | Int/Float → String | PA | NO | `:952,957`; emitted `EcoToLLVMHeap.cpp:1534,1551`. |
| `elm_array_empty`, `_singleton_{int,float,char,box}`, `_push_{int,float,char,box}`, `_slice`, `_append_n` | Persistent array ops | PA | NO | `:962–1012`; emitted `EcoToLLVMHeap.cpp:1418,1438–1444,1468–1474,1494,1512`. |
| `eco_clone_array`, `eco_array_set_fix_kind` | Functional array update | PA / RT | NO | `:939,947`; emitted `EcoToLLVMHeap.cpp:1328`. |
| `elm_alloc_bytebuffer`, `elm_bytebuffer_len`, `elm_bytebuffer_data`, `elm_utf8_width`, `elm_utf8_copy`, `elm_utf8_decode`, `elm_encoder_size`, `elm_encoder_write_into`, `elm_maybe_nothing`, `elm_maybe_just` | Bytes-fusion (BF dialect) | PA / PH | NO | Declared **with zero attributes — not even gc-leaf** — by the local `declareFunc` lambda at `BFToLLVM.cpp:99–130`; emitted `:114–129`. |

### H. Debug / crash / IO

| Symbol | Purpose | Class | Inline-lowered today? | Notes |
|---|---|---|---|---|
| `eco_crash(msg)` | Abort with an Elm error string | E | NO | gc-leaf, `EcoToLLVMRuntime.cpp:848`; emitted `EcoToLLVMErrorDebug.cpp:148,180`. **`[[noreturn]]` in C++ (`RuntimeExports.cpp:2788`) but the LLVM decl has no `noreturn`.** |
| `eco_dbg_print{,_int,_float,_char,_typed}` | `Debug.log` / `eco.dbg` | E | NO | All gc-leaf, `:1022–1046`. |
| `eco_register_type_graph(ptr)` | Register `__eco_type_graph` at init | E | NO | gc-leaf, `:875`. |
| `eco_print_value`, `eco_print_elm_value`, `eco_value_to_string{,_typed}`, `eco_output_text`, `eco_{set,get}_output_stream`, `eco_enable_list_chunks` | Value printing / harness plumbing | E / RT | never emitted by codegen | Kernel or driver only. |

### I. Platform / ports / scheduler — **empty for generated code**

`PortRuntime.hpp:118–125` exports six weak C symbols (`eco_port_send`, `eco_port_subscribe`,
`eco_port_unsubscribe`, `eco_port_count`, `eco_port_name`, `eco_port_is_incoming`).
**None is referenced anywhere under `runtime/src/codegen/`** — not emitted, not
JIT-registered. Their only consumers are `runtime/src/embed/eco_embed.{h,cpp}` and
`eco_node_addon.cpp`. `PlatformRuntime.hpp` and `Scheduler.{hpp,cpp}` contain **zero**
`extern "C"` declarations at all — pure C++ classes reachable only through
`Elm_Kernel_Platform_*` kernel shims (JIT-registered at `RuntimeSymbols.cpp:835–843`).
Likewise `ListOps`/`StringOps`/`BytesOps` have **no C linkage whatsoever** — they are
`namespace Elm::{ListOps,StringOps,BytesOps}` backends behind kernel shims.

---

## Part 2.1 — Which allocation shapes are inline today

| Shape | Inline bump? | Gate | Site |
|---|---|---|---|
| ElmInt box (i64) | **YES** | none | `EcoToLLVMHeap.cpp:221` |
| ElmFloat box (f64) | **YES** | none | `EcoToLLVMHeap.cpp:221` |
| ElmChar box (i16) | **YES** | none | `EcoToLLVMHeap.cpp:221` |
| Bool | **no allocation at all** | — | embedded constants, `EcoToLLVMHeap.cpp:257–268` |
| Cons | **YES** | none | `EcoToLLVMHeap.cpp:445`; `EcoToLLVMValueAgg.cpp:580` |
| Tuple2 | **YES** | none | `EcoToLLVMHeap.cpp:670`; `ValueAgg.cpp:237` |
| Tuple3 | **YES** | none | `EcoToLLVMHeap.cpp:759`; `ValueAgg.cpp:314` |
| Record | **YES** | `recByteSize ≤ 4096` | `EcoToLLVMHeap.cpp:951`; `ValueAgg.cpp:396` |
| Custom | **YES** | `cusByteSize ≤ 4096` | `EcoToLLVMHeap.cpp:1090`; `ValueAgg.cpp:478` |
| Closure / PAP create | **YES** | `cloByteSize ≤ 4096` | `EcoToLLVMClosures.cpp:756`; `ValueAgg.cpp:805` |
| Zero-capture interned closure | NO | — | `eco_intern_closure0`, `EcoToLLVMClosures.cpp:740` |
| String (any) | **NO** | dynamic size / interning | `eco_alloc_string*` |
| Array (any) | **NO** | dynamic size | `elm_array_*` |
| `eco.allocate` / `eco.allocate_ctor` (dynamic size) | **NO** | — | `EcoToLLVMHeap.cpp:337,376` |
| Sibling closure group (let-rec) | **NO** | — | `eco_alloc_closure_group_slow` |
| PAP extend | **NO** | — | `eco_pap_extend` |
| Cons-accumulation loops | replaced by scratch templates | — | `EcoListTemplate.cpp` |

The whole inline family is one shared emitter — `emitInlineAllocWithHeader`
(`EcoToLLVMInternal.h:837–862`) + `emitInlineAllocMetaWord` (`:864–878`) +
`emitFreshFieldStore` (`:794–825`) — gated by `inlineAllocEnabled()`
(`EcoToLLVMInternal.h:760–767`, default ON, `ECO_INLINE_ALLOC=0` restores calls).
Expansion to the actual bump diamond is `expandInlineAllocs`
(`EcoBackend.cpp:986–1130`), pre-RS4GC. Capacity-check hoisting
(`applyCapacityHoisting`, `EcoBackend.cpp:~2150–2400`, CGEN_074, default-ON) can strip
the compare/slow-edge/phi entirely for runs covered by a dominating
`eco_ensure_nursery_slow`.

**Could the remaining ones be inlined?** Strings and arrays cannot without a
variable-size bump (the marker requires a compile-time-constant size — HEAP_034(a)),
which is a real but bounded extension: the diamond generalises to a runtime `size`
operand with no other change to the invariant. `eco_intern_closure0` is a hash-table
probe, not an allocation shape — inlining would mean inlining the probe, not the bump.
`eco_pap_extend` is a copy-and-extend whose size is known at the call site and is a
plausible future inline candidate.

## Part 2.2 — `eco_apply_closure` / `eco_apply_closure_typed`, and whether typed calling bypasses them

- `eco_apply_closure(clo, u64* args, n)` (`RuntimeExports.h:371`) is the fully generic
  apply: it reads `n_values`/`max_values` off the closure header and handles
  under-saturated (build a new PAP), exactly-saturated (call the evaluator), and
  over-saturated (saturate this stage, then recurse into the resulting closure).
- `eco_apply_closure_typed(clo, i64* typed_args, n, layout)` (`RuntimeExports.h:385`) is
  the Phase-D entry: the args buffer is raw `i64` and each slot's interpretation comes
  from `layout->kinds[i]`; it re-boxes non-`PK_Boxed` slots and forwards to
  `eco_apply_closure`. CGEN_059 makes this the **single locus** where re-boxing may
  happen — the LLVM IR for a generic apply is forbidden from containing
  `eco_alloc_int/_float/_char` calls introduced purely to box arguments.
  `eco_apply_closure_eval` adds a typed *result* slot; `eco_apply_segmentation_unknown`
  routes under-saturated → `eco_pap_extend`, saturated/over → `_typed`.

**Yes, the typed-closure-calling path bypasses them for known-arity calls.** The
`_dispatch_mode` attribute (CGEN_CLOSURE_007, always present) selects among three
lowerings in `emitDispatchedClosureCall` (`EcoToLLVMClosures.cpp:1390–1430`):

- `"fast"` → `emitFastClosureCall` (`:1222`): inline `__eco_resolve_fwd` diamond, inline
  capture loads at fixed offsets, then a **direct `call @lambda$cap(caps…, args…)`**.
  Zero runtime helpers. This is the hot path (the comment at `:1237` records 99.6 M
  resolves/run at Run-M scale).
- `"closure"` → `emitClosureCall` (`:1334`): one `eco_resolve_hptr` call, a load of
  `closure->evaluator` at offset 16, then a **typed indirect call**. Still no
  `eco_apply_*`.
- `"unknown"` → `emitUnknownClosureCall` → the `eco_apply_*` family.

So the `eco_apply_*` surface is now reached only from `_dispatch_mode="unknown"`,
generic-mode `eco.papExtend` (CGEN_058: no `remaining_arity` attribute), and
`segmentation_unknown` callees. This matches the recorded HOF-elimination result
(P6: −99.2% dispatch events).

One residual: `emitClosureCall` calls `eco_resolve_hptr` **unconditionally**
(`EcoToLLVMClosures.cpp:1344`) rather than using the `__eco_resolve_fwd` marker the
fast path uses — an easy inline win on the heterogeneous path.

## Part 2.3 — What purity/memory attributes are on runtime and kernel calls today

**Answer: essentially none. Exactly one symbol in the entire compiler carries LLVM
memory-effect attributes.**

Exhaustive grep over `/work/runtime/src/` for `readnone|readonly|memory(|
setDoesNotAccessMemory|setOnlyReadsMemory|nounwind|setDoesNotThrow|willreturn|
setWillReturn|speculatable|setSpeculatable|argmemonly|inaccessiblemem|
MemoryEffectsAttr|memory_effects|Attribute::ReadNone|…` returns **six lines, all in
one file, all about one symbol**:

```
/work/runtime/src/codegen/EcoBackend.cpp:1015   bs->setDoesNotAccessMemory();   // memory(none)
/work/runtime/src/codegen/EcoBackend.cpp:1016   bs->setDoesNotThrow();          // nounwind
/work/runtime/src/codegen/EcoBackend.cpp:1017   bs->setWillReturn();
/work/runtime/src/codegen/EcoBackend.cpp:1018   bs->setSpeculatable();
/work/runtime/src/codegen/EcoBackend.cpp:1019   bs->addFnAttr("gc-leaf-function");
```

…plus the identical five-line block duplicated for the capacity-hoisting pass at
`EcoBackend.cpp:2219–2223`. The symbol is `eco_bump_state`. The only other
attribute setters anywhere are three bare `nounwind`s:
`EcoBackend.cpp:1030` (`eco_alloc_inline_slow`), `EcoBackend.cpp:2235`
(`eco_ensure_nursery_slow`), and the two `eco_bump_state` sites above.

Everything else gets **at most the string attribute `"gc-leaf-function"`**, which is
**not a memory-effect attribute**: it is consumed solely by
`llvm::callsGCLeafFunction` to tell `RewriteStatepointsForGC` not to insert a
statepoint. It says nothing to LLVM's alias analysis, GVN, LICM, CSE, or DCE.

Where each attribute path is set:

| Emitter | Attributes attached | File:line |
|---|---|---|
| `EcoRuntime::getOrCreateFunc(..., gcLeaf)` — the single locus for **all** runtime decls | `passthrough = ["gc-leaf-function"]` when `gcLeaf=true`, otherwise **nothing** | `EcoToLLVMRuntime.cpp:141–149` |
| `KernelFuncOpLowering` — the single locus for **all** `Elm_Kernel_*` / `Eco_Kernel_*` decls | **nothing at all** (external linkage only) | `EcoToLLVMFunc.cpp:26–96`, esp. `:85–87` |
| `BFToLLVM` bytes-fusion decls | **nothing at all** — not even gc-leaf | `BFToLLVM.cpp:99–130` |
| `installCafMemoGuard` | `passthrough = ["gc-leaf-function"]` on `eco_caf_promote` | `EcoToLLVMGlobals.cpp:590–597` |
| `runEcoBackend` prologue | `gc-leaf-function` on `eco_scratch_mark/_push_boxed/_push_scalar` | `EcoBackend.cpp:2510–2513` |
| marker expansions | `gc-leaf-function` on `__eco_resolve_fwd`, `__eco_slot_to_hptr`, `eco_follow_forward`, list-proj slow fns | `EcoBackend.cpp:885–887, 1172–1186, 1272–1276, 1436` |
| `gcFreeLeafPropagation` | `gc-leaf-function` on **generated** functions proved GC-free | `EcoBackend.cpp:1716` |

**Consequences.** The runtime and the kernel are compiled into separate objects; there
is no LTO anywhere in the build (`grep -rn 'flto|LTO|ThinLTO'` over `CMakeLists.txt` /
`CMakePresets.json` returns nothing). So LLVM sees every runtime and kernel symbol as
an attribute-free external declaration and must assume the worst: **may read and write
all memory, may throw, may not return, may free memory**. Every `Elm_Kernel_*` call,
every `eco_alloc_*` / `eco_cons_head_i64` / `eco_int_pow` / `Eco_Runtime_getOrderLT`
call is a full optimisation barrier for GVN/LICM/CSE/DSE and for load forwarding across
it. `PostOrderFunctionAttrs` (which runs in the Cgu `-O2` leg via
`mlir::makeOptimizingTransformer`, `EcoBackend.cpp:296`) cannot help — it only infers
attributes for functions with bodies. `InferFunctionAttrs` helps only for names in
TargetLibraryInfo, i.e. `asin`/`acos`/`atan`/`atan2` and libc calls.

**Counter-consideration (a real constraint, not a hypothetical).** Motion-enabling
attributes are *deliberately* withheld in at least one documented place:
`EcoToLLVMRuntime.cpp:886–891` says of the slot-cast barriers —
"Attrs are gc-leaf ONLY — do NOT add `memory(none)`/`speculatable`/`willreturn`:
motion-enabling attributes would let a pre-RS4GC pass move the call across a
statepoint, recreating exactly the raw-i64 crossing the barrier exists to prevent."
Any purity-attribute campaign must respect this: RS4GC relocation semantics mean a
`memory(none)` call taking a `ptr addrspace(1)` argument can be sunk past a statepoint
and then read a stale, unrelocated pointer. The safe subset is symbols whose arguments
and results are **not** GC pointers.

**Symbols that are safe candidates today** (no `ptr addrspace(1)` in the signature,
no runtime state, no allocation):

- `eco_int_pow(i64,i64) -> i64` — `memory(none) nounwind willreturn speculatable`.
  Fully pure; the only such symbol on the arithmetic path.
- `asin`/`acos`/`atan`/`atan2` — same (LLVM already knows these by name in the `-O2`
  leg, but the Dev leg's function-simplification-only pipeline does not run
  `InferFunctionAttrs`).
- `eco_crash` — `noreturn` (+ `cold`). Currently missing despite `[[noreturn]]` on the
  C++ declaration at `RuntimeExports.cpp:2788`.
- `eco_dbg_print*`, `eco_output_text` — `nounwind` at least.

**Symbols that are `readonly`-shaped but GC-pointer-typed** (would need care, or the
`__eco_resolve_fwd`-style marker treatment instead of an attribute):
`eco_cons_head_i64/_f64/_i16`, `eco_get_header_tag`, `eco_get_custom_ctor`,
`eco_list_head_hybrid`, `Eco_Runtime_getOrder{LT,EQ,GT}`, and the 24 dead
`eco_*_get_*` accessors.

---

## Key findings

1. **The emitted LLVM IR carries essentially no purity information.** Exactly one
   symbol — `eco_bump_state` — has memory-effect attributes, set at
   `EcoBackend.cpp:1013–1019` and duplicated at `2219–2223`
   (`memory(none)`, `nounwind`, `willreturn`, `speculatable`, `gc-leaf-function`).
2. **Three bare `nounwind`s exist and nothing else:** `eco_bump_state`
   (`EcoBackend.cpp:1016`, `2220`), `eco_alloc_inline_slow` (`:1030`),
   `eco_ensure_nursery_slow` (`:2235`). No `readnone`, `readonly`, `argmemonly`,
   `inaccessiblememonly`, `willreturn`, `speculatable`, `noreturn`, `nofree`, or
   `noalias` is set on any other symbol anywhere in `runtime/src/`.
3. **`gc-leaf-function` is not a purity attribute.** It is a string attr read only by
   `llvm::callsGCLeafFunction` to suppress statepoint insertion in RS4GC
   (`EcoBackend.cpp:1604`, `1700–1705`). It conveys nothing to AA/GVN/LICM/CSE. Roughly
   90 runtime decls carry it; that is the entire "purity" story today.
4. **Kernel calls carry zero attributes.** `KernelFuncOpLowering`
   (`EcoToLLVMFunc.cpp:26–96`) is the sole emitter of every `Elm_Kernel_*` /
   `Eco_Kernel_*` declaration and sets only `Linkage::External`. Same for the entire
   bytes-fusion family in `BFToLLVM.cpp:99–130` — those get not even `gc-leaf`.
5. **No LTO.** The runtime/kernel objects are never visible to the LLVM pipeline that
   optimises generated code, so every kernel/runtime call is an unqualified
   optimisation barrier. `PostOrderFunctionAttrs` cannot recover anything (no bodies);
   `InferFunctionAttrs` recovers only recognised libcalls.
6. **MLIR *does* model purity — and then throws it away.** 104 `Pure` traits in
   `Ops.td` (`get_tag`, every `project.*`, `array.get/length`, `box`, `unbox`,
   `construct.list/record/custom`, `papCreate`, all arithmetic). MLIR CSE/DCE exploits
   this pre-lowering, but nothing propagates it to the LLVM level. `eco.call` and
   `eco.papExtend` are correctly non-Pure.
7. **Inline bump allocation covers every fixed-shape allocation**: Int/Float/Char
   boxes, Cons, Tuple2, Tuple3, and (≤ 4096 B) Record, Custom, Closure. Bool never
   allocates. Strings, arrays, dynamic-size `eco.allocate`, `eco_intern_closure0`,
   `eco_pap_extend`, and closure groups still take C++ calls.
8. **The whole inline-alloc family funnels through three helpers** —
   `emitInlineAllocWithHeader` / `emitInlineAllocMetaWord` / `emitFreshFieldStore`
   (`EcoToLLVMInternal.h:794–878`) — expanded by `expandInlineAllocs`
   (`EcoBackend.cpp:986–1130`) before every RS4GC flavour. One choke point.
9. **`eco_resolve_hptr` and `eco_get_tag` are already inline** via the
   `__eco_resolve_fwd` / `__eco_get_tag_inline` markers; the remaining direct calls are
   A/B-leg fallbacks — **except `emitClosureCall` (`EcoToLLVMClosures.cpp:1344`), which
   calls `eco_resolve_hptr` unconditionally on the `_dispatch_mode="closure"` path.**
   That is a free inline win.
10. **`eco_apply_closure*` is bypassed for all known-arity calls.** `_dispatch_mode`
    routes `"fast"` to a direct `@lambda$cap` call with inline capture loads
    (`EcoToLLVMClosures.cpp:1222`) and `"closure"` to a typed indirect call (`:1334`).
    The `eco_apply_*` family survives only for `"unknown"`, generic-mode `papExtend`
    (CGEN_058), and `segmentation_unknown`.
11. **24 dead declarations.** `eco_tuple2_get*` (6), `eco_tuple3_get*` (9),
    `eco_record_get_*` (3), `eco_custom_get_*` (3), `eco_array_get_*` (3) are declared
    (`EcoToLLVMRuntime.cpp:722–842`) and force-materialised (`:1222–1231`) but no
    lowering pattern emits them — projections inline via `emitInlinePrimLoad`. Their
    "Pattern C" rationale in `RuntimeExports.h:632–644` is now obsolete; GlobalDCE
    drops them. Likewise the `eco_alloc_*_fast` (10) and `eco_alloc_*_slow` (9)
    families.
12. **`eco_cons_head_i64/_f64/_i16` is the one hot projection still paying a call**
    (`EcoToLLVMHeap.cpp:529,536,543`) — it must handle both boxed and unboxed heads, so
    it needs a diamond, not a single load. A marker-expansion (the `__eco_get_tag_inline`
    pattern) would fit exactly.
13. **`eco_crash` is missing `noreturn`** despite `[[noreturn]]` on the C++ definition
    (`RuntimeExports.cpp:2788`); the decl at `EcoToLLVMRuntime.cpp:848` sets only
    gc-leaf. Free code-size/CFG win.
14. **`Eco_Runtime_getOrder{LT,EQ,GT}` are called three-at-a-time, unconditionally**,
    on every ordering comparison (`EcoToLLVMArith.cpp:1011–1013`), then `select`-ed.
    Each is a single load of a rooted global — three unattributed calls per compare
    that LLVM cannot CSE, hoist, or sink.
15. **There is a documented reason not to add purity attributes naively**:
    `EcoToLLVMRuntime.cpp:886–891` forbids `memory(none)/speculatable/willreturn` on the
    slot-cast barriers because motion across a statepoint recreates the raw-i64 crossing
    they exist to prevent. Any campaign must start with GC-pointer-free signatures —
    `eco_int_pow`, the libm four, `eco_crash`'s `noreturn`, and `nounwind` on the debug
    printers.
