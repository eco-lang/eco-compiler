# 11: Reuse mechanics: what to cache, when to write and read it, and how objects are reused

**Status:** design, 2026-10-06. It draws on:
- a read-only investigation of object composition, the final link and the existing caches;
- the measured object-reuse experiment `exp-x11-object-reuse.md`;
- docs 03 (names), 06 (units), 08-10 (relations, thin link) and X1-X8.

## 1. How close is the thin-link design to a complete design?

The thin link (doc 10) settles *what facts flow between units* and *how they are solved*. The
pieces of a full incremental-build design and their state:

| Piece | Status | Where |
|---|---|---|
| Unit definition (module-aligned, hot modules split, cold ones merged) | Designed and measured | 06, X4, X5 |
| Stable naming | Designed; not implemented | 03 |
| Ownership of specs (requester ownership by key) | Designed; soundness conditions known | 02, X7 |
| Cross-unit relations and which survive | Catalogued | 08, 09 |
| Thin-link summaries, solves, slices, cutoff | Designed; partly validated (X11) | 10 |
| **Which artifacts to cache, at which level, under which keys** | **This document** | §2-§4 |
| **When to write and read; the build algorithm** | **This document** | §4 |
| **Object reuse at link; the link unit** | **This document** + X11 | §5 |
| Cache store mechanics (atomicity, concurrency, eviction, corruption) | This document | §6 |
| A per-unit mono driver (incremental mono itself) | **Open: the largest engineering item** | 04, X7 |
| A codec for Mono-level artifacts (or a server instead) | **Open** | 05, X8 |
| Validate twin and reproducibility gates (warm build == cold build) | Outlined | 10 §2, §8 here |
| Orchestration (scheduler, parallelism, streaming) | Outlined | §4.3; hand-off plan |

So **the design is complete enough to build the back-end half (stages A and B in §7) now.** The
front-end half (incremental mono) still needs its driver and a persistence strategy.

## 2. The artifact ladder: what could be cached per unit

Each row is a candidate artifact for one unit. Sizes are self-compile totals divided across about
300 units.

| Level | Artifact | Size (total) | Work it saves when reused | Format available today | Recommendation |
|---|---|---|---|---|---|
| L0 | `.eci` / `.ecot` | 8.7 MB `.ecot` | parse / check / build (≈ 24 s) | Exists | **Keep** (Elm's existing cache) |
| L1 | Per-unit **mono output** (the owner's spec bodies) + summary S1 + read-set trace | ~150-200 MB live heap; unknown when serialized | Monomorphization (25 s), assign (3 s), pre-mono | **No codec exists.** `.ecot` experience says an Elm codec would cost seconds (Dict/Set work) | **Defer.** Needs the per-unit mono driver first. Then a server (keeps it live, X8) or a compact codec |
| L2 | Per-unit **post-GlobalOpt Mono** | similar | inline + GlobalOpt (≈ 2.2 s) | No codec | **Don't cache.** Small saving; re-derive from L1 |
| L3 | Per-unit **eco-dialect MLIR bytecode** (codegen output) + interface/thin-link summaries S2 | ≈ 15-16 MB (13.4 MB today + per-unit tables and declarations) | MLIR codegen (12.3 s) | **Yes:** the Elm bytecode writer, self-contained per unit with fresh `StreamTables` | **Cache.** Cheap, deterministic, and naturally keyed by content hash |
| L4 | Per-unit **stage-1 llvm-dialect MLIR** (after TailConversions) + summary S3 | ≈ same order | Back-end stage 1 (≈ 12 % of back end) | **Yes:** `mlir::writeBytecodeToFile`, present in the linked libraries but unused | **Cache.** Needed so a slice-only change re-runs only stage 2 |
| — | LLVM IR / bitcode | — | translate (≈ 7 %) | `WriteBitcodeToFile` (unused on disk) | **Don't cache.** Stage 2 runs translate → emit as one unit |
| L5 | Per-unit **object file** + the worker's side reports (gc-leaf report, deleted-late, marked survivors) | ≈ 110 MB total | Back-end stage 2 (≈ 88 % of back end; most of the 56 s on 12 cores) | **Yes** (X11: deterministic) | **Cache.** The big win |
| L6 | **Link unit** (`main`, ports, `__eco_init_globals`, type table, kernel artifacts) | small | — | — | **Regenerate every build** (cheap) |
| L7 | Final executable | 92 MB | link (≈ 1.1 s) | — | Output only. Not worth caching: relinking is cheap |

**Why L3 is the key front-end cache level.** It is the first point where artifacts are already
bytes, so no new codec is needed. It is self-contained per unit, and it hashes cheaply. Caching L3
lets an edit skip codegen for all but the dirty units, and feeds L4/L5 lookup directly.

**What is not worth caching:**
- the post-GlobalOpt graph (cheap to recompute, and no codec);
- LLVM bitcode (no stage boundary there);
- the final executable.

## 3. Metadata and facts to cache, beside the artifacts

Per unit, small:

| Item | Contents | Used for |
|---|---|---|
| **Interface summary** (down-facts, published) | exported signatures/schemes; LSS signatures; alias, arity, eta; CallInfo inputs; constant-thunk values; layouts and ctor shapes; sret/psplit membership; published AbiCloning representatives; cap budget/coverage and gc-leaf of exported definitions (from the TL3 result) | Importers' keys and inputs (like `.eci`) |
| **Thin-link summaries** S1 (settles, taint), S2a/b/c (AbiCloning, sret, psplit), S3 (back end) | per doc 10 | Re-running the global solves each build without re-running units |
| **Trace** per artifact | hashes of everything the unit *read* when the artifact was produced: own input hash, each consumed interface entry, each consumed slice entry (a read set, for TL1's homes table), the stamp | Verifying a cache hit (§4) |
| **Slice record** per thin link | the slice the unit last consumed, and its hash | Early cutoff: re-run only if the new slice hash differs |
| **Unit manifest** | unit id, modules or definition groups in the unit, exported symbols, artifact hashes per level | Link and orchestration |

Global:
- **Stamp:** compiler build id (front end *and* back end; today's `V.compiler` does not change
  when only the C++ changes), `Config.hash`, every lowering-relevant `ECO_*` switch (about 63 are
  read by the back end), opt tier and level, output kind, target CPU, runtime ABI version.
- **Thin-link results cache:** each solve keyed by the vector of its input summary hashes. A
  no-change build then skips even the millisecond solves.
- **Link manifest:** the ordered object list and link-unit inputs. Order is fixed (sorted unit id)
  only for byte-identical output; stackmap parsing is order-insensitive.

## 4. When to write, when to read: the build algorithm

### 4.1 A verifying-trace build with early cutoff

This is the pattern of Shake and *Build Systems à la Carte* (constructive vs verifying traces).
Every artifact is stored together with its trace of input hashes. A build proceeds phase by phase,
because the thin links are barriers:

```
stamp check: different stamp ⇒ every key changes (treat the cache as cold for this stamp)

for each phase P (mono → TL1 → GlobalOpt → TL2 → codegen → stage 1 → TL3 → stage 2 → link):
    for each unit U (in parallel where independent; import order where a phase needs it):
        key = H(stamp, P, hash of U's input artifact from the previous level,
                hashes of the consumed interface entries, hash of U's slice for P)
        if store has key:   reuse; load only U's *summary* and the artifact's hash
                            (do not load the artifact unless a later miss needs it)
        else:               load inputs; run P on U; write artifact, then summary, then trace (§6)
    if P is followed by a thin link: gather all units' summaries (cached or fresh),
        solve (or hit the thin-link results cache), compute each unit's slice and its hash
```

**Two properties keep this cheap:**
1. **The hash chain.** Keys are computable from small metadata: input hashes, summary hashes and
   slice hashes. Big artifacts are loaded only on a miss. On a no-change build the compiler reads
   only manifests, summaries and slices (a few MB), then relinks.
2. **Early cutoff at every level.** If a re-run produces an artifact or summary whose hash equals
   the previous one, everything downstream sees the same key and hits. This is X11's e2: the code
   changed at Mono level, the machine code didn't, so nothing downstream of the object re-ran.

### 4.2 When to write

- **Write each artifact as soon as it is produced, atomically:** temp file, then rename. An
  interrupted or failed build keeps all completed units; the next build resumes.
- **Commit order is artifact → summary → trace.** The trace is the commit point: an artifact
  without a trace is invisible.
- **Don't wait for the whole build to succeed.** A cache entry is valid because its key covers
  everything it read, not because the build finished. A unit that compiled successfully stays
  cached even if a later unit fails to type-check.

### 4.3 When to read, and the order of work for an edit

1. **Elm's existing incremental check:** `.eci` / `.ecot` with early cutoff. Only edited and
   interface-affected modules re-check.
2. **Front end, today's whole-program mono** (until L1 exists): run mono → GlobalOpt over the whole
   program, then *for codegen*, look up each unit's L3 key. Keys use the unit's post-GlobalOpt
   content hash, so codegen runs only for units whose content changed.
3. **Back end:**
   - look up L4 by the L3 hash;
   - run TL3 on all S3 summaries;
   - look up L5 by (L4 hash, slice hash);
   - lower only the misses;
   - relink everything with the regenerated link unit.
4. **Once incremental mono exists:** the per-unit mono driver uses L1 traces (does the read set of
   consumed signatures, template bodies and imported interfaces match?), and L3 keys come from L1
   outputs plus TL1/TL2 slices.

### 4.4 Streaming

- In a clean or mostly-dirty build, misses stream into the native worker pool as each unit's L3
  bytes are produced. That is the partitioned hand-off plan's pipeline.
- In an incremental build, stage 1 of dirty units overlaps codegen of the others. TL3 is a barrier
  before stage 2. Since only a few units are dirty, the barrier is cheap (doc 10 §7).

## 5. Reusing object files at the final link

**Yes, objects can be reused, and X11 measured it.** With module-aligned units (272), lowering is
deterministic: a second lowering of the same MLIR gives identical objects for every unit.

| Naming | Units whose object changes, per edit (X1's ten edits) |
|---|---|
| Today's naming | 0-209 units; 5 of 10 edits changed at most 1 object; the worst changed 92 % of lowering CPU |
| Under stable naming (estimated by comparing section contents) | **at most 5 units (≤ 2.9 % of lowering CPU)**; 0-1 units for most edits |

### 5.1 What makes an object depend on more than its unit (and the fix)

| Dependency | Fix |
|---|---|
| Global counters in names (`_tail_<opId>`, SpecIds, lambda uids) | Stable naming (03) |
| `externalizeAllLocals` exports every local, so per-module counter names (`__eco_str_N`, `__eco_str_case_*`) collide across separately built units | Export only the unit's real exports; keep everything else Internal |
| **Type ids** are dense integers indexing one global table. They are baked into `Debug.toString` and `eco.dbg` sites, and the runtime keeps one `g_type_graph` | Debug sites load `@__eco_tyid$<canonical key>` (external `i32`). The link unit merges the per-unit type lists, numbers them, and emits the table plus the id definitions. (A more ambitious alternative is content-hashed `linkonce_odr` type descriptors; it needs a printer rewrite.) |
| `__eco_init_globals`, `__eco_type_graph`, `main`/`eco_main`, `__eco_register_ports`, `eco_enable_list_chunks` injection are fixed-name singletons | The **link unit**, regenerated each build. Units emit `__eco_init_globals$u` only if they have roots; the link unit calls them. |
| Kernel closure artifacts are owned by whichever unit uses them | A fixed kernel-artifact unit, regenerated at link, or hidden `linkonce_odr` COMDAT |
| Facts on declarations (gc-leaf, cap, `$sat` masks) | Part of the slice hash (L5 key). If wrong they fail silently, so the key must cover them. |
| Module name `eco-part-<i>` reaches the object's `STT_FILE` symbol | Name modules by unit id |
| Config not visible in the bytes: list chunks, veq, ~63 `ECO_*` switches, opt tier, target CPU, runtime ABI | The stamp |
| Worker side reports needed by the cross-unit checks | Store them with the object (L5 entry) |

Already favourable:
- objects contain no absolute paths, timestamps or DWARF from generated code (all locations are
  unknown);
- lowering is deterministic (X11);
- stackmaps are discovered as one linked `.llvm_stackmaps` section and parsed blob by blob, with
  records keyed by absolute address, so **object order is irrelevant**. One hazard to keep checked:
  a blob with alignment above 8 would insert padding that stops the parser early.

### 5.2 The link step

- **Every build relinks all objects** (cached and fresh) plus the link unit. Today that is about
  1.1 s with GNU ld (bfd), chosen because lld 14 rejects the absolute relocations in
  `.llvm_stackmaps` for PIE output.
- **Possible speedup:** lld or mold with `-z notext` (unmeasured; it needs a stackmap correctness
  test).
- **Avoid incremental linkers:** thunked function addresses break stackmap lookup (seen on
  Windows).
- **Archives and grouped `ld -r` don't help** with bfd.

## 6. Cache store mechanics

- **Layout:** a content-addressed store per stamp, e.g. `eco-stuff/<ver>/cache/<level>/<hash>`,
  next to the existing `.eci`/`.ecot`. Artifacts, summaries and traces are separate files, or one
  file with a checksummed header.
- **Concurrency:** Eco's file `lock`/`unlock` kernels are **no-op stubs**, so the store must be
  lock-free. Content addressing plus atomic rename makes concurrent builds safe: they write
  identical bytes to the same key.
- **Atomicity and durability:** the Elm side already has an atomic writer (`writeBytesAtomic`: temp
  file + rename, but no fsync). The C++ side has `llvm::localCache` (temp file, atomic keep) and
  `CachePruning`.
- **Hashing:** compute keys in C++ (xxh3 or BLAKE3: about a millisecond per MB), or add a gc-leaf
  `Eco.Hash.bytes` kernel. Today Eco only hashes Strings.
- **Corruption:**
  - A corrupt `.ecot` currently **segfaults** the compiler (an open pre-existing bug). Every new
    Elm-decoded cache file needs a magic number, length and checksum, and must be verified before
    decoding.
  - On any decode or verification failure, treat the entry as a miss and delete it.
  - If a link fails after cache hits, purge those hits and relink cold.
- **Eviction:** LRU by access time with a size cap (`CachePruning`). Old stamps are deleted
  wholesale.
- **A server, later** (05, X8): the same store, plus summaries, traces and possibly L1 mono state
  held in memory. The store stays the source of truth for restarts.

## 7. Adoption order and expected warm-edit times

These are estimates on the 12-core box. Today's measured warm one-module edit to an executable is
~100 s: front end 43.7 s, of which codegen is 12.3 s; back end ~56 s (X6).

| Stage | What is cached | Prerequisites | Expected warm edit |
|---|---|---|---|
| **A** | L5 objects, keyed by the *post-pipeline* partition module (today's whole-module pipeline still runs) | module-aligned EcoSplit policy (exists as an experiment); `_tail_` naming (hand-off Phase 2.5) and SpecId/lambda naming; stamp; link-unit synthesis | ~43 s front end + ~10 s back end (whole-module pipeline + dirty units + link) ≈ **~55 s** |
| **B** | + L4 and TL3 (two-stage per-unit back end) | doc 10 §5; hand-off Phase 2 prerequisites | front end unchanged; back end ≈ dirty units + link ≈ **~45 s** |
| **C** | + L3 (per-unit codegen) and TL2 | per-unit `StreamTables`; codegen keyed by unit content | ~31 s whole-program mono/GlobalOpt + small codegen + small back end ≈ **~35 s** |
| **D** | + L1 (per-unit mono) and TL1 | the per-unit mono driver; ownership by key; settle and taint handling (X7, doc 10 §3); a codec or a server | parse/check (ms) + dirty units' mono + the rest ≈ **a few seconds** (target) |

**Each stage is useful on its own** and keeps output reproducible: a warm build must equal a cold
build byte for byte (§8).

## 8. Correctness gates

- **Warm == cold:** after any edit sequence, an incremental build's executable must be
  byte-identical to a clean build's. This extends today's G6 gate from `.mlir` to the executable.
  It holds only if every key covers everything an artifact read: the trace discipline.
- **Validate twin per thin link** (doc 10 §2).
- **Fuzzed edit replays:** apply random edit sequences (like X1's corpus) and check warm == cold
  after each.
- **Cache poisoning tests:** corrupt random cache entries. The build must detect them, treat them
  as misses, and still produce the identical executable.
