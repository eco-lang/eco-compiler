# SpecKey Optimisation — Census, Survey, then Decide

**Status: PHASES 1–2 DONE; PHASE 3 SCOPED TO H2 AND IMPLEMENTATION-READY (§10).**

**Phase 1–2 headline — key SIZE is a NO-GO.** The sharing already exists: the
largest specialization key in the corpus is a **118-node DAG** (median 9), the
4,657-*logical*-node key is a 103-node object graph, and the total
size-proportional work at every key site is ≈5 M type-node visits per
self-compile. H1/H4 are closed by K6, H5 is rejected, and H3 is real but two
orders of magnitude below this repo's ≥3% signal threshold. The census and the
survey are in §8 and §9; §8.7 lists the small non-size residue.

**Phase 3 is what survived: H2.** The registry itself builds no string at any
point — `toComparableSpecKey` has no caller in the entire tree — but two
`Dict String` maps in `PhaseMono` still key on a rendered `MonoType`
(`Translate.elm:2627` `callMemo`, `Engine.elm:1330` `recordMultiInstance`).
**§10 lowers both to implementation-ready detail.** They are a strict reduction
in work: the type being keyed already exists and is already kept; only the
rendering is deleted. Site 1 is expected byte-identical; **site 2's changed
iteration order — and therefore a changed `out.mlir` — is ACCEPTED by decision
(user, 2026-08-18), with no sort at emission** (§10.4).

Sections 1–7 below are the ORIGINAL outline, left unedited so the results can be
read against what was predicted. Where the outline's seed lists turned out to be
stale, §9.2 says so in place rather than rewriting them; the one exception is a
pointer added at the head of §5 so nobody reads the hypothesis list as still
open.

## 0. What triggered this

A report-gated census added while deriving the MONO_030 watchdog limits
(`plans/lss-fidelity-1-watchdogs-budget-accounting.md` §7.6) measured the size of
every specialization key on a full self-compile:

```
spec key nodes: entries=40879  mean=45  max=4641
hist:  <=8 -> 9,586 | <=32 -> 22,982 | <=128 -> 5,934 | <=512 -> 1,487 | <=2048 -> 874 | >2048 -> 16
```

So the body is small (80% of keys ≤32 nodes) but there is a real fat tail:
**890 keys exceed 512 nodes and 16 exceed 2,048, topping out at 4,641.** The
working hypothesis that prompted this plan is that wide record types are being
embedded whole into keys, and that the tail is hurting compile performance.

**Precise the numbers before quoting them**: the histogram buckets are ≤512 /
≤2048 / >2048, so "keys over 1,000 nodes" is not directly measured — what is
measured is 890 keys >512 and 16 keys >2,048.

## 1. The question, stated so it can be answered

Three separate questions hide inside "keys are too big". Phase 1 must separate
them, because they have different answers and different fixes:

1. **Size** — are these keys *logically* big (many nodes when you walk them) or
   *physically* big (many distinct heap objects)? See §2: K6 already
   hash-conses at construction, and the census counter deliberately counts
   **logical** nodes, so a 4,641-node key may be a much smaller DAG.
2. **Cost** — what actually pays for key size? Candidates, all measurable:
   per-probe equality confirms, the O(size) type walks that run *per enqueue*
   (`Intern.widenSets`, `joinAnnotationsChanged`), string-key construction on
   the paths that still build strings, and retention of the 40,879 live
   registry entries.
3. **Provenance** — which globals own the fat keys, and which record types
   recur inside them.

Until (1) and (2) are answered, "intern the records" is a hypothesis, not a
plan — and §2 explains why that particular hypothesis needs care.

## 2. Prior art — read before proposing anything

This ground has been worked twice; the results constrain Phase 3 hard.

- **K6 — construction-time hash-consing: SHIPPED** (`plans/mono-comparable-key-optimization.md`
  §14). `Compiler.AST.Intern` is `HashMap MonoType MonoType`, structure →
  canonical object, probed by every composite constructor as it is built, in
  both engines (solver via `Store.classifyGo`/`zonkFlatC`/`Zonk.canTypeToMonoWithI`,
  subst via `TypeSubst.applySubst*I`). Canonicalisation is by **exact structure
  (`==`)**, never by comparable-key equality — the key equivalences merge
  distinct shapes (`MVar _ CNumber` keys as `MInt`; `MVar` ids erased), so
  canonicalising by them would silently change emitted code. Measured: subst
  −2.17% wall, −6.15% promotion, −16.4% max RSS.
  **Consequence: equal record types already share one object.** Any Phase-3
  proposal of the form "intern record types" must first show what K6 is *not*
  already doing.
- **K5 — retrofit interning: BUILT, MEASURED, REVERTED at +18.3% wall / +56%
  objects** (§12 of the same plan). Ids retrofitted onto an already-built graph
  cost a rebuild of every type in it. **The durable rule: intern at
  CONSTRUCTION or not at all.** Phase 3 may not propose a post-hoc pass over
  the graph without confronting this number.
- **K4 / K1–K2 — string keys off the hot paths.** The registry is
  `HashMap SpecKey SpecId` keyed on `specHashOf` — an `Int` stored *in* the type
  node, computed O(arity) at construction, never a tree walk — with
  `eqKeySpec` confirming on bucket hit via `identicalOr` (pointer identity
  first). So the registry probe is **not** obviously size-sensitive; that is a
  thing to verify, not assume.
- **`plans/hash-prefix-comparable-keys.md`** exists and is unshipped — Phase 3
  should either absorb or explicitly reject it rather than reinvent it.

**Therefore the plan's centre of gravity is NOT "make keys smaller" but "find
out whether key size costs anything, given that sharing already exists".** If
Phase 1 shows heavy sharing and Phase 2 finds no size-proportional hot path,
the honest outcome is a NO-GO with numbers — and that is a perfectly good
result for this plan.

---

## 3. Phase 1 — the key census

**Deliverable: `/work/speckey-census.txt`, one line per registry entry, from a
full self-compile**, plus an analysis section appended to this plan.

### 3.1 What each line carries

Tab-separated, one line per live registry entry, prefixed `SPECKEY\t` so it can
be grepped out of the report stream:

| field | why |
|---|---|
| `specId` | join key back to the graph |
| `global` | provenance — which global owns fat keys |
| `logicalNodes` | `Mono.typeNodeCount` (exists) — nodes counted per occurrence |
| `distinctNodes` | **the new number**: distinct subterm STRUCTURES, i.e. DAG size |
| `maxRecordWidth` | widest `MRecord` field count anywhere in the key |
| `depth` | max nesting depth |
| `key` | the rendered key (`Mono.toComparableSpecKey`) |

`distinctNodes` is what settles §1's question 1. Compute it with a
`HashMap MonoType ()` over all subterms using the same structural equality K6
canonicalises by — so `logicalNodes / distinctNodes` is exactly the sharing
factor that hash-consing is already delivering.

### 3.2 Mechanism

Extend the existing report path — do **not** add IO plumbing to the pure
compiler:

- `renderLssReport` already returns a `String` that the Builder prints to
  stderr. Add the per-key dump behind a **new env flag**
  (`ECO_SPEC_KEY_CENSUS=1`) so ordinary `ECO_MONO_LSS_REPORT=1` runs stay
  small; the flag rides the same config path as the other report knobs and is
  hash-excluded (output-only).
- Capture with `2> /work/speckey-census.txt` and strip non-`SPECKEY` lines.
- Both engines populate `registry.reverseMapping`, so the same census works for
  subst; run the solver leg first (it is the shipping default).

### 3.3 Expected size, and the guard

Mean 45 nodes ⇒ a few hundred bytes per rendered key; 40,879 entries ⇒ roughly
10–20 MB, plus a fat tail where a 4,641-node key may render to ~100 KB. That is
an acceptable text file. **Guard:** cap the rendered `key` field at a
configurable prefix (default ~4 KB) with a `…+N` suffix, so a pathological key
cannot produce a gigabyte line; `logicalNodes` still records the true size.

### 3.4 Analysis to produce from the dump (the actual deliverable)

1. **Sharing factor**: total logical vs total distinct, whole-corpus and for the
   fat tail specifically. *This decides whether "embedded whole" is even true.*
2. **Cross-key sharing**: distinct subterms across ALL keys vs the sum of
   per-key distinct counts — i.e. do the 890 fat keys share one record type, or
   890 different ones?
3. **Top-20 fattest keys** with owning global, plus the biggest recurring record
   subterms and their occurrence counts.
4. **Fat-key provenance**: are they concentrated in a few globals (a fixable
   pattern) or spread (a structural property of the corpus)?

### 3.5 Gates

Census-only: no graph mutation, flag-gated, `--target full` green, and the
census leg must not change `out.mlir` (byte-identical to a no-flag run).

---

## 4. Phase 2 — code survey

**Deliverable: a table appended to this plan** — every keyed structure, how its
key is built, and whether it is size-sensitive. Two halves:

### 4.1 Where keys get BUILT

Enumerate every construction/probe site: `Engine.enqueueSpec` /
`enqueueSpecKeyed` (solver), `Registry.getOrCreateSpecId` /
`getOrCreateSpecIdKeyed` / `updateRegistryType`, `seedSpec`, the subst engine's
`Specialize` call sites, and the entry seeding. For each: what type is built,
how often, and whether it is hash-consed.

### 4.2 Full inventory of keyed structures

For each: key representation (`String` / hashed `MonoType` / `Int`),
population, lifetime, and hot-path status. Seed list (verified present, to be
completed and corrected by the survey):

**Hash/structure-keyed (post-K4/K6):** `SpecKeyMap` (`registry.mapping`),
`LayoutMap`, `SpecMap`, `Intern` itself, `MonoGraph.ctorShapes`.

**String-keyed survivors — the interesting half:**
`Engine.monoMemo.callMemo` (key built from arg types at
`Translate.elm:2627-2629`), `monoMemo.schemeMono` / `kernelAbiMono`,
`recordMultiInstance.instances` (`toComparableMonoType`, `Engine.elm:1330`),
`nodeResolution` and `countByGlobal` (comparable-global strings),
`AbiCloning.siteFingerprint` (`shallowLayoutKey`), `CafHoist.elm:1236`,
`Staging/Rewriter.elm:644`, and the `Generate/MLIR/Context` worklist set.

**Size-proportional work that is not a map at all** — likely where the real
cost lives, if anywhere: `Intern.widenSets` (rebuilds a widened copy **per
keyed enqueue**, `Engine.elm:922,1116`), `Mono.joinAnnotationsChanged`
(`Registry.elm:160` per keyed hit + `MonoSolver/Monomorphize.elm:678` per
completed spec), `eqKeySpec` confirms, and retention of 40,879 live
`reverseMapping` entries.

### 4.3 What the survey must conclude

A ranked shortlist of *size-proportional* costs with their call frequencies
(the census counters already report probe/join populations: `identical=81,091
noop=4,582 changed=3,431 completion=33,644`). Frequency × size is the quantity
Phase 3 optimises; either factor alone is not evidence.

---

## 5. Phase 3 — OPEN

> **RESOLVED — see §8.6 for each hypothesis's verdict, and §10 for the one that
> survived.** H1/H4/H5 are closed and H3 is below the signal threshold; **H2 is
> Phase 3**, scoped and specified to implementation-ready detail in §10. The
> text below is the original outline.

Chosen after Phases 1–2. Recorded here only as hypotheses **with their
disqualifying conditions**, so nobody starts one prematurely:

- **H1 — record sharing.** Only if Phase 1 shows a low sharing factor (logical
  ≫ distinct). If K6 is already sharing them, this is closed before it starts.
- **H2 — remaining String keys → hashed.** Cheap, precedented (K1/K4); gated on
  Phase 2 showing one of them on a hot path with fat inputs.
- **H3 — the per-enqueue O(size) walks** (`widenSets`, `joinAnnotationsChanged`).
  Most likely place for fat keys to actually cost, because it is size ×
  frequency. Fixes would be memoisation or incrementalisation, both
  correctness-sensitive (LSS_010 depends on the join).
- **H4 — field-name/record-shape sharing** inside `MRecord`'s `Dict String
  MonoType`.
- **H5 — hash-prefix keys** (`plans/hash-prefix-comparable-keys.md`): absorb or
  reject explicitly.

**Forbidden without confronting the prior measurement:** any retrofit interning
pass over a built graph (K5: +18.3%).

## 6. Traps (all previously paid for)

- `typeNodeCount` is **logical** by construction — never quote it as an object
  count.
- Canonicalise only by **exact structure**, never by comparable-key equality
  (K6): key equality deliberately merges distinct shapes.
- Allocation legs need `ECO_INLINE_ALLOC=0`; the standard counter is
  inline-alloc-blind (~6× undercount).
- Judge allocation changes on **bytes and retention**, not object count (the
  `List.reverse` lesson: −1.74% bytes at +0.22% objects).
- Iteration over any interned/hashed table must stay **insertion-ordered** —
  hash-ordered iteration broke codegen once already.
- Wall measurements follow the protocol of the benchmark file matching the
  engine under test (`benchmarks/lss-opt.md` for solver+LSS); one cold run,
  counters first, ≥3% is signal.

## 7. Non-goals

- Changing what a key *means* (which specializations are distinct) — that is
  `speckey-container-aware-specialization.md` / MONO_020-024 territory and
  carries miscompile risk; this plan is about representation and cost.
- Reducing spec COUNT (that is the LSS budget/fan-out question, closed at
  `maxSpecsPerGlobal = 64` in the fidelity-1 sweep).

---

# RESULTS

## 8. Phase 1 — census results (DONE 2026-08-18)

**Deliverable: `/work/speckey-census.txt`** — 40,996 `SPECKEY` lines (one per live
post-prune registry entry) + a `SPECKEYSUM` block + three ranked
`SPECKEYTOP*` tables, 26.8 MB, from a full cold-cache self-compile of
`compiler/src/Terminal/Main.elm` under `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1
ECO_SPEC_KEY_CENSUS=1`.

### 8.1 Mechanism as built

- New flag `ECO_SPEC_KEY_CENSUS=1|<n>` → `mono.lss.keyCensus : Int`
  (`Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm`). The value doubles as
  the per-key rendering cap (`1` = the 4,096-char default; §3.3's guard). **No
  hash token** — output-only, exactly the MONO_030 precedent.
- New module `Compiler/Monomorphize/KeyCensus.elm` (pure, `MonoGraph -> String`),
  emitted through the existing `renderLssReport` stderr channel in
  `MonoSolver/Monomorphize.elm`. `keyCensus` is deliberately **not** implied by
  `lss.report`, so ordinary report runs stay small.
- Solver leg only (the shipping default). The subst engine has no report
  channel; wiring one was not needed to answer §1.
- Two refinements beyond §3.1's field list, both to keep the numbers honest:
  the **composite** columns (`Intern.hashCons` shares composites only — leaves
  and `MVar` are handed back untouched, so an all-subterm sharing factor
  credits hash-consing with sharing it never did), and NUL/SOH sanitisation of
  the rendered key so the dump is greppable text.

**Instrumentation REMOVED after its one-shot measurement (user-directed,
2026-08-18)** — same disposition as the MONO_030 trigger census
(`plans/lss-fidelity-1-watchdogs-budget-accounting.md` §7.5). The tree carries
no `keyCensus` field, no `ECO_SPEC_KEY_CENSUS` override and no
`KeyCensus.elm`; **the dump at `/work/speckey-census.txt` is the durable
artifact** and every number below is re-derivable from it with `grep`/`awk`.

*Re-instrumentation recipe*, if any of this needs re-measuring: add
`keyCensus : Int` last in `LssConfig` (append-only — the decoder's apply chain
is positional), default `0`, no hash token; add the `ECO_SPEC_KEY_CENSUS`
override to `applyEnvOverrides` (value doubles as the per-key char cap, `1` =
4,096); re-add `Compiler/Monomorphize/KeyCensus.elm` as a pure
`Int -> MonoGraph -> String` folding `registry.reverseMapping`, with a per-key
`HashMap MonoType Int` under exact `==` for the DAG count and a corpus-wide
`HashMap MonoType ( Int, Int )` over composites for cross-key reuse; emit it
through `renderLssReport`'s existing stderr channel in
`MonoSolver/Monomorphize.elm`, gated separately from `lss.report`.

**Gates (§3.5), as measured when the instrumentation was in the tree: PASSED.**

- **Output invariance** — census leg vs no-flag leg, same binary, `eco-stuff`
  purged between them (the flag is hash-excluded, so an unpurged second leg
  would be vacuous): `out.mlir` **byte-identical**, 13,811,404 B both.
- **`--target full`: green — 1,675 passed / 0 failed.**
- **`--target elm-tests`: 13,118 passed / 12 failed, and all 12 are
  PRE-EXISTING.** Verified by A/B, not by inspection: reverting all four
  changed files and re-running the three owning test files gives the identical
  `271 passed / 12 failed`, as does restoring them. The failures are
  TYPE_007 / POST_010 / golden-constraint tests in the type-checker's
  constraint layer (`NodeVarConstrainedTest`,
  `PostSolveNodeTypeGroundedTest`, `GoldenConstraintTest`) — nothing this plan
  touches.
- **Census cost, for the record** (not a shipped cost — the default is `0`, and
  flag-off the census code is unreachable): wall 5:37.27 → 5:44.31 (+7.0 s,
  +2.1%) and max RSS 6,770,640 → 6,848,364 kB (+1.1%), all of it in the report
  path rendering the 26.8 MB dump. No `benchmarks/lss-opt.md` entry: this is a
  census, not a perf change, and there is no shipped behaviour to regress.

Note the corpus grew slightly since §0's trigger run (which was
`build/compiler/build-kernel/keycensus.stderr`, 2026-08-18 15:03): entries
40,879 → **40,996**, max 4,641 → **4,657**, mean 45 → **45.94**. The buckets
reproduce §0's to within that drift, so the two runs are comparable.

### 8.2 Analysis 1 — sharing factor (§3.4.1). **This settles §1's question 1.**

| population | entries | logical | distinct (DAG) | sharing | composite sharing |
|---|---|---|---|---|---|
| whole corpus | 40,996 | 1,883,171 | 504,210 | **3.73×** | 2.62× |
| `<= 8` | 9,615 | 45,493 | 37,571 | 1.21× | — |
| `<= 32` | 23,036 | 399,999 | 218,128 | 1.83× | — |
| `<= 128` | 5,958 | 322,275 | 103,810 | 3.10× | — |
| `<= 512` | 1,497 | 311,100 | 53,099 | 5.86× | — |
| `<= 2048` | 874 | 760,562 | 89,911 | 8.46× | — |
| `> 2048` | 16 | 43,742 | 1,691 | **25.87×** | — |
| **fat tail (> 512)** | **890** | 804,304 | 91,602 | **8.78×** | 4.96× |

**Sharing rises monotonically with key size, and it rises fast.** The fat tail
is 2.2% of entries and 42.7% of the LOGICAL node mass but only **18.2% of the
distinct-node mass**.

The decisive figure is the per-key DAG-size distribution:

```
logical  nodes: n=40996 min=1 p50=16 p90=61  p99=615 max=4657
distinct nodes: n=40996 min=1 p50=9  p90=19  p99=106 max=118
```

**No specialization key anywhere in the corpus occupies more than 118 distinct
type objects, and the median is 9.** The top-20 fattest keys make the mechanism
visible: the 4,657-logical-node key is a **103-node DAG** — a 45× collapse.

| logical | distinct | distComposite | maxRecWidth | depth | owning global |
|---|---|---|---|---|---|
| 4,657 | **103** | 100 | 26 | 12 | `Mlir.Mlir.opBuilder` |
| 4,657 | **103** | 100 | 26 | 12 | `Compiler.Generate.MLIR.Ops.opBuilder` |
| 3,640 | **103** | 100 | 26 | 15 | `elm/core List.foldl` |
| 3,490 | 99 | 96 | 26 | 14 | `elm/core List.foldl` |
| 2,350 | 103 | 100 | 26 | 15 | `elm/core List.foldrHelper` |
| 2,249 | 112 | 108 | 31 | 15 | `MonoSolver.Engine.traverse{,Go}` |
| 2,243 | 111 | 107 | 31 | 15 | `elm/core Basics.apR` |
| 1,825 | 101 | 98 | 26 | 15 | `BytesFusion.Emit.emitWriteEachItem` |

`maxRecordWidth` over the fat tail is **26 (525 keys) or 31 (329 keys)** — the
MLIR `OpBuilder`/`Context` record and the solver's own `S` record (31 fields, at
the runtime's 32-slot scan cap). The **widest record anywhere in any key is 31.**

**So the working hypothesis in §0 is half right and its conclusion is wrong.**
Wide records *are* embedded, repeatedly and deeply, into monadic
`Step`/`OpBuilder` function spines — that is what makes the logical count 4,657.
But **every one of those occurrences is the same object**: K6 has already
collapsed it. `logicalNodes` was never an object count (§6's first trap), and
here that distinction is a factor of 45.

### 8.3 Analysis 2 — cross-key sharing (§3.4.2)

`distinctCompositeSum = 448,885` (summed per key) vs
`distinctCompositeGlobal = 94,595` (distinct corpus-wide) = **4.75× cross-key
reuse.** The 890 fat keys do *not* each carry their own copy of a record type;
they share one canonical object across the whole corpus.

### 8.4 Analysis 3 — recurring subterms (§3.4.3)

The most-recurring subterms are **tiny**, not wide:

| rank | occurrences | keys containing | own nodes | subterm |
|---|---|---|---|---|
| 1 | 40,027 | 3,302 | 1 | `Monomorphized.MonoType` (nullary) |
| 2 | 28,334 | 2,445 | 1 | `TypeCheck.IO.Point` |
| 3 | 21,723 | 1,461 | 2 | `Id MVarPh` |
| 5 | 18,703 | 4,388 | 2 | `List String` |
| 9 | 10,592 | 1,899 | 3 | `Dict Int String` |

The most-recurring **record** subterms are also small — widths 2–16, 3–30 nodes
(top: a 6-field / 9-node record at 6,258 occurrences across 1,551 keys). The
widest recurring record is 16 fields / 19 nodes (`InlineConfig`). The wide
`OpBuilder` (26) and `S` (31) records appear inside the *fat* keys but each is
one shared object; ranked by occurrence they do not lead the table.

The biggest recurring subterms (`SPECKEYTOPBIG`) are all **arrow spines through
builder/solver state**, e.g. `A(OpBuilder(...) -> ...)` chains and
`A(S -> A(... DecoderOp ...))` — monadic plumbing, not data.

### 8.5 Analysis 4 — fat-key provenance (§3.4.4)

890 fat keys are spread over **498 distinct globals** — but heavily
concentrated at the head:

```
 97  MonoSolver.Engine.andThen        21  MonoSolver.Engine.traverse{,Go}
 61  elm/core Result.Ok               19  elm/core Basics.apR
 59  MonoSolver.Engine.map            11  MonoSolver.Engine.getS
 53  elm/core List.foldl              10  MonoSolver.Engine.succeed
```

This is **the compiler monomorphizing its own solver monad**: `Engine.andThen`,
`map`, `traverse`, `getS`, `succeed` are the `Step` combinators, and their
type argument is the 31-field `S`. The pattern is a property of the corpus
(a state-monad-heavy self-compile), not a fixable local mistake.

Cross-cutting the size question with the budget question: the globals that
dominate `widenedByBudget` have small DAGs even where their logical counts are
large —

| global | specs | mean logical | max logical | mean distinct | max distinct |
|---|---|---|---|---|---|
| `Basics.apR` | 3,228 | 54.0 | 2,243 | **12.7** | 111 |
| `List.foldl` | 2,056 | 66.1 | 3,640 | **13.6** | 117 |
| `Basics.apL` | 1,476 | 50.9 | 2,239 | **13.7** | 108 |
| `List.foldrHelper` | 845 | 38.0 | 2,350 | **13.5** | 103 |
| `List.foldr` | 844 | 36.0 | 2,348 | **11.8** | 102 |
| `Result.Ok` | 501 | 92.9 | 581 | **20.5** | 108 |

### 8.6 What Phase 1 + Phase 2 decide together

Frequency × size, using Phase 2 §9.3's event counts and this census's sizes.
The one thing to be careful about: **`Intern.widenSets` and
`joinAnnotationsChanged` are plain recursive walks — they are NOT DAG-aware, so
they pay LOGICAL size, not DAG size.** That is the only place the fat tail can
bill anything:

| site | events | size paid | node visits |
|---|---|---|---|
| `Intern.widenSets` (over-budget arm) | 50,921 | logical, ≈54 mean at the budget-widened globals | ≈2.8 M (+ ≈1.7 M `Intern` probes) |
| completion `joinAnnotationsChanged` | 33,650 | logical, 45.9 corpus mean, ×2 trees | ≈1.5 M |
| registry `joinAnnotationsChanged` | 8,039 | same | ≈0.37 M |
| `storedType == storeType` | 81,112 | O(1) on pointer identity (K6) | ≈0 |

**Total ≈ 5 M type-node visits per self-compile.** For calibration on this
workload: 485,092 sets zonked, 960,867 LSS slots minted, and — historically —
3.68 B kernel calls before the kernel-opt track, where a −89.4% cut bought
−3.6% wall. Five million node visits is two to three orders of magnitude below
any population that has produced a measurable wall change in this codebase.

**Verdict: NO-GO on key size, with numbers.** This is the outcome §2 named as
"a perfectly good result for this plan".

- **H1 (record sharing) — CLOSED.** K6 already shares them; the fat tail is the
  *most*-shared population in the corpus (8.78×, and 25.87× above 2,048).
- **H4 (field-name / record-shape sharing) — CLOSED on the same evidence.** The
  widest record in any key is 31 fields and it is one shared object; the
  recurring records are 2–16 fields wide.
- **H2 (String keys → hashed) — NARROWED to two sites, and NOT closed by this
  census. CORRECTION (2026-08-18, post-review):** an earlier draft of this
  section said these two sites are "not fed by the fat tail because they are
  gated to arrow-free ground args". The gate is real but it does **not** bound
  key SIZE, and the claim was wrong:
    - `lssFastOk` requires no arrow in any **arg** and `groundCanType` on args
      and result — but the **result type is never arrow-checked**, and
      *arrow-free does not mean small*.
    - The MLIR `Context` record is **arrow-free** (all 26 fields are data —
      verified against `Generate/MLIR/Context.elm:206-246`) and **renders to
      4,786 characters on its own** (measured: the smallest Context-bearing key
      in the census is 289 logical / 93 distinct nodes and 4,786 chars). 1,445
      keys embed a >= 20-field record.
    - So a trivial-signature global called with a `Context`-shaped ground arg
      builds a ~4.7 KB `String` per translation at `Translate.elm:2627` and then
      does `Dict String` comparisons over it.
  **What this census did NOT measure: whether such calls actually occur, and at
  what frequency** — it measured the *registry's* keys, a different population.
  That measurement is cheap (a key-length histogram at the two sites behind the
  same `keyCensus` flag) and is carried into §10 as the optional P3.0.
  **H2 is Phase 3 — specified to implementation-ready detail in §10.** It is
  actioned without waiting on P3.0 because the change is a strict reduction in
  work regardless of the sizes: the keyed `MonoType` already exists and is
  already retained, so only the rendering is deleted.
- **H3 (per-enqueue O(size) walks) — the only surviving lead, and it is small.**
  It is real (≈4.7 M of the 5 M visits) and it is where the fat tail actually
  bills, because these two walks are logical-size not DAG-size. But 4.7 M
  visits cannot plausibly be ≥3% of a 344-second compile, so **it does not
  clear this repo's own signal threshold** and should not be attempted as a
  wall optimization. Its 99.99%-no-op completion-join half is already
  documented as retired (substrate track Phase 5a).
- **H5 (hash-prefix keys, `plans/hash-prefix-comparable-keys.md`) — REJECTED
  explicitly**, as §5 asked. Its premise is that comparable-key STRINGS are
  built on hot paths. Post-K4 they are not (§9.2): the registry probe reads an
  `Int` already stored in the node and confirms with a pointer-first
  `eqKeySpec`. A hash prefix would optimize a string that no longer exists.

**Forbidden and untouched:** no retrofit interning pass was proposed (K5,
+18.3%).

### 8.7 Residue worth picking up separately (small, not part of this plan's thesis)

Found by the survey, none of it size-driven, all of it cheap:

1. **`monoMemo.kernelAbiMono` is dead code** — no reader, no writer anywhere in
   the tree, plus two exported dead accessors (`Engine.lookupKernelAbi` /
   `putKernelAbi`). `S` is at the runtime's 32-slot record scan cap, so a field
   deletion here has non-zero value.
2. **`recordMultiInstance.instances` is `Dict String` in the solver but
   `Mono.SpecMap` in subst** (`Specialize.elm:359`). A pure consistency fix
   with K4 precedent.
3. **§4.2's seed list needs correcting in place** (see §9.2): the MLIR
   `Context` worklist set and `MonoGraph.ctorShapes` are hash-keyed already,
   and `Staging/Rewriter.elm:644` is a crash message.

## 9. Phase 2 — code survey (DONE 2026-08-18)

Read-only survey of the tree at the time of Phase 1's census binary. The
headline is that **§4.2's "String-keyed survivors — the interesting half" is
almost entirely stale**: K1/K4 finished that job, and what the seed list names
as string-keyed is now either hash-keyed, dead, default-off, or an error-path
message.

### 9.1 Where keys get BUILT

| # | site | what is built | frequency (self-compile) | hash-consed? |
|---|---|---|---|---|
| B1 | `Engine.enqueueSpec` — lss-off arm (`Engine.elm:932`) | key = the demand itself; `Registry.getOrCreateSpecId` | 0 under the shipping default (lss on) | n/a — no new type |
| B2 | `Engine.enqueueSpec` — lss-on, `keyed = False` arm (`Engine.elm:922`) | `Intern.widenSets` rebuild of the whole demand | 0 under the shipping default (`keyed = True`) | YES (`Intern.widenSets`) |
| B3 | `Engine.enqueueSpecKeyed` — UNDER budget (`Engine.elm:1110`) | none: `keyType = storeType = monoType` | the bulk of enqueues | n/a — no new type |
| B4 | `Engine.enqueueSpecKeyed` — OVER budget (`Engine.elm:1116-1118`) | `Intern.widenSets` rebuild of the whole demand | **50,921** (`widenedByBudget`) | YES |
| B5 | `Registry.getOrCreateSpecIdKeyed` probe | `Mono.specKeyMapGet` → `specKeyHash` (O(1), read from the node) + `eqKeySpec` confirm | every enqueue | n/a |
| B6 | `Registry.getOrCreateSpecIdKeyed` hit | `storedType == storeType` (`Registry.elm:150`), else `Mono.joinAnnotationsChanged` (`Registry.elm:160`) | 89,151 hits: identical **81,112** / noop **4,605** / changed **3,434** | join output is NOT interned |
| B7 | `Monomorphize.processItem` completion (`MonoSolver/Monomorphize.elm:626-668`) | `Mono.joinAnnotationsChanged actualType storedT` (`:632`) + `updateRegistryType` | **33,650**, of which **33,646 no-op (99.99%)** | not interned |
| B8 | `Monomorphize.seedSpec` (`MonoSolver/Monomorphize.elm:362`) + flags decoder | `Registry.getOrCreateSpecId` at the entry type | 2 | `Intern.disabled` at entry seeding |
| B9 | subst `Specialize.enqueueSpec` (`Specialize.elm:271`) | `TypeSubst.refreshConstraints` — O(size) pre-scan, rebuild only on a stale stamp | every subst enqueue | ReadOnly intern |
| B10 | subst `Specialize.elm:1987/2095/2162` | `Registry.getOrCreateSpecId` at an already-built type | per specialized node | ReadOnly intern |
| B11 | `Prune.pruneUnreachableSpecs` | closes residual `CNumber` in every live `reverseMapping` entry behind a `hasResidualType` pre-scan (`Prune.elm:184-205`); drops `mapping` entirely (`specKeyMapEmpty`) | once, over 40,996 entries | rebuilt types not interned |

**B2/B4 are the same call.** Under the shipping default (`lss.keyed = True`)
the only live `Intern.widenSets` site is the over-budget arm, so *set-widening
of keys happens 50,921 times* and never on the under-budget majority.

### 9.2 Inventory of keyed structures

**Hash/structure-keyed (post-K4/K6) — no string is built at all:**

| structure | key repr | population | lifetime | hot? |
|---|---|---|---|---|
| `registry.mapping` (`SpecKeyMap SpecId`) | `specKeyHash` Int (stored in the node) + `eqKeySpec` confirm | >= 40,996 (pre-prune `nextId`) | mono only — Prune sets it to `specKeyMapEmpty` | YES, every enqueue |
| `registry.reverseMapping` | `Array` indexed by SpecId | **40,996 live post-prune** | **whole backend** — GlobalOpt, AbiCloning, MLIR codegen all read it | probe O(1) |
| `Compiler.AST.Intern` | `specHashOf` + exact `==` | ~116 K distinct structures (K6 §13) | mono only | YES, per composite construction |
| `MonoGraph.ctorShapes` (`LayoutMap`) | `layoutHashOf` + `eqKeyLayout` | per reachable custom type | whole backend | codegen only |
| MLIR `typeRegistry.typeIds` + the `getOrCreateTypeIdForMonoType` worklist `queued` set (`Context.elm:475-505`) | `LayoutMap` | whole program type set | codegen | **the seed list calls this string-keyed; it is not** — K1.1 removed that |
| subst local-multi `entry.instances` (`Specialize.elm:359/1213/1300`) | `SpecMap` | small | per item | — |

**String-keyed — the corrected and COMPLETE list.** A grep for every
`toComparableMonoType` / `toComparableLayoutKey` / `toComparableSpecKey` call in
`compiler/src` returns exactly these (doc-comment mentions excluded):

| site | phase | status |
|---|---|---|
| `Translate.elm:2627` / `:2629` — `monoMemo.callMemo` key, `gkey ++ "\|" ++ arg keys ++ "->" ++ result key`, probed in a `Dict String` | **PhaseMono** (solver, per-item translation of a global call — the M2b ground-memo path) | **LIVE.** Gated by `lssFastOk` (trivial callee signature + no arrow in any ARG) and `groundCanType` on args and result. **That gate bounds arrows, not size** — the result is never arrow-checked, and an arrow-free `Context` arg renders to 4,786 chars. Sizes here are UNMEASURED; see the H2 correction in §8.6. Actioned in §10.2. |
| `Engine.elm:1330` — `recordMultiInstance`, `instances : Dict String NumberInstance` | **PhaseMono** (solver; called from `Translate` at 8 sites via `recordLocalInstance` / `recordNumberInstance`) | **LIVE**, tiny population (number-multi / local-multi let-bindings only; `localMultiBypass = 469`). Note the asymmetry: the **subst** engine's equivalent is already a `Mono.SpecMap` (`Specialize.elm:359`). Actioned in §10.3. |
| `CafHoist.elm:1236` — `fingerprintOf`, a bucket key | PhaseGlobalOpt | Default-OFF, and it has **two** callers, both default-off: `CafHoist` itself (`cafMemo.hoist.enabled = False`) and `MonoCse.elm:606` (`cse.enabled = False`). |
| `Diff.elm:202` / `:384` | PhaseMono | `ECO_MONO_ENGINE=diff` only — graph serialization for the engine cross-check. Never a production compile. |
| `Staging/Rewriter.elm:644` | PhaseGlobalOpt (staging) | **An error-path `crash` message.** The seed list's inclusion of it is a false positive. |
| `KeyCensus.elm:564` | PhaseMono tail | This plan's own census, flag-gated. |

In `compiler/tests` there are 8 more uses, all in
`TestLogic/Monomorphize/ComparableKeyEncodingTest.elm` — the gate pinning
`eqKeySpec a b == (toComparableMonoType a == toComparableMonoType b)`, i.e. the
reason the string function must still exist even though no hot path calls it:
it is the reference semantics the `Int` hash and the structural `eq` are tested
against. **That test is also what makes §10 sound** — it already pins the
equivalence the swap relies on.

**`toComparableSpecKey` — the function that renders a whole registry key — has
NO caller at all.** Complete occurrence set across `src` and `tests`: its own
definition (`Monomorphized.elm:2290`), the `exposing`/`@docs` lines, and this
plan's census (`KeyCensus.elm:317`). No production caller, no test. The 77,101-
character rendering of the fattest key has therefore never existed during a real
compile. Unlike `toComparableMonoType` it does not even have the test-oracle
role justifying its presence — see §8.7.

Other seed-list entries that are not type-keyed at all, so key SIZE cannot
reach them: `monoMemo.schemeMono` and `S.nodeResolution` (both keyed by
`TOpt.toComparableGlobal`), `registry.countByGlobal` (`Mono.toComparableGlobal`).

`AbiCloning.siteFingerprint` (`shallowLayoutKey` at `fingerprintDepth = 4`) is
**depth-capped by construction**, so it is not size-proportional in depth — but
it *is* width-proportional at `MRecord`, which emits every field NAME
(`"R" ++ n ++ "(" ++ String.join "," (Dict.keys fields) ++ ")"`). A wide record
in a param or return position pays its full field-name list per site and per
instance.

**Dead code found:** `monoMemo.kernelAbiMono` with its `Engine.lookupKernelAbi`
/ `putKernelAbi` accessors has **no callers anywhere in the tree** — an always-
empty `Dict` field and two exported dead functions.

### 9.3 Size-proportional work that is not a map

Ranked by frequency × per-event size, which is the quantity §4.3 asks for:

| rank | site | per-event cost | events | notes |
|---|---|---|---|---|
| 1 | `Intern.widenSets` (`Engine.elm:1116`) | **full O(size) rebuild** of the demand + one `Intern` hash probe per composite node | **50,921** | The largest size-proportional population at a key site. Every over-budget enqueue re-walks and re-probes the whole type. `widenSets` is *semantically* a no-op on an all-`LTop` tree but still walks it. |
| 2 | `joinAnnotationsChanged` at completion (`MonoSolver/Monomorphize.elm:632`) | **full two-tree O(size) walk, no pointer-identity fast path at the top** | **33,650**, 33,646 of them no-ops | Already characterised by Phase 4a of the substrate track; the rebuild is elided, the *walk* is not. |
| 3 | `storedType == storeType` (`Registry.elm:150`) | O(1) when the two are pointer-identical (K6 makes that the common case), else O(size) | 81,112 | Cheap *because* of K6 — the one place hash-consing already pays at a key site. |
| 4 | `joinAnnotationsChanged` at the registry (`Registry.elm:160`) | full two-tree O(size) walk | 8,039 | 4x rarer than #2. |
| 5 | `eqKeySpec` confirm on a bucket hit (`specKeyMapGet`) | O(1) on pointer identity, else O(size) | per enqueue | Same K6 dependency as #3. |
| 6 | `callMemo` key build (`Translate.elm:2627`) | O(Σ arg sizes + result size) **string** build + `Dict String` compares (O(log n) × O(len)) | M2b calls — **not measured** | The only remaining string-keyed hot path. Its arg gate is arrow-freedom, NOT size: an arrow-free `Context` arg renders to 4,786 chars, and the RESULT type is not arrow-checked at all. See the H2 correction in §8.6; actioned in §10.2. |
| 7 | subst `refreshConstraints` (`Specialize.elm:271`) | O(size) allocation-free pre-scan every enqueue | every subst enqueue | subst engine only. |
| 8 | Prune's per-entry residual close (`Prune.elm:194`) | O(size) `hasResidualType` pre-scan, `closeType` rebuild only if a residual is present | 40,996 | once per compile; `closeType` does NOT intern, so a closed entry leaves the shared DAG. |
| — | retention of `reverseMapping` | 40,996 live `( Global, MonoType )` pairs held for the whole backend | — | Size here is *retention*, not walk cost; the DAG sharing measured in Phase 1 is what decides how many objects that actually is. |

### 9.4 What the survey concludes

1. **The remaining string-keyed surface is one hot site (`callMemo`) plus one
   cold one (`recordMultiInstance`).** Phase 1 measured the REGISTRY's keys,
   which is a different population from what those two sites key on — so it
   cannot settle H2 either way. See the correction in §8.6: the callMemo gate
   bounds arrows, not size, and a 4,786-char arrow-free record arg is
   admissible. **Both sites are actioned in §10.**
2. **The real size × frequency mass is `Intern.widenSets` (50,921) and the
   completion join (33,650).** That is H3's territory, and H3 was already the
   plan's own favourite — but §8.6 prices it out.
3. **K6 is load-bearing at exactly two key sites** (#3 and #5) — it is what
   makes the 81,112 identical hits O(1). Any Phase-3 change that produces
   *un-interned* key types would silently turn those back into O(size) walks.
   Note that both join sites already produce un-interned output (B6/B7), and
   that this is exactly the concern behind §10.6's optional P3.3.

## 10. Phase 3 — de-string the two surviving type-keyed maps (IMPLEMENTATION-READY)

**Scope: H2 only.** H1/H4 are closed by K6 (§8.2), H5 is rejected, H3 is real but
below the signal threshold (§8.6). What remains is the two `Dict String` maps
that key on a *rendered* `MonoType` — the only places in the tree where a type
is still materialised into a `String` on a path a default compile executes.

Both are in **`PhaseMono`, solver engine**, and in the same inner loop
(`Engine.recordMultiInstance` is called from `Translate`).

**Decision taken (user, 2026-08-18): both sites land, and the emission-order
change at site 2 is ACCEPTED. Do NOT sort at emission to preserve
byte-identity.** §10.4 states what that costs and how it is gated instead.

### 10.1 Why this is a strict reduction in work, not a trade

At both sites the `MonoType` being keyed **already exists** — it is built, rendered
to a `String`, and the string is then used as the key while the type itself is
kept anyway. The change deletes the rendering. Nothing new is computed.

Three properties make the swap sound rather than merely plausible:

1. **The equivalence is already pinned by a test.**
   `tests/TestLogic/Monomorphize/ComparableKeyEncodingTest.elm` asserts
   `eqKeySpec a b == (toComparableMonoType a == toComparableMonoType b)`. Both
   maps key on `toComparableMonoType`, so replacing the string with
   `specHashOf` + `eqKeySpec` partitions the key space **identically**. No new
   soundness argument is needed; the gate for it already exists and must stay
   green.
2. **`specHashOf` is not a walk.** It is an `Int` already stored in the type
   node, computed O(arity) at construction from the children's stored hashes
   (`Monomorphized.elm:280-300`). The probe never touches the tree.
3. **The hash contract is one-directional and already respected by the API.**
   Equal keys imply equal hashes, never the converse; every `specKeyMap*` /
   `specMap*` operation confirms a bucket hit with `eqKeySpec`. Do not add a
   hash-only short-circuit anywhere (26-bit packed hashes — collisions are
   certain at self-compile scale).

### 10.2 Site 1 — `monoMemo.callMemo` → `Mono.SpecKeyMap`

The key is `(global, [arg types], result type)`. Fold the args and result into
the arrow they already denote and key on `Mono.SpecKey`.

**`Compiler/MonoSolver/Engine.elm`**

- `type alias MonoMemo` (`:198-201`) — change
  `callMemo : CoreDict.Dict String ( Mono.MonoType, Mono.MonoType, Mono.SpecId )`
  to `callMemo : Mono.SpecKeyMap ( Mono.MonoType, Mono.MonoType, Mono.SpecId )`.
  Update the field's doc bullet (`:188-190`) to say the key is the callee global
  plus the synthetic `args -> result` arrow.
- `emptyMonoMemo` (`:205-206`) — `callMemo = Mono.specKeyMapEmpty`.
- `lookupCallMemo` (`:1492-1493`) — signature `Mono.SpecKey -> Step (Maybe ( ... ))`,
  body `getS (\s -> Mono.specKeyMapGet key s.monoMemo.callMemo)`.
- `putCallMemo` (`:1499-1504`) — signature `Mono.SpecKey -> ( ... ) -> Step ()`,
  body uses `Mono.specKeyMapInsert`.

**`Compiler/MonoSolver/Translate.elm`, `translateGlobalCallGroundMemo` (`:2613-2690`)**

Replace the `let key = ...` block (`:2618-2630`) with:

```elm
key : Mono.SpecKey
key =
    Mono.SpecKey (toptToMonoGlobal global)
        (Mono.mFunction Mono.LTop
            (List.map (Zonk.canTypeToMono superStatic << TOpt.typeOf) args)
            (Zonk.canTypeToMono superStatic callCanType)
        )
```

Nothing else in that function changes — `Engine.lookupCallMemo key` (`:2690`)
and `Engine.putCallMemo key (...)` (`:2674`) keep their shape.

**No new API.** `SpecKey(..)`, `mFunction`, `LambdaSetAnno(..)`, and
`specKeyMapEmpty/Get/Insert/Size` are all already in `Monomorphized`'s
`exposing` list; `toptToMonoGlobal` already exists at `Translate.elm:5298`.

**Points to get right:**

- **`LTop` is the correct constant** for the synthetic wrapper. `canTypeToMono`
  stamps `LTop` on every arrow, which is exactly what the existing
  "annotation-neutral by construction (M4 == audit)" comment at `:2619` asserts.
  The wrapper is a key only — it never escapes into a node — but it must be a
  CONSTANT annotation or the memo would split on sets it should not see.
- **Global equality matches.** `toptToMonoGlobal (TOpt.Global home name) =
  Mono.Global home name` is structurally injective, so `specKeyEq`'s `g1 == g2`
  partitions exactly as `TOpt.toComparableGlobal` equality does today.
- **Arity is preserved by construction.** `eqKeySpec` compares arg-list length
  structurally (`eqKeyList`), so the wrapper cannot merge an n-arg call with an
  (n−k)-arg call the way a careless string concatenation might.
- **Ordering is a non-issue here.** `callMemo` is only ever `get` and `insert`
  (`Engine.elm:1493, 1504`); it is never iterated anywhere in the tree, so
  `Dict`-sorted vs `HashMap`-insertion order is unobservable.

**Expected result: byte-identical `out.mlir`.** Site 1 changes representation
only. Gate on exactly that (§10.5).

**Secondary win worth recording:** `callMemo` is a GLOBAL memo (it survives
`resetItem`), so today it retains every key string for the whole compile. §8.6
measured a single arrow-free `Context` at **4,786 chars**; those strings are
pure added retention. After the swap the retained key is the already-shared
type. Given this codebase's repeated finding that wall follows RETENTION rather
than allocation count (K6: −16.4% max RSS; K5: +18.3% wall for +56% objects),
record `Maximum resident set size` for this leg, not just wall.

### 10.3 Site 2 — `NumberMultiEntry.instances` → `Mono.SpecMap`

A plain `MonoType`-keyed map, so `Mono.SpecMap` is a direct fit — and the subst
engine's twin already uses it (`Specialize.elm:359`), so this also removes an
engine asymmetry.

**`Compiler/MonoSolver/Engine.elm`**

- `type alias NumberMultiEntry` (`:592-596`) —
  `instances : Mono.SpecMap NumberInstance`. Update the doc above it (`:588-591`).
- `pushNumberMulti` (`:1223`) and `pushLocalMulti` (`:1277`) —
  `instances = Mono.specMapEmpty`.
- `numberMultiRootType` (`:1254`) — `Mono.specMapValues entry.instances`.
- `recordMultiInstance` (`:1324-1355`) — **delete the `key` binding entirely**
  (`:1328-1330`, the `toComparableMonoType` call) and rewrite `update`:
  `Mono.specMapGet monoType entry.instances`,
  `Mono.specMapSize entry.instances` for `idx`,
  `Mono.specMapInsert monoType inst entry.instances`.

**`Compiler/MonoSolver/Translate.elm`** — four iteration sites plus one emptiness
test:

- `:3791` `case Dict.values entry.instances of [ inst ] -> ...` →
  `Mono.specMapValues`. **Order-insensitive** (only the singleton arm is read).
- `:3970` `Dict.values entry.instances |> List.filter ...` → `Mono.specMapValues`.
- `:4277` `List.filter ... (Dict.values e.instances)` → `Mono.specMapValues`.
- `:4852` `Dict.isEmpty entry.instances` → `Mono.specMapIsEmpty`.
- `:4859` `buildLocalDefs` — `Dict.values entry.instances` → `Mono.specMapValues`.

**No new API**: the whole `specMap*` family is already exposed.

**What does NOT change: the names.** `freshName` is assigned from
`specMapSize` at INSERT time (`defName` for index 0, `defName ++ sep ++ idx`
after), which is insertion-driven and therefore identical before and after.
`numberMultiRootType`'s `List.filter (\i -> i.freshName == name) |> List.head`
stays correct because `freshName`s remain unique per entry.

### 10.4 What site 2 costs, stated plainly

`Dict String` iterates in **lexicographic order of the rendered type**;
`Data.HashMap` iterates in **insertion order** (`orderedEntries` sorts on a
per-entry sequence number — deliberate, and the repo rule is that iteration over
a hashed table must stay insertion-ordered, never hash-ordered). Both are
deterministic; they are not the same order.

`buildLocalDefs` (`Translate.elm:4859`) and the `:3970` / `:4277` sites emit one
definition per instance IN ITERATION ORDER, so:

- **`out.mlir` changes. The byte-identity gate does not apply to site 2.** This
  is accepted, not an accident.
- **Do not expect a small diff.** Reordering the per-instance `retranslateAt`
  calls reorders the spec enqueues behind them, so `registry.nextId` is handed
  out in a different order and **SpecIds renumber globally**, which renames
  symbols throughout the emitted MLIR. "Eyeball the diff" is therefore not a
  viable check — §10.5's gates are semantic, by necessity.
- **Spec counts may move slightly.** Which demands arrive under
  `maxSpecsPerGlobal = 64` is order-dependent, so `widenedByBudget` and the
  per-global spec counts can shift. That is expected variance, not a
  regression — record the numbers rather than requiring them to match.
- **Semantic argument for why the reorder is safe:** the instances are
  independent specializations of ONE source binding at different types; they do
  not reference one another, their names are already fixed by insertion order,
  and each is retranslated in its own scratch store (`retranslateAt`). The LSS_010
  registry join is a monotone lattice with a drain-end flush to fixpoint, so the
  joined demand each spec ends up with does not depend on the order the demands
  arrived in.
- **Incidental improvement:** after the swap, emission order agrees with the
  `f`, `f$1`, `f$2` numbering. Today it does not — today `f$2` can be emitted
  before `f$1` if its rendered type sorts earlier.

### 10.5 Landing order and gates

**Land and gate site 1 ALONE first.** Its byte-identity gate is the strongest
evidence available for a representation swap, and it is destroyed if site 2 is
in the same binary.

| step | change | gate |
|---|---|---|
| P3.1 | Site 1 only | `out.mlir` **byte-identical** vs a pre-change binary on a frozen corpus. `--target full` green. Record wall AND max RSS (§10.2). |
| P3.2 | Site 2 only, on top | `out.mlir` **expected to differ** — instead: (a) **determinism**: two cold runs of the new binary produce identical `out.mlir`; (b) **bootstrap fixed point**: the Stage-4b `eco-boot-2.js == eco-boot-3.js` check still converges; (c) `--target full` green; (d) `ECO_MONO_VALIDATE=1` clean (MONO_029 layout agreement — the safety net for a change that reorders emitted defs); (e) record spec counts / `widenedByBudget` deltas. |

Standing conditions for both: `--target elm-tests` must stay at its **12
pre-existing failures** and no more (§8.1 — they are TYPE_007 / POST_010 /
golden-constraint tests in the type checker, unrelated to this work);
`ComparableKeyEncodingTest` must stay green, since it is the pinned equivalence
this whole phase rests on; purge `eco-stuff` between legs.

Benchmarks per `benchmarks/lss-opt.md` (solver+LSS, one cold run, counters
first, ≥3% is signal). P3.1 is an A/B against a pre-change binary on a frozen
corpus — flag-off is not available, so this is the two-binaries protocol.

### 10.6 Optional refinement, measure before adopting

- **P3.0 (optional, cheap, do it only if you want the payoff quantified
  up front):** a key-length histogram at the two sites. §8.6's open question is
  that nobody has measured how large these key strings actually get; the census
  measured the REGISTRY's keys, a different population. Note the `keyCensus`
  flag no longer exists (§8.1) — this needs the re-instrumentation recipe
  there, or simpler standalone counters, since all it needs is
  `String.length key` bucketed. Not a blocker: the change is a strict reduction
  in work either way, and P3.0 only turns "no regression" into a quotable win.
- **P3.3 (optional, after P3.1 lands):** intern the site-1 key components.
  Today's `Zonk.canTypeToMono` runs with `Intern.disabled`, so the key type is a
  fresh tree and `eqKeySpec`'s `identicalOr` fast path cannot fire — a hit pays
  a structural walk instead of a pointer compare. Threading `Zonk.canTypeToMonoI`
  (or `Intern.readOnly`, which probes without registering) would make hits O(1),
  the same mechanism that makes the registry's 81,112 identical hits free. Note
  `Intern.hashCons` canonicalises the TOP node only, so this requires interning
  the ARGS, not just the wrapper. Separate measurement; do not fold into P3.1's
  byte-identity leg.

### 10.7 Rollback

Both sites are pure representation swaps behind unchanged call-site shapes, so
reverting is a file-level revert of `Engine.elm` + `Translate.elm`. Neither
introduces a flag, and neither should: a config knob here would double the
test matrix for a change whose off-arm is the code being deleted.

### 10.8 OUTCOME — both sites LANDED 2026-08-18

Benchmarks: `benchmarks/lss-opt.md` **Run O** (site 1) and **Run P** (site 2).

| gate | result |
|---|---|
| P3.1 `out.mlir` byte-identical (site 1, pre vs post, one frozen corpus) | **PASS** — 13,772,811 B both, `cmp` clean, and every lss census line identical |
| P3.2 `out.mlir` (site 2) | **DIFFERS as designed** — same SIZE (13,777,733 B), content differs at byte 1,907,828: the signature of a pure permutation |
| P3.2 determinism (two cold runs of the post binary) | **PASS** — byte-identical to each other |
| P3.2 `ECO_MONO_VALIDATE=1` (MONO_029) | **PASS** — no violations |
| P3.2 Stage-4b bootstrap fixed point | **PASS** — converged |
| `--target full` | **PASS** — 1,675 / 0 |
| `--target elm-tests` | 13,118 / 12 — **the same 12 pre-existing** failures as §8.1, no new ones |

**Cost: FLAT on both sites.** Site 1: wall −1.0%, minors 1,402 = 1,402, majors 15 = 15,
promoted +0.005%. Site 2: wall +0.5%, minors 1,406 = 1,406, majors 14 = 14, promoted
−0.025%. By this repo's ≥3% rule both are "no regression detected"; neither is a win and
neither is claimed as one. The honest summary is that H2 was **correctness-and-hygiene
work, not a perf win** — which is what §8.6 predicted when it declined to wait on P3.0.

**Two predictions from §10 to correct, both in the safe direction:**

1. **§10.4 said spec counts might shift** because which demands land under
   `maxSpecsPerGlobal = 64` is order-dependent. **Refuted: every lss census counter is
   identical across the site-2 arms** — `sets zonked`, `widened byBudget`, all three join
   populations, and the per-global spec counts. The reorder moves emission order and
   SpecId assignment order only; the spec population and the LSS analysis are untouched.
   That is a stronger result than the plan allowed for, and it is why the diff is a pure
   permutation at identical byte size.
2. **§10.2's retention thesis is NOT confirmed.** Max RSS did fall 2.1% (−124 MB) at site
   1, but `promoted` is flat to 0.005%, which argues against "the memo stopped retaining
   key strings" being the mechanism. Same parked class as Run G's unexplained −259 MB;
   do not build on it.

**P3.0 was never run** and is now moot for the decision — the change landed on the
strict-reduction-in-work argument, and the measured answer is FLAT either way. Anyone
wanting the key-size distribution at those two sites still has to re-instrument.

**P3.3 (intern the site-1 key components) remains open and unmeasured.** Today's
`Zonk.canTypeToMono` still runs with `Intern.disabled`, so a memo HIT pays a structural
`eqKeySpec` walk rather than the pointer compare K6 makes available. Given Run O came out
FLAT, the expected value of chasing it is low.
