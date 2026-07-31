# Borrow Inference — Phase 0: Up-front Measurement & Groundwork

> **Superseded for sequencing (2026-07-31):** the active optimization
> roadmap is the tier series `plans/opt-tier{1..4}-*.md` (impact-ordered).
> This file remains the implementation spec / as-built record for its
> milestone; do not take execution order from it.

Status: IMPLEMENTATION-READY (v2, deep-dive pass). Parent design:
`design_docs/globalopt/borrow-inference-design.md` (DETAILED DESIGN v2,
2026-07-21) — this phase implements its B0 milestone (§18) plus the
up-front measurement the analysis-first program wants done before any
optimization is scheduled. Series:
`plans/borrow-inference-phase{0..6}-*.md`.

**Dependencies:** none. All units parallelizable. **Gates:** U0.6's B0
report is decision gate **G1** (so named in Phase 5) — it gates Phase 5
(the optimization track), NOT Phases 1–4 (the analysis), which may start
immediately and concurrently.

**CLOSED 2026-07-31 — B0 DONE; D0.6 DISCHARGED.** The B2-final
full-precision census (**32% borrowed**, `wouldFree=13,869`;
`design_docs/borrow-inf-census.md` §16) confirms the preliminary
Strategy-B call this phase produced — the runtime track (B4/B5) stays
deferred. The census doc §17 records the plan-review outcome, including
the **new lateral finding**: stack promotion of
`nonEscapingOwned=1,961,771` (**46.7%** of resources, §15.1) → phase-6
backlog item 8. (B0's as-built record lives in the census doc, §§9–17.)

**Goal:** produce the evidence base — the Perceus-cost denominator, the
dynamic payoff ceiling, the kernel audit, and the runtime-strategy call —
so every later optimization unit is sized by data before it is built.

## Verified facts this plan is built on

1. **Census wiring point** — `Builder/Generate.elm:900`
   `runGlobalOptPhase : Bool -> FEStats.Handle -> Mono.MonoGraph -> Task
   Exit.Generate MonoBuildResult`. It runs
   `MonoGlobalOptimize.globalOptimizeWithStats simplifiedGraph`
   (`:905-906`, the final Mono graph) and, when its `Bool` (`lssReport`,
   plumbed from `ecoConfig.mono.lss.report` at `:823`) is set, emits one
   gated `System.IO.writeLn System.IO.stderr "lss globalopt: …"` line
   (`:913-959`) then `Task.map (\_ -> result)`. This is the exact house
   census idiom U0.1 mirrors — a stderr side-channel that returns
   `optimizedGraph` untouched (analysis-only ⇒ graph-inert).
2. **`MonoTraverse.foldExpr` suffices** — `MonoTraverse.elm:146`
   `foldExpr : (MonoExpr -> acc -> acc) -> acc -> MonoExpr -> acc`
   (exposed, `:3`), bottom-up over every sub-expression; direct-recursion
   (`foldExprAccFirst`, `:160`), no PAP. Design §5.3 blesses it for
   one-shot analysis folds; the AbiCloning first-order-recursion lesson
   applies to *rewrite* passes only. The mono-time precedent is
   `Monomorphize.elm:532-570` (`extractSpecId`/`collectCalls`/
   `collectCallsFromNode` — the four body-carrying node kinds pattern).
3. **Graph shape** — `MonoGraph(..)` is exposed (`Monomorphized.elm:6`);
   pattern-match `MonoGraph { nodes }` gives `nodes : Array (Maybe
   MonoNode)` (`:815`). Body-carrying node kinds are `MonoDefine expr t`,
   `MonoTailFunc params expr t`, `MonoPortIncoming expr t`,
   `MonoPortOutgoing expr t`; `MonoCtor`/`MonoEnum`/`MonoExtern`/
   `MonoManagerLeaf` carry no body (`:865-872`).
4. **Heap-typed decision (mirror of design §7.2, from `MonoType` at
   `Monomorphized.elm:203-215`).** Non-resources: `MInt`, `MFloat`,
   `MBool`, `MChar`, `MUnit`. Resources (heap-typed): `MString`,
   `MList _`, `MTuple _`, `MRecord _`, `MCustom _ _ _`, `MFunction _ _ _`
   (closure env), `MVar _ _` (erased `CEcoValue` box — poisoned).
   Bool/Unit are embedded HPointer constants, never allocated
   (REP_CONSTANT_001, HEAP_010).
5. **Config plumbing** — env→config lives in `Builder/Eco/Config.elm`
   `applyEnvOverrides` (`:104`); `report`-style flags are read via
   `Utils.envLookupEnv` and are **excluded from `hash`**
   (`Compiler/Eco/Config.elm:361-405` never references `report`/
   `validate`/`diffDump`), so a new output-only flag is cache-inert.
6. **Header layout** (`runtime/src/allocator/Heap.hpp:153-165`,
   `static_assert(sizeof(Header)==8)`): first 32-bit word bit-fields,
   clang LSB-first: `tag:TAG_BITS(=5)` [0,4], `color:2` [5,6], `pin:1`
   [7], `age:2` [8,9], `unboxed:6` [10,15], `refcount:15` [16,30],
   `builder:1` [31]; second word `size:u32`. `refcount:15` ⇒ max
   `0x7FFF` = `RC_SATURATED` (design §16.2). The design's "refcount bits
   [16,30]" is exact.
7. **The two object-copy paths** (`NurserySpace.cpp`): promotion —
   `std::memcpy(new_obj, obj, size)` (`:1168`) then `new_hdr->age = 0`
   (`:1171`) + `new_hdr->color = White` (`:1176`); to-space survival —
   `std::memcpy(new_obj, obj, size)` (`:1237`) then `new_hdr->age++`
   unless builder (`:1244-1246`) + `new_hdr->color = White` (`:1248`).
   Both preserve the header by memcpy and edit **only `age` and
   `color`**. There is no third copy path (`evacuate` is the sole
   copier; `evacuateUnboxable` `:1267` delegates to it). Old-gen major
   GC does not relocate live bodies (mark-sweep + free-list coalescing,
   `Heap.hpp:124-133`), so no old-gen header-copy path exists to audit.
8. **Runtime tag names** (`Heap.hpp:77-114`): pointer-free flat buffers
   are `Tag_String` (80), `Tag_ByteBuffer` (91), `Tag_StringUtf8Leaf`
   (112). Interior-pointer (view/spine/split) forms are `Tag_StringRope`
   (94), `Tag_StringSlice` (95), `Tag_ByteBufferSlice` (96),
   `Tag_LargeStringHeader` (101), `Tag_LargeByteHeader` (102),
   `Tag_StringUtf8View` (111). `Tag_Array` (92) carries HPointer slots.

### Design discrepancies

Flagged here and returned in open_questions; do NOT silently reinterpret
the design when populating the B0 report / KernelSigs seed.

- **D0.1 — `Console.write` is NOT a read-only sink.**
  `Eco_Kernel_Console_write(handle, content)`
  (`eco-kernel-cpp/src/eco/ConsoleExports.cpp:9`) returns a
  `Task_Binding` capturing a `Tuple2 {handle:Int, content:String}`
  (`eco-kernel-cpp/src/eco/Console.cpp:52-60` `writeBody`); the binding
  survives the call and is stepped later by the scheduler. `content` is
  therefore a **surviving reference** ⇒ `POwned`, not `PBorrowed`. Only
  the scalar `handle` is trivially borrowed. Net benefit = 0 ⇒ the
  "Console.write-family sinks" allowlist entry (§12.2) is **dropped**;
  the all-owned default is already sound. (Console is also not in
  `design_docs/elm_kernel_functions.csv` at all — it is an `eco/kernel`
  package function under `eco-kernel-cpp`, tracked separately from the
  ~322 `elm/core` C-linkage kernels §12.1 counts.)
- **D0.2 — `List.length` and `String.isEmpty` are not kernels.** Neither
  appears in `design_docs/elm_kernel_functions.csv` (List kernels are
  `cons/fromArray/map2..5/sortBy/sortWith/toArray`, lines 76-85; String
  kernels include `length/startsWith/endsWith/contains` but not
  `isEmpty`). Both are pure-Elm (`List.foldl`-based / `== ""`), so they
  never surface as `MonoVarKernel` — a `KernelSigs` entry would be dead
  weight. They are handled by the Phase-3 SCC fixpoint as ordinary
  SpecIds. Drop both from the §12.2 seed; the design's phrasing is a
  documentation error.
- **D0.3 — `Debug.log` returns its argument by identity.**
  `Elm_Kernel_Debug_log(tag, value)` prints then `return value`
  (`elm-kernel-cpp/src/core/DebugExports.cpp:26-45`). The result
  **aliases param 1** ⇒ model as `resultAliases = Just 1` (a §8.3 `gets`
  vertical flow), not a plain `PBorrowed` result. `Debug.toString`
  produces a fresh string (`eco_value_to_string_typed`, `:56`) ⇒
  `resultAliases = Nothing`.
- **D0.4 — GC edits `color` and `age` only, never `pin`.** The outline's
  "modulo color/age/pin" phrasing hypothesized `pin` might be GC-edited
  on copy. (§16.2 itself says the header must be carried "verbatim",
  `:1411-1413` — which is imprecise the other way, since GC does
  legitimately edit `age`/`color`; the "modulo color/age/pin" wording is
  the outline's, not §16.2's.) Fact 7 shows `pin` is memcpy-preserved and never
  written by either copy path (it gates the *promotion predicate* at
  `:1163` but is not mutated). U0.5's assertion mask therefore excludes
  `color` + `age` and **includes** `pin` (plus `builder`, `unboxed`,
  `refcount`, `tag`, `size`).
- **D0.6 — the §22.1 runtime-strategy call: B0 vs B2 (design-internal
  inconsistency).** §18's B0 bullet (design `:1505-1506`) assigns "the
  runtime-strategy call with DS6's evidence" to **B0**, but §22.1
  (`:1664-1665`) states "**The B2 census is the deciding evidence**" for
  the very same A/B/C call. The design contradicts itself on whether B0
  or B2 decides. This plan resolves it as: the B0 §22.1 call (U0.6) is a
  **preliminary go/no-go** made from DS6 + U0.2's dynamic-ceiling data,
  and is **revisited/confirmed by the B2 static census** (Phase 2) per
  §22.1 — not the final, irrevocable word. Returned as an open question;
  do not read the B0 call as definitive if B2's census later contradicts
  the ceiling.
- **D0.5 — `heap-profile.py` has no per-tag counters.** It reports
  allocation-size histograms (Nursery/Old-Gen/**String**), old-gen page
  residency + promotion, free-list size-classes, GC cycle counts and
  bytes/objs (fact under U0.2). There is no `Tag_ByteBuffer`-level
  count. U0.2 uses the String histogram + residency for the string/byte
  buffer families and records the per-tag gap as a B4 tooling item, not
  a Phase-0 blocker.

## U0.1 — Static RC-traffic census (the Perceus denominator)

A cheap syntactic count over the final Mono graph (no solving): per-def
and aggregate — heap-typed occurrences, would-be dups under the
all-owned model (every non-final owned occurrence), would-be drops,
per-type split (strings / lists / records / customs / closures),
immortal-literal share. Throwaway-shaped — superseded by the real B2
census (Phase 2); delete this unit's code when B2 lands.

> **Cleanup OUTSTANDING (2026-07-31).** B2's real census landed
> 2026-07-26 (`design_docs/borrow-inf-census.md` §9) but the deletion
> has NOT been performed — `ECO_BORROW_CENSUS0` still exists:
> `Compiler/Eco/Config.elm` `borrowCensus0`, `Builder/Eco/Config.elm`
> `applyBorrowCensus0Override` (~:369-374), and the
> `Builder/Generate.elm` fold. Recorded here as an outstanding cleanup
> item, not performed as part of this closure stamp.

**Flag plumbing (`ECO_BORROW_CENSUS0=1`, output-only, hash-inert —
mirror `mono.validate`).** Five edits:

1. `Compiler/Eco/Config.elm:61` — add field to `MonoConfig`:
   `, borrowCensus0 : Bool  -- env ECO_BORROW_CENSUS0=1; Phase-0 throwaway
   census, excluded from hash`.
2. `Compiler/Eco/Config.elm:231` (`default.mono`) — add
   `borrowCensus0 = False`.
3. `Compiler/Eco/Config.elm` `monoDecoder` lambda (`:286-289`, the block
   that sets `diffDump`/`validate` from `default`) — add
   `borrowCensus0 = default.mono.borrowCensus0` (env-only, never JSON).
4. `Builder/Eco/Config.elm` — add an override in `applyEnvOverrides`
   (`:104`) modelled on the `ECO_INLINE_REPORT` handler (`:144`,
   `:508-531`): `Utils.envLookupEnv "ECO_BORROW_CENSUS0"` →
   `{ cfg | mono = { mono | borrowCensus0 = True } }` on `"1"/"true"/
   "yes"`.
5. `Builder/Generate.elm:823` — thread the flag:
   `runGlobalOptPhase ecoConfig.mono.lss.report ecoConfig.mono.borrowCensus0
   stats`; widen `runGlobalOptPhase`'s signature (`:900`) with a second
   `Bool` and, inside the existing `let` (`:904`), append the census
   emit. `hash` is untouched (fact 5) so flag-off caches are unaffected.

**The fold (add a private `borrowCensus0Line : Mono.MonoGraph ->
String` helper in `Generate.elm` near `abiCensusLines`, `:971`).** Over
`Array.foldl` on `nodes`, per `Just node` of a body-carrying kind
(fact 3), first tally that node's own binders into `wouldDrops` (they are
NOT reachable by the body fold — see below), then run
`MonoTraverse.foldExpr classify emptyAcc body`:

**Binder tally (per-node wrapper, not the body fold).** Param binders live
at the *node* level, outside the body the fold traverses: `MonoTailFunc
(List (Name, MonoType)) …` (`Monomorphized.elm:866`) and `MonoTailDef Name
(List (Name, MonoType)) …` (`:967`) carry their params as `(Name,
MonoType)` pairs. In the `Array.foldl` layer that already dispatches on
node kind, count each param whose `MonoType` is `heapTyped` as a candidate
`wouldDrops`. Let-bound binders are reached by the body fold instead, via
an explicit `MonoLet` case in `classify` (below) — their type is not on the
`MonoDef` (`MonoDef Name MonoExpr`, `:966`; no type field) so it is
recovered from the bound expression with `Monomorphized.typeOf`
(exposed, `:12`; `:1126`) and counted when `heapTyped`.

```elm
type alias Census0 =
    { heapOcc : Int, wouldDups : Int, wouldDrops : Int
    , strings : Int, lists : Int, records : Int, customs : Int
    , closures : Int, immortal : Int }
```

`classify : MonoExpr -> Census0 -> Census0`:
- On `MonoVarLocal _ t` / `MonoVarGlobal _ _ t` — if `heapTyped t`,
  bump `heapOcc` and the per-type bucket via `bucketOf t` (`MString→
  strings`, `MList→lists`, `MRecord→records`, `MCustom→customs`,
  `MFunction→closures`; `MTuple`/`MVar` fold into `customs`). Under the
  all-owned model every occurrence but the last of a binding is a dup;
  a syntactic upper bound (no liveness) is `wouldDups += 1` per
  non-first occurrence — for the Phase-0 denominator count **every**
  heap-typed variable occurrence as a candidate dup. (Candidate drops
  come from the binder tally above, not from occurrences.) The real
  refinement is B2; keep this a raw ceiling.
- On `MonoLet def _ _` — inspect `def`'s bound binder: for `MonoDef _ e`
  take `heapTyped (Monomorphized.typeOf e)`, for `MonoTailDef _ _ e`
  likewise (its params are counted where the enclosing node is, not
  here) — when heap-typed, `wouldDrops += 1`. This is the only path by
  which let binders reach the census (params are tallied in the per-node
  wrapper above).
- On `MonoLiteral (LStr _) _` — `immortal += 1` (interned string
  constants carry saturated counts, S5). `LStr` is the sole heap-typed
  literal: `LChar` is `MChar` (a non-resource, fact 4) and
  `LBool`/`LInt`/`LFloat` are unboxed.
- `heapTyped : MonoType -> Bool` and `bucketOf` are the only new pure
  helpers; both live in the `where`/`let` of the emit block — throwaway,
  not exported.

Emit one house-pattern line:
`borrow census0: heapOcc=… wouldDups=… wouldDrops=… strings=… lists=…
records=… customs=… closures=… immortal=…` via
`System.IO.writeLn System.IO.stderr`, then `|> Task.map (\_ -> result)`
(same shape as `:917-959`). Do NOT add `Debug.*` (kept out of the
bootstrap chain).

## U0.2 — Dynamic payoff ceiling (profile before building)

Eco is GC'd: RC pays only through RC-1 mutation, old-gen reclaim, and
static uniqueness (design DS6). Measure the ceiling.

**perf profile — diag build recipe.** The `build` preset ships
`-fomit-frame-pointer` implicitly and tail-optimizes wrappers, which
breaks perf's fp caller attribution (the R5.M lesson,
`allocator-resolve-inlining.md:357-367`). Configure a separate diag tree
reusing the `build` preset's flags plus both frame flags (the
`-fno-omit-frame-pointer` is the decisive one):

```bash
cmake --preset build -B build-diag \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -g -UNDEBUG -fno-omit-frame-pointer -fno-optimize-sibling-calls" \
  -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -g -UNDEBUG -fno-omit-frame-pointer -fno-optimize-sibling-calls"
cmake --build build-diag        # then lower the cold subst self-compile workload
```

`-B build-diag` overrides the preset `binaryDir` (`${sourceDir}/build`);
the C++ flags do not touch compiled-Elm codegen. Profile the standard
cold subst self-compile at `perf record -F 199 --call-graph fp`. Diag
walls are **shares-only** (frame-keeping taxes the runtime) — never
compare them to production Run-P/Q walls.

Bucket flat samples into the buffer-family cost classes (symbol names
verified present): string copy/append/slice/join —
`StringOps::forEachSegmentEx`, `StringOps::join`, `StringOps::compare`,
`StringOps::slice` (`runtime/src/allocator/StringOps.cpp`); Bytes codec
helpers — `writeEncoder`, `encoderSize`, `Elm_Kernel_Bytes_read_string`,
`Elm_Kernel_Bytes_write_string`
(`elm-kernel-cpp/src/bytes/BytesExports.cpp:144,124,588,877`);
buffer-family allocation — `eco_alloc*` sites stamping `Tag_ByteBuffer`/
`Tag_String`/`Tag_StringUtf8*`. Record each class's flat %.

**heap profile — `/work/heap-profile.py` (fact D0.5).** Run mode
compiles Stage-7 once with a heap config and parses runtime stdout into
per-block TSVs. Available signal for the `rcManaged` families:
`String Allocation Size Histogram` (string-leaf allocs by size,
`heap-profile.py:1042-1046`, source `GCStats.cpp:1305`), Nursery/Old-Gen
size histograms (`:1041-1044`), `Old-Gen Page Residency Histogram`
(promotion/old-gen churn, `:1057-1059`, `GCStats.cpp:153`),
`major_gcs`/`minor_gcs`/`objs_alloc`/`bytes_alloc_MB`/`peak_commit_MB`/
`final_live_MB` (`SUMMARY_COLUMNS`, `:161-170`). It does **not** break
down by `Tag_ByteBuffer` — record that per-tag counters are a B4 GCStats
add, and for Phase-0 read the string/byte families off the String
histogram + residency, and old-gen large-body churn off the residency +
free-list histograms (HEAP_026 pinned bodies).

**Benchmark hygiene** per `benchmarks/runtime-calls.md`: interleaved
legs ×3, cold Stage-7a, **record major-GC counts alongside every wall**
(the major-GC trigger-lottery lesson). Set `ECO_INLINE_ALLOC=0`
(HEAP_034 inline-nursery-alloc) for census-comparable attribution if
inline alloc smears buffer alloc into the mutator.

Output: a ceiling table in the B0 report — flat % in each buffer class,
buffer-family alloc/promotion volume, and the go/no-go framing for
§22.1 (does RC-1-on-buffers clear the B4/B5 build cost, or stop at
B3.5).

## U0.3 — Kernel audit + counting-obligation checklist

Audit criterion (§12.2): *reads argument heap data; never stores the arg
or an interior pointer into a result/global; result shares no identity
unless declared `resultAliases`.* Keying is plain `(home, name)`
(Phase-3 fact 3). Suffix instances (`_Int/_Float/_Char`) are an
MLIR-emission concern only and never change borrow behavior.

**Allowlist audit table (≥6 verified; verdict → evidence).** This is
the B0-report content and the Phase-3 `KernelSigs.lookup` seed.

| kernel `(home,name)` | verdict | evidence |
|---|---|---|
| `(Utils,compare)` | all params `PBorrowed`, `resultAliases=Nothing` | `Utils.cpp:400` `compare` → `cmp(a,b)` then encodes an `ORDER_*` singleton; structural read only |
| `(Utils,equal)` | params `PBorrowed` | `Utils.cpp:412` `equal`→`eqHelp` (`:416`) reads via `getTag`/`StringOps::equal`; returns bool |
| `(Utils,notEqual/lt/le/gt/ge)` | params `PBorrowed` | thin wrappers over `cmp`/`eqHelp` (same read-only core); CSV lines 135-139 |
| `(String,length)` | param `PBorrowed` | `StringExports.cpp:18` → `String::length(ptr)`; no store, scalar result |
| `(String,startsWith/endsWith/contains)` | params `PBorrowed` | `StringExports.cpp:106/110/114` → `StringOps::startsWith`… → boxed bool; `String.cpp:430` confirms pure read |
| `(JsArray,length)` | param `PBorrowed` | `JsArrayExports.cpp:204` → `alloc::arrayLength`; scalar result |
| `(JsArray,unsafeGet)` | params `[PBorrowed,PBorrowed]`, `resultAliases=Just 1` | `JsArrayExports.cpp:210` reads elem at index from `array` (**param 1**, the second arg — `unsafeGet index array`) and returns it/boxes it; result aliases the array's element ⇒ `Just 1` |
| `(Debug,log)` | params `[PBorrowed,PBorrowed]`, `resultAliases=Just 1` | `DebugExports.cpp:26` `return value` (identity — D0.3) |
| `(Debug,toString)` | param `PBorrowed`, `resultAliases=Nothing` | `DebugExports.cpp:56` → `eco_value_to_string_typed` (fresh string) |
| `(Basics,*)` numeric | documentation only | scalar args carry no resource (fact 4) — entries record intent, cost 0 |
| ~~`(List,length)`~~ | **not a kernel** — drop | D0.2 |
| ~~`(String,isEmpty)`~~ | **not a kernel** — drop | D0.2 |
| ~~`Console.write`~~ | **not `PBorrowed`** — drop | D0.1 (`content` stored into binding) |

`unsafeGet`'s `resultAliases=Just 0` in §12.2 assumes `(array,index)`
arg order; the C signature is `unsafeGet index array` (index first), so
the aliased param is **index 1** — confirm the Mono-level arg order in
Phase 3 before committing the integer.

**§12.3 counting-obligation set (RC-mode surviving-reference creators).**
Concrete, byte/string-local for the v1 pointer-free-buffer scope — every
kernel that creates a *surviving* reference to a `rcManaged` value or an
interior view into a backing buffer must `inc` it before B4:

- **View/slice makers** (interior pointer into a backing leaf →
  `Tag_StringSlice`/`Tag_StringUtf8View`, S3 corollary):
  `String.slice` (`StringExports.cpp:56` → `StringOps::slice`,
  `StringOps.cpp:31` allocs `Tag_StringSlice`, `:118` allocs
  `Tag_StringUtf8View`), and the slice-emitting `String.split`, `lines`,
  `words`, `trim*` (`StringExports.cpp:61-104`; `String.cpp:225,337`
  call `StringOps::slice` internally).
- **String builders** (produce a fresh leaf/rope holding refs):
  `String.append/join/cons/fromList/reverse/toUpper/toLower`
  (`StringExports.cpp:29-88`).
- **Bytes codecs**: `Bytes.Encode.encode` (writeEncoder tree →
  `Tag_ByteBuffer`, `BytesExports.cpp:144`), `Bytes.Decode.string` /
  `Bytes_read_string` (`:588` — builds a string view over the byte
  buffer, zero-copy per the UTF-8 pipeline ⇒ surviving interior ref),
  `Bytes_write_string` (`:877`).
- **`Json.Encode.string`**: `Elm_Kernel_Json_wrap`
  (`json/JsonExports.cpp:1560`) stores the string HPointer into an
  `ENC_STRING` custom node (`:1590`) — the encoder tree retains the arg.

The §12.3 audit lands as a B0-report checklist (kernel → obligation →
file:line); it is scheduled before **B4**, not before the analysis
milestones, and is the borrow twin of the MonoSolver kernel-honesty
frontier (`solver-reuse-evaluation.md §6.3`).

## U0.4 — View-counting decision (design §22.2)

Resolve per string form: count-at-view-creation vs exclude view-backed
forms from RC-1 (S3 corollary — `Tag_StringUtf8View` interior pointers
are invisible to both the count and the statics; the backing must be
counted or the form excluded; no third option). Verified form split
(fact 8):

| form | interior HPointer? | RC-1 eligible (pointer-free)? | v1 disposition |
|---|---|---|---|
| `Tag_String` / `Tag_ByteBuffer` / `Tag_StringUtf8Leaf` | no | yes | **rcManaged** (backing, counted) |
| `Tag_StringUtf8View` / `Tag_StringSlice` / `Tag_ByteBufferSlice` | yes (`base`) | no | **excluded** from `rcManaged` v1 |
| `Tag_StringRope` | yes (`left`/`right`) | no | excluded |
| `Tag_LargeStringHeader` / `Tag_LargeByteHeader` | yes (`body`) | no (header); body ∈ rcManaged | header excluded; body counted (HEAP_026) |

Because the view/slice forms are themselves excluded from `rcManaged`
v1, RC-1 mutation never targets a view. The remaining live question is
the **backing**: a view creates an uncounted interior alias to a
pointer-free leaf that *is* rcManaged, so RC-1-mutating that leaf while a
view aliases it is the S3 hazard. **Decision framework, resolved with
U0.2's data:** default = *exclude the backing leaf from RC-1 whenever any
view over it can be live* (conservative, zero-copy-preserving), UNLESS
U0.2 shows view-backed volume is a large share of mutation candidates,
in which case *count-at-view-creation* for that form (inc the backing at
`StringOps::slice`/`Bytes_read_string`, adding those to the §12.3 inc
set). Output: a per-form decision row in the B0 report; the U0.2 view-
backed-volume number is the tie-breaker and is the recorded input.

## U0.5 — Refcount header-preservation audit

The §16.2 obligation: minor-GC copy and promotion must carry the header
word — including `refcount` [16,30] — verbatim, else survivors reset to
0 = "untracked" and RC-1 silently dies for promoted objects.

**Audit result (read-only, fact 7):** both copy paths in
`NurserySpace::evacuate` use `std::memcpy(new_obj, obj, size)`
(promotion `:1168`, to-space `:1237`) which preserves the full 8-byte
header by construction, then edit **only** `age` and `color`. There is
no header-rebuild path and no old-gen relocation path. So RC-1 is safe
today; the risk is a *future* refactor that replaces memcpy with a
field-wise header construction and forgets `refcount`. The assertion is
that regression tripwire.

**Assertion placement (added at B4 with `reify=rc`, scaffolded now under
`#if ECO_HEAP_VALIDATE`).** In `evacuate`, immediately after
`size = getObjectSize(obj)` (`:1154`, before either branch mutates
anything), snapshot the source: `const Header srcHdr = *hdr;`. Add a
static helper `assertHeaderPreservedAcrossCopy(const Header& src, const
Header* dst)` and call it at the tail of each branch — in the promotion
branch after `:1176` and in the to-space branch after `:1248` (both
after `age`/`color` are set, before the source is overwritten with the
forwarding pointer at `:1259-1262`). Compare **field-wise** (avoids
bit-order assumptions), asserting equality of every non-GC-edited field:

```cpp
assert(dst->tag == src.tag && dst->pin == src.pin &&
       dst->unboxed == src.unboxed && dst->refcount == src.refcount &&
       dst->builder == src.builder && dst->size == src.size &&
       "HEAP: minor-GC copy/promotion must preserve header modulo age/color");
// color and age are the ONLY fields GC legitimately edits on a copy (D0.4).
```

`pin` is **included** in the preserved set (D0.4 — the outline's guess
that GC edits `pin` is wrong). The equivalent bitmask form is
`(src_word & ~0x360u) == (dst_word & ~0x360u)` on the first 32-bit word
(`color`=0x60, `age`=0x300) plus `src.size == dst.size`; the field-wise
form is preferred for clarity. Gate: green under `ECO_HEAP_VALIDATE` on
the full E2E corpus (§Gates). Until B4, `refcount` is always 0 (unused),
so the assertion is trivially true — it becomes load-bearing when
alloc-site count-init lands (B4).

## U0.6 — B0 foundation report

Assemble U0.1–U0.5 into `design_docs/globalopt/borrow-b0-report.md`
(new file, created in Phase 0 — this IS the B0 deliverable):

- **Runtime-strategy A/B/C call (§22.1) — preliminary, B2-revisited
  (D0.6).** Argued from DS6 + U0.2's ceiling numbers: whether the v1
  payoff (pointer-free buffer RC + RC-1 on Bytes/strings + static
  uniqueness) justifies the B4/B5 runtime work, or the program stops at
  B3.5 (analysis + census as an optimization oracle) until arrays
  justify the runtime path. This is a **provisional go/no-go**: §22.1
  names the B2 static census the deciding evidence, so the B0 call is
  confirmed or overturned there (D0.6).
- **The `rcManaged` v1 tag set, fixed** (fact 8): `Tag_String`,
  `Tag_ByteBuffer`, `Tag_StringUtf8Leaf`, and the `Tag_String`/
  `Tag_ByteBuffer` bodies behind `Tag_LargeStringHeader`/
  `Tag_LargeByteHeader` (HEAP_026 pinned large bodies). All view/slice/
  rope/split-header forms excluded (U0.4).
- **The kernel checklist (U0.3)** — allowlist table + §12.3 inc-set —
  and the **view decision (U0.4)**.
- **U0.1's Perceus denominator** as the standing baseline table
  (self-compile + elm-aws-codegen numbers).

## Gates

- **U0.1** census runs on self-compile and elm-aws-codegen; numbers in
  the report; the flag path is graph-inert. Verify byte-identity of
  emitted MLIR flag-off vs `ECO_BORROW_CENSUS0=1` (analysis only — the
  fold returns `optimizedGraph` untouched). Honor the LSS verification
  traps (`§19.4`): touch all test `.elm` before the flag-on leg (harness
  cache is env-blind); `grep -a` the captured log (census lines can
  carry binary chars); run E2E and elm-tests **serially** (typed-
  artifacts cache race). Build/run once, tee to `/tmp/test_output.txt`,
  grep — never re-run (CLAUDE.md). The flag+field are deleted when B2's
  real census lands. **(OUTSTANDING 2026-07-31: B2 landed 2026-07-26 but
  the flag/fold still exist — see the U0.1 cleanup note above.)**
  ```bash
  cmake --preset build                      # ELM_SOURCES glob is non-CONFIGURE_DEPENDS
  cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
  grep -aE "borrow census0|PASS|FAIL|Falsifiable" /tmp/test_output.txt
  ```
  (Config.elm edits are existing sources ⇒ the reconfigure is a glob
  refresh, not a new-source add; still cheap and mandatory before the
  guida rebuild.)
- **U0.5** assertion green under `ECO_HEAP_VALIDATE` on the E2E corpus
  (built with `-DECO_HEAP_VALIDATE=ON`; `AllocatorCommon.hpp:34` gates
  it off by default). Scaffolded in Phase 0, load-bearing at B4.
- **B0 report reviewed**; the Phase-5 scheduling decision (§22.1) is
  recorded in it — that **preliminary** decision is the gate this phase
  exists to produce, revisited and confirmed by the B2 census (D0.6).

## References

- Design: §1 (deliverables), §7.2 (heap positions), §12 (kernels:
  §12.1 table, §12.2 allowlist, §12.3 counting), §13 (census), §16
  (runtime RC path, §16.2 header-preservation), §17 S1–S6 (soundness),
  §18 (B0 milestone), §22.1/22.2/22.3 (open questions this phase closes).
- Code anchors: `Builder/Generate.elm:823,900-963,971` ·
  `Compiler/Monomorphize/MonoTraverse.elm:146` ·
  `Compiler/Monomorphize/Monomorphize.elm:532-570` ·
  `Compiler/AST/Monomorphized.elm:203-215,813-825,864-872` ·
  `Compiler/Eco/Config.elm:61,231,286-289,361-405` ·
  `Builder/Eco/Config.elm:104,508-531` ·
  `runtime/src/allocator/Heap.hpp:77-114,153-165` ·
  `runtime/src/allocator/NurserySpace.cpp:1154,1163-1193,1233-1264` ·
  `runtime/src/allocator/GCStats.cpp:153,1243-1348` · `heap-profile.py`
  (run/sweep modes, size + residency histograms).
- Kernel evidence: `elm-kernel-cpp/src/core/{Utils,String,JsArray,Debug}
  Exports.cpp`, `elm-kernel-cpp/src/bytes/BytesExports.cpp`,
  `elm-kernel-cpp/src/json/JsonExports.cpp`,
  `eco-kernel-cpp/src/eco/{ConsoleExports,Console}.cpp`,
  `runtime/src/allocator/StringOps.cpp:31,118` (view alloc),
  `design_docs/elm_kernel_functions.csv`.
- House methodology: `benchmarks/runtime-calls.md` (interleaved legs,
  major-GC recording); `plans/allocator-resolve-inlining.md:327-367`
  (diag-build recipe); design §19.4 (LSS verification traps).
- CMake: `build` preset is the configure name (CLAUDE.md's
  `ninja-clang-lld-linux` is stale); `-B build-diag` overrides the
  preset `binaryDir` for the perf tree.
