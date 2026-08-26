# LSS injection completeness: total member injection over the producer forms

**Status: PLANNED (2026-08-26).** Supersedes the deleted
`plans/lss-pap-argument-members.md` outline (argument-scoped, never
implemented) — the scope, the rationale, and the acceptance criteria are all
materially different: this is a SOUNDNESS-bearing paper-fidelity plan with a
totality instrument, not a reach lever.

**One sentence.** Make every arrow-typed PRODUCER inject a lambda-set member —
the paper's own soundness mechanism — starting with the one known-missing form
(partial applications, expression-level), and build the census that turns
"totality" from an argument into a number whose zero licenses solver-root
sharing with no widening guard at all.

---

## §0 Why — the miscompile, and the paper argument

**The crash this closes the door on.** The `arrowSolverRoots` root cause
(`plans/lss-solver-root-signature-identity.md` §3 P0, established 2026-08-26):
in `\flg -> if flg then (::) x else identity`, the bare `identity` injects
`g|Basics.identity` (position-independent since `refIdentity`) while the
`(::) x` PARTIAL APPLICATION injects **nothing**. The branch join yields the
locally-false set `{identity}` — which per-occurrence slot fragmentation
quarantines at shipping defaults, and which solver-root sharing delivered to a
consumer, where devirt compiled `Task.map f` into the identity map
(`\a -> succeed a`, capture elided) and the compiler could no longer find its
own source files.

**The false sets exist at DEFAULTS today.** Fragmentation quarantines them; it
does not make them honest. Every one-sided join in the program follows the
same line: since `refIdentity`, bare references inject position-independently
and partial applications inject nowhere.

**The paper's answer is TOTALITY, not widening** (user-directed correction,
2026-08-26 — "widening to ⊤ is not part of LSS"). L^src has no currying: what
Elm writes `(::) x` the paper can only write as an explicit λ, and **every
abstraction self-injects** — Fig. 6's 𝒬 adds `λ[…] ⋸ α` per lambda term, no
exceptions. The false singleton cannot form; no guard is ever needed. Total
injection is the paper's soundness mechanism, and it is finitely enumerable
over Eco's producer forms because the type system enumerates them (§1).

**The retraction that reshaped this plan:** the old outline's soundness note
("`readPointCell` returns an inner lambda, no sound member exists") was read
as proof that enumeration can never reach totality. Wrong — it conflated "no
sound `g|` member" with "no sound member". The paper's element for an
inner-lambda return is THE INNER LAMBDA ITSELF, and Eco already injects it:
`l|` members, kept by `selfIdOf`'s filter ("Inner-lambda ids are NOT
filtered"), measured carrying at the residual ordinal (GAP-2 §2.6b row 11:
`readPointCell / UnionFind.get / UnionFind.repr / IO.pure` all read
`ord0: m=1,l`). A later AbiCloning DECLINE does not undo the soundness job —
any honest second member kills a false singleton.

---

## §1 The invariant and the producer enumeration

**INVARIANT (the paper's, made explicit for Eco): a lambda-set class is
devirt-complete iff every producer position whose value can flow into it
injected a member.** Occurrence identity enforced a weaker accidental form
(write-locality); root sharing needs the real one.

| producer form (TOpt) | paper's rule | Eco status 2026-08-26 |
|---|---|---|
| lambda literal (`Function`/`TrackedFunction`) | λ self-injects | ✓ `l|` (LSS_017 qualified at translate; raw in signatures) |
| bare `VarGlobal`/`VarEnum`/`VarBox`/`VarCycle` | `d⟨σ̄⟩` + Q | ✓ `g|`/`c|`/`k|` (kernel-alias fold), position-independent since `refIdentity` |
| **partial application of a known global** | *is* a λ — self-injects | ✗ **THE GAP — this plan's Phase 1** |
| partial application of an UNKNOWN callee | is a λ | ✗ deferred: residual set = callee's set (LSS_013 "a PAP of m is m" as TRANSPORT); counted by the census, out of v1 scope |
| full call returning a function | callee's Q at the result | ✓ via signature facts at the residual ordinal; TOTALITY UNPROVEN — the census's `carried` bucket |
| branch/case results | joins | ✓ `joinCfHub` — honest iff the branches injected (inherits from the forms above) |
| container/field/ctor-payload reads | set rides the element TYPE | ✓ slots exist inside container types; store-side honesty inherits from producers |
| kernel/FFI-produced closures | no paper counterpart | **⊤ — the one PERMANENT boundary** (parent register §3.6; excluded from the totality target) |

**Zero-modulo-kernel on this table is the condition under which root sharing
needs no guard** — the class-level tripwire (R2 in the solver-root plan)
exists only until the census proves it, plus permanently at the kernel
boundary.

---

## §2 Design

### §2.1 Phase 1 — expression-level PAP injection (the known missing form)

When a `TOpt.Call` has a known callee (`VarGlobal`/`VarEnum`/`VarBox`/
`VarCycle`) and `supplied < declared`, the expression's runtime value IS a PAP
of that callee, and the callee's member is sound on the residual arrows —
LSS_013's arity bound licenses exactly this ("a PAP of member m is m", design
OQ4, rated DIVERGENT-but-sound in the fidelity mapping as Eco's flavour of the
paper's staged-lambda element).

**Where — the `classifyRef` template, at the EXPRESSION, not the argument.**
`Translate.classifyRef` (§5.4.5 of the parent register) already does exactly
this shape for bare references: load the type, inject via
`injectArgLambdaMember` (kernel-alias fold included), zonk the answer back.
Phase 1 is the same movement for the partial-Call result path in
`translateGlobalCall`'s partial branch: inject into the loaded result-type
slots at depth `declared − supplied`, via `injectSpineMemberId`
(`LssInfer.elm:2340`) with the arity from `declaredArityOf`
(`LssInfer.elm:2144` — the TrackedFunction arity-walk fix is landed and gets
its unit pin here, since this is its first soundness-bearing consumer).
Position-independence is the point: a branch result, a stored element, and a
call argument all pass through the expression's own translation.

**Member identity**: the SAME mint family as the bare-reference path —
`standaloneArgMember`/`standaloneArgKernelMember` with `kernelAliasOf`, so
`(::) x` yields `k|List.cons` (one identity per global; a split `g|`/`k|`
identity would join to a 2-set and kill singleton consumers — the E9.2
lesson). Provisional ids ground at zonk per LSS_019.

**Inference-side twin**: the same classification in `LssInfer.walkExpr`'s
Call handling, injecting into the loaded `meta.tipe` of the Call node — so
producer signatures that RETURN partial applications carry the member at the
residual ordinal, keeping the two sides in the `spineDepthForGlobal` lockstep
discipline.

**Flag**: `lss.papMembers`, env `ECO_MONO_LSS_PAP_MEMBERS`, hash token
`lssPM=` (verified free), DEFAULT-OFF until the battery.

### §2.2 Phase 0 — the injection-totality census (build FIRST)

Report-gated (`lss.report`), `ARGF`-row plumbing (`bumpArgFlowCensus`), zero
default-path cost, inertness proven by byte-identity as §5.1 did for `Q`.

At translation of every expression whose type's HEAD is an arrow, classify:

```
inj|<form>|<verdict>    form    ∈ lambda, ref, papKnown, papUnknown,
                                  callResult, branch, read, kernel, other
                        verdict ∈ injected      (a member write happened here)
                                  carried       (callResult: the callee sig owns it)
                                  carriedTrivial(callResult via a TRIVIAL sig — the
                                                 unproven-totality bucket, split out)
                                  none          (a producer that injected NOTHING)
```

**`inj|*|none` summed over non-kernel forms IS the totality number.** The
existing ArgStash `sat|`/`arity|` census (Translate.elm:3133-3203) already
computes `supplied`/`declared`/`partial` — the classifier reuses it. Expected
at HEAD: `papKnown → none` ≈ the old census's 2,475 argument sites plus the
branch/store population the argument count never saw (this census is the first
instrument that can see them); after Phase 1, `papKnown|none` must read **0**.

The `carriedTrivial` bucket is deliberately split out: it is the "full-call
results, totality unproven" row of §1, and it feeds the follow-on question
(are trivial-signature callees' results reaching devirtable positions?)
without blocking this plan on it.

### §2.3 What Phase 1 does to sets — expected, and how it is judged

Residual arrows that today read `var` gain a member (analysis coverage UP —
gate 0); joins that today publish one-sided sets become honest 2-sets
(`kN` up; some fast-dispatch stamps decline — **recorded, not gated**, per the
standing gate-0 policy). The combinator population from the old census
(`composeL` 216, `composeR` 157, `always` 77, `flip` 73, `Tuple.pair` 32 …,
87.7 % at residual depth 1) all become member-carrying.

---

## §3 Phases

**P0 — the census, instrument-only.** Gate: byte-identical `.mlir` census
on/off; the `inj|` table lands in the report. Deliverable: the HEAD totality
number, by form — §1's table turned into measurements.

**P1 — expression-level PAP injection**, flag-gated default-off. Gates:
flag-off byte-identity (two-binary rail); flag-on `inj|papKnown|none = 0`;
§2.5 ledger `RECONCILES=yes`.

**P2 — the battery** (§4) and the flip decision on the day's evidence.

**P3 — the end-to-end soundness probe, and it is this plan's sharpest
acceptance test:** rebuild the `arrowSolverRoots` reproducer arm
(`+refIdentity +ARROW_ROOTS +papMembers` self-compile → lower → **RUN**). The
false singleton must read `{k|List.cons, g|identity}`, `Task_map`'s wrapper
must keep its capture, and the binary must complete a `make`. This does NOT
flip `arrowSolverRoots` — it proves the injection kills the recorded
miscompile class at its origin. (The `Tiny.elm` reproducer recipe and
`ECO_HOME` isolation are in the solver-root plan's P0.)

---

## §4 Gates

1. **Gate 0 — analysis coverage must rise** (the standing programme gate):
   `coverage:` line, positions. Residual-arrow `var` positions become
   members; expect k1+kN up.
2. `inj|papKnown|none = 0` flag-on; the census total is the plan's headline.
3. §2.5 ledger `RECONCILES=yes`; flag-off byte-identity; census-on/off
   byte-identity (P0).
4. Fast-dispatch census on the Run-AE/AO rail — RECORDED, NOT GATED; honest
   2-sets legitimately decline stamps. Report `stampedStaged` /
   `declinedNoInstance` beside it.
5. **Self-compile lowers AND the lowered binary RUNS a `make`** — the
   solver-root plan's gate 5b, born from exactly this bug class.
6. elm-tests at the pre-existing set; E2E `--target full`. Unit pins:
   `declaredArityOf` reads composeL=3 / always=2 (the TrackedFunction fix's
   first soundness-bearing consumer); a `step/run`-shaped probe pinning the
   2-set (the minimal crash shape from the root-cause writeup).
7. Q verifier (`ECO_MONO_LSS_QCENSUS=1`): injection goes through
   `unifySlotWithSetC`, so recording is automatic — `REPRODUCES=yes`,
   `diverge=0` confirms no bypass was introduced.
8. Wall/GC per `benchmarks/lss-opt.md`.

---

## §5 Soundness

- **The member is right by LSS_013**: supplied < declared ⇒ the residual
  arrows lie within the declared arity ⇒ the PAP dispatches the callee's
  staged code. Contrast `readPointCell ref` — a FULL call returning an inner
  lambda: stamping the GLOBAL there would be unsound, and is out of this
  arm's classification by the `supplied < declared` guard; its sound member
  (the inner lambda's `l|`) already travels via the signature channel.
- **A wrong `g|`/`k|` is the representative-hijack miscompile class** — the
  pins must cover both the stamp-correct direction (singleton devirt fires
  and is right) and the decline direction (2-set refuses).
- **Unknown-callee partials are OUT of v1** and counted by the census. Their
  paper-faithful treatment is transport (residual set = callee's set), not
  injection; until built, they are exactly what the class-level tripwire in
  the solver-root plan exists to catch.

---

## §6 Non-goals

- **Flipping `arrowSolverRoots`** — stays with
  `plans/lss-solver-root-signature-identity.md`; P3 here feeds its P0 exit
  criteria but does not ship the flag.
- **R2-as-semantics** — the class-level guard remains a verifier-era tripwire
  defined in the solver-root plan; this plan is what retires it.
- **Removing kernel/FFI ⊤** — permanent boundary, excluded from totality.
- **`carriedTrivial` repair** — measured here, fixed elsewhere if the number
  says so.
- **Sum lowering** — the consumer; unchanged.

---

## §7 Relationship to other plans

- `plans/lss-solver-root-signature-identity.md` — BLOCKED on its P0, whose
  repair path is this plan (R1-as-totality) plus its own tripwire; P3 here is
  the shared acceptance probe.
- `plans/lss-gap2-callarg-transport.md` — supplies the ArgStash/census
  plumbing and the `declaredArityOf` fix this plan reuses.
- The deleted `lss-pap-argument-members.md` outline — superseded; its census
  numbers (2,475 argument sites; combinator head 100 % partial; 87.7 % depth 1)
  remain valid sizing input and are quoted in §2.3.
