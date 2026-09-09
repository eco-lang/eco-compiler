# Direct-call stamping declines and the generic call path

Two censuses of ONE fully-optimized self-compile, so the static reasons and the
dynamic weights describe the same program and join per `SpecId`.

## Provenance

| | |
|---|---|
| binary | `build/compiler/build-kernel/bin/eco-i35` |
| fixed point | **yes** — reproduces its own input byte-for-byte, so the per-`SpecId` join is valid |
| flags | shipping defaults, all LSS on (incl. LSS_038/039/040) |
| workload | the compiler's own front end, `compiler/src/Terminal/Main.elm` |
| static census | `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1` |
| dynamic census | bpftrace uprobes, caller-attributed by return address (`@gen[*(uint64*)reg("sp")]`) |
| date | 2026-09-08 |

Probes were placed on BOTH generic entry points.
**`eco_apply_segmentation_unknown` recorded ZERO events** — the under-saturated
route (which diverts to `eco_pap_extend` and never reaches the evaluator) is
never taken on this workload. The whole generic path is
`eco_apply_closure_eval`: **933,032,776 calls**. Wall under the probe was
15:05; the probe taxes every dispatch, so that number is not a wall figure.

## 1. Static — direct-call stamping declines

| outcome | sites |
|---|---:|
| `dispatchUpgraded` (stamped) | 17,174 |
| &nbsp;&nbsp;of which `stampedPapGlobal` (LSS_040) | 2,135 |
| &nbsp;&nbsp;of which `stampedStaged` / `stampedPapPrefix` | 678 / 3 |
| `declinedNoInstance` | **14,109** |
| `declinedBlocked` | **6,618** |
| `declinedBodyMismatch` | 1,194 |
| `declinedShape` (of which `arityOver` 379) | 685 |
| `declinedAbiMismatch` | 354 |

`noInstance` is dominated by a NON-failure:

| guard | sites | meaning |
|---|---:|---|
| `g2global` | 11,462 | **the success case** — mono substituted the global in, the call is ALREADY direct |
| `g1absentl` | 1,439 | `l\|` lambda member with no instance in the index |
| `g1kernel` | 770 | kernel member |
| `g1absentp\|papAmbiguous` | 201 | two specs match a layout-blind `p\|` key (correctly declined — E11) |
| `g1absentp\|papShapeMiss` | 88 | no spec of the global has the right shape |
| `g1absent?` | 108 | member with no recorded kind |
| `g1accessor` | 37 | accessor member |
| `g1absentp\|papChar` | 4 | `MChar` in the bound prefix |

So the real remaining static population is `blocked` (6,618) and `g1absentl`
(1,439), not the 14,109 headline.

## 2. Dynamic — who calls the generic path

Grouped by WHY the site is generic:

| group | events | share |
|---|---:|---:|
| C. IO monad spine (andThen / map / traverse) | 370,949,194 | 39.8% |
| D. Elm lambda (mostly IO continuations) | 247,325,530 | 26.5% |
| B. C++ kernel calling an Elm closure | 115,980,848 | 12.4% |
| A. Runtime re-entry (over-application) | 111,208,149 | 11.9% |
| E. Elm fold / collection callbacks | 61,403,717 | 6.6% |
| F. Other Elm specs | 26,165,338 | 2.8% |
| **TOTAL** | **933,032,776** | 100% |

### Top 20 hosts, with their static decline reasons

| events | share | live sites | host | static declines at this host |
|---:|---:|---:|---|---|
| 234,751,320 | 25.2% | 36 | `System_TypeCheck_IO_andThen` | `blocked`=105, `noInstance`=85, `stampedPapGlobal`=28, `bodyMismatch`=20 |
| 99,010,065 | 10.6% | 5 | `System_TypeCheck_IO_map` | `blocked`=37, `noInstance`=34, `stampedPapGlobal`=24, `multi2`=1 |
| 91,978,380 | 9.9% | 1 | `eco_apply_closure_eval` | — |
| 55,026,399 | 5.9% | 1 | `_ZL8foldImplN3Elm4HPtrES0_S0_b` | — |
| 36,101,180 | 3.9% | 1 | `Elm_Kernel_JsArray_initialize_Int` | — |
| 28,494,528 | 3.1% | 2 | `Dict_foldl` | `stampedFlat`=279, `arityOver`=23, `bodyMismatch`=6, `stampedPapGlobal`=2 |
| 23,782,575 | 2.5% | 28 | `List_foldrHelper` | `stampedFlat`=6230, `stampedPapGlobal`=900, `bodyMismatch`=850, `abiMismatch`=290 |
| 21,110,849 | 2.3% | 1 | `Terminal_Main_lambda_15449` | — |
| 19,031,770 | 2.0% | 1 | `kernelListMapN` | — |
| 15,982,344 | 1.7% | 1 | `eco_apply_closure_typed` | — |
| 15,624,578 | 1.7% | 1 | `Terminal_Main_lambda_15580` | — |
| 15,428,652 | 1.7% | 1 | `Terminal_Main_lambda_15630` | — |
| 15,428,635 | 1.7% | 1 | `Terminal_Main_lambda_15631` | — |
| 14,219,914 | 1.5% | 1 | `Terminal_Main_lambda_15106` | — |
| 14,219,914 | 1.5% | 1 | `Terminal_Main_lambda_15099` | — |
| 14,199,503 | 1.5% | 1 | `Terminal_Main_lambda_8739` | — |
| 11,817,794 | 1.3% | 1 | `System_TypeCheck_IO_traverseListGo_$_19694$sret` | — |
| 10,145,538 | 1.1% | 5 | `System_TypeCheck_IO_mapMGo_` | `noInstance`=1 |
| 9,591,070 | 1.0% | 1 | `Terminal_Main_lambda_15567` | — |
| 9,591,070 | 1.0% | 1 | `Terminal_Main_lambda_15575` | — |

A `—` on a `lambda_*` row is a JOIN ARTIFACT, not an absence: `byHost` keys
declines by the enclosing spec's HOST GLOBAL, and a lambda's own symbol does
not demangle to that key. Those rows' declines are counted under their
enclosing module's global.

### Hottest individual call sites

| events | share | site |
|---:|---:|---|
| 91,978,380 | 9.9% | `eco_apply_closure_eval+0x820` |
| 55,026,399 | 5.9% | `_ZL8foldImplN3Elm4HPtrES0_S0_b+0x1f7` |
| 36,101,180 | 3.9% | `Elm_Kernel_JsArray_initialize_Int+0x235` |
| 26,361,474 | 2.8% | `System_TypeCheck_IO_andThen_$_19506+0xdc` |
| 26,361,474 | 2.8% | `System_TypeCheck_IO_andThen_$_19506+0x61` |
| 25,139,642 | 2.7% | `System_TypeCheck_IO_andThen_$_19658+0xc3` |
| 21,110,849 | 2.3% | `Terminal_Main_lambda_15449+0x136` |
| 19,031,770 | 2.0% | `kernelListMapN+0xb7c` |
| 17,034,656 | 1.8% | `System_TypeCheck_IO_map_$_19665+0xa8` |
| 15,982,344 | 1.7% | `eco_apply_closure_typed+0x14` |
| 15,624,578 | 1.7% | `Terminal_Main_lambda_15580+0x8b` |
| 15,624,578 | 1.7% | `System_TypeCheck_IO_map_$_19571+0x61` |

## 3. Why the top callers do not reach the direct path

### The IO monad (groups C + D, ~66%) — structural, not an analysis gap

`System.TypeCheck.IO` is the compiler's shared state monad, and
`IO a = State -> (State, a)`: **every IO value is a function**, so binding one
means applying an unknown function to the state.

```elm
andThen f ma s0 =
    let ( s1, a ) = ma s0 in
    f a s1
```

Read out of the emitted MLIR for `System_TypeCheck_IO_andThen_$_19506`:

```mlir
%0 = "eco.papExtend"(%arg1, %arg2) {_call_kind = "segmentation_unknown"}  ; ma s0     GENERIC
%3 = "eco.papExtend"(%arg0, %2)    {_call_kind = "singleton_fast",        ; f a       STAMPED
       _fast_evaluator = @Terminal_Main_lambda_15466$cap, ...}
%4 = "eco.papExtend"(%3, %1)       {_call_kind = "segmentation_unknown"}  ; (f a) s1  GENERIC
```

**The continuation `f` IS resolved and stamped.** What stays generic is:

1. `ma s0` — `ma` is a PARAMETER. Its lambda set is the union of every IO
   action ever passed to that spec. It is genuinely not a singleton, so no
   increase in analysis precision makes it one.
2. `(f a) s1` — `f a` mints a NEW closure at run time; the site cannot know
   which.

Exactly two generic dispatches per `andThen`, which is why the two hot sites
carry **26,361,474 events each — identical to the digit**.

This is not reachable by LSS. It needs inlining of `andThen` chains,
defunctionalizing `IO`, or direct state-passing — the
`plans/io-monad-dispatch-reduction.md` arc, which already took −43 % this way.

### A. Runtime re-entry, 111.2 M — not a call site at all

`eco_apply_closure_eval` calling **itself** 91,978,380 times is
`runtime/src/allocator/RuntimeExports.cpp:2240`: an OVER-APPLIED call
saturates the closure, then re-enters with the remaining arguments. One source
call, two dispatches. `eco_apply_closure_typed` (16.0 M) is the same shape one
level up.

### B. C++ kernel boundary, 116.0 M — invisible to AbiCloning by construction

`foldImpl` (55.0 M), `Elm_Kernel_JsArray_initialize_Int` (36.1 M),
`kernelListMapN` (19.0 M) are C++ kernels invoking an Elm closure. There is no
Elm call site for the pass to stamp.

### E. Folds, 61.4 M — already largely won

`List.foldrHelper` shows `stampedFlat`=6,230 against 653 live sites and
`Dict.foldl` `stampedFlat`=279: LSS_039 converted these. What remains is the
residue, not the population.

## 4. What is left on the table

Ranked by size against tractability:

| # | target | weight | why it is tractable (or not) |
|---|---|---:|---|
| 1 | **Over-application re-entry** | 92.0 M (9.9 %) | The compiler already knows statically which sites over-apply — that IS `arityOver`, and LSS_039 peels the type there. Emitting the saturating call plus the residual application as two ops, instead of routing both through the runtime, removes one dispatch per over-applied call. A codegen change, not a rewrite. **Unexamined.** |
| 2 | **Kernel callback boundary** | 116.0 M (12.4 %) | Give the hot kernels a typed/fast callback entry, or let the stamp cross into them. Well-defined, larger change. |
| 3 | **IO monad** | 371 M + continuations | Largest by far, but not an LSS problem — inlining / defunctionalization, and the arc that owns it has already banked −43 %. |
| 4 | **`g1absentl`** | 1,439 sites, weight UNMEASURED | The `l\|` lambda members with no instance — the direct successor to the `p\|` work. **Census before opening**: this arc has mispredicted weight from site counts four times. |
| 5 | `blocked` (LSS_018 μ-tie) | 6,618 sites, weight UNMEASURED | Biggest static decline class after the `g2global` non-failure. Force-blocked for soundness; any repair needs the μ-tie argument revisited, so it is a design question, not a fix. |

**Recommendation.** Take #1 first: 9.9 % concentrated in a single runtime
function, the static signal already exists, and it is codegen rather than
analysis. #4 needs one census line before it can be judged at all.

**Do not** read #3's 39.8 % as an LSS opportunity. The stamp is already firing
on the half of `andThen` that can be resolved; the other two applications are
what the representation costs.
