# E4a use-site overlay: one deferred walk per outermost let-function

**Status:** SHIPPED 2026-09-04 (unflagged — a pure refactor of an existing
pass, output byte-identical on the self-compile).

**Context:** the Aug-26 → Sep-3 self-compile regression investigation
(`context.md`; memory `lss-aug26-regression-is-input-not-compiler`). The
2.22× was not a slower compiler: the same binary took 7:03 on the Aug-26
source and 15:41 on the Sep-3 source, and on identical input two binaries 20
commits apart agreed on every dispatch counter to the digit. The input had
become 2.22× more expensive to compile, and 68 % of all dispatch was ONE
pass — E4a's local-multi use-site overlay at `Translate.elm`
`translateLocalMultiLet`.

## 1. The mechanism (item 2 of the brief: confirmed by census)

`translateLocalMultiLet` — every let-bound FUNCTION routes through it —
finished by walking the whole let body with `MonoTraverse.traverseExpr` to
overlay the per-instance defs' lambda-set annotations onto the `MonoVarLocal`
uses (plan `lss-dispatch-value-extraction.md` §9.1). Three costs compounded,
and the census (§4.2) ranks them:

1. **`traverseExpr` re-lifts its callback at every let-RHS and case-branch
   boundary — exponential in let/case nesting. THE dominant factor.**
   `traverseExpr f` passes the already-lifted `traverseExpr f` to
   `traverseExprChildren`, which applies it directly to call/list/if/closure
   children (correct) but hands it to `traverseDef` / `traverseDecider` /
   `traverseChoice` for `MonoLet` defs and `MonoCase` inline branches — and
   those call `traverseExpr f …` on it AGAIN. Every let-RHS / case-branch
   subtree is therefore traversed by `traverseExpr (traverseExpr f)`: each of
   its nodes triggers a full traversal of its own subtree, and each nested
   let/case inside repeats the trick. Measured: the pass's callback ran
   **2,266,918,179** times on the Sep-3 self-compile for a tree of
   **190,194** nodes — an 11,900× amplification; on the Aug-26 source
   6,882,339 calls for 52,547 nodes (131×). Even the toy corpus shows it
   (638 callbacks for 482 nodes). Recorded as defect 3 in
   `DEFECTS_DO_NOT_FORGET.md`; the two other `traverseExpr` callers
   (`MonoInlineSimplify.remapLambdaIds`, `Generate/MLIR/Expr.resolveFusedLets`)
   carry the same defect at 253K / 16K dispatches today.
2. **Once per let, not once per body.** A body nested under k let-functions
   was walked k times (`let a = … in let b = … in let c = … in body` walks
   `body` at c's, b's and a's completion). Real but modest: per-let visits /
   tree nodes = 1.55× (Aug) → 4.08× (Sep).
3. **The Sep-3 source has the shape that feeds 1.** The deepest let-function
   chain went from 7 (Aug-26) to **18** (Sep-3, two walks). By a source
   heuristic (let-bound function defs per top-level function) the newcomer is
   `Monomorphize.renderLssReport` with **36** local helper functions (Aug-26's
   top entries: `processElts` 13, `formatModuleHeader` 9) — the LSS *report
   renderer* added during Aug 26 → Sep 3, gated off at runtime but compiled
   every time. Also `settleVarCtorRows` (7).

So: the 20 commits added a report renderer whose deep let/case nesting hit an
exponential in `traverseExpr`, inside a pass that ran per let-function. The
analysis code itself was never slower (two binaries 20 commits apart agree on
every counter on identical input — memory `lss-aug26-regression-is-input-not-compiler`).

## 2. The change (item 1: fix the traversal)

Files: `compiler/src/Compiler/MonoSolver/Translate.elm` (the pass),
`Engine.elm` (one field on the `localMulti` stack entry, one census helper),
`Monomorphize/MonoTraverse.elm` (`childrenOf`, used by the census only).

- **Direct walk, allocation-free when unchanged.** `overlayLocalMultiUses`
  is a hand-written recursion returning `Maybe` — `Nothing` for an unchanged
  subtree — so parents are rebuilt only above a rewritten use. No PAP, no
  tuple, no rebuild on the 97.5 % of the tree that does not change.
- **Deferred to the outermost let-function.** At a let-function's completion,
  `flushLocalMultiEnrich` looks at the engine's `localMulti` stack (already
  pushed/popped around every let-function body, including local tail defs):
  if an enclosing let-function is on it, the instance names are recorded in
  that entry's new `pendingEnrich` field (`Engine.NumberMultiEntry`; the S
  record is at the runtime's 32-slot cap so the stack entry is where per-item
  state can go, and `retranslateAt` leaves the stack alone). The outermost
  let-function walks its body ONCE with every recorded group.
- **Lexically scoped bindings.** The walk binds each recorded group's
  `instance -> typeOf rhs` at the group's own `MonoLet` chain (`olmChain`:
  same recorded defName, RHS type identical to the type recorded at
  completion), so a sibling scope reusing a name binds its own value; Elm's
  no-shadowing rule makes the body-scoped binding exact.

### 2.1 Why the output is the same tree

The per-let scheme's observable behaviour, reproduced point for point:

| per-let scheme | deferred walk |
|---|---|
| a let's walk covered its body, not its own instance RHSs | own-group RHSs are walked with the OUTER environment (`olmRebuild`) |
| an enclosing let's later walk covered nested chains AND their RHSs | inherited names are in scope there |
| `annoByName` was built from the un-enriched instance RHS types | `Dict.get n groups` records `typeOf rhs` at completion, before any enclosing overlay |
| non-top chain members carried `typeOf` of the own-overlaid body | `memberType` in `olmGroup` |
| `letType` from the un-enriched body | unchanged (computed from `monoBody` before the flush) |
| lss off: identity | `flushLocalMultiEnrich` returns the body untouched |

Verified three ways (§3): a crafted corpus of every shape above, a unit pin,
and byte-identity of the self-compile output.

## 3. Verification

- **Crafted corpus** (nested chains, a let-function inside another's RHS,
  sibling scopes reusing a name for a function vs a plain value, an alias
  whose RHS is a bare use, a bare-use body, a tail-recursive local with a
  nested let-function, lambdas, HOF use, a five-deep chain): the unmodified
  native compiler and the fixed JS compiler emit **byte-identical** MLIR
  (16,353 B, sha256 `8798d1da…`); the report shows the walk engaged (14
  walks, 21 groups, chain depth up to 5, oldVisits 482 vs nodes 237).
- **Unit pin** `compiler/tests/TestLogic/Monomorphize/LssLocalMultiEnrichTest.elm`
  (8/8): under the solver with LSS on, every use of a `MonoDef`-bound local
  function satisfies `t == overlayAnnotations t (typeOf rhs)` under lexical
  scoping, with a non-vacuity guard (some checked binding has a set head).
- **Self-compile byte-identity**: `eco-fixed` (built from this source) and
  `eco-i31` (built from the unchanged source) run on the SAME pristine Sep-3
  source (`/work/eco-compiler-sep-3`, commit 218d1c77): see §4.
- **Unit suite**: 13,426 tests — all pass except 12 pre-existing typechecker
  failures: 11 POST_010 pins (`PostSolveNodeTypeGroundedTest` /
  `NodeVarConstrainedTest`, verified identical on the pristine 218d1c77 tree
  with a project rooted at that checkout) and `GoldenConstraintTest`
  "if-chain" — none touch the monomorphizer.
- **E2E** (`--target full`): see §4.

## 4. Results

(Same binary configuration as every measurement in the investigation:
`cumulative_env 17` flags, caps 8/512, `ECO_MONO_ENGINE=solver`,
`ECO_DISPATCH_STATS=1`, cold `eco-stuff`, one run at a time.)

### 4.1 Headline: same corpus, two binaries

| run | binary | source | wall | total dispatch `sat` | `traverseExpr` | minor GCs |
|---|---|---|---:|---:|---:|---:|
| before | `eco-i31` (unchanged source) | Sep-3 pristine | 15:41.49 | 8,223,895,629 | 3,338,666,092 | 3,537 |
| **after** | **`eco-fixed`** (this change) | Sep-3 pristine | **7:52.25** | **2,285,190,785** | **269,098** | **1,983** |
| Aug baseline | `eco-i31` | Aug-26 | 7:03.15 | 2,082,836,746 | 9,396,058 | — |
| after, report on | `eco-fixed` | Aug-26 | 7:18.33 | — | — | — |
| after, report on | `eco-fixed` | Sep-3 pristine | 8:21.45 | — | — | — |

- **Output byte-identical**: `eco-fixed` and `eco-i31` on the same pristine
  Sep-3 source both emit 15,695,083 B, sha256 `0e2e49463c4b616b…`.
- Wall −49.8 %; dispatch −72 %; `traverseExpr` 3.34e9 → 2.7e5 (the two other
  callers); minor GCs −44 %; peak RSS unchanged (11.62 GB — the working set is
  the front-end + shared mono, not this pass).
- The remaining Sep-vs-Aug gap (7:52 vs 7:03, +11.6 %) tracks the bigger
  input: +3.77 % source lines, +9.7 % dispatch (2.29e9 vs 2.08e9). The
  regression is closed; the compile is back at the Aug-26 level for the
  Aug-26 amount of work.
- Next on the profile after this change: `Terminal_Main_lambda_14930$cap`
  231,975,379 (10.2 %), `lambda_14926$cap` 4.2 %, `lambda_40114$cap` 3.7 % —
  a different investigation.

### 4.2 The mechanism census (`ECO_MONO_LSS_REPORT=1`, `e4a|*` cells)

| | Aug-26 source | Sep-3 source |
|---|---:|---:|
| outermost walks (`e4a\|walks`) | 534 | 561 |
| instance-def chains (`e4a\|groups`) — vs bpftrace entries of the old function | 683 (683) | 760 (764) |
| nodes the single walk visits (`e4a\|nodes`) — the new cost | 33,900 | 46,660 |
| nodes the per-let scheme visited (`e4a\|oldVisits`, Σ chain-body sizes) | 52,547 | 190,194 |
| old callback invocations, measured (dispatch census) | 6,882,339 | 2,266,918,179 |
| amplification: callbacks / oldVisits (the `traverseExpr` re-lift) | 131× | 11,919× |
| per-let re-walk factor: oldVisits / nodes | 1.55× | 4.08× |
| deepest chain (`e4a\|depth\|d`) | 7 | 18 |

The chain counts agree with the independent uprobe counts of the old
function's entries, so the census walks exactly the lets the old scheme did.

### 4.3 Gates

- Crafted corpus byte-identical (native unchanged vs JS fixed), unit pin 8/8,
  full unit suite 13,413 / 13,426 with the 12 pre-existing POST_010 failures
  (identical on pristine 218d1c77).
- E2E `--target full` (clean, rebuild, Stage 1 from this source, JIT E2E): **1,718 / 1,718 passed**.

## 5. Shape guideline (item 2)

None needed. With §7 the traversal is linear and the E4a pass is one linear
walk per outermost let-function, so a `let` block with 36 local helpers costs
36 chain members, not an exponential. For the record, the shape that tripped
the defect: a `let` block with N local functions nests N deep in the
monomorphizer (one `translateLocalMultiLet` per function), and Sep-3's
`renderLssReport` carries 36 (chain depth 18 at the mono level).

## 6. Traps met on the way

- `build-kernel/src` is a SYMLINK to `/work/compiler/src` and the project
  root is the CWD's `elm.json` — the `Main.elm` path argument does not select
  the source tree. Byte-identical output from a supposedly different tree is
  the tell.
- `uretprobe` on the eco binary SIGSEGVs the GC at self-compile scale
  (fine on a toy); count entries only.
- The engine's `S` record is at the 32-slot GC-scan cap: per-item state goes
  in `itemAux` (cleared/restored by `retranslateAt`) or, as here, on the
  stack entry it belongs to.

## 7. The traversal itself, fixed (same day)

`MonoTraverse.traverseExpr` was rewritten so that `traverseExprChildren`,
`traverseDef`, `traverseDecider`, `traverseChoice` and the list helpers all
take the USER callback and recurse through `traverseExpr f` as a saturated
direct call: one lift, once per node, bottom-up, evaluation order — and no
`traverseExpr f` PAP built per node (context.md §11 item 1). `traverseList`
is replaced by typed helpers (`traverseExprs`/`traverseKeyed`/
`traverseCaptures`/`traverseBranches`/`traverseEdges`); the fold family was
already single-lift and is untouched.

Pin: `compiler/tests/TestLogic/Monomorphize/MonoTraverseTest.elm` (5/5) —
callback visits == node count (from `childrenOf` and `foldExpr`) over a
12-deep let chain, a 10-deep case chain and a mixed tree; leaves seen left to
right before their parent; identity callback returns the same tree.

Gates, same protocol as §4: crafted corpus byte-identical; E2E 1,718/1,718;
`eco-fixed2` (built from this source by `eco-fixed`) on the pristine Sep-3
corpus: wall **7:52.48** (vs 7:52.25 — the two remaining callers were
negligible, as §4.1 predicted), output **byte-identical** to the pre-change
`probe-run.mlir` (so `remapLambdaIds`' double application had not been
changing the surviving numbering on this corpus after all), `sat`
2,284,597,112 (−594K), `traverseExpr` and `remapClosureLambdaId` **0**
dynamic dispatches (direct calls now), minor GCs 1,982.
Bootstrap fixed point (`eco-fixed3` built from `eco-fixed2`'s self-compile
reproduces it byte-for-byte): **REACHED** — `eco-fixed2`'s self-compile (v2b, 15,559,486 B) == `eco-fixed3`'s (v2c); and already `eco-fixed`'s compile of this source (v2) == v2b, i.e. the pre- and post-traversal-fix compilers agree on this source too.
Full unit suite: 13,431 tests, 13,419 pass; the 12 failures are the same pre-existing typechecker set as before either change (11 POST_010 `node types grounded` / `node vars constrained` pins, verified identical on the pristine 218d1c77 tree, plus `GoldenConstraintTest` "if-chain", also failing before this work).
