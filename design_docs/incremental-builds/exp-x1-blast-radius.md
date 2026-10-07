# X1: Blast-radius study: what a small edit dirties under each unit rule

**Status:** run on 2026-10-06 in a bootstrapped copy of the tree. Raw data is in
`/tmp/inc-exp/results/x12/` (`census/*.tsv` is 1.1 GB). The instrumentation is in
`experiments/x12-inc-census.diff` (new `Compiler/GlobalOpt/IncCensus.elm`, env-gated hooks in
`Builder/Generate.elm`). Analysis scripts, edit diffs and result tables are in `experiments/x12/`.

**Question (07 §2):** for realistic small edits to the compiler's own source, how many
specializations, modules and compilation units change? How much does each design layer buy:
- stable naming (03);
- module-aligned units (06);
- requester ownership and its placement variants (02 §2.1)?

## Method

### Census

With `ECO_INC_CENSUS=<path>` set, the instrumented compiler writes one line per live spec of the
final post-GlobalOpt graph (the graph handed to codegen). With the flag set, the MLIR is
byte-identical to stock. Each line records:
- **raw SpecId and MLIR symbol name;**
- **a stable key:** the global plus its type with ids erased.
  - Lambda-set members are rendered by stable source identity (`L:<enclosing global>#<ordinal>`
    for lambdas). Type variables are canonicalized.
  - 784 key collisions (1,925 specs, mostly constructors) are disambiguated by body fingerprint,
    then by SpecId order.
- **home module and package;**
- **instance flag.** A spec counts as an instance, i.e. a candidate for requester ownership, if
  any of these holds:
  - its declared type is polymorphic;
  - it is LSS-keyed in an argument position;
  - its global has more than one spec;
  - it is an accessor;
  - it is a constructor used at more than one type or with a foreign type in its key.

  That gives 25,839 instances, 51.8 % of cost.
- **cost:** the inliner's `computeCost`;
- **body fingerprint.** Spec references are replaced by stable keys, lambdas are named
  (owner, ordinal), locals are alpha-normalized, and regions, closure kinds and member ids are
  erased;
- **referenced specs, and the type/lambda homes of the key.**

### Edit corpus

Each edit is a separate copy of the subject, and every one type-checks:

| Edit | Change |
|---|---|
| e1 | string literal in a leaf CAF (`Terminal.Main.outro`) |
| e2 | a new case branch in `Intrinsics.stringIntrinsic` |
| e3 | a new `Dict String Intrinsic` CAF plus a `Dict.get` at that new type |
| e4 | a new field in the record alias `Ctx.FuncSignature` (12 construction sites) |
| e5 | a parameter rename |
| e6 | a new *unused* top-level function containing a lambda |
| e7 | the crash message of the polymorphic `Prelude.head` |
| e8 | a new top-level function called from one site |
| e9 | comment only (control) |
| e10 | one extra `String.replace` in a small helper |

### Unit rules

A unit is dirty if its set of (identity, fingerprint) pairs changed. Unit cost = Σ spec cost + 1.

| Rule | Units |
|---|---|
| (i) **today:** 24 equal-cost contiguous SpecId ranges; identity = raw symbol name | 24 |
| (ii) the same ranges with stable keys | 24 |
| (iii) one unit per *definition* module | 326 |
| (iv-A) requester ownership, per-requester copies | 292 |
| (iv-B) dominator sharing (a transitive import graph parsed from the sources) | 314 |
| (iv-A+C) per-requester copies plus an append-only package pool | 324 |

### Controls and validation

- Two baseline runs gave byte-identical censuses and MLIR.
- The fingerprints were checked against the real emitted text MLIR on 7 of the 10 edits. They
  matched exactly on e1, e7 and e8, and on 762 of 763 specs on e4.

## Results

Each cell gives dirty units, then the share of total cost they hold (and the largest single dirty
unit, where it differs).

| Edit | Dirty specs (+/−/changed) | SpecIds renumbered | (i) today | (ii) stable ranges | (iii) def. module | (iv-A) | (iv-B) | (iv-A+C) |
|---|---|---:|---|---|---|---|---|---|
| e1 literal | 1 (0/0/1) | 0 | 1 (4.3 %) | 1 (4.3 %) | 1 (0.14 %) | 1 (0.63 %) | 1 (0.62 %) | 1 (0.65 %) |
| e2 case branch | 1 | 0 | 1 (4.2 %) | 1 (4.2 %) | 1 (0.27 %) | 1 (0.24 %) | 1 (0.27 %) | 1 (0.25 %) |
| e3 new Dict instance | 9 (8/0/1) | **5,126** | **23 (96 %)** | 17 (71 %) | 2 (9.8 %; `Dict` unit 9.5 %) | 1 (0.26 %) | 1 (0.29 %) | 1 (0.27 %) |
| e4 record field | 763 (358/358/47) | 0 | 4 (16.7 %) | 4 (16.7 %) | 21 (30.6 %; max 12.3 %) | 13 (8.75 %; max 3.4 %) | 13 (9.3 %) | 13 (8.6 %) |
| e5 rename param | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| e6 unused function | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| e7 polymorphic `head` | 10 (0/0/10) | 0 | 6 (25 %) | 6 (25 %) | 1 (0.03 %) | 10 (8.2 %) | 10 (6.0 %) | 10 (8.3 %) |
| e8 new function + call | 2 (1/0/1) | **8,750** | 11 (46 %) | 1 (4.2 %) | 1 (0.64 %) | 1 (1.18 %) | 1 (0.64 %) | 1 (1.22 %) |
| e9 comment | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| e10 small helper | 1 | 0 | 1 (4.2 %) | 1 (4.2 %) | 1 (0.01 %) | 1 (0.01 %) | 1 (0.01 %) | 1 (0.01 %) |

**Summary over the 10 edits:**

| Rule | Median dirty units | Mean dirty units | Median dirty cost | Mean dirty cost |
|---|---:|---:|---:|---:|
| (i) today | 1 | 4.7 | 4.25 % | 19.6 % |
| (ii) stable ranges | 1 | 3.1 | 4.19 % | 13.0 % |
| (iii) definition module | 1 | 2.8 | 0.09 % | 4.2 % |
| (iv-A) | 1 | 2.8 | 0.25 % | 1.9 % |
| (iv-B) | 1 | 2.8 | 0.28 % | 1.7 % |
| (iv-A+C) | 1 | 2.8 | 0.26 % | 1.9 % |

### Ground truth from the real MLIR

- **e3 and e8 change 11,758 and 18,721 symbol groups** of today's actual output. That makes 227
  and 243 of 327 definition-module units dirty (83-85 % of cost). The census model (i) slightly
  *under*-counts reality.
- **e4 renumbers no SpecIds, yet 209 symbol groups change across 60 modules (44 % of cost).** The
  cause is global counters: `_tail_<name>_<opId>` and the inliner's `mono_inline_N`. Normalizing
  them brings it to 21 modules.
- **Local names reach text MLIR, but not bytecode.**
  - e3 shifts inliner-generated parameter names in ~1,180 specs, which would dirty 68 modules if
    units were hashed on text.
  - Bytecode drops names: e5, e6 and e9 give bytecode identical to the baseline.
  - LSS member and closure-kind ids never reach the output either. e6 shifts them in 16,525 specs
    with no change in bytecode.

### Early cutoff (rule v)

- Under (iii), e4's 21 dirty units are 1 own-source and 20 callee-only.
- Under (iv-A), e7's 10 dirty units are all callee-only, because the copies of `Prelude.head` live
  in their requesters.
- All 47 indirect changes in e4 come from callers whose callee's *key* changed: the record type
  is in the key. That is an interface change, which early cutoff cannot avoid.
- No indirect change came from inlining in this corpus.

## What this means

1. **Stable naming is the first-order win (03).** Any edit that adds a specialization (e3, e8)
   renumbers 5,000-9,000 SpecIds and dirties **83-96 %** of today's units. Even without
   renumbering, the `_tail_`/`mono_inline_N` counters dirty 60 modules where stable names would
   dirty 21.
2. **Module-aligned units are the second win (06).** With stable names, median dirty cost falls
   from ~4.2 % (range units) to **0.1-0.3 %** of the program. With X4's ~3.8 s per 1 % of single-
   threaded lowering, that is about 1 s of back-end work for a typical edit.
3. **Definition-module ownership fails for packages.** A new `Dict` instance (e3) dirties the
   `Dict` unit (9.5 % of the program). Requester ownership puts it in the requester: one unit at
   0.26 %.
4. **Requester ownership has a cost: editing shared generic project code.** Changing
   `Prelude.head` (e7) dirties all 10 requesters' copies (8.2 %), against 1 unit (0.03 %) under
   definition ownership. Dominator sharing (B) helps only partly (6.0 %).
5. **Type changes cascade through spec keys** (e4: 763 dirty specs, 13 units, ~9 %) under every
   rule. That is essential blast radius.
6. **Cache keys must be name-insensitive.** The byte-hash object cache of 06 §5 must hash bytecode
   (or name-normalized text), not text MLIR.

## Limitations

- Cost is the inliner's cost measure, not lowering time (X4 covers that).
- Rule (i) is an equal-cost range split, not the hand-off plan's makespan rule. It does not model
  lambda-uid shifts.
- The 02 §4 restrictions and package-only inlining were not simulated. They need modified passes;
  X3 measures their cost, not their blast radius.
- B's churn from *new* requesters is not measured.
- Early cutoff is attributed by "was this unit's module edited", without provenance tracking.

## Side finding: a crash bug in the base compiler (not part of the question)

The first version of `IncCensus` crashed the stock `eco-compiler-boot` during codegen:
`lookupVar: unbound variable mono_inline_…`, inside a lambda.

- **Trigger:** a `List.foldl` over a 3-tuple accumulator, followed by
  `|> (\( a, b, _ ) -> ( a, b ))`, nested in another `List.foldl` lambda.
- **Reproduction:** about 3 s with `experiments/inliner-bug-repro/`.
- **Diagnosis:** this looks like the post-mono inliner losing a captured variable. It needs a
  ticket.
