# Wide heap objects: tail kind words for Custom, Record and Closure

**Status:** READY FOR IMPLEMENTATION (draft 5, consolidated, 2026-10-05).
**Progress:** Phase 0 DONE (2026-10-05; see the phase-0 file for the recorded baselines and pin results).
Phase 1 DONE (2026-10-05; gate results in the phase-1 file §7.1).

**Scheme (user choice):** layout C, *tail kind words*, for Custom, Record and Closure, plus fixes for
every known boxing/unboxing bug.

**User decisions:**
- **D1:** widen the closure header to `n_values:11 | max_values:11 | result_kind:2 | kinds:40`, so
  stage arity is ≤ 2047. Record ≤ 2047 fields and Custom ≤ 2040, so every record or constructor is
  usable as a function value.
- **D2:** fix `eco.make.closure` (do not delete it).
- **D3:** closure `header.size` counts allocated value slots + tail kind words (physical size). The
  tail kind words are the last K words.
- **D4:** evaluators with stage arity > `SAT_MAX_ARITY` get an empty `sat[]`, because the sat guard
  makes it unreadable.
- **D5:** every user-facing limit (stage arity, captured variables, ctor fields, record fields) is a
  source-located compile error. They share one error constructor, `TooLarge`, which Phase 2 builds
  for arity and Phase 3D extends to fields (§S.9).

**Implementation files.** Each has numbered steps, code sketches, pins, commands, expected-failure
lists, rollback, a checklist and a gate:

| Phase | File | Content |
|---|---|---|
| 0 | [`wide-object-tail-kind-words-phase-0.md`](wide-object-tail-kind-words-phase-0.md) | baselines, censuses, harness stack fix, every fail-first pin |
| 1 | [`wide-object-tail-kind-words-phase-1.md`](wide-object-tail-kind-words-phase-1.md) | correctness fixes under today's layout |
| 2 | [`wide-object-tail-kind-words-phase-2.md`](wide-object-tail-kind-words-phase-2.md) | closures end to end |
| 3 | [`wide-object-tail-kind-words-phase-3.md`](wide-object-tail-kind-words-phase-3.md) | Custom/Record: 3A runtime layout, 3B lowering + dialect, 3C front end, 3D caps / attribute removal / invariants / final gate / definition of done |

This overview holds the design (§1–§3), the shared definitions every phase file uses (§S), the
phase map (§4) and the cross-cutting procedures (§5–§8). Shared helpers, limits and commands are
defined only in §S; the phase files refer to them.

**Byte-identical output:** no. Kind attributes change form. The bootstrap fixed point (B==C) must
hold at every gate that has it.

---

## S. Shared definitions (binding for every phase file)

The phase files (`wide-object-tail-kind-words-phase-N.md`, N = 0..3) use **these names and
signatures**. A phase file may add private helpers; it must not rename these.

### S.1 Runtime helpers (`runtime/src/allocator/Heap.hpp`, after `pointerMaskFromKindBitmap`)

```cpp
// Introduced in Phase 1 (values for CLOSURE_HDR_SLOTS change in Phase 2).
constexpr u32 CUSTOM_HDR_SLOTS   = 24;    // Custom::unboxed:48
constexpr u32 RECORD_HDR_SLOTS   = 32;    // Record::unboxed:64
constexpr u32 CLOSURE_HDR_SLOTS  = 25;    // Phase 1: Closure::unboxed:50. Phase 2: 20 (unboxed:40)
constexpr u32 SLOTS_PER_EXT_WORD = 32;
constexpr u32 CUSTOM_MAX_FIELDS  = 2040;  // enforced from Phase 3A (runtime) / 3D (verifier)
constexpr u32 RECORD_MAX_FIELDS  = 2047;  // = CLOSURE_MAX_ARITY: a record-alias ctor is a function of field-count arity
constexpr u32 CLOSURE_MAX_ARITY  = 2047;  // Phase 2; 63 before
constexpr u32 SAT_MAX_ARITY      = CLOSURE_HDR_SLOTS;  // Phase 2: the ONE constant used by the EcoBackend sat guard
                                          // and every descriptor emitter; sat[] is empty above it (D4)

constexpr u32 extWords(u32 n, u32 hdrSlots) {
    return n > hdrSlots ? (n - hdrSlots + SLOTS_PER_EXT_WORD - 1) / SLOTS_PER_EXT_WORD : 0;
}
// Kind of slot i (< 32) within one 64-bit kind word. The ONLY shift on kind words.
inline u32 kindInWord(u64 word, u32 i) { assert(i < 32); return u32(word >> (2 * i)) & 3u; }

// Custom/Record: K lives in header.unboxed (Phase 3A). Phase 1 versions return 0 (boxed)
// for i >= HDR (D semantics); Phase 3A adds the ext-word branch, bounded by header.unboxed.
inline u32 customSlotKind(const Custom* c, u32 i);
inline u32 recordSlotKind(const Record* r, u32 i);
inline const u64* customExtWords(const Custom* c) { return reinterpret_cast<const u64*>(&c->values[c->header.size]); }
inline const u64* recordExtWords(const Record* r) { return reinterpret_cast<const u64*>(&r->values[r->header.size]); }

// Closure kinds: a snapshot for every loop that can allocate (the closure may move), and the
// direct accessor closureSlotKind only where nothing can allocate between read and use.
struct ClosureKinds {
    u64 hdr;        // inline kinds (Phase 1: 50 bits/25 slots; Phase 2: 40 bits/20 slots)
    u32 max;        // max_values
    u32 k;          // number of ext words copied into ext[] (Phase 1: always 0)
    u64 ext[64];    // Phase 2: extWords(max, CLOSURE_HDR_SLOTS) <= 64
};
inline void snapshotClosureKinds(const Closure* cl, ClosureKinds& out);
inline u32 closureKindAt(const ClosureKinds& ks, u32 slot);   // boxed (0) past the known kinds
// Direct accessor: ONLY where nothing can allocate between the read and its use (GC walkers, validate).
inline u32 closureSlotKind(const Closure* cl, u32 slot);
// snapshotClosureKinds copies only the k ext words that exist.
// Phase 2 (physical size rule): ext words are the LAST k words of the object.
inline const u64* closureExtWords(const Closure* cl) {
    return reinterpret_cast<const u64*>(&cl->values[cl->header.size - extWords(cl->max_values, CLOSURE_HDR_SLOTS)]);
}
```

### S.2 Runtime root helper (`runtime/src/allocator/RuntimeExports.h`; a template, so defined in the header)

```cpp
// Push GC roots for a buffer of n slots whose kinds come from kindOf(i); chunks of 64 because
// eco_gc_push_stack_range asserts count <= 64 and takes a u64 mask.
template <class KindOf>
inline void pushRootsByKinds(uint64_t* base, uint32_t n, KindOf kindOf) {
    for (uint32_t off = 0; off < n; off += 64) {
        uint32_t c = std::min<uint32_t>(64, n - off);
        uint64_t mask = 0;
        for (uint32_t i = 0; i < c; ++i) if (kindOf(off + i) == 0) mask |= uint64_t{1} << i;
        if (mask) eco_gc_push_stack_range(base + off, c, mask);
    }
}
```

### S.3 Codegen helpers (`runtime/src/codegen/Passes/EcoToLLVMInternal.h`)

```cpp
uint8_t slotKindOf(mlir::Type t);    // i64->1, f64->2, i16->3, everything else ->0
struct PackedKinds { uint64_t hdrBits; llvm::SmallVector<uint64_t, 2> ext; };
PackedKinds packKinds(llvm::ArrayRef<uint8_t> kinds, unsigned hdrSlots);   // hdr slots inline, rest 32/word
uint64_t packClosureWord(uint32_t nValues, uint32_t maxValues, uint8_t resultKind, uint64_t hdrBits);
          // Phase 1: n:6|max:6|rk:2|kinds:50 ; Phase 2: n:11|max:11|rk:2|kinds:40
// EcoToLLVMClosures.cpp (replaces deriveAllParamKindsBitmap in Phase 2; Phase 1 makes the old one UB-free):
static llvm::SmallVector<uint8_t> deriveAllParamKinds(const EcoRuntime&, llvm::StringRef funcSymbol, int64_t arity);
```

### S.4 New runtime entry points (Phase 2)

```cpp
extern "C" HPtr eco_pap_extend_l(HPtr closure, uint64_t* args, uint32_t num_newargs,
                                 const EvalParamLayout* caller_layout);   // replaces eco_pap_extend
extern "C" void eco_alloc_closure_group_l(/* exact 13-parameter signature: phase-2 step 2.6 */); // replaces eco_alloc_closure_group_slow
```

### S.5 Dialect attribute `slot_kinds` and its lifetime

- **Form:** `slot_kinds : DenseI8ArrayAttr`, one entry per slot, values 0..3.
  - papCreate: one entry per capture.
  - papExtend: one entry per newarg.
  - construct.custom / construct.record: one entry per field.
  - papCreateGroup: one `DenseI8ArrayAttr` per sibling, in an `ArrayAttr`.
- **Front end:** `ArrayAttr (Just I8) [ IntAttr Nothing k, … ]`, encoded as a dense array by
  `Mlir/Bytecode/AttrType.elm`. Phase-2 step 2.0 fixes that encoder's element width first.
- **Lifetime:**
  - **Introduced** in Phase 2 for the closure ops and in Phase 3B for construct.custom,
    construct.record and to_heap.
  - **Before Phase 3D:** `slot_kinds` is **optional**. When it is absent, kinds are derived from the
    operand types. A present old bitmap (`unboxed_bitmap`, `newargs_unboxed_bitmap`,
    `unboxed_bitmaps`) is verified, via `hasAttr`, for the slots it can describe. Phase 2 makes
    papCreateGroup's `unboxed_bitmaps` optional; Phase 3B makes construct.record's `unboxed_bitmap`
    optional.
  - **Phase 3D:** `slot_kinds` becomes required, except on `to_heap`, where it stays optional and
    normally derived. Leftover old attributes are rejected and the fixtures are swept.

### S.6 Test-only "wide objects allowed" switch

- **Runtime:** `inline bool Elm::testing::allow_wide_objects = false;` in `Heap.hpp`.
  - Added in Phase 1.
  - Builders' and validate checks' "compiled objects are narrow" asserts skip while it is true.
- **Dialect:** the **module attribute** `eco.allow_wide_objects`, added in Phase 3B.
  - It lifts the Custom/Record verifier caps for `test/codegen` fixtures.
  - It is a module attribute, not a command-line option, because JIT fixtures run in-process through
    `EcoRunner`, where no command line is parsed.
  - `EcoRunner` sets `Elm::testing::allow_wide_objects = true` while it runs a module that carries
    the attribute, then restores the previous value.
- **Removal:** Phase 3D removes both, together with the `wideObjectsAllowed` helper.

### S.7 Canonical commands (CLAUDE.md: each test command ONCE, tee'd, then grep the file)

```bash
# elm front-end tests
cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt
# full E2E (+ unit + codegen fixtures in build/test/test); cache wipe first (§6.3)
rm -rf /work/build/test/*/eco-stuff
find ~/.eco/0.1.3/packages \( -name artifacts.dat -o -name typed-artifacts.dat \) -delete
rm -rf ~/.eco/0.1.3/packages/eco/kernel
ulimit -c 0; cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
# unit/fixture subset without rebuilding Elm (only when no Elm/MLIR change)
cmake --build build --target test && ulimit -c 0 && build/test/test --filter "<pattern>" 2>&1 | tee /tmp/test_output.txt
# validate tree (recreate if absent)
cmake -S /work -B /work/build-validate -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DECO_HEAP_VALIDATE=ON
cmake --build /work/build-validate --target test && ulimit -c 0 && /work/build-validate/test/test --filter "<pattern>" 2>&1 | tee /tmp/test_output_validate.txt
# other gates
cmake --build build --target register-guards 2>&1 | tee /tmp/test_output_rg.txt
cmake --build build --target tla-canary 2>&1 | tee /tmp/test_output_tla.txt   # strict: -DECO_TLA_CANARY_STRICT=ON
cmake --build build --target run-aot-e2e 2>&1 | tee /tmp/test_output_aot.txt   # move build/test/aot-e2e/*/eco-stuff aside first
cmake --build build --target bootstrap 2>&1 | tee /tmp/test_output_boot.txt && cmake --build build --target eco-verify 2>&1 | tee -a /tmp/test_output_boot.txt
```

### S.8 How to add tests

- **E2E:** drop `test/elm/src/<Name>.elm` with `-- CHECK:` lines (the harness discovers it). The
  harness has no expected-compile-error mode, so compile-error pins are elm-tests.
  GC-forcing variants that need `Eco.GC.majorGC` go in `test/eco-kernel/src/`.
- **Codegen fixtures:** `test/codegen/<name>.mlir` with `// RUN: %ecoc %s -emit=… | %FileCheck %s`;
  negative fixtures check the error text; `// XFAIL:` is supported there only.
- **Unit tests:** a `static void test_x()` plus `suite.add(Testing::TestCase("name", test_x))` in a
  `test/allocator/*Test.cpp`. A new file needs a `register…Tests` in `test/main.cpp` and an entry
  in `test/CMakeLists.txt` (as `GenericApplyBoxingTest.cpp`).
- **Death tests:** use the `fork()` + `waitpid` pattern of `test/allocator/ParallelMinorTest.cpp:440`.
- **elm-test:** add `Test.test` cases to the existing `compiler/tests/TestLogic/Generate/CodeGen/*Test.elm`.


### S.9 Front-end limit diagnostics (D5; built in Phase 2, extended in Phase 3D)

Every limit a user can hit is a **source-located compile error**, reported like any other
canonicalization error: the region is underlined in a code snippet and the build exits non-zero.
- **Constants:** a new leaf module `compiler/src/Compiler/Data/HeapLimits.elm` mirrors `Heap.hpp`
  (§S.1).
  - Phase 2 adds `maxStageArity = 2047` (`CLOSURE_MAX_ARITY`).
  - Phase 3D adds `maxCtorFields = 2040` and `maxRecordFields = 2047`.
  - It is the only place these numbers appear in Elm; `Types.elm` and the generator import it.
- **One error constructor** in `compiler/src/Compiler/Reporting/Error/Canonicalize.elm`, beside its
  precedent `TupleLargerThanThree`:
  ```elm
  | TooLarge A.Region TooLargeWhat Int Int        -- region, what, actual, limit

  type TooLargeWhat
      = TooManyParams Name                 -- Phase 2: top-level or let-defined function
      | TooManyLambdaParams                -- Phase 2: \a1 … an ->
      | TooManyClosureSlots (Maybe Name)   -- Phase 2: params + captured locals of a lambda / local function
      | TooManyCtorFields Name             -- Phase 3D
      | TooManyRecordFields (Maybe Name)   -- Phase 3D: alias name, or Nothing for a literal / annotation
  ```
- **Report titles:** `TOO MANY PARAMETERS`, `TOO MANY CAPTURED VARIABLES` and `TOO MANY FIELDS`.
  Each body reads: "`<what>` has <n> <parameters|parameters and captured variables|fields>, but
  Eco supports at most <limit> (<HEAP_078|HEAP_019>)", with one line of advice: pass a record,
  split the function, or nest the record.
- **Who emits it:** canonicalization only (`Compiler/Canonicalize/{Module,Expression,Environment/Local}.elm`).
- **Compiler-generated arity** (η-expansion, staging and inlining that rebuild closures) never
  creates a user-visible limit error. Those passes **decline** any rewrite that would exceed
  `maxStageArity`.
- **Monomorphization backstop.** Specialization can multiply one captured polymorphic local
  function into several captured specializations. A post-mono check reports such a closure as a
  **located** `Exit.GenerateMonomorphizationError`: module, function and `line:col` from the
  closure's region. The MLIR generator's own check is an internal-compiler-error assert, never the
  user-facing path.

## 1. What is broken today (evidence)

Programs were compiled with `node compiler/bin/index.js make <file> --output=X.mlir --text-mlir`
(from a copy of `build/test/elm/elm.json`) and lowered with
`build/runtime/src/codegen/eco-boot-native X.mlir -o X.elf`.

| # | Program (scratch source) | Today | Expected |
|---|---|---|---|
| E1 | `test/elm/src/WideCtorField24Test.elm`: 27-field ctor | verifier: `size (27) exceeds Custom's 24-slot limit` (`EcoOps.cpp` CustomConstructOp::verify) | CHECK values |
| E2 | record with 33 fields (`RecA`, `RecC`) | verifier: `field_count (33) exceeds Record's 32-slot GC scan limit` | values |
| E3 | 28-Int record destructured `viaPat { f27, f25 } = f27*1000 + f25` (`RecB`) | **silently wrong**: `1120986464801025`. `.f27` and record update are correct | `1028025` |
| E4 | arity-28 `big`, 20 args, then 7 inside `step7`, then 1 (`rv/proj/src/Pap27b.elm`) | **silently wrong**: `[90799903730678, 90799903725370]`. `eco_pap_extend` boxes the newargs at slots 25 and 26 (their kind is truncated to boxed), and the typed consumer reads them raw | `[23702, 40502]` |
| E5 | 26 or 27 typed args at once to an arity-27/28 function (`CloP26I`, `CloP27I`) | verifier: `newargs_unboxed_bitmap exceeds 50-bit capacity`. With the bitmap fixed it would hit the count cap (E6) | values |
| E6 | 27 `String` args at once (`CloP27S`) | verifier: `newargs count (27) exceeds 25-slot limit` | values |
| E7 | lambda capturing 27 `String` params passed to `List.map` (`rv/proj/src/CapL27.elm`) | verifier: `num_captured (27) exceeds 25-slot limit` | values |
| E8 | **record alias of 26 Ints built with the decoder pattern** `Just R \|> andMap (Just x) …` (`AndMap26`); also 30 fields (`AndMap30`) | **silently wrong**: `r.f25` prints `1120986475384` (f24 correct). The record constructor's closure has arity 26; its param kind 25 is truncated (B5) | `[25, 26]` … |
| E9 | the same with 70 fields (`AndMap70`) | verifier: `papCreate arity (70) exceeds 6-bit max_values limit (63)`, plus the record cap | values: the arity part is fixed in Phase 2 (2047, §2.3), the record cap in Phase 3D |

| E10 | the compiler's own `InlineConfig` (27 fields) built by `inlineDecoder` (`Compiler/Eco/Config.elm:649`) | latent E8 instance: param 25 `kernelCostHof : Int` is truncated; it only runs with an `eco-config.json` `"inline"` key | correct config values; the Phase 2 gate runs one self-compile with such a config |

**E8 is the important one.** `Decode.succeed Model |> required …` / `andMap` over a record of 26 or
more fields with a primitive field at declaration position ≥ 25 is an everyday Elm idiom, and today it
returns pointer bits silently.


**GC side.** Every Custom/Record walker stops at `i < 24` / `i < 32` (e.g. `HeapChildWalk.hpp`
visitHeapChildren, `NurseryChildWalk.hpp` forEachChildSlot), so a boxed slot past the cap is never
traced. Only the verifier caps keep such objects out of compiled code.

## 2. Layout C

### 2.1 The layout

```
Custom : [Header][ctor:16 | kinds 0..23 :48]                [values[0..size)][ext[0..K)]       K in Header.unboxed
Record : [Header][kinds 0..31 :64]                          [values[0..size)][ext[0..K)]       K in Header.unboxed
Closure: [Header][n:11|max:11|rk:2|kinds 0..19 :40][evaluator][values[0..size-K)][ext[0..K)]   K = extWords(max_values, 20)
ext[j] bits [2i,2i+1] = kind of slot  HDR + 32*j + i            (HDR = 24 / 32 / 20)
```

- **Values:** field/capture/param `k` stays at `values[k]`. Every projection and every `values + k`
  offset is unchanged.
- **K's value:** `extWords(n, HDR) = n > HDR ? (n - HDR + 31) / 32 : 0`.

**Custom/Record.**
- `n = header.size`, the field count.
- K (≤ 63) is stored in `Header.unboxed` (6 bits), so
  `getObjectSize = 16 + 8*(hdr->size + hdr->unboxed)`, with no branch.

**Closure (user decision 1, see §2.3).**
- **New packed word:** `n_values:11 | max_values:11 | result_kind:2 | unboxed:40`. That is 20 inline
  slot kinds and a stage arity up to **2047**.
- **K:** `extWords(max_values, 20)`, up to **64**, which does not fit the 6-bit `Header.unboxed`.
- **Why max_values and not slots allocated:** a closure's kinds cover **every** stage param, captured
  or not. `eco_pap_extend` needs the kinds of not-yet-supplied params to convert new args, and copies
  them to the extended closure. So K must follow `max_values`, not the slots an object allocates.
- **Rule: `Closure.header.size` counts physical words after the evaluator**, i.e.
  `allocated value slots + K`. The ext words are the **last K words**:
  `ext = &values[hdr->size - K]`.
  - **Why this deviates from the "derive K in `getObjectSize` from the packed word" proposal.**
    Sizing must stay a function of the 8-byte header word alone:
    - the parallel minor copier sizes a claimed object from its pre-claim header word only
      (`NurseryParallel.cpp` copyClaimed: "never getObjectSize(obj): it reads BUSY"; the region
      copier `copyClaimedR` likewise; both are in M3 / W5 regions);
    - sweep slices step over young YLOS cells concurrently (CR-019, `loadHeaderRelaxed`);
    - `getObjectSizeFromHeader(const Header*)` is the API.

    Reading the packed word at +8 would change those modelled protocols.
  - With the physical-size rule, `getObjectSize` for `Tag_Closure` stays `24 + 8*hdr->size`,
    unchanged.
  - `initHeaderForTag`'s byte-derived size (`(bytes - sizeof(Closure))/8`) becomes exactly right
    with no change, including YLOS (`allocateYoungLarge`) and the call paths.
  - Only kind readers need K: they compute it from `max_values`, read from the same snapshot as the
    kinds.
  - `Header.unboxed` stays 0 for closures.
- **The anchor under this rule** (re-verified per allocator, each now allocating `S + K(max_values)`
  words):

  | Allocator | Value slots S |
  |---|---|
  | papCreate | `arity` (= `max_values`) |
  | `eco_alloc_closure_k` / `allocClosureK` | `max_values` |
  | groups | `arities[i]` |
  | `eco_pap_extend` | `new_n_values` (≤ `max_values`) |
  | `eco_intern_closure0` | `arity` (only arity ≤ 20, §2.2) |

  Every object satisfies `n_values ≤ S = hdr->size - K`. Walkers scan `i < n_values` and never
  touch ext words; validate builds assert `hdr->size >= n_values + K(max_values)`.
- **Asymmetry, accepted:** Custom/Record keep `header.size` as the logical field count. Equality,
  printers and the field-count compare use it, and their K fits the header.

**All tags.**
- **Always written.** `zeroNewObject` (`ThreadLocalHeap.hpp`) clears only the 8-byte header in
  production builds (W1 per-site zeroing; the rest is stale, or 0xD8 poison in validate builds).
  - Every allocation entry and every codegen path stores **all K ext words explicitly**, all-zero
    words included.
  - Validate builds check K (Custom/Record: `hdr->unboxed == extWords(size, CAP)`; Closure:
    `hdr->size >= n_values + K`) and that no ext word has bits past its last slot.
- **Bounded readers (Custom/Record):** readers take K from `hdr->unboxed` and never recompute it.
  A slot ≥ CAP with `j >= hdr->unboxed` reads as boxed. This lets the Custom/Record runtime land
  before their codegen (Phase 3A before 3B).
- **Limits:**

  | Kind | Limit | Note |
  |---|---|---|
  | Closure stage arity | **2047** | 11-bit `n_values` / `max_values`; K ≤ 64 |
  | Record | **2047** fields | 32 + 63·32 = 2048 would fit K, but the record-alias constructor has arity = field count, so 2047 keeps **every record usable as a function value** (decoder pattern) |
  | Custom | **2040** fields | 24 + 63·32; already ≤ 2047, so every ctor is usable as a function value |

  Every runtime allocation entry aborts **in release builds** past these limits. A 6-bit K or an
  11-bit arity would otherwise wrap; these are slow paths.
- **Size and placement:**
  - Inline allocation (HEAP_034) stays limited to `sizeof(T) + 8(n+K) ≤ 4096` (`sizeof` = 16 for
    Custom/Record, 24 for Closure). Wider sites take the `eco_alloc_*` call path.
  - Objects ≥ `LARGE_OBJECT_THRESHOLD` (8 KiB: about 1000 fields, or a closure of arity about 1000)
    go through `placeLarge`: nursery-large or YLOS (HEAP_062).
  - They are still **young**, so "codegen stores ext words after the call, before any safepoint"
    stays safe with respect to the concurrent marker.
  - A `static_assert` checks that the maximum byte sizes (Custom 16 + 8·2103, Record 16 + 8·2110,
    Closure 24 + 8·2111) are below the born-old threshold (`GroupLargeObjectThreshold`,
    `EcoGCPrepare.cpp`, 32 KiB).

### 2.1.1 `Header.unboxed` is free for these tags (verified by both investigations)

Only Custom/Record use it for K. Closures leave it 0 (§2.1).

- Every read or write of `header.unboxed` in `runtime/src`, `elm-kernel-cpp/src` and
  `eco-kernel-cpp/src` is in a Cons/Tuple2/Tuple3/ElmArray/ListBacking/Task arm.
- The only tag-generic writer is `eco_set_unboxed`'s `default:` (`RuntimeExports.cpp`). Phase 1
  makes it assert the tag.
- The header is preserved by every copy:
  - serial minor (memcpy plus `assertHeaderPreservedAcrossCopy`);
  - parallel `copyClaimed` (pre-claim word; only age and colour are edited);
  - `promoteYoungLarge` (whole-word load, edit, store);
  - CAF permanent copy and compaction (`getObjectSize` bytes);
  - forwarding replaces the header with `Tag_Forward`.
- `unboxed` shares a 32-bit word with `tag`, which every sizing path already reads, so it is not a
  new shared location.
- **YLOS header fix-up:** writing `size` and `unboxed` must be one whole-word store (CR-019's
  `storeHeaderRelaxed` form). A transient state of `size = n, unboxed = 0` would under-size the
  object.

### 2.1.2 Custom `scalar_bytes` / `AllocateCtorOp`

- `hdr->size = field_count + scalar_bytes/8` would put scalar words in the tail loop and break
  `extWords`.
- No producer emits `eco.allocate_ctor` (it appears only in its lowering, `EcoToLLVMHeap.cpp`
  AllocateCtorOpLowering, and in `computeAllocSize`'s arm).
- **Decision:** delete `AllocateCtorOp` and the `scalar_bytes` parameter in Phase 3A (an ABI change, so
  the 3A gate includes bootstrap). Until then,
  assert `hdr->size <= 24` whenever `scalar_bytes != 0`.

### 2.2 Closures, concretely

| Concern | Decision |
|---|---|
| **Packed word** | `n_values:11 \| max_values:11 \| result_kind:2 \| unboxed:40` (`Heap.hpp` Closure). Every writer and reader changes together in Phase 2: the runtime bitfields (recompiled); the codegen packers (papCreate inline, call and interned paths, papCreateGroup, `make.closure`, in `EcoToLLVMClosures.cpp` and `EcoToLLVMValueAgg.cpp`: one shared `packClosureWord` helper); the **sat dispatch guard in `EcoBackend.cpp`**, which reads the raw word with `& 63`, `>> 6`, `>> 12` and `>> 14` (new masks 2047, shifts 11, 22 and 24; the `mx <= 25` guard becomes `mx <= 20`); and `eco_intern_closure0`'s packed argument |
| **Where kinds of params 20..2046 live** | The closure's own ext words (the last K words, §2.1). `EvaluatorDesc.kinds` has no runtime reader (only `desc->kinds = 0` in `RuntimeExports.cpp` and the codegen offset constant). It stays one u64 for params 0..31, advisory, with UB-free packing |
| **`EvaluatorDesc.stage_arity`** | Widens to `u16`, **placed in the existing `_pad0` at +18**. The old `unsigned char` at +16 becomes padding; `result_kind` stays at +17; `sat` stays at +24 (`EvaluatorDescSatOffset` unchanged). `sat[]` is sized `stage_arity + 1` when `stage_arity <= SAT_MAX_ARITY` and is **empty** otherwise. The sat guard (`max_values <= SAT_MAX_ARITY`) makes it unreadable for wide evaluators; phase-2 step 2.6.8 has the reader audit. The `static_assert`s in `Heap.hpp` and `EcoToLLVMInternal.h`'s `EvaluatorDescStageArityOffset` move to 18. Emitters: the two descriptor builders in `EcoToLLVMClosures.cpp` (struct `{ptr, i64, i8, i8, i16, i32, [N x ptr]}`: `put(2, i8, …)` becomes 0 and `put(4, i16, stageArity)`), and the runtime `ecoDescForKernelEvaluator` (`RuntimeExports.cpp`, `desc->stage_arity`). No runtime reader exists today; the sat entries' own `stageArity > 16` reject is unchanged. An arity-2047 descriptor is 24 bytes (empty `sat[]`) |
| **`EvalParamLayout`** | `num_params` is `unsigned char` today. It becomes `{ u16 num_params; u8 result_kind; u8 _pad; u8 kinds[]; }`, so kinds move from +2 to +4. Every hand-built layout changes with it: the codegen `ensureEvalLayoutGlobal` (`{i8, i8, [N x i8]}` becomes `{i16, i8, i8, [N x i8]}`; global names hash long kind vectors); the runtime all-boxed table `kAllBoxedLayoutsHolder` / `getAllBoxedLayout` (sized for 63, and it **silently clamps n to 63**: becomes a small static table for n ≤ 64 plus an interned on-demand cache up to 2047); `sub_buf[2 + 64]` in `eco_apply_closure_eval`; `OneArgLayoutHolder` (`Scheduler.cpp`); and the kernels' static layouts (`JsArrayExports.cpp`, `ParserExports.cpp`, `TimeExports.cpp`, `ListExports.cpp`, `StringExports.cpp`, `BytesExports.cpp`). A `constexpr` builder in `Heap.hpp` replaces the hand-written byte arrays, so the next change cannot miss one |
| **Other u8 or 63-sized arity state** | `RuntimeExports.cpp`: `kMaxClosureArity = 63`; the `max_values > 63` check in `eco_apply_segmentation_unknown`; the `max_values <= 63` asserts in `eco_apply_closure_eval` and `spliceArgsForSaturatedCall`; `conv[63]` in `eco_pap_extend` (becomes a small-vector, inline 64). `combined_args` already heap-allocates above 16. `ClosureMeta` (`ListExports.cpp`) widens. Wrappers and `buildEvaluatorArgs` take kinds from snapshots. The lowering implementation pass greps for `0x3F`, `& 63`, `63` and `unsigned char` arity near closure code and lists each hit |
| **Root ranges over 64 slots** | `eco_gc_push_stack_range` asserts `count <= 64` with a u64 mask. Arg and capture buffers of up to 2047 slots are pushed by a helper `pushRootsByKinds(base, n, kinds)` in ≤ 64-slot chunks. It is used by `eco_pap_extend`, `eco_closure_call_saturated`, `invokeSaturatedTyped`, `eco_apply_*` and the codegen papExtend/papCreateGroup paths (one call per chunk) |
| **Source of kinds** | Two sources. **Captures:** from operand types. **Uncaptured params:** from the target signature (`deriveAllParamKindsBitmap`, which becomes `deriveAllParamKinds`, a vector). The two agree on captures by CLONE_RELATION_001. On the legacy (untyped-wrapper) path the captures are stored raw by operand type, so their kinds come from operand types and the remaining params are boxed |
| **Snapshots, not pointers** | `ClosureKinds { u64 hdr40; u16 max; u16 k; const u64* ext; }`, with the ext words copied into a caller-provided inline buffer (64 words) by one read of the (re-)resolved closure. `eco_pap_extend`, `spliceArgsForSaturatedCall`, `eco_closure_call_saturated`, `invokeSaturatedTyped` and `ClosureMeta` read kinds from the snapshot. Their loops allocate (boxing), so a `Closure*`-dereferencing accessor would read from-space after a GC |
| **`eco_pap_extend` ABI** | A **new entry** `eco_pap_extend_l(closure, args, u32 n, const EvalParamLayout*)`. It allocates `new_n_values + K` words, copies the values and the old closure's ext words (from the snapshot) to the new tail, and converts each new arg from its caller kind to its slot kind. The old u64 entry stays as a shim until every caller has moved, within Phase 2: the lowering's under-saturated papExtend path, `eco_apply_segmentation_unknown`, the `eco_apply_closure_eval` under-saturated branch (both pass `args_layout` through and lose their `assert(num_args <= 32)` bitmap builds), and `test/allocator/GenericApplyBoxingTest.cpp`. The shim is deleted at the end of Phase 2 |
| **`papCreateGroup`** | A new group entry with per-sibling kind vectors and `S + K` sizes. The flat-capture root mask comes from operand types and is pushed in chunks. **Pre-existing bug:** `flatOffset + k >= 64 → break` leaves later boxed captures unrooted in release (B15, fixed in Phase 1) |
| **Kernel closures** | `allocClosureK` / `eco_alloc_closure_k` allocate and **zero** K(max_values) ext words. `closureCapture` **never** writes an ext word: its abort for an idx ≥ 20 (was 25) with a typed kind is permanent. Phase 0 records a census of every `closureCapture` / `allocClosureK` call site with its maximum arity, and all are small |
| **Sat fast path** | Guard `max_values <= 20` (header kinds only). Sat entries are generated only for `stageArity <= 16`. The sat filter's `kindsBitmap >> 2*(stageArity-n)` is computed **before** the `stageArity > 16` reject, so it is UB for arity ≥ 33 (B7): move the reject first |
| **Interning** | `eco_intern_closure0` only when arity ≤ 20 (all kinds inline). Wider zero-capture closures take the normal path (HEAP_033 reworded) |
| **`make.closure` (user decision 2: fix)** | Its packing is **wrong today**: `numCaptured \| arity<<6 \| bitmap<<12` puts slot 0's kind into `result_kind`, writes no `result_kind`, writes capture kinds only, and its verifier cap is 26 (`EcoToLLVMValueAgg.cpp` MakeClosure lowering; `EcoOps.cpp` MakeClosureOp::verify). **Phase 1** routes it through papCreate's packer and `deriveAllParamKinds` (B13, with a pin). **Phase 2** gives it the new packed word, ext words and `S + K` sizing through the shared helpers, and lifts its cap to 2047 |
| **PAPSimplify** | Chain fusion (`EcoPAPSimplify.cpp`, fusion pattern "P2": the fused-extend loop) packs `kind << 2*i` with **no cap**. Release builds don't re-verify after passes. P4 fusion caps at 25 and writes `unboxed_bitmap` onto the cloned papCreate. Phase 2 makes both emit `slot_kinds` (§S.5, §2.4) and cap at 2047, and the verifier runs after PAPSimplify in validate and test builds |
| **Front-end closure attributes** | papCreate captures and papExtend newargs carry `slot_kinds` (§S.5, §2.4) instead of `unboxed_bitmap` / `newargs_unboxed_bitmap`, emitted at `Expr.elm` (papCreate, the six papExtend sites), `Expr.elm:859` (zero-capture papCreate), `Lambdas.elm`, `BytesFusion/Emit.elm` and `Ops.elm` papCreateGroup |

### 2.3 Stage arity: widened to 2047 (user decision 1)

The compiler makes stage arity by itself:
- closure conversion: captures + params;
- η-flattening;
- record-alias and ctor function values: arity = field count. E9 is a 70-field alias through
  `andMap`, which emits `papCreate arity = 70`.

A cap of 63 would have limited records built by decoders to 63 fields. **Rationale for widening
rather than keeping 63 with a limit error (rejected) or staging (rejected: curried wrapper chains):**
it removes the limit where users meet it, and with Record ≤ 2047 and Custom ≤ 2040 every record or
ctor is usable as a function value.

**Cost.**
- Closures with 21–25 params gain one ext word, because the inline kinds drop from 25 to 20 (the
  Phase 0 census measures how many).
- Every closure-word reader and writer changes (§2.2).

**Above 2047** (D5, §S.9):
- **Source constructs:** a function, let-function or lambda with more than 2047 parameters, or a
  lambda / local function whose parameters plus captured locals exceed 2047, is a canonicalization
  error (`TooLarge`) at its region. A record alias or ctor used as a function value is bounded by
  the field limits (Record 2047, Custom 2040), also `TooLarge` (Phase 3D).
- **Compiler-generated flattening:** η-expansion (`GlobalOpt/PreMono/EtaExpand.elm`), staging
  (`raiseStagedSpecs`, `GlobalOpt/Staging/Rewriter.elm`) and every GlobalOpt site that rebuilds a
  closure's captures **declines** a rewrite that would exceed 2047. A user can therefore only meet
  the limit through a construct they wrote.
- **After specialization:** a closure that still exceeds it is reported, located, by the post-mono
  check.

### 2.4 Kind attributes: `slot_kinds` replaces the u64 bitmaps

- Elm `Int` is exact only to 2^53, so the front end cannot emit a 64-bit kind word.
- Removing the attribute outright would lose the **only production check** that construction operand
  types agree with the front end's layout. The verifiers check `attr ⇔ operand types` today, and the
  E3/B1/B2 bug class lives exactly there.
- So each u64 bitmap is replaced by **`slot_kinds : DenseI8ArrayAttr`**, one kind per slot (0–3),
  exact in Elm, which the bytecode encoder already supports (`ArrayAttr (Just t)` →
  `EDenseArrayAttr`).

The ops and attributes involved:

| Op | Old attribute | New attribute |
|---|---|---|
| `eco.construct.custom` | `unboxed_bitmap` (DefaultValued I64) | `slot_kinds` |
| `eco.construct.record` | `unboxed_bitmap` (plain I64) | `slot_kinds` |
| `eco.papCreate` | `unboxed_bitmap` | `slot_kinds` (captures only) |
| `eco.papExtend` | `newargs_unboxed_bitmap` | `slot_kinds` (newargs only) |
| `eco.papCreateGroup` | `unboxed_bitmaps` | `slot_kinds` per sibling (ArrayAttr of dense arrays) |
| `eco.to_heap` | `unboxed_bitmap` (`Ops.td`) | `slot_kinds`, or derived when absent |
| `eco.construct.tuple2/3`, `eco.construct.list` | unchanged | ≤ 3 slots |

Verifier rules for these ops:
- every operand's kind (`i64`→1, `f64`→2, `i16`→3, `!eco.value` or aggregate → 0) must equal
  `slot_kinds[i]`;
- the length must equal the slot count;
- **`i1` operands are rejected** for construct ops. Today they are stored as zext 0/1 in a kind-0
  slot (`emitFreshFieldStore`, `widenFieldToI64`), a latent GC hazard; the front end emits none
  (0 of 953 `.mlir` files under `build/test`). The closure ops already reject `i1`;
- closure ops never accept aggregates;
- the caps (Custom 2040, Record 2047, closure captures ≤ 2046, newargs and stage arity ≤ 2047).

While both forms coexist (Phases 2–5), a present old attribute is verified for the slots it can
describe, using `hasAttr`. `getUnboxedBitmap()` on a DefaultValued attribute returns 0 when absent.

## 3. Known bugs

Each bug gets a fail-first pin (Phase 0) unless marked otherwise. Fix column: the phase/step that fixes it.

| id | Bug | Where (anchor by function) | Fix |
|---|---|---|---|
| B1 | `generateCtor` declares fields at index ≥ 24 `!eco.value` while callers pass `i64` (REP_ABI_001) | `Functions.elm` generateCtor | P1 (phase-1 B1 step carries the code) |
| B2 | Patterns, CustomContainer boxed branch projects a boxed slot to an unboxable target, including **promoted aggregates** (prepareCtorSlots also stores slots ≥ 24 as `!eco.value`) | `Patterns.elm` generateMonoPath, CustomContainer arm | P1 (no `aggOperand == Nothing` guard; code in phase-1 B2 step) |
| B3 | `generateMonoFieldOnHeap` ignores `isUnboxed` in **both** directions (E3), and its missing-field default silently projects field 0 (`Maybe.withDefault { index = 0 … }`; also `Expr.elm` MonoRecordAccess) | `Patterns.elm` generateMonoFieldOnHeap | P1: mirror the Custom arm (box when an unboxed slot meets a `!eco.value` target; project then unbox when a boxed slot meets a primitive target); the default becomes a crash |
| B4 | Closure cap disagreement: front end 26 (`Types.maxTypedSlots` via `bitmapSetKind`) vs verifiers 25 vs make.closure 26 | Types.elm, EcoOps.cpp | P2 (dissolved by `slot_kinds` and the 2047 cap) |
| B5 | Closure param kinds ≥ 25 silently truncated by the 50-bit mask (interned path and the papCreate/fused path), causing E4 and E8 | `EcoToLLVMClosures.cpp` papCreate lowering | P2 |
| B6 | `closureCapture` idx ≥ 25 with a typed kind stores raw and leaves the slot boxed | `HeapHelpers.hpp` closureCapture | P1 (permanent abort at ≥ 25; ≥ 20 from P2) |
| B7 | UB shifts (index ≥ 32): `fieldKind` / `pointerMaskFromKindBitmap` users; closure walkers to `n_values` (≤ 63 today, ≤ 2047 after P2); `eco_pap_extend`; `spliceArgsForSaturatedCall` (and its validate tripwire); `eco_closure_call_saturated`; `invokeSaturatedTyped`; `eco_apply_segmentation_unknown`; `eco_apply_closure_eval` (under-saturated); `closureNewArgKind` (`ListExports.cpp`); equality (`Utils.cpp`); `Debug.toString` (custom, record, typed variants); `HeapHelpers::custom()` / `record()` (shift before the `i < 64` test); `deriveAllParamKindsBitmap`; sat filter (`getOrCreateEvalDesc`); `kindBitmapFor` (`EcoToLLVMValueAgg.cpp`); PAPSimplify fused bitmap; papExtend lowering `hptrMask` | as listed | P1 for runtime readers (bounded accessors) and codegen packers; P2 replaces closure ones |
| B8 | `custom()` / `record()` u64 `hptr_mask`: slots ≥ 64 unrooted on the slow path | `HeapHelpers.hpp` | P1 (root in 64-slot chunks) |
| B9 | AbiCloning `ctorTypedSlotCap = 24` declines ctors wider than 24. Its rationale becomes false once B1 lands | `AbiCloning.elm` | P1, with B1. Pin: Phase 0's AbiCloning elm-test case 9 (a decline counter in `AbiCloningStats` if no clone is observable) |
| B10 | Stale comments: `Heap.hpp` Custom ("max 48 fields") and Record ("max 64"); `EcoToLLVMValueAgg.cpp` (`unboxed:52`); `WideCtorField24Test.elm` header; `eco_intern_closure0` comment (claims scans cover `max_values`); `UnboxedBitmap.elm` ("52-bit") | | P1 (no pin: comments) |
| B11 | `eco_set_unboxed` `default:` writes `header.unboxed` for unnamed tags | `RuntimeExports.cpp` | P1 (unit death test) |
| B12 | *(withdrawn: the zero-arg unknown-segmentation call was already fixed on Oct 5)* | | |
| B13 | `make.closure` packing (§2.2) | `EcoToLLVMValueAgg.cpp` MakeClosure lowering | P1 (codegen fixture pin) |
| B14 | `i1` construct operands accepted and stored as 0/1 in a kind-0 slot | `EcoOps.cpp` construct verifiers | P1 (negative fixture) |
| B15 | papCreateGroup flat-capture root mask stops at 64, so boxed captures past 64 are unrooted in release | `EcoToLLVMClosures.cpp` papCreateGroup lowering | P1 (unit or fixture: 3 siblings × 25 captures under GC) |
| B16 | PAPSimplify chain fusion has no slot cap, and release builds don't verify after passes | `EcoPAPSimplify.cpp` | P1: cap at the verifier limit; P2: `slot_kinds` |
| B17 | Test oracles capped or UB: `test/allocator/HeapSnapshot.hpp` (Custom `i < 48`, Record `i < 64`, Closure `i < 52` with `fieldKind`), `MinorWorkload.hpp` (`fieldKind` to `hd->size`) | | P1 (the walker split covers them too) |
| B18 | Closure stage arity > 63 is reachable from source (E9: record-alias ctor as a function value) and fails late with an op-level message | | P2: widened to 2047 (§2.3); above that, a located `TooLarge` compile error (§S.9) |
| B19 | `getAllBoxedLayout` silently clamps n to 63 (a wrong layout for wider closures; latent today because of the verifier caps) | `RuntimeExports.cpp` | P2 (§2.2 `EvalParamLayout` row) |
| B20 | Sat guard shifts the kind word by `2*n` even when the arity guard fails (poison, UB) | `EcoBackend.cpp` sat dispatch | P2 step 2.6.5 |
| B21 | Compiler exits 0 after an internal error, so truncated MLIR reaches the backend | `compiler/bin/index.js`, `eco-boot-runner.js` | P1, no pin |
| B22 | papCreate verifier's per-slot loop includes GC-root operands (shift ≥ 64, spurious errors) | `EcoOps.cpp` PapCreateOp::verify | P1 (loop `i < numCaptured`) |
| B23 | `emitInlineClosureCall` root mask stops at 64; shadow-frame push of more than 64 slots | `EcoToLLVMClosures.cpp`, `EcoToLLVMFunc.cpp` | P2 step 2.2 |


## 4. Phase map

| Phase | What | Commits | Gate highlights |
|---|---|---|---|
| **0** | Baselines on today's tree (elm-tests 14,059 pass / 4 fail; E2E 2,040 / 1; AOT; bootstrap B==C, not run since the Oct 5 fixes; perf triple and GC counters; MLIR census script; kernel census), the harness stack fix (§6.5), and every fail-first pin with its recorded failure reason | pins only | each new pin fails for its recorded reason; nothing else changes |
| **1** | Correctness fixes, no layout change: B1–B3, B6–B11, B13–B17, B21, B22; the D-semantics walker split | per sub-phase 1a–1e | elm-tests down to the 2 GOPT_003 failures; E3 green; counters bit-identical |
| **2** | Closures end to end: bytecode i8 dense arrays (2.0), `slot_kinds` on the closure ops, chunked roots, u16 `EvalParamLayout` / `EvaluatorDesc.stage_arity`, `eco_pap_extend_l`, closure layout v2 (packed word, tail kind words, physical size, `SAT_MAX_ARITY`, empty `sat[]`), caps 2047, front end, located limit diagnostics (§S.9), [P2] invariants | 2.0–2.9 (2.6 atomic) | E4–E8 and the closure pins green; E10 config run; AOT; bootstrap; perf (closures of arity 21–25 gain a word) |
| **3A** | Custom/Record runtime layout C, inert (K = 0 for every compiled object), `validateExtKinds`, `AllocateCtorOp` deleted, the wide-object unit matrix (YLOS, nursery-large, region mode, concurrent mark, compaction, CAF) | 3A steps | unit (default, validate, TSan); bootstrap; validate-tree E2E; counters bit-identical |
| **3B** | Custom/Record lowering + dialect: `slot_kinds`, ext-word stores and sizes, `eco.allow_wide_objects` | steps 2–5 are one commit | wide fixtures under JIT and GC; counters bit-identical |
| **3C** | Custom/Record front end: drop the 24/26 caps, emit `slot_kinds`, retarget the elm-test checkers | one commit | records with 27–32 primitives become fully unboxed; bootstrap B==C |
| **3D** | Lift caps (2040/2047), field-limit `TooLarge` variants, delete the old attributes and the switch, fixture sweep, invariants, docs, final gate, definition of done | per step | everything green; only unrelated failures remain |

## 5. GC concurrency procedure (CLAUDE.md, `test/tla/README.md`, GC_MODEL_001)

- **Which pins fire:** the manifest pins regions `NP.scanEntryP` (M3), `NP.MinorEnv` (M2, M3) and
  `NR.RegionEnv` (M2, M3), which hold Custom/Record arms or prefetches. It also has **census** pins
  on files this plan edits (`AllocatorCommon.hpp` M3/M4, `RuntimeExports.cpp` M1, `NurserySpace.cpp`,
  `PermanentSpace.cpp`, `ThreadLocalHeap.cpp`). That list is indicative; **the canary's report is
  authoritative**.
- **When it fires, for each named model:**
  1. Read the change against MAPPING.md, including footprint rows. The expected verdict is "no model
     change": children are read from a frozen object, the header word is one existing location, ext
     words are immutable after allocation, and no atomic/lock/order is added.
  2. Write a dated AUDIT.md entry (what changed, the verdict, the 12-hex prefix). For W drivers, use
     `test/genmc/AUDIT.md`.
  3. Then run `test/scripts/check-tla-manifest.sh . --update`.
- **Voluntary entries:** the shared walkers (`HeapChildWalk.hpp`, `NurseryChildWalk.hpp`,
  `OldGenSpace.cpp` scanChildren / compaction, the serial minor scan) are **not pinned**, so the
  canary won't fire where most semantics change. Write voluntary AUDIT.md entries in M1, M3 and M5
  for Phases 1 (1d), 2 and 3A.
- **Phase-specific audits:** phase-2 step 2.6.6 (closure packed word, `NP.scanEntryP` closure arm) and
  the 3A TLA step (Custom/Record arms). Object size stays a function of the header word alone (D3),
  so `NP.copyClaimed` / `NR.copyClaimedR` (M3, W5) and the CR-019 sweep path are not edited.
- **No model change expected.** Run `tla-trace` M1/M3 once after Phase 2 and once after Phase 3A
  (traced scan paths).
  `NP.copyClaimed` / `NP.evacuateP` should not be touched: they size from the pre-claim header word.
  If they are, W5 needs an audit.


## 6. Test mechanics

### 6.1 Rules for every gate command

- **Run each test command once**, `2>&1 | tee /tmp/test_output.txt`, then read the file with
  grep/head/tail. Never re-run to see more (CLAUDE.md).
- Run `ulimit -c 0` before any validate or negative-control run (core dumps fill the disk).
- `build/test/test` and `stress-test` are not in ALL. Build them by name
  (`cmake --build <tree> --target test`) and check their mtime.
- `build-validate` and the heap-TSan trees were deleted for disk space; recreate them, with disk
  headroom.
- After runtime edits, run `cmake --build build` (all runtime static libraries) before
  `eco-boot-native` or AOT. A stale `libEcoEntryStatic` with the old size formula mis-sizes K > 0
  objects.

### 6.2 Expected-failure lists

The Elm E2E harness has no XFAIL. **Decision:** each phase gate carries an explicit list of
`test name → expected failure reason` (verifier message substring or CHECK mismatch). The gate
passes when the failures in `/tmp/test_output.txt` equal that list exactly. elm-tests are judged the
same way, by test name.

### 6.3 Cache wipe before every E2E/AOT gate (every phase, after compiler, runtime or kernel edits)

```bash
rm -rf /work/build/test/*/eco-stuff
find ~/.eco/0.1.3/packages -name 'artifacts.dat' -o -name 'typed-artifacts.dat' | xargs rm -f
rm -rf ~/.eco/0.1.3/packages/eco/kernel          # one-time copy of eco-kernel-cpp
# AOT: move build/test/aot-e2e/*/eco-stuff aside (corrupt-cache trap)
```

`full` runs `clean` but does not remove these caches.

### 6.4 GC stress mechanism

- Pins in `test/elm/src` hold wide objects live across in-program allocation churn (precedent:
  `WideRecordGcBitmapTest.elm`), so minor GCs move and promote them.
- Variants in `test/eco-kernel/src` also call `Eco.GC.majorGC` (HEAP_076) for majors and compaction.
- Each stress pin has CHECK lines on a GC count it prints, or on the gc-stats banner (stderr is
  captured), proving collections ran. The default config runs zero minors, a vacuous pass.
- For unit tests, heap configs are passed through `initAllocator`, e.g. a nursery of a few blocks
  and `large_ptr_nursery_divisor = 0` for YLOS.

### 6.5 Harness stack size

The large pins (arity 2047, the 1100-field objects) overflow the Stage-1 compiler's native and node
stacks; it then truncates its output or crashes. Phase 0 step 0.5 sets `ulimit -s unlimited` and
`node --stack-size=500000` in `test/ElmE2ETestBase.hpp`'s compile command and in the AOT runner.

## 7. Performance gate (small objects must not regress)

- **Closures with 21–25 params** (user decision 1: 20 inline kinds instead of 25) gain one ext
  word, +8 bytes each. Expect allocation and promoted-byte counters to move by
  `census(21..25) × 8 B`. The sat fast path (`mx <= 20`) no longer serves arity 21–25 closures,
  which matters only if the census shows hot ones. Record that census row in the Phase 2 entry.
- **What changes for small objects:**
  - the size formula gains `+ hdr->unboxed` (from a word already loaded);
  - walkers gain a never-taken tail check;
  - papExtend passes a layout pointer instead of an i64 (generic path);
  - closure readers take a 3-word snapshot.
- **How it is measured:** the timed triple per `benchmarks/fe-opt-loop.md` §1 at each gate, judged
  on wall, GC time and counters.
  - Counters are bit-identical at Phases 1, 3A and 3B.
  - At Phases 2 and 3C they may differ only by the census objects; at 3D only by explained wide objects.
  - Use the mark-loop alignment trap: identical mark-loop instructions with ±4 % mark time is
    layout, not this change.
- **Rule:** a wall regression outside the triple's spread blocks the phase. Correctness fixes (Phases 1
  and 2) still ship over budget, with the cost recorded (GC-fix rule).
- **Snapshots:** snapshot with `lss-loop-snap.sh` or a git tag before each perf-gated phase.

**Definition of done** for the whole plan: phase-3 file, end of §3D. Phase gates and checklists:
the phase files.


## 8. Rollback summary

| Phase | Reverts alone? | Notes |
|---|---|---|
| 0 | yes | delete the pin files and the harness change |
| 1 | yes, per sub-phase item | |
| 2 | as one unit | runtime ABI and callers together; 2.6 is atomic |
| 3A | yes | no compiled object depends on it, but revert `AllocateCtorOp` deletion with its codegen |
| 3B | yes | 3A stays inert |
| 3C | yes, until 3D | old attributes still accepted |
| 3D | no | deletes the old attributes; snapshot or tag before 3D |

## Appendix: Review log (compact)

**Reviews (2026-10-05):** runtime (RT), compiler (C), plan (P). All findings were verified against
the tree and **accepted**; none were rejected.
- C1/C2 changed the evidence: Pap28 was not a miscompile, so E4 became Pap27b, and front-end boxing
  was dropped.
- C3 (= P1): closures land as one phase with runtime and codegen together.
- The other findings map to bugs B13–B19, the `slot_kinds` design (§2.4), the `ClosureKinds`
  snapshot, explicit ext-word stores, the YLOS tests, the expected-failure lists, the Phase 0
  baselines, and the cache-wipe and run-once rules.

| Group | Findings | Where applied |
|---|---|---|
| Evidence | C1, C4, C5, P2 | §1 (E4 Pap27b, E7, E8/E9) |
| Closure design | C2, C3, C7, RT1, RT3, RT4, RT5, RT6, P1, P7 | §2.2, phase 2 |
| Missing sites / UB | C6a–j, RT8, RT10, RT11, P8, P20 | §3 (B7, B13–B19), phase 1/2 |
| Attribute design | C8, C12, C17, P24 | §2.4, §S.5 |
| Pins and gates | plan review P3–P6, P9–P16, P21, P25, P27 | phase 0, §6, §8 |
| Invariants and docs | C16, P22, RT13 | phase 2 step 2.9, phase 3D |

**User decisions:** D1–D4 (header).

**Draft-4 self-check:** the phase files were cross-checked (378 file:line references in range). The
resulting rulings are applied in place: bug ids B20–B23, E10, the test switch (§S.6), the census
script, the bytecode encoder step 2.0, checker timing, `validateExtKinds`, the 3A bootstrap gate,
the limit errors, CGEN_026 and the harness stack size.
