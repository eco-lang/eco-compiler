# X7: Soundness of owner-scoped monomorphization

**Status:** run on 2026-10-06 in a bootstrapped copy of the tree. Raw data is in
`/tmp/inc-exp/results/x7/`. The instrumentation is in `experiments/x7-owner-census.diff`, and the
counterexample program in `experiments/x7-counterexample/`.

**Question (04 §5, 07 §2):** 04 proposes running monomorphization per owner module under requester
ownership (02 §2): a generic or LSS instance belongs to the module that requests it, nested
requests inherit the root requester, and non-generic definitions belong to their defining module.
Would the results be the same, and would they be sound?

## Verdict

**Sound only with specific changes, and never output-identical to today.**
- **Fine to scope to an owner:** most mono state. That covers LSS shared-key joins, the call memo,
  `rootLamOf`, the μ-tie and the member tables.
- **Not sound to scope as proposed:** the post-drain **settles** (ctor-row and var-lambda unions).
  A per-owner union can leave out real inhabitants that another module constructs. That is the
  known false-singleton miscompile class, and a two-module program demonstrates it.
- **Two premises of 02 §2 and 04 §4 are wrong:**
  - "Non-generic definitions belong to their defining module." Spec keys of non-generic
    definitions are shaped by their callers' lambda sets.
  - "All sharers of a key live in one owner." This fails for home-owned specs.

## Method

**Census instrumentation.** An env-gated census (`ECO_INC_OWNER_CENSUS=<path>`) was added to the
solver engine. It records:
- every keyed enqueue, as (requester spec, callee, hit kind, demand), plus call-memo hits as
  edges;
- harvest events and taint reads;
- kernel-licence checks;
- `rootLamOf` reads and inserts, μ-ties, `demandQualified` candidates, signature hits and flex
  marks.

**Post-drain analysis.**
- It derives owners and re-runs copies of `settleVarCtorRows`, `settleCtorRows` and
  `settleVarLambda` on each settle's real input, once globally and once per owner.
- It compares the results arrow by arrow.
- The copies matched the real settles on every row. With the census on, the self-compile's MLIR
  is byte-identical to the base.

**Ownership rule R.**
- A spec is *home-owned* (owner = its home module) if its global's annotation has no type variable
  *and* its creation demand carries no lambda set in an argument position.
- Every other spec (generic, LSS-keyed, accessor) is *requester-owned*. Its owner set is the union
  over the specs that enqueued it, computed as a fixpoint over enqueue edges.
- Variant A (02 §2.1) turns a spec with k owners into k copies.
- Rule R0 (ignoring LSS keys) gives the same picture.
- All 130,896 node references are covered by the enqueue log.

**Inputs.** The compiler's own source (338 modules, 43,426 specs), plus 13 single-module E2E
programs and a purpose-built two-module program.

**Cost.** The census added about 11 s and 0.2 GB to the front end.

## Ownership on the self-compile

| | Rule R |
|---|---|
| specs: home-owned / requester-owned | 8,740 / 34,686 |
| specs with more than one owner | 4,442 (10.2 %) |
| variant-A copies | 57,338 (×1.32); expression nodes ×1.21 (857k → 1,038k) |
| most owners for one spec | 131 (`Basics.append`) |
| distinct enqueue edges | 88,419: 60,257 to requester-owned callees, 11,268 to home-owned specs in the same module, **16,894 (19.1 %) to home-owned specs in another module** |
| home-owned specs demanded by another module | 3,225, of which **2,379 are demanded *only* by other modules** |
| non-generic globals with more than one home-owned spec | 440 (453 extra specs, 344 of them demanded only from other modules) |

**Caller-shaped keys are real.** `Compiler.Type.Solve.restore` (not generic) has 6 specs that
differ only in the lambda-set annotations of the result arrow. The caller's context is merged into
the callee's demand by unification. Such a spec depends on its *callers*, so it cannot be owned by
its defining module.

## Per-mechanism findings

| Mechanism | Owner-scoped sound? | Equal output? | Evidence (self-compile) |
|---|---|---|---|
| **LSS shared-key joins** (LSS_010) | Yes, at the default budget (`maxSpecsPerGlobal = 0`) | Annotations identical | 7,736 join events; 7,735 no-op and 1 changed (1 flush round). 6,512 joins come from an owner other than the spec's creator. Of 4,442 multi-owner specs, 18 would get a different per-owner join, but all 57 differing arrows have *identical annotations* (differences are residual MVar ids or CNumber vs Int only). Unsound with a non-zero budget (widened keys share specs across owners), unless ownership is decided by demand content. |
| **Post-drain settles** | **No**, as proposed | No | See below |
| `settleVarSuccessors` | Yes (row-local) | Yes | `Monomorphize.elm:1188-1208` |
| **`superTable` number taint** | Believed sound per owner (the close is uniform within an owner; owner boundaries are closed-type functions) | No | 50 tainted keys, 24 harvested in more than one owner. 3 residual MVars are tainted from another owner (e.g. `List.reverse`'s variable tainted by `Borrow.buildSCC`). 204 of 258 `hasNumberVar` answers from harvested taint are cross-owner. 582 kernel-licence checks, 0 flipped. |
| μ-tie / `demandQualified` / member interning | Yes | Yes, except numbering | 0 ties; 64,547 members interned by content key |
| `rootLamOf`, call memo | Yes | Yes | 93,589 reads, 0 order effects. 11,125 memo hits (8,573 cross-owner), all pure. |
| LSS signatures | Yes, if published in the interface | Yes | 9,706 inferred. **90 %** of 186,557 reads come from specs owned by another module, so signatures must go in the module interface (02 §6). Otherwise per-owner runs would re-infer 25,037. |

### The settles counterexample

`experiments/x7-counterexample/` contains two modules:
- `X7.Lib` defines `type Op = Op (Int -> Int)`, constructs an `Op` with its own lambda (`mkLib`),
  and destructures `Op`s in `run`/`runAll`;
- the importer constructs `Op`s with its own lambdas, including `List.map Op [\x -> x - 1, \x -> x * x]`.

**What happens.**
- `X7.Lib.Op` at its plain argument type is home-owned by `X7.Lib`, but only the importer requests
  it.
- The **global** settle writes the row `{421, 422, 425, 428, 451}`.
- **`X7.Lib`'s per-owner** settle writes `{451}`, i.e. only `mkLib`'s lambda.
- That leaves out the importer's lambdas (422, 425), which are real inhabitants of a row that
  `run` dispatches on.

This is a caller → callee flow: an importer's constructions shape a lower module's row. Bottom-up
compilation cannot see it.

### Settles on the self-compile

| | varCtor | ctorRows (⊤-heal) | varLambda |
|---|---|---|---|
| groups / groups spanning more than one owner | 1,714 / 259 | 2,083 / 189 | 31,751 / 2,910 |
| (row, owner) pairs compared / differing from global | 14,685 / 2 | 453 / 437 | 365 / 1 |
| settle writes / of those in owner-spanning groups | 24 / 13 | 1,547 / **1,517** | 82 / 26 |

**Other observations:**
- 190 constructor names are shared by *different* constructors in different modules (4,573 rows).
  `settleVarCtorRows` keys cells by constructor *name*, which couples unrelated modules.
- 338 ctorRows positions are healed only from rows of a different type instantiation.

## What it would take

1. **Ownership by key, not by definition.** A spec is home-owned only when its key is the home
   module's canonical seed key. Caller-shaped keys and budget-widened demands go to the requester.
   This corrects 02 §2 and 04 §4.
2. **Settles: choose one.**
   - **(a) A whole-program settle at link time.** This brings back a caller → callee dependency.
     Settled rows are read only by AbiCloning's exact-match target choice (E9.5), reports, and
     Borrow/MapTemplate (both off by default), so the dependency is narrow. It still forces a
     global step before codegen.
   - **(b) Per-owner settles that treat any owner-spanning group, or any row referenced from
     another owner, as containing ⊤.** This loses 1,517 of 1,547 ctorRows writes, 13 of 24 varCtor
     writes and 26 of 82 varLambda writes on this program, i.e. most of the settles' precision.
   - Either way, key varCtor cells by constructor *global* rather than name.
3. **Taint.** Scope `superTable` to the owner and accept output differences. Or stop harvesting
   callee annotation variables.
4. **μ-tie.** Choose by content order rather than interning order. That is not exercised today,
   but it is required for reproducibility.
5. **Interfaces and ids.** Publish LSS signatures in the module interface. Make SrcLambdaIds
   relative to their definition (03).

**How much crosses owners:**
- 10.2 % of specs have more than one owner (32 % more specs as copies).
- 19.1 % of edges cross owners.
- 9-15 % of settle groups span owners, but they hold 98 % / 54 % / 32 % of the settle writes.

## Implications for the design

- **02 §2's "requester ownership keeps every flow in import order" is false for mono.** It holds
  for code bodies. It fails for the LSS facts that settles compute and for caller-shaped
  non-generic specs.
- The design needs either option (a), a narrow whole-program "settle" step between per-module mono
  and codegen, or the acceptance of option (b)'s precision loss in the incremental profile.
- **The cost of variant A** (×1.32 specs, ×1.21 expression nodes) is a second, independent
  measurement of the duplication that X2 sizes.

## Limitations

- The comparison is first-order: each settle is re-run on the real global input state. Knock-on
  effects of per-owner ordering and demands were not simulated.
- The "same constructor, same type" key includes MVar ids, so 3 varCtor flags are artifacts.
- `licensedKernelAliasNode` (`Monomorphize.elm:4771`) reads taint but was not instrumented.
- The 13 E2E programs are single-module, so they show no owner differences.
