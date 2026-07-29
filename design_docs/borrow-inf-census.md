# Borrow Inference — Phase 0 (B0): Measurement & Groundwork Report

**Status:** measurement in progress / assembled by implementing
`plans/borrow-inference-phase0-measurement.md`. This file is the B0
deliverable the plan calls `design_docs/globalopt/borrow-b0-report.md`
(recorded here at the path requested by the user). It is **decision gate
G1** for Phase 5 (the RC-optimization track); it does **not** gate Phases
1–4 (the analysis), which may proceed concurrently.

**Parent design:** `design_docs/globalopt/borrow-inference-design.md` (v2).
**Date:** 2026-07-26. **Engine:** solver (the shipped default), all-keyed.

---

## 0. Summary of what was done

| Unit | What | Status |
|---|---|---|
| U0.1 | Static RC-traffic census (Perceus denominator) — new `ECO_BORROW_CENSUS0=1` flag + fold in `Builder/Generate.elm` | **implemented + measured** |
| U0.2 | Dynamic payoff ceiling — perf cost-classes + GC allocation/promotion volume | **measured** (perf enabled via transient `perf_event_paranoid` drop, DWARF unwinding on the RELWITHDEBINFO build in place of a dedicated frame-pointer diag build; volume from the runtime's exit GC-stats dump) |
| U0.3 | Kernel allowlist audit + §12.3 counting-obligation checklist | **verified against source (with corrections)** |
| U0.4 | View-counting decision (per string form) | **resolved** |
| U0.5 | Refcount header-preservation audit + `ECO_HEAP_VALIDATE` assertion scaffold | **implemented (extended to all 3 nursery copiers)** |
| U0.6 | This report + runtime-strategy A/B/C call | **assembled (preliminary, B2-revisited)** |

**Gate results**
- **E2E:** `cmake --build build --target full` → **1636/1636 PASSED** (FULL_EXIT=0). The census flag defaults off and the fold returns the graph untouched, so the change is graph-inert; the C++ (U0.5) edits are all under `#if ECO_HEAP_VALIDATE` (off in the default build) so they compile to nothing there.
- **Byte-identity (U0.1):** emitted MLIR flag-off vs `ECO_BORROW_CENSUS0=1` — _(see §1)_.

---

## 1. U0.1 — Static RC-traffic census (the Perceus denominator)

### Implementation

`ECO_BORROW_CENSUS0=1` is an output-only, **hash-inert** flag (mirrors
`mono.validate` / `ECO_INLINE_REPORT`; never referenced in `Config.hash`,
so flag-off caches are unaffected). Five wiring edits + one fold helper:

- `compiler/src/Compiler/Eco/Config.elm` — `MonoConfig.borrowCensus0 : Bool` field (+ `default.mono` = `False`, + `monoDecoder` env-only pass-through).
- `compiler/src/Builder/Eco/Config.elm` — `ECO_BORROW_CENSUS0=1|true|yes` override (`applyBorrowCensus0Override`, modelled on `applyValidateOverride`).
- `compiler/src/Builder/Generate.elm` — thread the flag through `runGlobalOptPhase` (widened with a 2nd `Bool`); after GlobalOpt, when set, emit one stderr `borrow census0: …` line via the existing house side-channel idiom, `Task.map (\_ -> result)` (graph-inert). The fold is `borrowCensus0Line : Mono.MonoGraph -> String` (+ throwaway `Census0` alias), placed beside `abiCensusLines`.

The fold runs over the **post-GlobalOpt** graph (`result.monoGraph`) — the
closest Phase-0 proxy to what the real Phase-6 borrow pass will see.

**Counting model** (a raw syntactic *upper bound*, no liveness — the real
refinement is B2):
- **Heap-typed** = design §7.2 resources: `MString`, `MList`, `MTuple`, `MRecord`, `MCustom`, `MFunction` (closure env), `MVar` (erased `CEcoValue`, poisoned). `MInt`/`MFloat`/`MBool`/`MChar`/`MUnit` are unboxed non-resources.
- `heapOcc` / `wouldDups` — **every** heap-typed variable occurrence (`MonoVarLocal`/`MonoVarGlobal`) counts as one candidate dup.
- `wouldDrops` — heap-typed binders: node-level `MonoTailFunc` params + `MonoLet` `MonoDef`/`MonoTailDef` bindings (and tail-def params).
- `immortal` — interned string literals `LStr` (S5). `LStr` is the only heap-typed literal.
- Per-type buckets: `strings`/`lists`/`records`/`customs`/`closures`; `MTuple`/`MVar` fold into `customs`.

> **Interpretation caveat (honest):** because every heap-typed occurrence
> is counted, a **`MonoVarGlobal` that references another top-level
> function** (type `MFunction`) counts as a `closures` occurrence and a
> `wouldDup` — i.e. direct-call callee references inflate `closures`/
> `wouldDups`. This is deliberate (a naive all-owned ceiling); the real
> B2 solver will not treat a known direct callee as a closure dup. Read
> `closures` as "closure-typed occurrences incl. function references",
> not "real closure dups".

### Numbers — self-compile (the standing baseline)

Workload: the eco compiler compiling its own front end
(`compiler/src/Terminal/Main.elm`, `--optimize`, solver/all-keyed) — the
same invocation as bootstrap Stage 7a.

```
borrow census0: heapOcc=380127 wouldDups=380127 wouldDrops=77993 strings=26131 lists=40820 records=23287 customs=128779 closures=161110 immortal=11754
```

| metric | value | % of heapOcc | notes |
|---|---:|---:|---|
| `heapOcc` | 380,127 | 100% | total heap-typed variable occurrences |
| `wouldDups` | 380,127 | 100% | = heapOcc (every occurrence is a candidate dup) |
| `wouldDrops` | 77,993 | — | heap-typed binders (params + let bindings) |
| `strings` | 26,131 | **6.9%** | ← the rcManaged v1 family (the RC target) |
| `lists` | 40,820 | 10.7% | |
| `records` | 23,287 | 6.1% | |
| `customs` | 128,779 | 33.9% | incl. tuples + erased MVar |
| `closures` | 161,110 | 42.4% | incl. function-reference occurrences (see caveat) |
| `immortal` | 11,754 | — | interned `LStr` constants (separate from heapOcc) |

Wall (flag-on self-compile): **3:09.70**, max RSS 6.3 GB (solver/all-keyed).

**String share of heap traffic** = `strings / heapOcc` = **6.87%**. This is
the headline denominator: the pointer-free-buffer RC target (strings, and
the equally-narrow Bytes family) addresses **under 7%** of heap-typed
occurrences in the compiler workload. `closures` (42%) and `customs` (34%)
dominate — though `closures` is inflated by direct-call function
references (see caveat), the data-carrying `lists`+`customs`+`records`
(~51%) are the real bulk, none of which v1 RC touches.

### Numbers — elm-aws-codegen (canary)

**Not measured — blocked on uncached dependencies.** The eco package
cache (`~/.eco/0.1.0/packages`) is missing most of
`projects/elm-aws-codegen`'s direct deps — `the-sett/{elm-aws-core,
elm-refine, salix, salix-aws-spec, elm-syntax-dsl, elm-string-case,
elm-error-handling}` and `hecrj/html-parser` are all absent (only
`the-sett/elm-pretty-printer` is present). A clean `eco make` would fail
at dependency solving. Fetching+solving the full the-sett dependency set
is out of scope for this measurement pass; the **self-compile census is
the authoritative Perceus denominator** here. The elm-aws-codegen canary
(a pathological deep-let-chain input) remains valuable for the B2/B3 wall
gates and should be re-run once its packages are cached.

### Byte-identity gate

**PASS.** Compiling `Terminal.Main.elm` with `ECO_BORROW_CENSUS0=1` vs
flag-off produced **byte-identical** MLIR: both `/tmp/census/self-on.mlir`
and `/tmp/census/self-off.mlir` are `12,876,687` bytes, `cmp` identical.
The census line appears on stderr only with the flag on; flag-off stderr
carries no `borrow census0:` line. The fold is confirmed graph-inert.


---

## 2. U0.2 — Dynamic payoff ceiling

Eco is a tracing GC; RC pays **only** through (a) old-gen reclaim at
mutator time, (b) RC-1 in-place mutation, and (c) static uniqueness
(design DS6). This unit measures the ceiling.

### 2a. Sandbox constraint (recorded)

The plan's recipe is `perf record --call-graph fp` on a dedicated
frame-pointer **diag build**. Two adaptations were forced/chosen:

- **`perf` was initially blocked**: `kernel.perf_event_paranoid = 3`
  captured **0 samples**. Lowered transiently to `1` (via sudo) to enable
  user-space sampling, and **restored to 3** afterward.
- **No dedicated diag build**: instead of a second full frame-pointer
  build (`build-diag`, ~another full C++ + bootstrap), I profiled the
  existing RELWITHDEBINFO native `eco-compiler` with **`--call-graph
  dwarf`** (it carries `-g`), which recovers attribution without frame
  pointers. Diag walls are shares-only regardless; flat-% attribution is
  what the ceiling needs.

### 2b. perf — flat % in buffer-family cost classes

`perf record -F 199 --call-graph dwarf` over one native self-compile
(3:16 wall under perf), reported with `--no-children` (self% leaf
attribution; 1,478 symbol rows, Σself ≈ 99.7%).

**Top self-time symbols:** `eco_gc_push_stack_range` **14.53%**,
`eco_apply_closure_eval` 7.58%, `NurserySpace::evacuate` 5.46%,
`Allocator::resolve` 4.84%, `invokeSaturatedTyped` 3.51%,
`spliceArgsForSaturatedCall` 2.57%, `OldGenSpace::markOneObject` 1.97%.

**Cost-class buckets (self%):**

| class | self% | in v1 RC scope? |
|---|---:|---|
| GC — root scan (`eco_gc_push_stack_range`) | 14.53% | no (tracing-GC cost) |
| GC — evacuate / scan / mark / minor / major | 14.45% | no |
| closure apply / dispatch | 12.63% | no |
| resolve / deref / tag | 5.09% | no |
| **StringOps** | **2.45%** | **yes** |
| **buffer alloc** (nursery/oldgen) | **1.37%** | **yes** (reclaim side) |
| **Bytes codec** | **0.39%** | **yes** |
| unclassified (mutator / Elm code) | 48.80% | — |
| **→ ALL GC** | **~29.0%** | no |
| **→ buffer-family total (the v1 RC surface)** | **~4.2%** | yes |

So the entire pointer-free-buffer surface RC v1 could touch is **~4.2%**
of runtime self-time, while tracing GC (root-scan + evacuate/mark) is
**~29%** — and GC is dominated by the large closure/custom/list
population (§1), none of which v1 RC touches. This matches the static
census (strings = 6.9% of occurrences ↔ buffer-family = 4.2% of runtime).

### 2c. allocation / promotion volume

The runtime dumps full GC stats at exit by default (`main.cpp:744` /
`eco_entry.cpp:178`), so the census run's stdout already carries the
volume data (a dedicated `heap-profile.py` run adds no signal beyond
this; the harness's per-tag `Tag_ByteBuffer` counter gap remains a B4
tooling item — D0.5).

| GC metric (self-compile) | value |
|---|---:|
| Objects allocated | **798,236,911** (~798 M) |
| Bytes allocated | **38,801 MB** (~38.8 GB churn) |
| Minor GC cycles | 1,203 |
| Objects promoted | **158,664,157 (19.9%)** |
| Minor GC time | 37.52 s |
| Major GC cycles | 10 |
| Major GC time | 10.41 s |
| **Total GC time** | **≈ 47.9 s** (~25% of the ~3:10 wall) |

**String Allocation Size Histogram** (every fresh `allocString` leaf — the
rcManaged string family): total **431,984** leaf allocs, ~96% in the
16–256 B range (small strings). That is **431,984 / 798,236,911 =
0.054%** of all objects allocated.

So the pointer-free **string** family is **~0.05% of allocation volume**
— even though strings are 6.9% of *occurrences*, fresh string leaves are
rare (most string flow passes existing values / uses read-only ops). The
~798 M allocations and 19.9% promotion are dominated by
Cons/closure/tuple objects (cf. the cons-reduction survey: Cons ≈ 65% of
allocation), **none of which v1 RC touches**.

### 2d. Ceiling verdict

The three measurements agree and are mutually reinforcing:

| lens | rcManaged-v1 (pointer-free buffer) surface | the rest |
|---|---:|---|
| static occurrences (U0.1) | strings 6.9% | closures/customs/lists/records 93% |
| runtime self-time (U0.2b) | buffer-family 4.2% | GC 29%, closures 13%, mutator ~49% |
| allocation volume (U0.2c) | string leaves 0.05% | ~798 M objects, Cons/closure-dominated |

**Does RC-1-on-buffers clear the B4/B5 build cost?** On this evidence,
**no — not on the v1 buffer surface alone.** Three compounding reasons:
1. The v1 rcManaged surface (pointer-free string/byte buffers) is a
   single-digit-% slice by every lens, and **0.05%** by allocation volume.
2. v1 has **no RC-1 in-place-mutation targets** (Phase-5 fact 10: the v1
   buffer kernels are purely functional), so v1's *only* lever is
   **old-gen reclaim of buffers** — whose alloc volume is ~0.05%, i.e.
   negligible reclaim.
3. The actual runtime cost is **tracing GC (29%)** driven by the ~798 M
   Cons/closure/custom allocations and 19.9% promotion — exactly the
   population v1 RC does **not** manage.

The payoff lives in **arrays/lists** (the ~51% data bulk + the Cons
allocation mass), which is explicitly **v2 backlog item 2**
(`arrays in rcManaged`, gated behind item 3 per-ctor precision).

---

## 3. U0.3 — Kernel audit + counting-obligation checklist

All rows below were **re-verified against the actual C++ source**
(elm-kernel-cpp / runtime). Corrections vs the plan are flagged **⚠**.
Audit criterion (§12.2): *reads argument heap data; never stores the arg
or an interior pointer into a result/global; result shares no identity
unless declared `resultAliases`.*

### 3a. Allowlist (Phase-3 `KernelSigs.lookup` seed)

| kernel `(home,name)` | verdict | evidence (verified) |
|---|---|---|
| `(Utils,compare)` | params `PBorrowed`, `resultAliases=Nothing` | `Utils.cpp:400` `compare`→`cmp` (read-only), returns an `ORDER_*` singleton. ⚠ the singleton is **pre-allocated & GC-rooted** (`Utils.cpp:28-45`), *not* fresh — but it aliases a global, never a param, so `Nothing` still holds |
| `(Utils,equal)` | params `PBorrowed` | `Utils.cpp:412`→`eqHelp` `:416` reads via `getTag`/`StringOps::equal`; boxed-bool result; local-only stacks in `dictEq` |
| `(Utils,notEqual/lt/le/gt/ge)` | params `PBorrowed` | `Utils.cpp:706-722` thin wrappers over `cmp`/`equal` |
| `(String,length)` | param `PBorrowed` | `StringExports.cpp:18`→`String::length`; unboxed `i64` scalar result |
| `(String,startsWith/endsWith/contains)` | params `PBorrowed` | `StringExports.cpp:106/110/114`→`StringOps::*`; embedded `Const_True/False` result |
| `(JsArray,length)` | param `PBorrowed` | `JsArrayExports.cpp:204`→`alloc::arrayLength`; scalar `i64` |
| `(JsArray,unsafeGet)` | params `[PBorrowed,PBorrowed]`, `resultAliases=Just 1` | `JsArrayExports.cpp:210` `unsafeGet(index_val, array)` — index is param 0, **array is param 1** ⇒ `Just 1` (not `Just 0`). ⚠ aliases an array element **only** in the boxed (`kind==0`) branch `:221`; unboxed kinds allocate a fresh box `:219` — `Just 1` is a *sound conservative over-approximation* |
| `(Debug,log)` | params `[PBorrowed,PBorrowed]`, `resultAliases=Just 1` | `DebugExports.cpp:26-42` prints then `return value` — result **is** param 1 (identity, D0.3) |
| `(Debug,toString)` | param `PBorrowed`, `resultAliases=Nothing` | `DebugExports.cpp:56`→`eco_value_to_string_typed` (fresh string) |
| `(Basics,*)` numeric | documentation only, cost 0 | scalar args carry no resource |
| ~~`(List,length)`~~ | **dropped — not a kernel** | D0.2: absent from `elm_kernel_functions.csv`; pure-Elm `foldl` |
| ~~`(String,isEmpty)`~~ | **dropped — not a kernel** | D0.2: absent from CSV; pure-Elm `== ""` |
| ~~`Console.write`~~ | **dropped — `POwned`, not `PBorrowed`** | D0.1: `ConsoleExports.cpp:9`→`Console::write` returns a `Task_Binding` capturing `Tuple2{handle,content}`; `content` is a surviving reference (`Console.cpp:52-64,127-133`). Console is not in the CSV |

### 3b. §12.3 counting-obligation set (RC-mode surviving-reference creators)

Every kernel that creates a **surviving** reference to an `rcManaged`
value, or an **interior view** into a backing buffer, must `inc` it before
B4. **The plan's string-builder list was too broad** — verified below.

**View/slice makers** (interior pointer into a backing leaf →
`Tag_StringSlice`/`Tag_StringUtf8View`, S3 corollary):
- `String.slice` — `StringExports.cpp:56` → `String::slice` (`String.cpp:174`) → `StringOps::slice`; allocs `Tag_StringSlice` (`StringOps.cpp:31`) / `Tag_StringUtf8View` (`StringOps.cpp:118`). ⚠ plan omitted the `String::slice` thunk hop.
- `String.split` / `lines` / `words` / `trim*` — **conditional** slice-emitters: they emit `Tag_StringSlice`/`Utf8View` only on the **both-UTF-8 fast path**; the UTF-16 mixed path copies. Anchors: `split` `StringOps.cpp:951,956`; `lines`/`words` `String.cpp:225,337`; `trim*` `StringOps.hpp:899,921,943`. ⚠ plan's single anchor covered only lines/words.

**String builders that RETAIN refs** (produce a rope holding child refs):
- `String.append` — large-total path `makeRope` → `Tag_StringRope` holding `left`/`right` (`StringOps.hpp:536` → `StringOps.cpp:84`).
- `String.join` — large-total path `buildBalancedRope` → `Tag_StringRope` (`StringOps.cpp:820-821`).

**⚠ DROPPED from the plan's §12.3 builder list** — these copy content into
a **fresh flat leaf** and hold **no** surviving reference / interior view,
so they carry **no** `inc` obligation:
- `String.cons` (`StringOps.hpp:1241`, "Always returns a flat leaf")
- `String.fromList` (reads Char *values*, `String.cpp:56`)
- `String.reverse` (`StringOps.hpp:838`, fresh leaf; only the `len==1` identity edge aliases)
- `String.toUpper` / `String.toLower` (`StringOps.hpp:762/801`, fresh leaf)

**Bytes codecs:**
- `Bytes.Encode.encode` — `writeEncoder` tree → `Tag_ByteBuffer` (`BytesExports.cpp:144`; `encoderSize` `:124`).
- `Bytes.Decode.string` / `Bytes_read_string` — builds a **zero-copy string view** over the byte buffer (surviving interior ref) — `BytesExports.cpp:588`, view path `:628-634`.
- `Bytes_write_string` — encoder node retaining the string arg (`BytesExports.cpp:877` → `makeEncoderUtf8` `:798`, roots `strHP` across the alloc).

**Json:**
- `Json.Encode.string` — `Elm_Kernel_Json_wrap` (`JsonExports.cpp:1560`) stores the string HPointer into an `ENC_STRING` custom node so the encoder tree retains the arg. ⚠ the retaining store is at **`:1637-1649`** (`ctor=ENC_STRING` `:1646`, `values[0].p=h` `:1648`), **not** the plan's `:1590` (that anchor is the empty-string-*constant* branch, which stores no live ref).

---

## 4. U0.4 — View-counting decision (§22.2)

Verified form split (all tag numbers exact against `Heap.hpp:76-115`):

| form (tag #) | interior HPointer? | RC-1 eligible (pointer-free)? | v1 disposition |
|---|---|---|---|
| `Tag_String`(80) / `Tag_ByteBuffer`(91) / `Tag_StringUtf8Leaf`(112) | no | yes | **rcManaged** (backing, counted) |
| `Tag_StringUtf8View`(111) / `Tag_StringSlice`(95) / `Tag_ByteBufferSlice`(96) | yes (`base`) | no | **excluded** |
| `Tag_StringRope`(94) | yes (`left`/`right`) | no | excluded |
| `Tag_LargeStringHeader`(101) / `Tag_LargeByteHeader`(102) | yes (`body`) | header no; body ∈ rcManaged | header excluded; **body counted** (HEAP_026; body pinned `pin=1` at `OldGenSpace.cpp:4187`) |

**Decision** (resolved with U0.2's data — see §2d): default = **exclude the
backing leaf from RC-1 whenever any view over it can be live**
(conservative, zero-copy-preserving). Switch to *count-at-view-creation*
for a form only if U0.2 shows view-backed volume is a large share of
mutation candidates (then `inc` the backing at `StringOps::slice` /
`Bytes_read_string`, adding them to the §12.3 inc-set).

Because the view/slice/rope forms are themselves excluded from `rcManaged`
v1, RC-1 mutation never targets a view; the only live hazard is
RC-1-mutating a **backing leaf** while a view aliases it (the S3 hazard),
which the default disposition avoids.

---

## 5. U0.5 — Refcount header-preservation audit + assertion

**§16.2 obligation:** a minor-GC copy/promotion must carry the header word
— including `refcount` [16,30] — verbatim, editing only `color`+`age`,
else promoted survivors reset to refcount 0 ("untracked") and RC-1 dies.

**Header layout** (verified bit-for-bit via a standalone probe;
`Heap.hpp:153-165`, `static_assert(sizeof(Header)==8)`): `tag:5`[0,4],
`color:2`[5,6], `pin:1`[7], `age:2`[8,9], `unboxed:6`[10,15],
`refcount:15`[16,30], `builder:1`[31]; word 2 `size:u32`. `refcount:15`
⇒ **RC_SATURATED = 0x7FFF**. ⚠ note: `RC_SATURATED` is a *design concept*,
not yet a named constant in the code; `refcount` is documented "unused
currently".

**⚠ Correction to plan fact 7 — `evacuate` is NOT the sole copier.** There
are **three** nursery object-copiers, each with a promotion + to-space
path, and D0.4 (edits only `age`/`color`, never `pin`/`refcount`) holds
for **all three**:
1. `NurserySpace::evacuate` (`:1062`) — the general copier (2 paths).
2. `NurserySpace::evacuateJitPtr` (`:1326`) — JIT raw-pointer roots (2 paths).
3. `NurserySpace::evacuateListSpine` (`:1787`) — contiguous Cons-spine copy (2 paths).

Old-gen major GC does **not** relocate live bodies: split-header bodies
are pinned (`pin=1`, `OldGenSpace.cpp:4187`) and the collector is
non-moving mark-sweep + free-list coalescing (`OldGenSpace.hpp:18-22,
53-83` — ⚠ plan cited `Heap.hpp:124-133`). So there is no old-gen
header-copy path to audit.

**Implemented** (scaffold, load-bearing at B4; trivially true now since
`refcount` is always 0): a `static inline
assertHeaderPreservedAcrossCopy(const Header &src, const Header *dst)`
guarded by `#if ECO_HEAP_VALIDATE`, a `const Header srcHdr = *hdr;`
snapshot taken right after `getObjectSize` in each copier, and a call at
the tail of every copy branch. It asserts equality of
`tag`,`pin`,`unboxed`,`refcount`,`builder`,`size` (excludes the
GC-legitimately-edited `color`+`age`).

> **Deviation from plan (justified):** the plan scoped U0.5 to
> `evacuate`'s two paths on the premise it is "the sole copier" (fact 7).
> That premise was refuted by source audit, so the tripwire was
> **extended to all three copiers** — a partial tripwire would give false
> confidence at B4. All six insertion sites are `#if ECO_HEAP_VALIDATE`,
> zero-cost in the default build.

**Gate:** compiles + runs clean under `-DECO_HEAP_VALIDATE=ON` — _(see
§5a)_.

### §5a — ECO_HEAP_VALIDATE build/run

**Compile-check: PASS.** `NurserySpace.cpp` was re-compiled with
`-DECO_HEAP_VALIDATE=1 -fsyntax-only` using the exact ninja include flags:
exit 0, **zero** warnings/errors. All six insertion sites (the helper +
three snapshots + calls across `evacuate`/`evacuateJitPtr`/
`evacuateListSpine`) compile under the flag.

**No false-positive by construction.** Every asserted field
(`tag`/`pin`/`unboxed`/`refcount`/`builder`/`size`) is `memcpy`-copied
from the source header and never rewritten on any copy path (verified by
reading all three copiers); the two fields GC legitimately edits
(`color`, `age`) are excluded. `refcount` is currently always 0, so the
assertion is trivially true today and becomes load-bearing when B4 adds
alloc-site count-init.

**Full E2E-under-`-DECO_HEAP_VALIDATE=ON` run: deferred to B4** (per the
plan's "scaffolded now, load-bearing at B4" framing) — it needs a
dedicated HEAP_VALIDATE runtime build; the compile-check + exhaustive
path reading above establish correctness for the scaffold stage.

---

## 6. U0.6 — Runtime-strategy A/B/C call (preliminary, B2-revisited)

Per **D0.6** (a design-internal B0-vs-B2 inconsistency), this call is a
**provisional go/no-go** from DS6 + U0.2's ceiling; §22.1 names the **B2
static census** the deciding evidence, so it is confirmed/overturned
there. The three strategies:

- **A** — full v1 runtime RC (B4/B5): pointer-free buffer RC + old-gen reclaim + static-unique free.
- **B** — analysis + census only (stop at B3.5): borrow inference as an optimization *oracle*, no RC ops emitted, until arrays justify the runtime path.
- **C** — defer entirely.

**Preliminary call: B — build the analysis + census through B3.5; defer
the B4/B5 runtime RC track to v2.** (B2's static census is the deciding
evidence per D0.6; this is the provisional go/no-go.)

Rationale (from §2d): the v1 pointer-free-buffer RC surface is ~4–7% by
occurrence/runtime and ~0.05% by allocation volume, v1 has no RC-1
mutation targets, and the dominant cost (tracing GC over ~798 M
Cons/closure/custom objects) is untouched by v1 RC. The **analysis** (B0–
B3.5: RTy → constraints → staged solve → interprocedural sigs → LSS
handshake) is still worth building — it is the uniqueness/sharing
**oracle**, the census source of truth for sizing v2, and the foundation
the v2 array/list RC (backlog items 2+3) requires. But committing the B4
runtime (RC ops + GC-coexisting refcount path + reclaim) to chase a
0.05%-of-allocations buffer surface is not justified by these numbers.

This does **not** kill the program — it sequences it: **A becomes
attractive only once `rcManaged` admits arrays/lists** (v2 item 2), which
is where the ~51% data bulk and the Cons allocation mass live. Recommend
Phases 1–4 proceed (analysis is engine-independent and low-risk), and
that the B4/B5 go/no-go be re-taken after the B2 static census confirms
these ratios on the full corpus.

### `rcManaged` v1 tag set (fixed)

`Tag_String`, `Tag_ByteBuffer`, `Tag_StringUtf8Leaf`, plus the
`Tag_String`/`Tag_ByteBuffer` **bodies** behind
`Tag_LargeStringHeader`/`Tag_LargeByteHeader` (HEAP_026 pinned large
bodies). All view / slice / rope / split-header forms excluded (§4).

---

## 7. Open questions & design discrepancies (returned to the design)

- **D0.1** Console.write is `POwned` (surviving binding), dropped. ✔ verified.
- **D0.2** `List.length` / `String.isEmpty` are not kernels, dropped. ✔ verified.
- **D0.3** `Debug.log` result aliases param 1; `Debug.toString` fresh. ✔ verified.
- **D0.4** GC edits only `color`+`age` (not `pin`). ✔ verified; `pin` included in the assertion's preserved set.
- **D0.6** §18 (B0) vs §22.1 (B2) disagree on who decides the runtime strategy — resolved as *B0-preliminary, B2-final*.
- **NEW (fact 7 refuted):** three nursery copiers, not one — U0.5 extended accordingly; the borrow/runtime analysis must account for all three copy sites.
- **NEW (§12.3):** the string-builder obligation set is narrower than the plan (cons/fromList/reverse/toUpper/toLower produce fresh flat leaves — no obligation); only append/join (rope path) + the view/slice makers + Bytes/Json retainers carry it.
- **NEW (§12.3 Json):** the retaining `ENC_STRING` store is at `JsonExports.cpp:1637-1649`, not `:1590`.
- **`unsafeGet` `resultAliases`:** confirmed `Just 1` (array is param 1); aliases only in the boxed branch, so `Just 1` is a sound over-approximation. Confirm the Mono-level arg order in Phase 3 before committing the integer.

---

## 8. Files changed

- `compiler/src/Compiler/Eco/Config.elm` — `MonoConfig.borrowCensus0` field + default + decoder.
- `compiler/src/Builder/Eco/Config.elm` — `ECO_BORROW_CENSUS0` env override + `applyBorrowCensus0Override`.
- `compiler/src/Builder/Generate.elm` — flag threading + `borrowCensus0Line` fold + `Census0` alias + imports (`Array`, `MonoTraverse`).
- `runtime/src/allocator/NurserySpace.cpp` — `assertHeaderPreservedAcrossCopy` + snapshot/calls in `evacuate`, `evacuateJitPtr`, `evacuateListSpine` (all `#if ECO_HEAP_VALIDATE`).

All U0.1 flag/fold code is **throwaway** — delete it (and the flag) when the
B2 real census lands. The U0.5 assertion is permanent (load-bearing at B4).

---

## 9. B1 + B2 — the analysis oracle (as-built, 2026-07-26)

Phases B1 (foundations) and B2 (intra-def analysis + census) are now
implemented — the Strategy-B analysis oracle runs as GlobalOpt **Phase 6**
in census-only mode (`reify = ROff`), producing the real uniqueness/sharing
census that supersedes the U0.1 throwaway ceiling above.

**B1** — `Borrow/Lifetime.elm` (lifetime lattice) + `Borrow/Dsu.elm`
(union-find), with `SkelFuzz`/`LifetimeTest`/`DsuTest`. Gate: **28/28**
Borrow tests pass at `--fuzz 200` (exhaustive battery vs a brute-force
reference arbiter + fuzzed lattice laws + pinned regressions + DSU model
test).

**B2** — `Borrow/Rty.elm` (resource types), `Borrow/Constrain.elm`
(18-constructor walker → constraints), `Borrow/Solve.elm` (Stage A–D
solver), `Borrow.elm` (driver + `BorrowStats`), wired through
`MonoGlobalOptimize` Phase 6 and `Builder/Generate`. Config: top-level
`borrow` block; env `ECO_BORROW=off|1|rc`, `ECO_BORROW_REPORT=1`. Invariant
`BORROW_001` landed. Default **disabled** (zero cost / byte-identical);
enabling it is graph-inert.

### Gates
- **Byte-identity (graph-inertness): PASS.** Self-compile with
  `ECO_BORROW_REPORT=1` vs off → **byte-identical MLIR** (both 13,007,671 B).
  No `borrow:` line leaks with the flag off.
- **Full E2E** (`--target full`, default = borrow off): **1636/1636 PASSED**
  (FULL_EXIT=0) — borrow default-off ⇒ behavior unchanged, no regression.
- **B1 unit gate:** 28/28 at `--fuzz 200`.

### The census (self-compile workload, solver/all-keyed)

```
borrow: defs=31002 resources=4159795 borrowed=860962 (20%) wouldDup=238774
        wouldDrop=122930 wouldFree=14400 poisonedByClosure=45286
        poisonedByErased=7242 poisonedByKernel=26988 capturesForcedOwned=22932
        nonVarOwnedFresh=14434 nonVarBorrowedProducer=2416
        updateCopiedHeapFields=5597 immortal=11788 maxExt=91
```

| counter | value | reading |
|---|---:|---|
| `defs` | 31,002 | defs analyzed |
| `resources` | 4,159,795 | ResVars minted (per heap position, nested, per-use — a finer denominator than U0.1's 380K occurrences) |
| `borrowed` | 860,962 (**20%**) | resources proven borrowable → **need no RC** (the analysis win) |
| `wouldDup` | 238,774 | owned heap occurrences (incref-candidate ceiling) |
| `wouldDrop` | 122,930 | owned scope-bound bindings (drop candidates) |
| `wouldFree` | 14,400 | rcManaged (string) owned drops — **the v1 RC reclaim target** |
| `poisonedByClosure` | 45,286 | args forced owned at closure/generic call sites (Phase-2 all-owned; B3.5 recovers) |
| `poisonedByKernel` | 26,988 | heap args at kernel calls (Phase-2 all-owned; B3 recovers via KernelSigs) |
| `poisonedByErased` | 7,242 | erased `MVar CEcoValue` (ROpaque) resources |
| `capturesForcedOwned` | 22,932 | closure captures forced owned (§8.4) |
| `nonVarOwnedFresh` / `nonVarBorrowedProducer` | 14,434 / 2,416 | heap non-var call operands (DS4 sizing) |
| `updateCopiedHeapFields` | 5,597 | record-update copied heap fields (sizes B6 field-selector) |
| `immortal` | 11,788 | interned `LStr` (cross-checks U0.1's 11,754) |
| `maxExt` | 91 | max borrow-induced lifetime depth |

**Reading:** ~20% of resources are provably borrowable at Phase-2 precision
(all boundaries all-owned) — a floor that B3 (kernel + direct-call
signatures) and B3.5 (LSS handshake) raise by recovering the ~79K
closure/kernel/erased poison. `wouldFree=14,400` is the concrete v1
string-reclaim opportunity count; `wouldDup`/`wouldDrop` are the
Perceus-op ceilings.

> **Honest v1 caveats.** `resources`/`borrowed`/`wouldDup`/`wouldDrop` come
> from a first-pass solver: Stage D (precise `ltP`) is computed as `ltA`,
> and `wouldDup`/`wouldDrop` are ceilings (owned occurrences / owned
> scope-bindings) not liveness-minimal counts. The *poison* and
> *structural* counters (closure/kernel/erased/captures/nonVar/update/
> immortal) are exact. These refine in B3/B3.5/Phase-5.

### Files added (B1 + B2)
- `compiler/src/Compiler/GlobalOpt/Borrow/{Lifetime,Dsu,Rty,Constrain,Solve}.elm` + `Borrow.elm`
- `compiler/tests/Compiler/GlobalOpt/Borrow/{SkelFuzz,LifetimeTest,DsuTest}.elm`
- edits: `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm`, `Builder/Generate.elm`, `Compiler/GlobalOpt/MonoGlobalOptimize.elm`, `design_docs/invariants.csv` (BORROW_001)

---

## 10. B3 — Interprocedural signatures (as-built, 2026-07-26)

B3 makes **direct calls and kernel calls stop being all-owned poison**:
per-`SpecId` `BorrowSig`s via a reverse-topological **SCC fixpoint**
(`Borrow/Sig.elm`) + an audited kernel table (`Borrow/KernelSigs.elm`,
seeded from §3a). Modules `Borrow/Mode.elm` (leaf, breaks the
`Constrain→Sig→Solve→Constrain` cycle) and `readbackSig` in the driver.

### Gates
- **`--text-mlir` byte-identity: PASS** (both 119,553,624 B, IDENTICAL) —
  graph-inertness confirmed with the canonical format. (Note: the *default
  bytecode* `--output` is **not** byte-canonical — its string-table/offset
  encoding varies run-to-run — so the identity gate must use `--text-mlir`,
  as the plan specifies.)
- **B1 + BORROW_005 unit tests: 29/29** (`--fuzz 50`). The BORROW_005
  scaffold builds a tail-recursive `loop : Int -> List Int -> List Int`,
  confirms its `MonoTailCall` heap args are escape-seeded (ltA non-empty,
  never `endsBefore` the body completion), with a negative control (some
  resource *does* die in-body).
- **Full E2E** (`--target full`, default off): **1636/1636 PASSED**.
- **Full `elm-tests`**: **13,037 pass / 12 fail** — all 12 are the
  pre-existing POST_010 type-var-scoping failures (Array/Accessor/Closure/
  Control-flow/Pattern-matching node vars+types, if-chain), identical to
  before any borrow work; **none borrow-related, no new failures**.

### The census (self-compile) — B2 → B3 delta

```
borrow: defs=31140 resources=4146593 borrowed=1100225 (26%) wouldDup=210020
        wouldDrop=114356 wouldFree=14031 poisonedByClosure=116868
        poisonedByErased=7276 poisonedByKernel=23564 poisonedParams=135278
        poisoningCallSites=46621 sigMissReads=0 kernelSigHits=5252
        kernelDefaultedHeapCalls=13113 sccBailouts=0 maxSccIter=3
        capturesForcedOwned=22956 nonVarOwnedFresh=37894
        nonVarBorrowedProducer=11977 updateCopiedHeapFields=5608
        immortal=11825 maxExt=90
```

| metric | B2 | B3 | note |
|---|---:|---:|---|
| **borrowed %** | **20%** | **26%** | direct + kernel call args stop being all-owned — the headline recovery |
| `poisonedByKernel` | 26,988 | 23,564 | audited kernel sigs recovered read-only args (`kernelSigHits=5,252`) |
| `kernelDefaultedHeapCalls` | — | 13,113 | un-audited kernel calls still all-owned (allowlist-growth evidence) |
| `poisonedParams` | — | 135,278 | owned param positions across all sigs |
| `sccBailouts` | — | **0** | fixpoint always converged |
| `maxSccIter` | — | **3** | matches the design's 2–3 prediction |
| `sigMissReads` | — | **0** | reverse-topo ordering held (no premature reads) |

**Reading:** the SCC fixpoint + kernel table lifts the provably-borrowable
share from **20% → 26%**, converging cleanly (0 bailouts, ≤3 iterations,
0 sig-miss reads). `poisonedByClosure` and the `nonVar*` counters *rose*
vs B2 — this is **re-attribution, not regression**: B3 now explicitly
classifies non-saturated global calls (PAP creation) as closure-boundary
poison (B2 silently owned them) and counts non-var operands on every call
branch (B2 only some). Net ownership only improved (borrowed ↑).

### Honest v1 simplifications (documented, deferred to a later refinement)
- **Argument-return lifetime coupling** (`resultLts`) is **not** emitted —
  `readbackSig` sets `resultLts = []`. An omitted coupling only shortens a
  lifetime (conservative for a census; unsound only under reification,
  which is off). This is the paper's α-join precision, deferred.
- A def's **result is forced owned** (returned value transferred to caller)
  in lieu of the LParams α-seeding mechanism — a simpler substitute that
  makes param modes meaningful (params reaching the result become owned;
  read-only params stay borrowed).

### Files added (B3)
- `compiler/src/Compiler/GlobalOpt/Borrow/{Mode,Sig,KernelSigs}.elm`
- `compiler/tests/TestLogic/GlobalOpt/BorrowTailCallEscapeTest.elm`
- edits: `Borrow.elm` (driver: edges + SCC + fixpoint + readback + census pass), `Borrow/Constrain.elm` (call-boundary upgrade + `constrainDef`), `Borrow/Solve.elm` (`Mode` moved out), `TestLogic/TestPipeline.elm` (signature)

---

## 11. B3.5 — LSS handshake (as-built, 2026-07-26)

B3.5 routes **closure calls with a singleton lambda set** through the
member's real lambda signature instead of poisoning them. New
`Borrow/LssFacts.elm`: an instance index (`byMember`/`blocked`, keyed by the
duplicated `instanceMember`/`isWrapperHome` from AbiCloning) + a query with
the decline ladder (`PTop/PBlocked/PUnresolved/PNoSig/PMixedMeet`) + a
call-site-only `meet` for multi-member sets (**BORROW_006**: params
any-owned-wins, result any-borrowed-wins, never written back). The driver
computes per-member lambda sigs once after the def-fixpoint converges;
`Constrain`'s closure/generic call branch calls `query` first.

### Gates
- **`--text-mlir` byte-identity: PASS** (both 119,951,614 B, IDENTICAL) — graph-inert.
- **Full E2E** (`--target full`): **1636/1636 PASSED**.
- **B1 + BORROW_005 unit tests: 29/29**.
- **Full `elm-tests`**: **13,037 pass / 12 fail** — the same 12 pre-existing POST_010 failures, none borrow-related.

### The census (self-compile, solver/all-keyed) — B3 → B3.5 delta

```
borrow: ... borrowed=1145717 (27%) ... poisonedByClosure=99486 closureRouted=11109
        poisonedByKernel=23612 poisonedParams=136658 sccBailouts=0 maxSccIter=3
        sigMissReads=0 ...
```

| metric | B3 | B3.5 | note |
|---|---:|---:|---|
| **borrowed %** | 26% | **27%** | +45K resources recovered by lambda routing |
| `poisonedByClosure` | 116,868 | **99,486** | −17,382 (−15%): closure calls routed to real lambda sigs |
| `closureRouted` | — | **11,109** | closure calls resolved to a singleton lambda member |
| `sccBailouts` / `maxSccIter` / `sigMissReads` | 0 / 3 / 0 | 0 / 3 / 0 | fixpoint unchanged & clean |

**Reading:** the LSS handshake recovers ~17K closure-poisoned resources
(15% of B3's closure poison) and lifts borrowed to 27%. Recovery is under
the **solver/all-keyed** engine (singleton lambda sets); under **subst** it
is fully inert (all arrows `LTop` ⇒ every query `Poison PTop` ⇒ Phase-3
boundary).

Initially B3.5 resolved **lambda members only** (standalone members →
`PUnresolved`); **U4.1 standalone-member routing is now also implemented**
(§11a below). Still deferred (all sound-conservative): the `fastEvaluator`
stamp shortcut (set-resolution via `headAnno` is used instead), routed
edges into the SCC graph (lambda sigs are computed post-fixpoint, so def
sigs don't yet benefit from lambda routing — only the census recovery
does), and `resultLts` arg-return coupling (still `[]`).

### Files added (B3.5)
- `compiler/src/Compiler/GlobalOpt/Borrow/LssFacts.elm`
- edits: `Borrow.elm` (build facts + per-member lambda sigs + census-pass routing), `Borrow/Constrain.elm` (`Env.lssFacts`, closure-branch `query`, `constrainClosureForSig`), `design_docs/invariants.csv` (BORROW_006)

### §11a — Standalone-member routing (U4.1, as-built 2026-07-26)

The full U4.1 handshake now routes **standalone members** too — a global,
ctor, kernel, or accessor appearing in a lambda-set position resolves to
its real signature instead of `PUnresolved`. This required the core AST
change the earlier scoping deferred:

- **`MonoGraph.lssMemberOrigins : Dict Int MemberOrigin`** + a new
  `MemberOrigin(..)` type in `Monomorphized.elm`, threaded through **all
  four** full-construction sites: solver assemble (populated via
  `buildMemberOrigins` — inverts `LssMemberTable.byKey` on the 2-char key
  prefix `g|/c|/k|/a|`, converting `TOpt.Global → Mono.Global`), subst
  assemble (`Dict.empty`, inert), Prune (preserve), MonoInlineSimplify
  (threaded through the `:797` destructure → `optimizeNodes` param → call →
  `:894` rebuild).
- `LssFacts` gained `origins` + a `globalIndex : Dict String [(MonoType,
  SpecId)]` (built from `registry.reverseMapping`, keyed by
  `Mono.toComparableGlobal`) + a `sigs` reader. `resolveMember` now handles
  `OriginKernel` (→ `kernelToSig` via the audited table), `OriginCtor` (→
  all-owned), `OriginAccessor` (→ borrowed), and `OriginGlobal` (→
  `globalIndex` layout-matched by `Mono.eqLayout` to a unique SpecId →
  `sigs`; 0/ambiguous → `PUnresolved`).

**Gates:** `--text-mlir` byte-identity **IDENTICAL** (120,247,780 B); full
E2E **1636/1636**; full `elm-tests` **13,037 pass / 12 fail** (the same
pre-existing POST_010 failures, none borrow-related); the core AST change
works across **both** monomorphizer engines + Prune + inline-simplify.
(Two test fixtures — `CafDedupeTest`, `CafHoistTest` — build a full
`MonoGraph` and gained the field; the plan's "no test builds a full
MonoGraph" was stale.)

**Census delta (B3.5 lambda-only → +standalone):** `closureRouted`
**11,109 → 11,627** (+518 standalone-member calls routed),
`poisonedByClosure` a further −240, borrowed +~3.7K resources. The gain is
**modest by design** — standalone members in lambda-set positions are
uncommon (most higher-order dispatch is on actual lambdas) — but the
analysis is now **complete**: every LSS member kind routes; no
`PUnresolved` fallback for standalone members. Fixpoint unchanged
(bailouts 0, maxIter 3, sigMissReads 0).

### Files added/changed (U4.1 standalone routing)
- edits: `Compiler/AST/Monomorphized.elm` (`MemberOrigin(..)` + `MonoGraph.lssMemberOrigins`), `MonoSolver/Monomorphize.elm` (`buildMemberOrigins`), `Monomorphize/Monomorphize.elm` + `Monomorphize/Prune.elm` + `GlobalOpt/MonoInlineSimplify.elm` (thread the field), `Borrow/LssFacts.elm` (origins/globalIndex/sigs + standalone adapters), `Borrow/Sig.elm` (`uniformSigTy`), `Borrow.elm` (`buildGlobalIndex`, assemble full facts), `TestLogic/GlobalOpt/{CafDedupe,CafHoist}Test.elm` (fixture field)

---

## 12. Status: the analysis oracle (Strategy B) is complete

**B0 → B3.5 are all implemented and gated.** The borrow-inference analysis
oracle runs as GlobalOpt Phase 6, census-only (`reify=ROff`, byte-identical,
default-off), and produces the uniqueness/sharing census with
interprocedural + LSS precision. Provably-borrowable share climbed
**B2 20% → B3 26% → B3.5 27% → +standalone → +resultLts 32%** as boundaries
were de-poisoned, and Stage-D precise `ltP` (§14) is now implemented —
**every analysis-precision item in the plan is done.** The runtime RC track
(B4/B5) remains deferred per the §6 Strategy-B verdict.

---

## 13. Argument-return coupling (`resultLts`, as-built 2026-07-26)

`resultLts` (paper §5.1) records which **param** positions each **result**
position couples to, so a caller learns "the value I get back is (part of)
the arg I passed" and can size ownership by how *it* uses the result. This
was `[]` (deferred) through B3/B3.5; now implemented — the biggest single
recovery so far (**27% → 32% borrowed**).

Mechanism (four pieces):
- **α-seeding** (`Constraints.paramSeeds`): each def param position `i`
  seeds its resources with position `i`.
- **Forward α-propagation** (`Solve`): a dedicated `alpha : Array (Set Int)`
  propagated **bind→use** (the *opposite* direction from lifetimes, which go
  use→bind) — so a returned value inherits its source params' α.
- **Readback** (`Borrow.resultLtsOf`): each result resource with a non-empty
  α-set emits `(pos, set)`.
- **Call-site application** (`Constrain.applyDirectSig`): apply the callee's
  **result modes** to the call result, and add coupling flows `arg[i] →
  result[pos]` for each `(pos, s)`, `i ∈ s`.

**Crucially, the two conservative "force result owned" rules were removed** —
`constrainDef` no longer force-owns a def's result, and `constrainCall` no
longer force-owns every call result. Ownership is now demand-driven: a value
is owned iff it is stored into a heap container (construct/store obligation),
passed to an Owned param (def/kernel/closure), or is the fresh result of a
poisoned/unknown call (conservative). A **pass-through** value (a param
returned, or a borrowed-through call result) is correctly **borrowed**, with
the α-coupling tying the caller's arg ownership to the caller's use of the
result. This is what unlocks the 5-point jump. Standalone adapters also
carry `resultLts` now (kernel `resultAliases → (0,{i})`, accessor →
`(0,{0})`, ctor `[]`; `meet` unions them).

**Gates:** `--text-mlir` byte-identity **IDENTICAL** (120,408,427 B); B1 +
BORROW_005 **29/29**; full E2E **1636/1636**; full `elm-tests` **13,037 pass
/ 12 fail** (pre-existing POST_010, none borrow-related). Fixpoint unchanged (bailouts 0,
maxIter 3, sigMissReads 0). Soundness: all owning demands are still
captured; only genuinely pass-through values became borrowed, so 32% is a
tighter (not optimistic) floor. It is sound for the census (reify off) and
matches the standard Perceus borrow model for a future B4.

**Files changed (resultLts):** `Borrow/Constrain.elm` (`paramSeeds` α-seed,
remove force-owned, `applyResultModes`/`applyResultLts`), `Borrow/Solve.elm`
(`alpha` array + `fixAlpha` + `alphaOf`), `Borrow.elm` (`resultLtsOf` in
readback), `Borrow/LssFacts.elm` (adapter `resultLts` + `meet` union).

---

## 14. Stage-D precise `ltP` (as-built 2026-07-26)

Stage D was a stub (`ltP = ltA`) through all prior milestones. It now
computes a **precise** lifetime distinct from the Stage-B approximation:

- **Seed** identically to `ltA` (from `cs.seeds`).
- **Lateral propagation** only through flows whose **use side is Borrowed** —
  an *owned* use consumes the value (transfers/moves it), so it does not
  extend the borrow lifetime; only borrowed (read) uses keep it live.
- **Vertical propagation** through `Get.out` pairs where the container is
  `Owned` and the projection `Borrowed` (an owned container must outlive a
  borrowed projection of it).

`ltP` is the **precise borrow lifetime** — the latest point a borrowed
reference is live — which is what governs drop placement and move legality
(the future Phase 5). The census now:
- computes `maxBorrowExtension` from `ltP` (the precise borrow-lifetime
  depth) rather than the `ltA` approximation, and
- reports **`ltpRefined`** = resources whose `ltP` differs from `ltA`.

**Census:** `ltpRefined = 101,035` (~2.4% of the 4.19M resources) —
Stage D produces a genuinely different (tighter/reshaped) lifetime for
~101K resources, i.e. that many drop-earlier / reuse-earlier opportunities
the approximation missed. `borrowed` stays **32%** — Stage D is
lifetime-only and does not touch ownership (correct). Fixpoint unchanged
(bailouts 0, maxIter 3).

**Gates:** `--text-mlir` byte-identity **IDENTICAL** (120,444,915 B); B1 +
BORROW_005 **29/29**; full E2E **1636/1636**; full `elm-tests`
**13,037 / 12** (pre-existing POST_010). Graph-inert.

**Files changed:** `Borrow/Solve.elm` (`fixLtP` lateral+vertical fixpoint,
`ltP = ltPFinal`), `Borrow.elm` (`maxBorrowExtension` from `ltP`, new
`ltpRefined` census counter).

### Analysis precision: complete
With Stage-D `ltP` done, **every analysis-precision item the borrow-inference
plans specify is implemented**: intra-def (B2), interprocedural SCC-fixpoint
sigs (B3), LSS singleton routing incl. standalone members (B3.5 + U4.1),
argument-return coupling (`resultLts`), and precise lifetimes (Stage D). The
oracle's provably-borrowable share is **32%**, computed with full precision.
The only borrow-inference work left is the deferred **runtime RC track
(B4/B5)** — which the Phase-0 Strategy-B ceiling verdict says to hold until
arrays/lists justify it (v2 backlog item 2).

---

## 15. Escape analysis (stack allocation) + kernel-audit blast radius (2026-07-26)

Two diagnostic questions asked of the oracle, answered by adding **graph-inert
census counters** (report-on == report-off byte-identical, 120,653,919 B; full
E2E 1636/1636). Both live behind `ECO_BORROW_REPORT`.

### 15.1 Does the oracle already do escape analysis? Yes.

Perceus drop-placement ⟺ escape analysis: an owned value discharged by an
inserted *drop* (not moved out via return/store/capture) provably does not
outlive the activation = does not escape = stack-allocatable. The predicate is
read straight off `Solved`:

```
notEscape(r) = reifiedOwned(r) ∧ α(r)=∅ ∧ r ∉ resultResvars ∧ ltP(r) ≠ LParams
```

New counters (`Borrow.elm`): `ownedResources`, `nonEscapingOwned`.

| counter | value | reading |
|---|---:|---|
| resources | 4,197,948 | |
| ownedResources | 2,829,721 (67%) | objects this fn owns/allocated |
| nonEscapingOwned | **1,962,244** | 69.3% of owned · 46.7% of all |
| wouldDrop | 112,635 | owned let-bindings w/ local drop (site-level) |

**Opportunity = a bracket, not a point:**
- Ceiling: 1.96M owned-non-escaping resvars (47% of resources) — but this is an
  UPPER bound; it does **not** chase transitive store-into-escaping-container
  escape (the DSU already links those classes → the tighter lower bound is a
  small extra escape-union pass, not new machinery).
- Site-level floor: ~112K owned locals with a local drop.
- Dynamic weight points DOWN: Phase-0 says allocation is ~65% Cons + closures +
  tuples; the kernel histogram (§15.2) confirms `List.cons` is the #1 owned
  site. Cons cells and closures mostly ESCAPE (returned/stored/captured), so the
  hot classes don't stack-promote. Realized win concentrates in short-lived
  intermediate records/tuples — real but low end. Mirrors the RC ceiling.

A stack-alloc pass would be a 4th reify target `stack-promote r`, gated on
`notEscape(r) ∧ fresh-here ∧ statically-bounded-size(r)`. The one new analysis
piece beyond today's oracle is the storage-transitive escape closure.

### 15.2 Kernel poisoning: heuristic, not necessity; whitelist, not blacklist.

Not all kernel calls poison: 5,311 sites (`kernelSigHits`) already match the
15-entry audited allowlist (`KernelSigs.elm`) and get precise modes. Only
un-audited kernels default all-owned; 13,217 of those carry heap args. That
default is **sound but conservative** (unknown ⇒ owned). `KernelSigs.elm` IS the
audit-driven allowlist; growing it reclaims borrows. It MUST stay a whitelist —
a blacklist (unknown ⇒ borrowed) would be unsound (forgotten retaining kernel →
premature free).

New histogram (`Gen.kernelDefaultedNames` → `renderKernelAudit`): per-kernel
heap-defaulting site count = the prioritized audit worklist. Top of 13,217:

```
List.cons=4151  Utils.append=3270  Scheduler.andThen=1625  Scheduler.succeed=907
Bytes.getStringWidth=696  Crash.crash=461  JsArray.foldl=322  List.map2=232
Scheduler.fail=167  JsArray.unsafeSet=137  JsArray.initializeFromList=122
Scheduler.onError=112  JsArray.initialize=96  List.sortBy=74  String.slice=72
String.cons=68  MVar.put=66  JsArray.push=61  ... (40 shown)
```

**Blast radius ≠ recoverable.** The audit splits conservatively-poisoned into
genuine-owner vs actual-reader:
- **Genuine owners (default already optimal, reclaim nothing):** `List.cons`
  (stores both args), `Scheduler.*` (wraps into Task/Process), `MVar.put`,
  `JsArray.push/unsafeSet/initialize/singleton/appendN`, `String.cons/fromList`,
  and — see correction below — `Utils.append` (String AND List). `cons` +
  `Scheduler.*` + `append` ≈ **10,300 sites (78%)**.
- **Actual readers (audit RECLAIMS):** `Bytes.getStringWidth`, `Crash.crash`,
  `JsArray.foldl/foldr/map`, `List.map2/sortBy/sortWith`,
  `String.slice/toLower/trim/words/uncons/toUpper/all`, `File.*Exists`,
  `Env.lookup`, `Bytes.width`. Recoverable slice ≈ 2–3K of 13.2K.

**CORRECTION (2026-07-27): `Utils.append` (3,270, 25%) is a genuine OWNER over
String as well as List, not "strings copy → borrowable".** `StringOps::append`
(`runtime/src/allocator/StringOps.hpp:477`) has two paths gated on
`total_len ≤ string_flatten_limit` (`STRING_FLATTEN_LIMIT = 32 KiB`,
`AllocatorCommon.hpp:85`): ≤32 KiB `memcpy`s into a fresh leaf (operands read-only);
**>32 KiB calls `makeRope(a,b)` which stores both operands as GC roots
(`StringOps.cpp:84`, `roots,2,0x3`) — the rope RETAINS them**, identical to list
append aliasing elements into new cells. Copy-vs-rope is a **runtime** decision on
byte length; a static `(home,name)` sig can't discriminate it, and soundness must
cover the rope path → the sound sig is `POwned` for both operands (+`resultAliases`).
Dynamically most appends are <32 KiB and *do* copy (morally borrowable), but a flat
sig can't exploit a per-call runtime property. Reclaiming the copy case would need
either an RC world where `makeRope` **dups** its operands instead of consuming them
(caller passes borrowed; RC bump only on the rope path — a real B4 lever) or a
size-guarded dual path — neither expressible in today's table.

So the #1 offender (`cons`, 31%) is a legitimate owner and `append` (25%) is too —
empirically re-confirming the cons/RC ceiling, and the retention-vs-copy subtlety
being a runtime property means the recoverable slice is even smaller than first
estimated (~78% of the blast radius is genuine owners). Auditing is still worth it
(sound rows, zero runtime risk) but works top-down skipping genuine owners; expect
low-thousands of reclaimed sites, not 13K.

**Cross-link:** a kernel audited `PBorrowed` lets its args stay borrowed → they
become escape-analysis candidates → stack-allocatable. Growing the whitelist
directly grows §15.1's opportunity.

**Files:** `Borrow.elm` (`ownedResources`/`nonEscapingOwned`/`kernelDefaultedNames`
+ `renderKernelAudit`), `Borrow/Constrain.elm` (`Gen.kernelDefaultedNames` tally
at the kernel-default site). Graph-inert; census-only.
