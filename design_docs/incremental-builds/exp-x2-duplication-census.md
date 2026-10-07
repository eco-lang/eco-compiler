# X2: Duplication census: what requester-owned instance placement costs

**Status:** run on 2026-10-06, from the baseline census of X1 (the same instrumentation,
`experiments/x12-inc-census.diff`). The analysis is `experiments/x12/analyze_x2.py`. Raw results are
in `/tmp/inc-exp/results/x12/x2-results.json`, `x2-table.txt` and `unit-size-dist.txt`.

**Question (02 §2.1, 07 §2):** under requester ownership, how many modules request each instance?
What do the placement variants cost in code size?

| Variant | Rule |
|---|---|
| **A** | per-requester copies |
| **B** | dominator sharing: shared when one module among {the generic's home, type-argument homes, lambda homes} transitively imports all the others |
| **C** | package pool: instances whose key mentions only package types and lambdas are shared once |
| **A+C**, **B+C** | combinations |

## Method

- **Input:** the post-GlobalOpt census of the compiler's own source: 32,739 specs, total cost
  1,948,482 (inliner cost measure).
- **Instances:** 25,839 (51.8 % of cost), by the X1 criterion.
- **Requesting modules:** propagated over references. An instance referenced only from other
  instances inherits their requesters; the roots are the home modules of non-instances.
- **Import graph for B:** parsed from the subject and package sources (transitive closure).
- **Code-size proxy:** Σ cost × number of copies.

## Results

**Fan-in is low.**
- 22,124 instances (**86 %**) have exactly one requesting module.
- The maximum is 72, e.g. `List.reverse @ List String` and `List.foldl` with `cons`.
- Package-only instances: 3,637, cost 129,867.
- Instances with an import dominator: 22,776.

| Variant | Cost vs today | Symbols (today: 32,739) |
|---|---:|---:|
| A: per-requester copies | **119.5 %** | 44,476 |
| B: dominator sharing | **101.7 %** | 33,455 |
| A+C: package pool + copies | **113.3 %** | 40,876 |
| B+C | 101.7 % | 33,390 |

The pool removes about a third of A's extra code.

**Most duplicated instances (under A).** Almost all are `elm/core` `Dict` internals at common key
types:

| Instance | Requesters | Extra cost |
|---|---:|---:|
| `Dict.balance @ (String, Int)` | 37 | +5,364 |
| `Dict.balance @ (String, ())` | 30 | +4,321 |
| `Dict.insertHelp @ (String, Int)` | 37 | — |
| `moveRedLeft` / `moveRedRight` / `removeHelp @ (String, Int)` | 20 each | — |

The others are pretty-printer instances (`List.foldrHelper`, `Internals.flatten`, `Pretty.join`
with the printer's lambdas: not package-only, but with a project dominator) and one large project
instance, `JavaScript.Builder.fromExpr` (2 requesters, +1,582).

**Largest single unit at baseline:**

| Rule | Largest unit |
|---|---|
| definition module | `List` 12.3 %, `Dict` 9.5 % |
| A | `Reporting.Error.Syntax` 4.4 % |
| B | 6.6 % |
| A+C | 4.6 % |

**Independent cross-check from X7.** On the mono graph, variant A gives ×1.32 specs and ×1.21
expression nodes. That is consistent with the +19.5 % cost here.

## What this means

1. **Duplication is affordable.**
   - The worst case (A, +19.5 % code) is acceptable for an incremental/dev profile.
   - A+C (+13 %) is the safe default: no cross-module ids for user instances (03 §2.2), and an
     append-only pool for package-only instances. The pool was never dirtied by X1's project
     edits.
   - B is nearly free (+1.7 %) and matches A's blast radius on the X1 corpus. But it has
     cross-module references to shared instances, so it needs stable ids (03 §2.1), and its churn
     from new requesters is unmeasured.
2. **Answering Q1 (07):**
   - Prefer **A+C** if stable cross-module ids should be avoided entirely.
   - Prefer **B(+C)** if the persisted id table (03 §2.1) is accepted anyway; its code-size cost
     is negligible.
3. **The `Dict` internals dominate duplication.** A cheap refinement is to put common package
   instances, such as `Dict` at `String` keys, in the pool even when one of the key types is
   user-defined. Or to accept B for those.
4. **Definition-module placement is the worst option** for unit balance (`List`/`Dict` units of
   9-12 %; see also X4's 48 s `List` unit) and for blast radius (X1 e3).

## Limitations

- The cost is the inliner's measure, not lowering time or bytes.
- Requester sets come from the final post-GlobalOpt graph, not from monomorphization's demand
  log. X7's demand-log ownership agrees: 10 % of specs have more than one owner.
- Under requester ownership, caller-shaped non-generic specs also move to requesters (X7). They
  are partly counted here through the "multi-spec global" and LSS-keyed criteria.
