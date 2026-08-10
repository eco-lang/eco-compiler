# Kernel-Opt 02: eco.array.push copy-churn: attribution, then fix

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v2 deepened from OUTLINE v1; v3 =
adversarial verification pass — every load-bearing anchor re-checked against the tree,
the Phase-0 build recipe corrected (a kernel C++ edit does **not** propagate through
`--target eco-compiler`), G0 restated from the impossible "binary byte-identity" to
flag-off *inertness*, the lane-B criterion corrected for the kernel ABI forwarders, the
`push_int` residue set corrected, and the missing §P1.0 call-site enumeration + lane A′
added). Derived from design_docs/kernel-boundary-reduction.md
§7 candidate 4 (JsArray/Array, lines 1847-1878 — which this plan must *distinguish
itself from*, see Evidence), the Stage-7a dynamic kernel census
(design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt), and the static census
(design_docs/kernel-boundary/callsite-census-self-compile.txt). This is the biggest
dynamic-census finding the design doc never addresses, and the only
allocation-REDUCTION item in Tier 1.

## Files touched

| File | Change |
|---|---|
| `runtime/src/allocator/RuntimeExports.cpp` | **P0:** `ECO_ARRAY_PUSH_CENSUS` globals + TLS tally + atexit dump, next to the `ECO_CONS_SITES` block (:291-370); tally call in `eco_clone_array` (:4637-4678, insert after :4647) |
| `runtime/src/allocator/HeapHelpers.hpp` | **P0:** `extern "C"` decls for the two new census symbols, next to the cons-site decls (:71-73) |
| `elm-kernel-cpp/src/core/JsArrayExports.cpp` | **P0:** tally calls in `elm_array_push_int/_float/_char/_box` (:745,:755,:765,:775) and `elm_array_slice` (:800) |
| `benchmarks/array-push-census.sh` | **P0 (new):** return-address symbolizer, modeled on `benchmarks/dispatch-census.sh` |
| `compiler/src/System/TypeCheck/IO.elm` | **P1 lane A:** export list :6 + `@docs` :36, `State` :121-128 (arrays :122-124) and its doc bullets :115-119, `unsafePerformIO` seed :78-84 (array fields :78-81), `PointInfo` → `PointCell` :510-512 (+ prose :496, :521) |
| `compiler/src/Data/IORef.elm` | **P1 lane A:** three `newIORef*`/`readIORef*`/`writeIORef*`/`modifyIORef*` families collapse to one `PointCell` family (whole file, incl. export list :2-7 and `@docs` :26/:31/:36/:41) |
| `compiler/src/Compiler/Type/UnionFind.elm` | **P1 lane A:** `fresh`/`repr`/`get`/`set`/`modify`/`union`/`redundant` rewritten against `PointCell` |
| `compiler/src/Data/Vector.elm` | **P1 lane A′ (independent):** drop the discarded `Array.push` accumulator in `imapM_` :60-79 |
| `compiler/src/Compiler/Type/Solve.elm` | **P1 lane A:** snapshot record :100-104 and :132-136 |
| `compiler/src/Compiler/Type/SolverSnapshot.elm` | **P1 lane A:** `SolverState` :29-33, `resolveVariableHelp` :36-46 |
| `compiler/src/Compiler/Type/SolverRoots.elm` | **P1 lane A:** `lookupContent` :252-259 |
| `compiler/src/Compiler/MonoSolver/Engine.elm` | **P1 lane A:** empty IO state :921-924 |
| `compiler/tests/**` (5 files) | **P1 lane A:** mechanical `solverState` record-type updates (list in §P1.6) |

Grep-verified counts: **7** compiler source files (`Compiler/Compile.elm:322-349` threads
`solverState` opaquely and is expected to need no edit — confirm after the type change)
and **5** test files (`grep -rln 'solverState' compiler/tests` → exactly the five in §P1.6).

## Goal

Attribute the ~95.5M-per-self-compile `eco.array.push` lowered calls (each = one fresh
array allocation + O(n) element copy) to their compiler-side drivers and length
distribution, then delete or shrink the copy work at the winner — via Elm-level loop
rewrites, kernel-side pre-sizing, or capacity-slack + in-place append under an RC-1
license. Allocation/copy deletion is the family that has actually moved wall.

## Evidence

- **Dynamic:** `elm_array_push_box` = 64,847,708 calls (rank #8) and
  `elm_array_push_int` = 30,614,780 (rank #11) in the Stage-7a dynamic census —
  ~95.5M pushes per self-compile. Box outnumbers int 2.1:1.
  (Verified: `design_docs/kernel-boundary/kernel-census-dynamic-stage7a.txt:9` and `:12`;
  line 1 is the `total=3676097627 distinct=98` header, so file line *n* = rank *n−1*.)
- **Invisible statically:** these are NOT `Elm_Kernel_*` symbols; they are the lowering
  targets of the `eco.array.push` dialect op — decls created at
  runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:1013-1031 (int :1015, float :1020,
  char :1025, box :1030), selected by `ArrayPushOpLowering`
  (EcoToLLVMHeap.cpp:1454-1483) off the *element* MLIR type. The static kernel census
  cannot see them; hence Phase 0.
- **Per-call cost (elm-kernel-cpp/src/core/JsArrayExports.cpp):**
  `copyAndExtendForPush` (:711-741) does `alloc::allocArray(len+1)` (:721) then copies
  all `len` elements (:725-727); `elm_array_push_box` (:775-798) inlines the same shape
  with both value and array rooted. Under `ECO_HEAP_VALIDATE` each push additionally
  validates every copied element (:733-738, :790-795).
- **NEW — every Elm `Array.push` pushes onto a ≤31-element tail.** `elm/core`'s
  `Array` is a 32-way tree (`branchFactor = 32`,
  `~/.eco/0.1.0/packages/elm/core/1.0.5/src/Array.elm:69-70`) and
  `push a (Array_elm_builtin _ _ _ tail) = unsafeReplaceTail (JsArray.push a tail) array`
  (:344-346). So the length histogram is ≤32-dominated *by construction*; a `33+`
  bucket can only be fed by a non-`Array.push` driver. The outline's kill criterion is
  restated accordingly (§P0.5): the metric is **total elements copied**, not bucket shape.
- **NEW — `Array.set` is a second, larger, and completely unmeasured copy engine.**
  `eco.array.set` lowers *inline* to `eco_clone_array` (`ArraySetOpLowering`,
  EcoToLLVMHeap.cpp:1308-1330, clone call at :1328 via `EcoRuntime::getOrCreateCloneArray`
  EcoToLLVMRuntime.cpp:964-968 → RuntimeExports.cpp:4637-4678), which allocates
  `allocArray(len)` (:4649) and copies every element (:4662-4664).
  `eco_clone_array` does not match the
  `Elm_Kernel_`/`elm_array_` prefixes the 2026-08-09 census instrumented
  (plans/kernel-call-census.md §C1.2), so **zero** `Array.set` traffic appears in the
  dynamic census. Every `writeIORef*` is an `Array.set`, and a tree `Array.set` clones
  one ≤32-element JsArray per level (~5 levels at 30M elements). Phase 0 counts it.
- **NEW — arithmetic hypothesis H1 (the push traffic is the type checker's union-find).**
  `Compiler/Type/UnionFind.elm:46-54` `fresh` calls, per point, exactly one
  `newIORefWeight` (`Array Int` → `push_int`, Data/IORef.elm:58-60), one
  `newIORefDescriptor` (:72-74) and one `newIORefPointInfo` (:65-67) — both boxed →
  `push_box`. Grep confirms `fresh` is the *only* caller of all three
  (`newIORefMVector` :79-81 is called only from `Data/Vector/Mutable.elm:31`).
  Prediction (write these down *before* running Phase 0):
  - `push_int` = #fresh **+ one small residue only**: of the 27 `Array.push` sites in
    `compiler/src` (§P1.0), exactly one other pushes an unboxed `Int` —
    `GlobalOpt/Staging/UnionFind.elm:179` (`Array.push nid sg0.uf.parent`, `nid` is
    `sg0.nextNodeId : Int`). Every other site pushes a boxed value. So
    **#fresh = push_int − staging-residue ≲ 30,614,780**.
  - `push_box` = 2 × #fresh (Descriptor + PointInfo) + tail-overflow tree pushes
    (`Array.elm:409,417` `JsArray.push (Leaf tail) tree` / `JsArray.push newSub tree`,
    ≈ N/32 per array × 3 arrays = 2.87M) + the boxed residue of the other 25 sites
    = 61,229,560 + 2,870,136 + residue = 64,099,696 vs **measured 64,847,708**
    — a 1.15% (748,012-call) residue for the other 25 boxed `Array.push` sites.
  H1 is the thing Phase 0 tests. If it holds, the fix is an Elm-level data-structure
  merge with no license machinery (lane A).
  *Correction to the outline:* `Constrain/Typed/NodeIds.elm:168` is **not** a `push_int`
  source — it sits in `arraySetGrowing : Int -> Maybe a -> Array (Maybe a) -> Array (Maybe a)`
  (:162-168), i.e. a boxed `Maybe` element → `push_box`.
- **NEW — capacity slack is already representable; the design doc's implied blocker is
  wrong.** `ElmArray` (Heap.hpp:722-727) has `header.size = capacity` and a separate
  `length`; `getObjectSize` sizes `Tag_Array` by **capacity** (AllocatorCommon.hpp:315-325),
  evacuation `memcpy`s `getObjectSize(obj)` bytes (NurserySpace.cpp:1027/1046), and every
  scan/mark/fixup walks `length` only (NurserySpace.cpp:1544-1600, :651-665;
  OldGenSpace.cpp:1716-1722, :3986-3992). `allocArrayBuilder` (HeapHelpers.hpp:1712-1718)
  already ships `capacity > length` arrays through GC. **The blocker for in-place append is
  purely the aliasing license, not the layout** (see lane C).
- **Compiler-side Array users** (design doc §7.4, lines 1857-1862): the type checker's
  IORef emulation stores union-find state in Array fields
  (compiler/src/System/TypeCheck/IO.elm:122-124, `unsafePerformIO` seed :78-81, wrapped by
  Data.Vector/Data.IORef), plus Monomorphize bookkeeping (State/Registry/Prune) and Graph.
  (The design doc quotes `IO.elm:79-82,123-126` — those anchors have drifted one line;
  the tree is the truth.) Hot HOF drivers: `JsArray_foldl` 365 static sites,
  `initializeFromList_Int` 118, `initialize_Int` 97, `foldr` 49 —
  `design_docs/kernel-boundary/callsite-census-self-compile.txt:10,15,18,28` (the design
  doc calls this file `kernel-callsites.txt`; no such path exists, the counts match the
  file above exactly).
- **Kernel builders already avoid push-per-element** — `Elm_Kernel_JsArray_initialize`,
  `initializeFromList` and `map` use `allocArrayBuilder` + `arrayPushKind` into
  pre-sized capacity (JsArrayExports.cpp:441, :481, :538, :961, :1009 with
  `arrayPushKind` at HeapHelpers.hpp:1828-1842). So lane (a) of the outline
  ("kernel-internal pre-sizing") is *a priori* mostly already done; Phase 0 must prove a
  remaining kernel-internal driver before that lane is opened.
- **Why candidate 4's REJECT does not cover this item:** that verdict (lines 1864-1878)
  rejects *wholesale representation replacement* on RETENTION grounds — `Tag_Array` is
  0.1-0.2% of promotion (LH1, benchmarks/tier2-opt.md:285). This plan targets *nursery
  churn + O(n) copy work* — deleted per-op work, the family of inline-nursery (−9.6%)
  and K6 (−5.07%) — not the retained set, and proposes no new heap representation.

## Approach

### Phase 0 (S) — attribution census. Mandatory; everything else is evidence-gated.

**Mechanism (PRIMARY, pinned): env-gated return-address tally + length histogram inside
the copy engines**, modeled byte-for-byte on the in-tree `ECO_CONS_SITES` census
(RuntimeExports.cpp:291-370) — chosen over `perf` because
`/proc/sys/kernel/perf_event_paranoid == 3` in this environment with no root
(confirmed 2026-08-10; matches plans/kernel-call-census.md "perf is unavailable"), and
over the 2026-08-09 `[kernel-census]` instrumentation because that tool is **not in the
tree** (`grep -rn eco_kernel_census /work/runtime/src /work/elm-kernel-cpp` → 0 hits;
it was scratch instrumentation) and because it counts calls only, not lengths or
`eco_clone_array`.

**P0.1 — census core (RuntimeExports.cpp, next to the cons-site block at :291-370).**

```cpp
// Array copy-churn census (ECO_ARRAY_PUSH_CENSUS=1, measurement builds):
// counts every array copy engine by caller return address, engine, and source
// length; dumped at exit with the main-module base so sites symbolize offline.
// Same TLS-map + mutex-merge shape as the cons-site tally above.
extern "C" bool eco_g_array_census = false;

namespace {
enum ArrEngine { AE_PushInt, AE_PushFloat, AE_PushChar, AE_PushBox,
                 AE_Clone, AE_Slice, AE_Count };
const char* kArrEngineName[AE_Count] =
    { "push_int", "push_float", "push_char", "push_box", "clone_set", "slice" };
// Buckets on the SOURCE length: 0-4, 5-8, 9-16, 17-32, 33+.
inline unsigned arrBucket(uint32_t n) {
    return n <= 4 ? 0u : n <= 8 ? 1u : n <= 16 ? 2u : n <= 32 ? 3u : 4u;
}
struct ArrCensusTotals {
    uint64_t calls[AE_Count][5] = {};
    uint64_t elems[AE_Count]    = {};   // elements copied (== source length)
    uint32_t maxLen[AE_Count]   = {};
};
std::mutex g_arrMu;
ArrCensusTotals g_arrAll;
std::unordered_map<void*, uint64_t> g_arrSitesAll[AE_Count];

// Defined HERE, inside this same anonymous namespace, before ArrCensusInit
// (the atexit lambda names it). Body = the dumpConsSites base computation
// verbatim (:302-333) plus the per-engine lines below.
void dumpArrCensus();

struct ArrCensusTls {
    ArrCensusTotals t;
    std::unordered_map<void*, uint64_t> sites[AE_Count];
    ~ArrCensusTls() { mergeInto(); }
    void mergeInto() {
        std::lock_guard<std::mutex> l(g_arrMu);
        for (int e = 0; e < AE_Count; ++e) {
            for (int b = 0; b < 5; ++b) g_arrAll.calls[e][b] += t.calls[e][b];
            g_arrAll.elems[e] += t.elems[e];
            if (t.maxLen[e] > g_arrAll.maxLen[e]) g_arrAll.maxLen[e] = t.maxLen[e];
            for (auto& kv : sites[e]) g_arrSitesAll[e][kv.first] += kv.second;
            sites[e].clear();
        }
        t = ArrCensusTotals{};
    }
};
thread_local ArrCensusTls g_arrTls;

struct ArrCensusInit {
    ArrCensusInit() {
        if (std::getenv("ECO_ARRAY_PUSH_CENSUS")) {
            eco_g_array_census = true;
            std::atexit([] { g_arrTls.mergeInto(); dumpArrCensus(); });
        }
    }
};
ArrCensusInit g_arrCensusInit;
} // namespace

extern "C" void eco_array_census_tally(uint32_t engine, uint32_t len, void* ra) {
    ArrCensusTls& s = g_arrTls;
    s.t.calls[engine][arrBucket(len)]++;
    s.t.elems[engine] += len;
    if (len > s.t.maxLen[engine]) s.t.maxLen[engine] = len;
    s.sites[engine][ra]++;
}
```

No new `#include`s are needed. `RuntimeExports.cpp` already includes `<algorithm>` (:17),
`<cstdio>` (:23), `<cstdlib>` (:24), `<unistd.h>` (:26), `<unordered_map>` (:31) and
`<vector>` (:32). Note `<mutex>` is **not** directly included yet `std::mutex` already
compiles at :299 (it arrives transitively through the allocator headers) — do not "fix"
that by adding an include in the same commit, or G0's output-identity comparison picks up
unrelated churn.

`dumpArrCensus()` — placed inside the anonymous namespace where it is forward-declared
above — reuses the `/proc/self/exe` + `/proc/self/maps` base computation verbatim from
`dumpConsSites` (:302-333) and prints:

```
[array-census] base=0x55e3f0a00000 total_calls=<N> total_elems_copied=<E>
[array-census] engine=push_box calls=<N> elems=<E> max=<L> b0_4=<n> b5_8=<n> b9_16=<n> b17_32=<n> b33p=<n>
...one line per engine...
[array-census] site engine=push_box +0x0012ab34 calls=<n>       (top 80 per engine, desc)
```

**P0.2 — declarations** (HeapHelpers.hpp, next to the cons-site pair at :72-73):

```cpp
// Array copy-churn census (ECO_ARRAY_PUSH_CENSUS=1 measurement runs; RuntimeExports.cpp).
extern "C" bool eco_g_array_census;
extern "C" void eco_array_census_tally(uint32_t engine, uint32_t len, void* ra);
```

**Registration checklist** (verified against how `eco_cons_site_tally` is wired —
`grep -rn eco_cons_site_tally /work/runtime /work/elm-kernel-cpp`):
1. definition in `runtime/src/allocator/RuntimeExports.cpp` ✔ (P0.1)
2. `extern "C"` declaration in `runtime/src/allocator/HeapHelpers.hpp` ✔ (P0.2)
3. **NOT** in `runtime/src/codegen/RuntimeSymbols.cpp` — generated code never calls it;
   `eco_cons_site_tally` is absent there too. (Contrast, both verified: `elm_array_push_int`
   needs `elm-kernel-cpp/src/KernelExports.h:281` + `runtime/src/codegen/RuntimeSymbols.cpp:767`
   `KERNEL_SYM(elm_array_push_int)` + `EcoToLLVMRuntime.cpp:1015` `getOrCreateFunc`;
   `eco_clone_array` is registered at `RuntimeSymbols.cpp:447-449` as a direct
   `symbolMap[interner(...)]` entry. **No new generated-code-visible symbol is introduced
   by this plan**, so neither table changes.)
4. **NOT** in `KernelExports.h` — that header is the generated-code ABI surface only.
5. Link surface: the tally lives in `EcoRuntimeStatic` and is called from
   `elm-kernel-cpp` TUs. That cross-archive shape is already exercised by
   `eco_cons_site_tally` (declared HeapHelpers.hpp:71-73, called from the inline helper at
   HeapHelpers.hpp:632 in kernel TUs), and both archives are linked into every produced
   binary by `eco-boot-native`, so no link-order work is needed.

`JsArrayExports.cpp` already `#include`s `allocator/HeapHelpers.hpp` (:13) and
`allocator/RuntimeExports.h` (:14), so no include churn.

**P0.3 — call sites (5 in the kernel, 1 in the runtime).** Each is one predicted-false
branch; `__builtin_return_address(0)` in the *export* frame is the generated-code caller.

```cpp
// JsArrayExports.cpp:745  elm_array_push_int (identically at :755 _float, :765 _char)
HPtr elm_array_push_int(int64_t v, HPtr array) {
    uint32_t len, kind;
    HPointer result = copyAndExtendForPush(array, len, kind);
    if (__builtin_expect(eco_g_array_census, 0))
        eco_array_census_tally(/*AE_PushInt=*/0, len, __builtin_return_address(0));
    ...unchanged...
}
// JsArrayExports.cpp:775  elm_array_push_box — after `uint32_t len = ...->length;` (:781)
    if (__builtin_expect(eco_g_array_census, 0))
        eco_array_census_tally(/*AE_PushBox=*/3, len, __builtin_return_address(0));
// JsArrayExports.cpp:800  elm_array_slice — after `int64_t len = src->length;` (:806).
// NOTE the type: `len` here is int64_t, so cast. Tally the SOURCE length (the
// bucket axis stays comparable across engines); the slice's copied count is
// (end-start) and is not what this axis measures.
    if (__builtin_expect(eco_g_array_census, 0))
        eco_array_census_tally(/*AE_Slice=*/5, static_cast<uint32_t>(len),
                               __builtin_return_address(0));

// RuntimeExports.cpp:4637 eco_clone_array — after `uint32_t len = src->length;` (:4647)
    if (__builtin_expect(eco_g_array_census, 0))
        eco_array_census_tally(/*AE_Clone=*/4, len, __builtin_return_address(0));
```

Do **not** put the tally inside `copyAndExtendForPush` — its return address is the
`elm_array_push_*` frame, which destroys attribution.

**Forwarder caveat (affects how the site table is read, and the §P0.5 gate).**
`Elm_Kernel_JsArray_push_Int/_Float/_Char` are one-line delegations to
`elm_array_push_*` (JsArrayExports.cpp:853-855), and `Elm_Kernel_JsArray_slice_Int`
likewise (:858-860). Calls that arrive through those kernel symbols will symbolize to
the forwarder frame (or, if the compiler inlines the callee into the forwarder, straight
through to the generated caller). Treat `Elm_Kernel_JsArray_push_*` /
`Elm_Kernel_JsArray_slice_Int` rows as **"arrived via the kernel ABI symbol"**, never as
"a kernel-internal driver" — see the corrected lane-B criterion in §P0.5.

**P0.4 — build, run, read.**

**Do NOT use `cmake --build build --target eco-compiler` to pick up this patch.**
Verified against the build files: Stage 6 is
`add_custom_command(OUTPUT ${ECO_COMPILER_ELF} … DEPENDS ${ECO_COMPILER_MLIR} eco-boot-native)`
(compiler/CMakeLists.txt:455-464), and `KERNEL_SOURCES` globs only
`eco-kernel-cpp/src/Eco/*.elm` + `*.js` (compiler/CMakeLists.txt:255-258). A C++ edit in
`elm-kernel-cpp/` or `runtime/src/allocator/` changes **neither** dependency file, so the
Stage-6 command is considered up to date and the ELF keeps the *old* kernel archive.
The kernel/runtime archives are linked into the output binary by `eco-boot-native`
shelling out to `clang` at run time (runtime/src/codegen/CMakeLists.txt:1565-1582, the
`ECO_BOOT_NATIVE_RUNTIME_DEPS` list, wired by `add_dependencies(eco-boot-native …)` at
:1583), so the correct recipe is: rebuild `eco-boot-native`
(that refreshes the archives), then **re-link a scratch census binary yourself** —
exactly the shape of plans/kernel-call-census.md §C1.4. This also keeps the pristine
in-tree `eco-compiler` intact for the A/B and side-steps the `--target full` .mlir-deletion
trap.

```bash
# 0. preserve the pristine binary for G0/G5 A-B before touching anything
cp /work/build/compiler/build-kernel/bin/eco-compiler /tmp/eco-compiler-prepatch

# 1. rebuild eco-boot-native => refreshes ElmKernel_* / EcoRuntimeStatic archives
cmake --build build --target eco-boot-native 2>&1 | tee /tmp/p0_build.txt

# 2. link the instrumented census binary from the UNCHANGED front-end MLIR
#    (RelWithDebInfo keeps symbols for the symbolizer)
S=/tmp/claude-1000/-work/692d3981-3e69-4e41-9a46-5cd6a429e26d/scratchpad/arrpush
mkdir -p "$S"
/work/build/runtime/src/codegen/eco-boot-native \
    /work/build/compiler/build-kernel/bin/eco-compiler.mlir \
    -o "$S/eco-compiler-census" 2>&1 | tee -a /tmp/p0_build.txt

# 3. Stage 7a, cold caches, scratch workdir (mirrors plans/kernel-call-census.md §C1.4
#    and the real Stage-7a command, compiler/CMakeLists.txt:478-490)
cd "$S"
cp /work/build/compiler/build-kernel/elm.json .          # no eco-stuff here => cold
cp /work/build/compiler/build-kernel/heap-config.json .
ECO_ARRAY_PUSH_CENSUS=1 "$S/eco-compiler-census" make --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output="$S/out.mlir" /work/compiler/src/Terminal/Main.elm 2> "$S/array-census.log"

# 4. read totals
grep '^\[array-census\] engine=' "$S/array-census.log"
grep '^\[array-census\] total' "$S/array-census.log"

# 5. symbolize the top drivers (symbolize against the binary that produced the log)
/work/benchmarks/array-push-census.sh "$S/eco-compiler-census" "$S/array-census.log" 30
```

`build/compiler/build-kernel/{elm.json,heap-config.json}` both exist and are what the
real Stage 7a runs against; `elm.json` declares `"source-directories": ["src"]` but the
entry point is passed as an absolute path and `build-kernel` itself has no `src/`, so the
scratch dir needs nothing more than those two files (that is exactly how the in-tree
Stage 7a works). Never run this concurrently with a test suite
(memory: eco-e2e-unit-cache-race — the shared `eco-kernel-cpp/typed-artifacts.dat`).

`benchmarks/array-push-census.sh` (new, ~40 lines) is `dispatch-census.sh` with the
anchor arithmetic simplified: the dump already emits module-relative offsets, so the
script only needs the greatest-lower-bound lookup:

```bash
nm -C "$BIN" | awk '$2 ~ /[tT]/ { print $1, $3 }' | sort > "$SYMS"
awk '/^\[array-census\] site/ { print $3, $4, $5 }' "$LOG" |   # engine=... +0xoff calls=n
while read -r ENG OFF CALLS; do
    ADDR=$(printf "%016x" $(( ${OFF#+} )))
    SYM=$(awk -v a="$ADDR" '$1 <= a { s = $2 } $1 > a { exit } END { print (s ? s : "<unknown>") }' "$SYMS")
    printf "%-12s %-14s %s\n" "${ENG#engine=}" "${CALLS#calls=}" "$SYM"
done
```

Mangled Elm symbols carry the module path (e.g. `Compiler_Type_UnionFind_fresh$…`), so
H1 is readable straight off this table. If a top site symbolizes to an inlined/anonymous
`$clo`/`$cap` clone, resolve against **the binary that produced the log** with
`addr2line -f -C -i -e "$S/eco-compiler-census" <off>`.

**P0.5 — decision gate (both branches specified).**

Let `E` = `total_elems_copied` over all engines, `Ppush` = push calls, `Pclone` = clone
calls, `top1..top6` = symbolized site shares.

| Criterion | Branch |
|---|---|
| **H1 CONFIRMED**: `push_int` sites ≥80% one symbol resolving into `Compiler_Type_UnionFind_fresh…` / `Data_IORef_newIORef…` — or, if `fresh` has been inlined, into a `Compiler_Type_*` caller of it — **and** `push_box ≈ 2 × push_int ± 10%` | → **Lane A** (§P1). Highest-value, license-free. |
| H1 refuted **and** ≥30% of push calls attribute to return addresses inside `elm-kernel-cpp`/`runtime` frames **other than** the thin ABI forwarders `Elm_Kernel_JsArray_push_*` (JsArrayExports.cpp:853-855) and `Elm_Kernel_JsArray_slice_Int` (:858-860) — those forwarders mean "arrived via the kernel symbol", not "a kernel-internal driver", and must be excluded from the 30% | → **Lane B** (kernel-internal pre-sizing, §P1.7). |
| H1 refuted, drivers diffuse (no site ≥20%), **and** `E < 300,000,000` (< ~2.4 GB moved) | → **NO-GO.** Record the census in `benchmarks/kernel-opt.md`, update design doc §7.4 with the reopen condition, stop. |
| H1 refuted, drivers diffuse, but `b33p` ≥ 25% of push calls | → true growable-vector usage exists; only lane C can help → **BLOCKED**, record and stop (§P1.8). |
| `Pclone × avg-clone-len` > `Ppush × avg-push-len` | → note in the report that `Array.set` is the larger engine; lane A already halves it (§P1.4), but a follow-on plan owns any further `Array.set` work. |

Predicted values under H1 (state them *before* running, then compare): `push_int` ≈
30.6M, `push_box` ≈ 64.8M, `E_push` ≈ 1.48G elements (≈ 11.8 GB), `b33p` ≈ 0 for
`push_*`, `Pclone` dominated by `Data.IORef.writeIORef*`.

**Acceptance:** the log exists, the engine table is complete, the symbolized top-30 is
pasted into this plan's §Results, and exactly one branch above is selected in writing.
Flag-off inertness re-checked (§Gates G0).

### P1.0 — the complete Elm-level `Array.push` surface (grep executed 2026-08-10)

`grep -rn 'Array\.push\|Vector\.push\|JsArray\.push' compiler/src --include=*.elm` →
**27 sites**, listed in full so lane selection needs no further searching. Element kind
is what picks the lowering (`ArrayPushOpLowering`, EcoToLLVMHeap.cpp:1454-1483).

| Site | Pushed element | Engine | Driver / note |
|---|---|---|---|
| `Data/IORef.elm:60` | `Int` (weight) | `push_int` | **H1 core** — from `UnionFind.fresh` only |
| `Data/IORef.elm:67` | `IO.PointInfo` | `push_box` | **H1 core** — from `UnionFind.fresh` only |
| `Data/IORef.elm:74` | `IO.Descriptor` | `push_box` | **H1 core** — from `UnionFind.fresh` only |
| `Data/IORef.elm:81` | `Array (Maybe (List Variable))` | `push_box` | MVector; only caller `Data/Vector/Mutable.elm:31` |
| `Data/Vector.elm:70` | `Maybe b` | `push_box` | **dead accumulator** in `imapM_` — lane A′ below |
| `Compiler/GlobalOpt/Staging/UnionFind.elm:178` | node | `push_box` | staging graph build |
| `Compiler/GlobalOpt/Staging/UnionFind.elm:179` | `Int` (`nid`) | `push_int` | **the only other `push_int` site in the tree** |
| `Compiler/Type/Constrain/Typed/NodeIds.elm:168` | `Maybe a` | `push_box` | `arraySetGrowing` :162-168 |
| `Compiler/Monomorphize/Registry.elm:68`, `:130` | `Maybe (…, …)` | `push_box` | reverseMapping |
| `Compiler/GlobalOpt/CafHoist.elm:198`, `:201`, `:211`, `:218` | `Maybe Mono.*` | `push_box` | node-array rebuild |
| `Compiler/GlobalOpt/AbiCloning.elm:556`, `:559` | `Maybe node` | `push_box` | node-array rebuild |
| `Compiler/GlobalOpt/Staging/Rewriter.elm:87`, `:94` | `Maybe node` | `push_box` | node-array rebuild |
| `Compiler/GlobalOpt/MonoGlobalOptimize.elm:1038`, `:1041` | `Maybe node` | `push_box` | node-array rebuild |
| `Compiler/GlobalOpt/MonoInlineSimplify.elm:674`, `:677`, `:680`, `:683` | `Maybe node` | `push_box` | node-array rebuild |
| `Compiler/AST/StringTable.elm:124` | `String` | `push_box` | intern table |
| `Compiler/MonoSolver/Store.elm:301` | `Maybe mvarId` | `push_box` | pad-and-set |
| `Compiler/Generate/MLIR/Intrinsics.elm:708` | — | — | comment only, not a call site |

Consequences pinned (26 real call sites + 1 comment = the 27 grep hits):
- Of the 22 non-`Data.IORef` real sites: 1 is the dead accumulator (`Vector.elm:70`),
  2 build the staging union-find graph once per staging node, and the remaining **19 are
  once-per-node/per-symbol array rebuilds** in GlobalOpt / Monomorphize / AST passes,
  each bounded by the node or symbol count of one module. None of them is a plausible
  source of tens of millions of calls. This is *why* H1 predicts a 1.15% residue rather
  than a diffuse distribution — and it is the list to check the symbolized top-30
  against if H1 is refuted.
- **`Data/Vector.elm` owns no growth policy.** Read whole (98 lines): it is
  `unsafeLast` / `unsafeInit` (`identity`) / `unsafeFreeze` (`IO.pure`) /
  `imapM_` / `mapM_` / `forM_` over `IORef (Array (Maybe (List Variable)))`. Its single
  `Array.push` (:70) is inside `imapM_` and is **pure waste** — see lane A′.

**Lane A′ (XS, independent of H1, no license, no flag): delete the dead accumulator in
`Data/Vector.imapM_` (:60-79).** Today the fold builds an array it then throws away:

```elm
imapM_ action ioRef =
    IORef.readIORefMVector ioRef
        |> IO.andThen
            (\value ->
                Array.foldl
                    (\( i, maybeX ) ioAcc ->
                        case maybeX of
                            Just x ->
                                IO.andThen
                                    (\acc -> IO.map (\newX -> Array.push (Just newX) acc) (action i x))
                                    ioAcc
                            Nothing -> ioAcc
                    )
                    (IO.pure Array.empty)
                    (Array.indexedMap Tuple.pair value)
                    |> IO.map (\_ -> ())    -- <- the whole accumulator is discarded here
            )
```

Replace the accumulator with unit; effects and their order are unchanged because
`IO.andThen`/`IO.map` still sequence `action i x` identically:

```elm
                Array.foldl
                    (\( i, maybeX ) ioAcc ->
                        case maybeX of
                            Just x -> ioAcc |> IO.andThen (\_ -> action i x) |> IO.map (\_ -> ())
                            Nothing -> ioAcc
                    )
                    (IO.pure ())
                    (Array.indexedMap Tuple.pair value)
            )
```

This deletes one `push_box` **and** one `Array.length`-proportional copy per element
visited by `forM_`/`imapM_` (the solver's rank-pool walks). Ship it as its own commit
with its own G1/G1b/G2 pass so its delta is attributable separately from lane A; it is
not gated on the Phase 0 verdict, but do measure it separately (never fold two
allocation deltas into one wall number).

### Phase 1 lane A (M) — merge the three parallel union-find arrays into one cell array

**Selected iff H1 confirms.** No representation change, no license, no runtime change.

**Why it works.** `UnionFind.fresh` (:46-54) pushes one element onto each of
`ioRefsWeight`, `ioRefsDescriptor`, `ioRefsPointInfo` — and *nothing else pushes onto
any of them*: the only writers of those three fields anywhere in the tree are
`Data/IORef.elm:60/67/74` (push) and `:140/147/154` (set), and their `newIORef*` entry
points have exactly one caller each, `fresh` (§P1.0; re-verify with
`grep -rn 'ioRefsWeight\|ioRefsPointInfo\|ioRefsDescriptor' /work/compiler/src /work/compiler/tests --include=*.elm`).
Therefore the three arrays are **index-synchronized**:
`Array.length` before each push is the same number in all three (each `newIORef*`
returns the pre-push length, Data/IORef.elm:60/74/67), so a point's `weight` ref,
`descriptor` ref and `pointInfo` ref are the *same integer*. `Info w d` stores two
copies of the point's own index. Collapsing to one array of one cell is behaviour-
preserving **and preserves the numeric point ids exactly**, which is why output
byte-identity is expected (§Gates G2).

**P1.1 — `System/TypeCheck/IO.elm`.** Replace `PointInfo` (:510-512) with:

```elm
{-| The union-find cell for a Point: either a root carrying its weight and
descriptor inline, or a link to its parent. Replaces the former
`PointInfo = Info Int Int | Link Point` plus the separate weight/descriptor
arrays; the three were index-synchronised (only `UnionFind.fresh` grew them,
one element each, kernel-opt-02).
-}
type PointCell
    = Root Int Descriptor
    | Chain Point
```

(Name-collision check run: `Root`/`Chain` are unused as constructors anywhere in
`System/TypeCheck/IO.elm`, and no module imports it with `exposing (..)` — every
consumer uses the qualified `IO.` prefix. Safe to add.)

`State` (:121-128; the three arrays to merge are :122-124) becomes:

```elm
type alias State =
    { ioRefsPoint : Array PointCell
    , ioRefsMVector : Array (Array (Maybe (List Variable)))
    , names : NameState
    , nodeIds : NodeIdState
    }
```

and the `unsafePerformIO` seed record (:78-84; the four `Array.empty` fields are
:78-81) drops to
`{ ioRefsPoint = Array.empty, ioRefsMVector = Array.empty, names = …, nodeIds = … }`.

Registration checklist for the renamed type (all four must move together, or the
front-end build fails / the docs block drifts):
1. export list :6 — `Point(..), PointInfo(..)` → `Point(..), PointCell(..)`;
2. `@docs Point, PointInfo` :36 → `@docs Point, PointCell`;
3. `State` doc bullets :115-119 — the `ioRefsWeight`/`ioRefsPointInfo`/`ioRefsDescriptor`
   bullets collapse to one `ioRefsPoint` bullet;
4. prose at :496 ("indices into the `ioRefsPointInfo` array") and :521 ("stored in the
   `ioRefsDescriptor` array") — both now describe `ioRefsPoint`.

**P1.2 — `Data/IORef.elm`** (177 lines total). The nine `Weight`/`PointInfo`/`Descriptor`
functions — `newIORef*` :56-74, `readIORef*` :85-120, `writeIORef*` :136-154 — plus
`modifyIORefDescriptor` :164-169 collapse to one three-function `PointCell` family. The
four `MVector` functions (`newIORefMVector` :79-81, `readIORefMVector` :123-133,
`writeIORefMVector` :157-161, `modifyIORefMVector` :172-177) are **untouched**. Update the
export list :2-7 and the four `@docs` lines :26/:31/:36/:41 in the same edit.

```elm
{-| Allocate a fresh union-find cell; returns its index (the Point id). ONE
`Array.push` where the pre-merge code did three. -}
newPointCell : Int -> IO.Descriptor -> IO Int
newPointCell weight desc =
    \s -> ( { s | ioRefsPoint = Array.push (IO.Root weight desc) s.ioRefsPoint }
          , Array.length s.ioRefsPoint
          )

readPointCell : Int -> IO IO.PointCell
readPointCell ref =
    \s ->
        case Array.get ref s.ioRefsPoint of
            Just cell -> ( s, cell )
            Nothing -> crash "Data.IORef.readPointCell: could not find entry"

writePointCell : Int -> IO.PointCell -> IO ()
writePointCell ref cell =
    \s -> ( { s | ioRefsPoint = Array.set ref cell s.ioRefsPoint }, () )
```

There is deliberately **no** `modifyPointCell`: the old `modifyIORefDescriptor` (:164-169)
was read-then-write over the *descriptor* array, and its only caller is
`UnionFind.modify` (:150, :158), which under `PointCell` must preserve the weight in the
same cell. So `modify` composes `readPointCell` + `writePointCell` directly (sketch in
P1.3) rather than going through a helper.

`type IORef a = IORef Int` stays only for the MVector family (its `newIORefMVector`
signature keeps the `IORef` wrapper, so the constructor and export must remain).
**Secondary win:** the three `IORef` wrapper allocations per `fresh` disappear along with
the two `IO.andThen` / one `IO.map` closures — see §Expected impact (and the caveat there:
that row is a *prediction to verify*, not a measured fact).

**P1.3 — `Compiler/Type/UnionFind.elm`.** `fresh` (:46-54) becomes a one-liner:

```elm
fresh : IO.Descriptor -> IO IO.Point
fresh value =
    IORef.newPointCell 1 value |> IO.map IO.Pt
```

`repr` (:57-81), `get` (:87-107), `set` (:113-137), `modify` (:143-164) and `redundant`
(:238-249) mechanically re-case `Info _ descRef → Root _ desc` (descriptor now in hand,
no second array read) and `Link p → Chain p`. Example, `get`:

```elm
get : IO.Point -> IO Descriptor
get ((IO.Pt ref) as point) =
    IORef.readPointCell ref
        |> IO.andThen
            (\cell ->
                case cell of
                    IO.Root _ desc ->
                        IO.pure desc

                    IO.Chain (IO.Pt ref1) ->
                        IORef.readPointCell ref1
                            |> IO.andThen
                                (\cell1 ->
                                    case cell1 of
                                        IO.Root _ desc -> IO.pure desc
                                        IO.Chain _ -> repr point |> IO.andThen get
                                )
            )
```

`set` on a root writes the whole cell (`Root w newDesc`) — same one `Array.set` as
before, not one more. `modify` loses its `modifyIORefDescriptor` helper and becomes
read-then-write on the same cell, preserving the weight:

```elm
                    IO.Root w desc ->
                        IORef.writePointCell ref (IO.Root w (func desc))
```

`repr` (:57-81) is unchanged in shape: its path-compression write at :74 copies the
parent's cell into the child, and under `PointCell` that cell is a `Chain` exactly when
it was a `Link` before (the `point2 /= point1` guard already guarantees the parent is
not a root), so the compression semantics are identical.

`union` (:171-219) drops from **three** `Array.set`s
(`writeIORefPointInfo ref2` + `writeIORefWeight w1` + `writeIORefDescriptor d1`) to
**two**:

```elm
                                    if weight1 >= weight2 then
                                        IORef.writePointCell ref2 (IO.Chain point1)
                                            |> IO.andThen (\_ -> IORef.writePointCell ref1 (IO.Root newWeight newDesc))
                                    else
                                        IORef.writePointCell ref1 (IO.Chain point2)
                                            |> IO.andThen (\_ -> IORef.writePointCell ref2 (IO.Root newWeight newDesc))
```

and the two `readIORefWeight` calls (:191, :194) vanish — `weight1`/`weight2` now bind
straight from the `( IO.Root weight1 _, IO.Root weight2 _ )` pattern at :186.

⚠️ **Trap in the `point1 == point2` branch (:187-188).** Today it is
`writeIORefDescriptor (IORef d1) newDesc` — a descriptor-only write that does **not**
touch the weight. Under `PointCell` the whole cell is rewritten, so it must keep the
*existing* weight, not the summed one:

```elm
                                                            if point1 == point2 then
                                                                IORef.writePointCell ref1 (IO.Root weight1 newDesc)
```

Writing `newWeight` here would silently double the weight of a self-union and change the
union-by-weight tree shape — which would surface as a G2 output diff, but debug it from
here rather than from the diff.

**P1.4 — the two safety preconditions, both verified against the tree now.**

*(a) No descriptor ref is ever shared between two points.* `IO.Info` is constructed in
exactly one place (`UnionFind.elm:52`) with the point's own fresh refs, and
`IO.Info`/`IO.Link` appear outside `UnionFind.elm` only as *patterns*
(`SolverSnapshot.elm:41`) or type mentions (Solve.elm:102,134; SolverSnapshot.elm:31,36;
IO.elm:124). **Re-run this grep before editing:**
`cd /work/compiler/src && grep -rn 'IO\.Info\|IO\.Link\|PointInfo' --include=*.elm .`

*(b) Nothing reads a NON-root descriptor slot by index.* This is the precondition that
actually matters, because merging destroys the orphaned slot. Under the old code a
`union` leaves the loser's descriptor slot holding a stale descriptor, unreachable
through the link chain; under the new code the `Chain` write overwrites it. Verified: the
only by-index reads of `state.descriptors` outside `UnionFind`/`Data.IORef` are
`SolverRoots.lookupContent` (:252-259) and `lookupFlatType` (:264-279), and **every**
call site feeds them a `rootIdx` that was just produced by
`SolverSnapshot.resolveVariable` — `rootedVarOf` :69-70 → `superOfRoot` :47-53, and
`walkTypeForBinders` :144-148 → :156/:166/:174/:201/:220. So the stale slots are already
unobservable today, and destroying them is behaviour-preserving.

*(c) Corollary that makes the merge type-check at all:* `lookupContent` indexes
`state.descriptors` with the **Point index** (`IO.Pt rootIdx`), not with a separate
descriptor ref. That in-tree code is therefore already relying on the index
synchronisation this plan makes explicit — further evidence for the merge, and the
reason `lookupContent`'s rewrite (§P1.5) is a one-constructor change.

**P1.5 — snapshot consumers (complete list, grep-verified).**
- `Compiler/Type/Solve.elm:100-104` (result type) and `:132-136` (construction):
  `solverState : { cells : Array IO.PointCell }`, built as
  `{ cells = s.ioRefsPoint }`.
- `Compiler/Type/SolverSnapshot.elm:29-33` `SolverState` → `{ cells : Array IO.PointCell }`;
  `resolveVariableHelp` :36-46 matches `Just (IO.Chain parent)`.
- `Compiler/Type/SolverRoots.elm:252-259` `lookupContent` (today:
  `case Array.get rootIdx state.descriptors of Just props -> Just props.content`):
  ```elm
  lookupContent state rootIdx =
      case Array.get rootIdx state.cells of
          Just (IO.Root _ props) -> Just props.content
          _ -> Nothing
  ```
  The `_ -> Nothing` arm now also catches `Chain`, which the old code could not
  distinguish from a root — behaviour-identical given P1.4(b), and a *stricter* failure
  mode if that precondition were ever broken (returns `Nothing` instead of a stale
  descriptor). `SolverRoots` otherwise only calls `SolverSnapshot.resolveVariable`
  (:70,:83,:95,:129,:145,:274); `lookupFlatType` :264-279 needs no edit (it goes through
  `lookupContent`). The import at `:23`
  (`import Compiler.Type.SolverSnapshot as SolverSnapshot exposing (SolverState)`) is
  unchanged.
- `Compiler/MonoSolver/Engine.elm:921-924` empty IO state.
- `Compiler/Compile.elm:322-349` passes `solverState` through opaquely — no edit expected;
  confirm after the type changes.

**P1.6 — tests carrying the record type** (mechanical, same rename; each occurrence is a
3-field `{ descriptors, pointInfo, weights }` record type that becomes `{ cells }`).
Grep-verified complete: `grep -rln 'solverState' /work/compiler/tests` returns exactly
these **five** files.
- `tests/TestLogic/TestPipeline.elm:100`, `:114`, `:505` — one-line inline record types.
  (`:219`, `:225`, `:238`, `:253`, `:520` merely thread the value through and need
  **no** edit.)
- `tests/TestLogic/Type/AnnotationEnforcement.elm:120-124`
- `tests/TestLogic/Type/UnificationErrors.elm:149-153`
- `tests/TestLogic/Type/Constrain/TypedErasedCheckingParity.elm:881-885`
- `tests/Type/Constrain/Shared.elm:139-143`

**Per-phase acceptance (lane A):** G1b (`elm-tests`) green; G1 (`--target full`) green;
G2 (output byte-identity on fixed input) IDENTICAL; G3 (new self-hosting fixed point)
reached; G4 (heap-validate suite) green at its current count; G6 re-census shows
`push_int` collapsed to the residue (< 1M) and `push_box` ≈ #fresh + tree spill (≈ 32M)
with `total_elems_copied` down ≥ 60%; G7 histogram shape asserted. Each suite run
**once**, teed to a file, then grepped (repo rule).

**P1.7 — Lane B (kernel-internal pre-sizing), only if the census puts ≥30% of pushes on
kernel return addresses *excluding* the `Elm_Kernel_JsArray_push_*` / `_slice_Int`
forwarders (JsArrayExports.cpp:853-860).** Concretely: find the `JsArrayExports.cpp`
function whose frame dominates and convert its push-per-element loop to
`alloc::allocArrayBuilder(n)` + `alloc::arrayPushKind` under an `alloc::BuilderGuard`,
copying the shape already used at :441-442 / :481+:488 / :538+:542:

```cpp
    arr = alloc::allocArrayBuilder(static_cast<size_t>(size));
    alloc::BuilderGuard builderGuard(&arr);   // RAII; ~BuilderGuard() calls clear()
    // … fill via alloc::arrayPushKind(allocator.resolve(arr), value, kind) …
    // optional early publish: builderGuard.clear();
```

(`allocArrayBuilder` HeapHelpers.hpp:1712-1718, `BuilderGuard` :1672-1700 — note the
namespace is `alloc`, not `Elm`, and `clear()` is idempotent and also run by the
destructor. `arrayPushKind` :1828-1842.) HEAP_BUILDER_001/002/003 apply verbatim
(invariants.csv:574-576). S-sized, pure C++, no flag needed beyond the standard gates.
Expected to be a *small* lane — the three existing builders already do this.

**P1.8 — Lane C (capacity slack + in-place append) — BLOCKED, recorded as shape only.**
The layout supports it today (`header.size` capacity, `getObjectSize` by capacity,
scans by length — see Evidence). What is missing is the **aliasing license**: bumping
`dst->length` in place is observable to any other holder of the same `HPointer`.
Two consequences to record and not forget:
- doubling capacity *without* the license buys **nothing** — the next push still copies,
  so the only effect is more bytes memcpy'd on evacuation. Do not ship "growth policy"
  alone.
- the license's home is the overlay-RC design (plans/opt-tier3-rc-runtime.md); the
  borrow-oracle series proved the ~45% pool is dynamic-RC-1-only. Revisit only there.

**P1.9 — Lane D (mutable store for the IO state) — fallback, only if lane A lands and
measures < ~1% wall.** Shape: keep `State` threading but back `ioRefsPoint` with a
kernel-side append-only store mutated in place; the linearity obligation is discharged
dynamically by a generation word (store carries `gen`, every mutation returns
`gen + 1`, reads through a stale handle `crash` under `ECO_STORE_VALIDATE`). L-sized,
needs its own plan; do not start it inside this one.

### Flag & rollback

- **Phase 0 census — env flag `ECO_ARRAY_PUSH_CENSUS`, default OFF.** Kill switch is
  "unset the variable": the hot path is one load of a `false` global plus a
  predicted-not-taken branch, exactly the `ECO_CONS_SITES`/`ECO_CLOSURE_STATS` shape.
  Revert = delete the RuntimeExports.cpp block, the two HeapHelpers.hpp decls, the six
  call sites (four `elm_array_push_*`, `elm_array_slice`, `eco_clone_array`), and
  `benchmarks/array-push-census.sh`. Gate G0 (flag-off *inertness* — output identity plus
  wall neutrality; **not** binary byte-identity, which is impossible for compiled-in
  instrumentation) proves the instrumented build is observationally a no-op when unset.
- **Phase 1 lane A — no runtime or emission flag exists or is appropriate.** This is a
  change to the *compiler's own source*, not to what the compiler emits, so the
  Config.elm flag pattern (the `default : EcoConfig` record at
  `compiler/src/Compiler/Eco/Config.elm:292-339` — note the path is
  `Compiler/Eco/Config.elm`; `compiler/src/Compiler/Config.elm` does **not** exist) does
  not apply: there is nothing to switch at compile time and a dual-representation
  union-find would cost more than it saves. **Named rollback = the git tag
  `pre-kernel-opt-02-laneA`**, cut on the parent commit before landing; rollback is
  `git revert <laneA-sha>` touching the **7 compiler source files + 5 test files**
  listed in §Files touched, followed by a re-bootstrap. Land lane A as a single
  self-contained commit with no unrelated changes so the revert is clean, and keep the
  pre-change `eco-compiler` binary at
  `build/compiler/build-kernel/bin/eco-compiler-prearr` for A/B and emergency use.
- **Phase 1 lane A′ (`Data.Vector.imapM_`)** — separate commit, tag
  `pre-kernel-opt-02-laneAprime`; revert = revert that one hunk. No flag (it deletes a
  provably dead accumulator; there is no behaviour to switch).
- **Phase 1 lane B** — pure C++ in one kernel function; revert = revert the hunk.
  No flag (the builder idiom is already the sanctioned shape).

## Traps & risks

- **Retention-vs-churn conflation:** do not let §7.4's REJECT (retention argument,
  lines 1864-1878) kill this item, and conversely do not smuggle wholesale replacement
  back in under this plan's banner. Scope is copy/alloc deletion only.
- **Only REMOVE allocation; never add fixed overhead to a hot path** (borrow-inf
  perf-tune standing rule; chunks-v1 mandatory backings were +7.6%). Census counters
  must be env-gated and compiled out of the default path.
- **Transform at construction or not at all** (K5 retrofit interning +18.3% REVERTED):
  capacity-slack decisions belong at `allocArray` time, never as later reshaping.
- **CORRECTED ANCHOR — the walker does NOT size `Tag_Array` from `length`.**
  `getObjectSize` uses `header.size` (capacity), AllocatorCommon.hpp:315-325, with an
  explicit comment saying sweep must stride by capacity while mark/copy iterate length.
  The v1 outline's "verify at implementation time" is resolved: **capacity ≠ length is
  already legal and already shipped** (`allocArrayBuilder`). The blocker for lane C is
  aliasing, not layout. Do not re-derive this from the design doc, which implies otherwise.
- **Capacity slack still costs GC bytes:** evacuation `memcpy`s `getObjectSize` bytes
  (size computed at NurserySpace.cpp:1027; the evacuation `std::memcpy(new_obj, obj, size)`
  copies are at :1046, :1118, :1216, :1236 — plus :1734/:1750 on the JIT-ptr path), i.e.
  slack is *copied*, and HEAP_042/043
  contiguous-nursery fail-soft clamps sit in every allocate path. Any future slack work
  must measure evacuated bytes, not just push counts.
- **GC-safety of in-place append:** `copyAndExtendForPush` re-resolves `src` after
  `allocArray` (:722) because allocation moves objects; `elm_array_push_box` roots both
  operands (`StackRootGuard guard(&srcHP, &valHP)`, :779). Any append-in-place path must
  keep that discipline; the kernel GC-root audit idioms apply.
- **Attribution trap:** never tally inside `copyAndExtendForPush` — its return address is
  the `elm_array_push_*` frame. Tally in the exported function.
- **`perf` is not a fallback here:** `/proc/sys/kernel/perf_event_paranoid == 3` with no
  root (re-confirmed 2026-08-10). If a future environment relaxes it, the fallback is
  `perf record --call-graph=dwarf -F 499 -g -o /tmp/push.data -- <binary> …` then
  `perf report -i /tmp/push.data --no-children -S elm_array_push_box -g graph,0.5,caller`
  — but expect DWARF unwinding through JIT/AOT Elm frames to be lossy; the RA tally is
  strictly better here.
- **`Array.set` traffic is invisible to the 2026-08-09 census** (it lowers inline to
  `eco_clone_array`, not an `elm_array_*` symbol). Any claim about "array cost" that
  quotes only the push rows is wrong by construction; this plan's census fixes that.
- **Counter blindness:** the standard alloc counter is inline-alloc-blind (K1-K7); push
  allocations happen in C++ so kernel counters see them, but any census comparing
  push-alloc share against total alloc needs `ECO_INLINE_ALLOC=0`.
- **GC-trigger lottery:** record major-GC counts alongside every wall A/B.
- **Heap-validate cost asymmetry:** the O(n) validate loops (JsArrayExports.cpp:733-738,
  :790-795; RuntimeExports.cpp:4666-4675) make validate-build timings non-representative;
  never time under ECO_HEAP_VALIDATE.
- **Lane A changes the compiler's own binary, so the bootstrap fixed point moves.**
  Byte-identity is asserted on *output for fixed input* (G2), not on the compiler binary;
  the fixed point must be re-established (G3).
- **`--target full` deletes/regenerates `eco-compiler.mlir`** (memory:
  capacity-check-hoisting). Take the census/A-B binaries before running it, or re-derive
  them after.
- **E2E/unit cache race:** never run the census concurrently with a test suite
  (memory: eco-e2e-unit-cache-race).

## Dependencies

- **Unblocked now** — one of the five mutually independent Tier-1 items
  (01, 02, 04, 05, 06). No dependency on the 07 → {03, 08, 11, 12, 13} spine.
- **Lane C blocked** on overlay-RC (plans/opt-tier3-rc-runtime.md) — external.
- **Lane D** would need its own plan (kernel-side mutable store + generation checking).
- **Coordination:** if Phase 0 lands on kernel HOF drivers, lane B overlaps
  array-optimisation.md steps 2-3 (lower `Array.map`/`foldl` to `scf.for` over
  `eco.array.*`) and should be sequenced with kernel-opt-14-elm-source-list-hofs.md
  rather than duplicated. kernel-opt-01 (List cons/construct) shares the
  "builder instead of push-per-element" idiom; keep counter names consistent
  (`[array-census]` here, so a sibling should use `[cons-census]`-style prefixes).

## Expected impact

Honest read: this is the one Tier-1 item in the family that has historically moved wall
(deleted allocations + deleted per-op copy work: inline nursery −9.6%, CAF memoization
−11.7%, $cap-inlining −14.5%, K6 −5.07%), and it deletes real work on a ~95.5M-call path.
Under H1, lane A's predicted deltas per self-compile are:

| Quantity | Before | After (lane A) | Δ |
|---|---|---|---|
| `elm_array_push_int` | 30.6M | ≲ 1M (`GlobalOpt/Staging/UnionFind.elm:179` residue only — it is the sole other `push_int` site, §P1.0) | −97% |
| `elm_array_push_box` | 64.8M | ≈ 32.3M (1 cell push per `fresh` + tree spill + residue) | −50% |
| push calls total | 95.5M | ≈ 33M | **−66%** |
| elements copied by push (est. avg tail ≈ 15.5) | ≈ 1.48G (~11.8 GB) | ≈ 0.51G | **−66%** |
| `Array.set` clones on the `union` path | 3 per union | 2 per union | −33% |
| array reads on the `get` path | 2 | 1 | −50% |
| incidental heap objects: 3 × `IORef` wrapper + 2 `andThen` + 1 `map` closure per `fresh` | ≈ 184M | 0 | −184M objects |

**Caveat on the last row — it is a prediction to verify, not a measured fact.** It assumes
the `IORef` wrapper (`type IORef a = IORef Int`, a single-constructor single-field custom
type) and the three `IO.andThen`/`IO.map` closures in `fresh` (:48-54) all survive to
runtime as heap objects. GlobalOpt inlining may already have removed some of them, and
sum-type-wrapper unboxing is an open Tier-2 item. **Measure it, do not assume it:** take a
true-allocation census of the pre- and post-change binaries with `ECO_INLINE_ALLOC=0` (the
standard counter is inline-alloc-blind, K1-K7) and compare the `Custom`/`Closure` rows —
that is G6. If the delta is materially below 184M, the wall case rests on the copy
deletion alone.

Lane A′ (`Data.Vector.imapM_`) is measured and reported **separately** — it is a different
commit and a different driver; never present a combined wall number.

If it *does* hold up, the incidental-objects row is the one most likely to move wall:
`Custom` is 38.6% and `Closure` 22.1% of true allocation (6.52B objects), so ~184M
deleted objects would be ≈ 2.8% of all allocation *plus* the ~1G deleted element copies.
Both are "deleted per-op work + reduced churn",
not metadata — the family that has moved, unlike the four consecutive
statepoint/metadata-only changes that measured wall-FLAT.

Calibration, stated up front so the result is judged honestly: expect **low single-digit
% wall**, not double digits. `Tag_Array` is 0.1-0.2% of *promotion*, so this is a nursery
churn win, and nursery churn wins have been worth −5% (K6) when they also cut retained
objects and ~0% when they only cut counts. If lane A measures FLAT with the census
confirming the −66%, that is a publishable negative result for the "allocation-count-only
does not move wall" ledger — record it and stop, do not escalate to lane D on hope.

If Phase 0 refutes H1: the fallback outcomes are (i) a concentrated kernel driver →
lane B, S-sized; (ii) diffuse tiny-leaf pushes → NO-GO at Phase 0, buying a definitive
census that closes the last unattributed Tier-1 row, the first-ever measurement of
`Array.set`/`eco_clone_array` traffic, and a reopen-condition record for §7.4. Either
outcome is worth the S-sized Phase 0.

## Gates

- **G0 (Phase 0) — flag-off inertness.** ⚠️ *Not* binary byte-identity: unlike the
  backend-injected census of plans/kernel-call-census.md §C1.3, this patch compiles new
  code into `EcoRuntimeStatic`/`ElmKernel_*`, so the linked binary **must** differ. The
  achievable, and correct, gate is that the instrumentation is *observationally inert*
  when the variable is unset — exactly the standing of the already-shipping
  `ECO_CONS_SITES` / `ECO_DISPATCH_STATS` counters:
  1. **Output identity.** Run the §P0.4 Stage-7a workload twice, once with the pristine
     `/tmp/eco-compiler-prepatch` and once with `$S/eco-compiler-census` and
     `ECO_ARRAY_PUSH_CENSUS` **unset**, each in its own cold scratch dir, serially; then
     `cmp` the two `.mlir` outputs — must be IDENTICAL, and the census log must be empty.
  2. **Wall neutrality.** Flag-off wall of the census binary within run-to-run noise of
     the pristine binary (one run each, cold, major-GC counts recorded — G5 protocol).
     The hot-path cost is one load of a `false` global plus a predicted-not-taken branch.
  Never compare a flag-ON run's wall against anything.
- **G1 — full E2E:** `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`,
  then `grep -E "FAILED|Failed|failures|Falsifiable" /tmp/test_output.txt | head -40` and
  `tail -20 /tmp/test_output.txt`. Never `check` (stale .mlir). Run ONCE; grep the file
  for anything else.
- **G1b — front-end suite:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/elm_tests.txt`
  (lane A touches type-checker internals; this is where union-find regressions surface first).
- **G2 (lane A / lane A′) — semantic byte-identity on fixed input.** The compiler's
  *output* must not change. Record `BASE=$(git rev-parse HEAD)` **before** starting the
  change (do not assume `HEAD~1` — lane A′, docs commits and fixups all move it), check
  the pristine source out to a worktree, and compile that one fixed tree with both
  binaries from **separate cold scratch dirs**, serially:
  ```bash
  BASE=<sha recorded before the change>
  git worktree add /tmp/pre-arr "$BASE"
  for B in eco-compiler-prearr eco-compiler; do
    D=/tmp/g2-$B; rm -rf "$D"; mkdir -p "$D"            # no eco-stuff => cold each time
    cp /work/build/compiler/build-kernel/elm.json /work/build/compiler/build-kernel/heap-config.json "$D"/
    ( cd "$D" && /work/build/compiler/build-kernel/bin/$B make --optimize \
        --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=/tmp/out-$B.mlir /tmp/pre-arr/compiler/src/Terminal/Main.elm )
  done
  cmp /tmp/out-eco-compiler-prearr.mlir /tmp/out-eco-compiler.mlir && echo IDENTICAL
  ```
  Run the two compiles **serially** — they share `/work/eco-kernel-cpp/typed-artifacts.dat`
  (memory: eco-e2e-unit-cache-race), and a concurrent run corrupts it.
  A difference means the union-find merge changed variable numbering or descriptor
  behaviour — stop and debug; the merge is designed to preserve point ids exactly (§P1).
- **G3 (lane A) — self-host to a NEW fixed point.** The compiler's own source changed, so
  the old fixed point is legitimately invalidated. Required: stage N and stage N+1 of the
  new compiler are byte-identical to each other (self-reproducing), and stage 7a completes
  clean. Say so explicitly in the commit message.
- **G4 — heap-validate suite green at its current count** (1632/1632 as of 2026-08-09):
  `cmake --build build-val --target full 2>&1 | tee /tmp/validate_output.txt`
  (`build-val` is the configured `ECO_HEAP_VALIDATE:BOOL=ON` tree, CMakeCache.txt:327),
  then `grep -cE "^ok |PASS" /tmp/validate_output.txt` and
  `grep -E "FAILED|abort|ARRAY KIND-MISMATCH" /tmp/validate_output.txt`. Array-heavy tests
  included.
- **G5 — wall A/B on Stage 7a with major-GC counts recorded** (trigger lottery):
  `/usr/bin/time -v` on the pre- and post-change binaries over the §P0.4 workload,
  uninstrumented, cold `eco-stuff`, one run each, GC major counts from the runtime's GC
  stats line recorded next to each wall. Never quote a census-instrumented run's time.
- **G6 — item-specific: re-run the Phase 0 census post-change.** Primary metric is
  **total elements copied per self-compile** (`total_elems_copied`), not call count; also
  report per-engine `elm_array_push_*` counts and `clone_set`. True-alloc delta measured
  with `ECO_INLINE_ALLOC=0`.
- **G7 — if lane A/B ships: assert the histogram, not just the totals.** `push_int` must
  collapse to the residue and `b17_32` mass must fall proportionally; a flat histogram
  with lower call counts means the copy work moved rather than disappeared.

## Results

*(Phase 0 output goes here: the `[array-census] engine=` table, the symbolized top-30,
the H1 verdict, and the selected branch from §P0.5.)*
