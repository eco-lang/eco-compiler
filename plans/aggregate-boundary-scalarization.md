---
status: not-started
updated: 2026-10-30
---

# Outline: scalarize value aggregates at function and block boundaries

**An outline, not scheduled for this release.** It records the problem and the intended fix so a
future release can pick it up. This release only guards the case with a hard compile error
(plans/review-likely-bugs-fixes.md, step 3c).

## Problem

Value aggregates (REP_AGG_001) lower to LLVM struct values whose fields may be
`ptr addrspace(1)`: `!eco.tuple2`, `!eco.tuple3`, `!eco.record`, `!eco.custom`, `!eco.cons` and
`!eco.closure_env`.

RS4GC (LLVM's statepoint rewriting) relocates GC pointers held in SSA values, but not GC pointers
inside a struct value. When an aggregate holding a GC pointer is live across a safepoint as a
struct, the pointer inside it is stale after a moving collection. The safepoints include:
- an allocation's slow path;
- a call;
- the function-entry capacity check (`eco-cap-budget`).

Today this is avoided only by what the front end happens to emit:
- `FoldExtractValuePass` (EcoPtrIntVerify.cpp) folds `extractvalue` back through the
  `insertvalue` chain that built the aggregate in the same function;
- aggregate-returning functions use `$sret` memory (CGEN_064);
- no function argument, function result, block argument or region result carries an aggregate.

The 2026-10-30 census of the compiler's self-compile found 2,109 aggregate constructions and no
such boundary. It was found through `make.closure` with an env argument (cpp-review-bugs.md,
"make.closure keeps an env aggregate ...") and reproduces with a plain tuple argument:
`ECO_FCA_SCAN=1` flags it.

This release turns the case into a hard compile error. That is a guard, not a fix: it also blocks
optimisations that want aggregates to cross boundaries, notably:
- closure-env promotion (T1.3.4, `plans/opt-tier1-aggregate-promotion.md`, deferred);
- passing tuples and records to functions in registers.

## Intended fix: scalarization

Flatten every aggregate-typed boundary into its scalar fields before RS4GC, so each GC pointer
becomes its own SSA value that RS4GC relocates:
- **Function signatures.** An aggregate parameter becomes N parameters, one per field, recursively
  for nested aggregates. An aggregate result becomes N results, through the existing multi-result
  lowering (`$sret` / CGEN_064) or a struct return of scalars. Rewrite every call site to match.
- **Block and region boundaries.** `scf.if` / `scf.while` / `eco.case` results and `cf` block
  arguments of aggregate type become one argument per field. This is SROA across control flow,
  done at the MLIR level where the aggregate types are still known.
  - Today an aggregate through an `scf.if` result is not lowered at all, even with only unboxed
    fields: EcoToLLVM does not convert the scf.if's result types. This was seen on 2026-10-30 while
    writing `test/codegen/aggregate_boundary_unboxed_ok.mlir`, so this part must also make that
    conversion work.
- **Address-taken functions and closures.** Indirect calls, PAPs and `$cap` evaluators use the
  closure capture ABI (REP_CLOSURE_*), where captures are stored in heap slots with slot kinds.
  - An aggregate crossing that ABI must be boxed (`eco.to_heap`), or its fields must become
    individual captures, which needs a per-field capture kind.
  - This is the riskiest surface in the backend and is the part T1.3.4 needs.

Where in the pipeline:
- **Option A: an MLIR pass** after the eco-level aggregate passes and before EcoToLLVM. It sees eco
  types and slot kinds. Preferred.
- **Option B: an LLVM pass** before RS4GC, generalising FoldExtractValuePass to arguments and phis.
  It sees only struct types, and loses the eco kind information the capture ABI needs.

## Questions to settle first

- **Cost.** Flattening raises argument counts. Measure register pressure and spills on the
  self-compile against today's front end, which never passes aggregates; the benefit only shows
  once producers exist.
- **Calling-convention limits.** Very wide records (up to 2,047 fields, wide objects) cannot be
  flattened into parameters. Choose a threshold above which an aggregate stays boxed.
- **Interaction with LSS fast dispatch and `$sat` / `$cap` signatures.** These ABIs are stamped and
  verified (CGEN_080, REP_ABI_*), so a flattened signature must flow through the stamps.
- **Debug printing.** `eco.dbg` and the type table describe aggregate-typed values, so decide how
  flattened values are described.
- **The invariants to amend:** REP_AGG_001, CGEN_061 and CGEN_064, plus the restriction this
  release adds (removed by this work).

## Tests to carry over

- `test/codegen/make_closure_env_arg_fca.mlir` and its tuple / `scf.if` siblings, which this
  release changes to expect the hard error, go back to asserting `FCA-SCAN: clean` and correct
  runtime behaviour.
- New JIT fixtures that force a collection while an aggregate with a nursery String crosses:
  - a call boundary;
  - an `scf.if` boundary;
  - the entry capacity check.

  Each checks the String's content afterwards.
- An E2E test once a front-end producer exists (for example, after T1.3.4).

## Exit criteria

- The lowering's hard error is deleted.
- Aggregates cross function and block boundaries with `ECO_FCA_SCAN` clean.
- `full`, the bootstrap fixed points and `fe-opt-loop.md` regression rows are FLAT or better.
