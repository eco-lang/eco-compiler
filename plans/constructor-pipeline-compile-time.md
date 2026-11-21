---
status: done
updated: 2026-11-21
---

# Constructor-pipeline compile time

A measure-fix-remeasure pass over the compile time of the constructor optimisations
(plans/constructor-representation-levels.md, plans/constructor-representation-followups.md and
K1 `knownCtorCase`), from the source snapshot `repr-K`. Every step was measured with a candidate
compiler built by `eco-optK` from the edited source, and kept only if that compiler's self-compile
output was byte-identical to `eco-optK`'s on the same source (the fixed point).

## Where the time was (perf, `eco-optK` self-compile)

The `representation` step had grown from 1.8 s (end of §13 of the levels plan) to 3.6 s:

| window | time | what |
|---|---|---|
| meets + kernel visibility, first collection | ≈ 0.5 s | 75,461 meets, 31,050 of them move-only |
| erasure plan, meet translation | ≈ 0.3 s | `eraseTypeMaybe`/`mentions` on every meet |
| node rewrite | ≈ 2.2 s | erasure type rewrite; the nullable traversal visited every node mentioning a `Maybe` |
| F1 tagged-union choice | ≈ 1.0 s | kernel visibility and meets collected a second time |

`KnownCtorCase` took ≈ 0.12 s (a rebuilding walk of every node, discarded when nothing folds);
codegen setup built several whole-program tables more than once.

## Changes (all kept)

1. **Move-only meets are not collected.** Since F4 every consumer (EraseWrappers twice,
   NullableMaybe, TaggedUnions, `validate`) skipped them; `RepresentationMeets.collect` and
   `translate` now drop them (a meet the erasure makes move-only too), the five consumer checks and
   `EraseWrappers.Choice.skippedMoveOnly` are gone, and only the `inline.report` census collects
   them (`collectWithMoveOnly`). MONO_029/MONO_033 amended.
2. **`eqKeyLayout` rejects on unequal layout hashes** before `==` and the walk (equal keys have
   equal hashes; every composite is built by the hashing constructors).
3. **`exprMeets`** builds a `global->N` site string only for a meet, and each node's type once
   (a constructor's was built at every reference).
4. **Report lines only under `inline.report`** (`meetsVarCensus` walked every meet on every compile).
5. **F1 reuses the carried meets** instead of collecting them again; the kernel-visibility set was
   still recomputed on the final graph. Under validation, the tag choice from the carried meets is
   compared with one from a second collection.
6. **The nullable traversal visits only nodes with a `case` testing a nullable value**
   (`NullableMaybe.touchesNode`, reading decision trees), not every node mentioning a type named
   like a nullable one; `rewriteNodes` takes a node predicate.
7. **One descent for tuples and records in `eraseTypeMaybe`** (was `mentions` then `eraseType`
   per element, repeated at each level); `finish` keeps unchanged registry entries.
8. **Erasure memo.** `Traverse.mapNodeTypesMaybe` threads a state (it has no other user);
   erasure passes a memo keyed by spec hash and confirmed with `==` (the result keeps lambda sets
   and type-variable ids, which the keys ignore). Also fixes a double traversal of tuple elements.
9. **Codegen setup** builds `ctorBySpec`, `nullConsBySpec`, `constCtorBySpec` and `sretPromoted`
   once (four, two, two and two builds before); `nullableValueCall` checks the callee before the
   type lookup.
10. **`KnownCtorCase` skips nodes with no `let` of a known constructor** (read-only scan), so its
    rebuilding walk runs only where it can count or fold.
11. **`TaggedUnions.choose`** decides each type's exclusion once.

Tried and not kept: memoising the registry erasure in `finish` (flat, more code).

## Results

| candidate | `representation` |
|---|---|
| `eco-optK` | 3.6 s |
| after 1-6 (P1) | 2.6 s |
| + 7 (P2) | 2.0 s |
| + 9, 10 (P3) | 2.1 s (inline + simplify 967 → 922 ms) |
| + 8 (P4) | 1.4 s |
| final (`repr-CT3`, `eco-optCT3`) | 1.5 s |

Quiet-machine A/B, alternating, 3 runs each: `eco-optK` 79.35 / 77.22 / 76.35 s (median 77.22),
`eco-optCT3` 74.84 / 73.94 / 74.86 s (median 74.84): **−3.1 % wall**; `representation` 3.6 → 1.5 s,
`inline + simplify` ≈ 0.97 → 0.91 s, codegen ≈ 9.3 → 9.0 s, GC unchanged.

Gates (`repr-CT3`, chain against `eco-optK`): full 3,141/3,141, the E2E MLIR corpus byte-identical
to `repr-K` (0 of 1,556 files differ), elm-tests 22,043/0, bootstrap 8c/9b, AOT 1,513/1,513, stress
114/114 in both configs, TLA canary, fixed point, `ECO_REPR_VALIDATE` self-compile identical.

## Found on the way

- **`ECO_REPR_VALIDATE=1` failed on `test/eco-kernel/src/FileCanonicalizeEmptyTest.elm`**
  (pre-existing, §13 R2.4 of the levels plan): a second collection of the kernel-visibility set
  after erasure finds an instance the carried set lacks. The carried set is right and the
  recollection over-approximates, so the validator no longer compares the set (§15 of the levels
  plan). Computing the set from erased roots was tried and reverted. The search found an unrelated
  open bug: `Debug` printing of an erased wrapper over a nullable or tagged `Maybe`
  (`test/elm/src/EraseWrapperNullableDebugTest.elm`, XFAIL).
- The first attempt at change 5 also reused the carried set for tagging; it changed the output of
  11 eco/system E2E programs (one more type tagged) and was corrected before the final gate.
- Still costly but not changed: the node-loop pre-scan (`anyNodeType mentions`, ≈ 0.1 s) and the
  meet collection (≈ 0.45 s, mostly layout-key equality on equal types).
