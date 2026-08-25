module Compiler.MonoSolver.KernelSetFacts exposing
    ( ParamSetFlow(..)
    , KernelPlan
    , LicenseScope(..)
    , TypeShape(..)
    , License
    , licenseApplies
    , shapeOfAnnotation
    , KernelSetFact(..)
    , factFor
    , licensedFiles
    , rows
    )

{-| LSS_021/LSS_022 — per-kernel SET-FLOW facts (GAP-4,
`plans/lss-fidelity-3-signature-flow-completion.md` Phase F for the
positional v1, `plans/kernel-parametricity-license.md` for the license
tier).

**Three tiers, strongest first.**

1.  `TypeFaithful` (LSS_022, the *parametricity license*): an audit has
    established that every function value entering or leaving this kernel
    flows only along the paths its Elm TYPE's variable-sharing graph
    describes, that the kernel retains nothing across the call, and that it
    introduces no function-valued inhabitants of its own. Both consumers
    then skip the LSS_004 poison ENTIRELY and let ordinary instantiation +
    unification do all the transport — the shared `a`/`b`/`c` Points in
    `(a -> b -> c) -> List a -> List b -> List c` ARE the flow edges. No
    positions, so no arity rule: a partial kernel application unifies
    against however many args are present and is shape-correct by
    construction.

2.  `Positional` (LSS_021, v1): a per-parameter, arity-aligned row saying
    which functional params the kernel merely APPLIES (`PSFApplies` — their
    arrow slots need no poison), which TUNNEL to the result (`PSFTunnels`),
    and which stay OPAQUE (`PSFOpaque` — poison). Used where the license
    could not be granted for the whole surface but some positions are
    certifiable.

3.  No row at all ⇒ LSS_004 full poison. That is the default for every
    unaudited kernel, every arity-mismatched or early-spine boundary, and
    every REJECTED kernel below.

**Why removing poison is the safe direction.** An unconstrained FunL slot
reads back `LTop` at zonk (`Store.zonkSetSlot`'s FlexVar arm), so a licensed
position that receives no flow still reads ⊤ — never a false empty set. The
only hazard is a *populated-but-incomplete* set: caller knowledge flows in,
the kernel secretly adds or reroutes an inhabitant the type does not account
for, and a downstream singleton consumer stamps the wrong function. That is
exactly what the §2 checklist excludes.

Deliberately parallel to `Compiler.GlobalOpt.KernelFacts` (same audit
discipline: `( Name, Name )` keys, MANDATORY C++ evidence anchors,
unknown ⇒ consumer keeps its own default) but a SEPARATE table — each audit
stands alone; this one is the set-flow axis, that one the borrow axis.

Both consumers — `LssInfer.kernelCallBoundary` (inference side) and
`Translate.poisonKernelArrowsThen` (translation side) — consult THIS module
through the single entry point `factFor`: the LSS_006-style two-sided
discipline; the sides must never disagree about which arrows poison.


## Evidence format (mandatory, plan §2.6)

    <class: vacuous|cheap|full> | entry: <file>:<fn>:<lines>
    | helpers: <file>:<fn>[, ...] | type: <file>:<line>
    | B1: <decisive lines> | B2: <scan result> | B3: <scan result>
    | audited: <date>

`class` records how much of the checklist was live:

  - `vacuous` — the whole Elm type has NO function-capable position (no
    arrows, no type variables anywhere: `String.length : String -> Int`).
    B1/B3/B4/B5/C1 are vacuous and the audit reduces to "the annotation is
    the real type" (A2 + A3).
  - `cheap` — type variables but no arrow parameters (`Utils.equal :
    a -> a -> Bool`). The `a` positions CAN hold closures, so B1/B2/B3 are
    live; C1 is usually vacuous ("result inert").
  - `full` — arrows in the type. The whole checklist runs.

**Soundness rule (unchanged from LSS_021, widened by LSS_022):** a wrong
license is a false-singleton miscompile — the same failure class as a wrong
`PSFApplies`, widened to every position at once. A missing license costs only
precision. Any checklist doubt ⇒ `Positional` or no row at all.

**License rot.** A license is a contract on C++ that this module cannot see.
Each licensed row lists the C++ files its grant depends on (`files`), and
`compiler/src/Compiler/MonoSolver/kernel-license-manifest.txt` pins their
sha256; `test/scripts/check-kernel-license-manifest.sh` fails the build when
a listed body changes without a re-audit. Bumping a manifest hash without
advancing the row's `audited:` date is the violation reviewers must catch.


## REJECTED — never license these

The 2026-08-20 survey covered all 338 kernel entry points across
`elm-kernel-cpp/` and `eco-kernel-cpp/`. Three predicates account for nearly
every refusal, and they are worth applying MECHANICALLY, before any prose
reasoning:

**1. CROSS-CALL retention — a value one call stores that a DIFFERENT call
reads.** This is the predicate; fieldless-ness is not.

CORRECTED 2026-08-25. This rule previously read "nullary-constructor
carriers: `type Task err ok = Task` (Platform.elm:83), `Cmd msg`, `Sub msg`,
`Decoder a`, `Expect msg`, `Resolver x a` … declare NO fields, so their type
parameters are PHANTOM while the C++ fills them with payload — refuse."
**That over-refuses, and it is why `Scheduler.succeed/fail/andThen/onError`
sat on the REJECTED list until 2026-08-25 with no soundness fact behind
them.** Passing a value THROUGH an opaque carrier is not retention in any
sense the analysis cares about: `Task.succeed f` hands back exactly `f`, and
`a` is the SAME type variable in the parameter and in `Task x a`, so ordinary
unification carries the set across. It is structurally
`JsArray.singleton : a -> JsArray a`, which has been licensed `Transports`
since the original audit. The two differ only in whether the Elm declaration
happens to name a field (`type JsArray a = JsArray a` does,
`type Task err ok = Task` does not) — a syntactic difference with no
consequence for set flow, because nothing in Elm can construct or match a
bare `Task` (`Platform` exposes `Task`, NOT `Task(..)`) and mono therefore
never forms a representation for it at all.

What actually disqualifies is an edge the TYPE cannot name, and the sharp
form of that is CROSS-CALL: the value goes into runtime storage on call A and
comes back out at a position reached by call B, so no amount of variable
sharing in A's type describes where it went.

  - **Refuse:** `Platform.sendToApp`/`sendToSelf` — `rawSend`
    (`Scheduler.cpp:476-484`) does `mailboxPushBack` + `enqueue`, and the
    message re-emerges at a DIFFERENT call's `update`/`onSelfMsg`.
    (`sendToApp` independently fails A3: declared `void` in
    `PlatformExports.cpp:44` against `Router msg a -> msg -> Task x ()`.)
  - **Refuse:** `MVar.read`/`take` — the canonical case; their result comes
    from a different call's `put`, so C1 has no incoming edge at all.
  - **Refuse:** effect managers, ports, TSFN/JS registration, VirtualDom's
    `static vnodeRegistry` — all the same shape.
  - **License:** `Scheduler.succeed`/`fail`/`andThen`/`onError` — the only
    store is into the Task THIS call returns, and the scheduler reads it back
    out of THAT SAME Task. Same rule that licenses `List.cons` and
    `JsArray.push`, whose B2 wording has always been "no store OUTSIDE
    RESULT", not "no store".

    E2E-gated by `test/elm/src/KernelLicenseTaskTest.elm`: two distinct
    functions stored in a Task's `a` and taken back out through `andThen`,
    both meeting at one shared call site, plus `onError`'s success and failure
    edges — each CHECK chosen so a false singleton prints a DIFFERENT NUMBER.
    Landing it first required fixing an unrelated `Platform.worker` defect it
    tripped over (`plans/task-perform-value-msg-segfault.md`).

The genuinely fieldless-driven refusals stand on their own evidence and are
NOT re-opened by this correction — but they must now cite the real reason:
`Http.expect` puts two closures into a `Resolver x a` that the HTTP runtime
retrieves on a LATER callback; every `Json.Decode` combinator's callback is
re-entered by a decode driver walking a value the type does not relate to the
combinator's own arguments.

**2. Type erasure into an opaque parameterless type.** `Json.wrap`'s identity
fall-through (`JsonExports.cpp:1683`) retypes an arbitrary argument as the
opaque `Value`; `Debugger.unsafeCoerce : a -> b` relates two UNSHARED
variables, so its honest flow is inexpressible in its type by construction —
the exact inverse of what `TypeFaithful` asserts. No body, however pure,
could make either licensable.

**3. Kernel-authored closure allocation reaching a type-visible position.**
Transient PAPs built INSIDE `eco_apply_closure_eval` under
under/over-saturation are sanctioned (they are the LSS_013-covered
inhabitants); a kernel minting its own closure launders an identity the
analysis has no member id for. The audited fabrication surface is wider than
earlier drafts of the plan recorded, and a grep must cover `runtime/` too:
`core/TaskEffectManager.cpp`, `http/HttpExports.cpp`,
`http/HttpEffectManager.cpp`, `time/TimeExports.cpp`,
`time/TimeEffectManager.cpp`, `virtual-dom/VirtualDom.cpp`,
`eco-kernel-cpp/src/eco/MVar.cpp`, `runtime/src/platform/TaskBinding.hpp`
(`makeBinding` :152, `makeAsyncBinding` :173 — reached by 41 of 47 eco
kernels), `runtime/src/platform/PlatformRuntime.cpp` (:80, :826),
`runtime/src/platform/Scheduler.cpp` (:849) and `PortRuntime.cpp`.
**`core/Utils.cpp` is NOT one of them** — its single `Tag_Closure` hit is a
read-only `case` label in `eqHelp` (:713, "functions cannot be compared").
That false positive had been blocking `List.sortBy`, whose grant reaches
`Utils::compare`.

Named classes that follow from the above:

  - **Task / Process / effect managers.** NARROWED 2026-08-25 — see the
    CROSS-CALL correction above. `Scheduler.succeed/fail/andThen/onError` are
    now LICENSED (`Transports`): storing into the Task you return is not
    retention, and the scheduler reads the value back out of that same Task.
    What remains refused here is the mailbox/router surface
    (`sendToApp`/`sendToSelf`/effect managers), which IS cross-call, and
    `spawn`/`kill`, which route through `TaskBinding.hpp` `makeBinding` and
    mint a C++ closure — OPEN, not decided: the minted closure lands in
    `t->callback` where no type variable names it, and `spawn`'s `a` does not
    appear in its result at all, so predicate 3 fires here mechanically
    rather than on a demonstrated hazard. Audit them properly before either
    licensing or citing them. The callback lands in the returned
    Task — stored through `Elm::alloc::allocTask`
    (`runtime/src/allocator/HeapHelpers.hpp:2047-2069`, the write at :2065),
    called from `Scheduler.cpp:123-162`: `taskSucceed` :123-126, `taskFail`
    :139-142, then the four callback-storing constructors `taskBinding`
    :144-147, `taskAndThen` :149-152, `taskOnError` :154-157, `taskReceive`
    :159-162. (`Scheduler::allocTask` does not exist as a member — earlier
    drafts cited it; the free `alloc::allocTask` above is the real store.)
  - **Ports and the embedding boundary.** `specializePort` poison is separate
    LSS_004 territory; TSFN/JS registration retains callbacks off-heap.
  - **VirtualDom and Browser, wholesale.** Not merely event handlers:
    `VirtualDom.cpp:390` holds a never-freed `static std::vector<VNodePtr>
    vnodeRegistry` and EVERY VNode-producing kernel returns a `Custom` holding
    only an INDEX into it, so a `Node msg` value is a handle into runtime
    storage; `map` stores its tagger in a `std::function` (:160) and
    `lazy`–`lazy8` build capturing C++ lambdas over Elm closures (:193-285).
    `elm/browser` is not even installed, so its 30 kernels have no type source
    to audit against either.
  - **`Debug`.** Refused on LOWERING SHAPE, not on C++ soundness (the three
    bodies are clean). `Debug` is special-cased in four places —
    `KernelAbi.alwaysPolymorphicModules`, `Translate`'s `remapWanted` (Debug
    alone is excluded from per-reference var freshening, so the §1 argument's
    assumption of ordinary instantiation does not hold), `Expr.elm`'s bespoke
    `eco.dbg` lowering, and `Monomorphize`/`CsePurity`/`CafHoist` guards. On
    top of that `Debug.toString` fails A3 outright: its export is arity 2
    (`HPtr value, int64_t type_id`) against an Elm arity of 1, and it ROUTES
    on that compiler-injected type id through the global type graph. A
    compiler-injected type descriptor is a hidden state argument and
    disqualifies a kernel by itself.
  - **`MVar`.** `MVar.put` wraps its `a`-typed argument in a hand-rolled
    closure (`MVar.cpp:295-300`) and fulfilment writes it into the
    process-global `static s_mvars` (:56, :103) or parks it (:241); the
    runtime's own `registerGcRootScanner` (:343-365) certifies that both
    outlive the call. `read`/`take` take their result from a DIFFERENT call's
    `put`, so C1 has no incoming edge at all.

The storage-rejection precedents in `KernelFacts.elm` (Console.write,
File.fileExists/dirExists, Env.lookup, Scheduler.spawn) are the BORROW axis
and are never themselves evidence — re-verified here, they turn out NOT to
transfer: those Tasks capture `String`s, so nothing function-capable is
retained and the kernels are licensable on this axis under the `Inert` rule.


## Two hazards this table cannot detect by itself

  - **Elm-annotation drift.** A row is a claim about the C++ *and* the type.
    The rot manifest hashes C++ only, so an `Inert` row whose Elm annotation
    later gains an arrow or a type variable becomes a claim nobody re-checked.
    Treat an annotation change to a licensed kernel as a re-audit trigger.
  - **One name, several types.** `factFor` is keyed by `(home, name)`, but a
    kernel can be reached through several aliasing annotations —
    `String.fromNumber` through both `fromInt` and `fromFloat`, `Http.pair`
    through five. A row is therefore a claim about EVERY type the name can
    carry, not just the one its evidence quotes. (The consumers read the
    occurrence's own solver-inferred type, so the multiplicity is handled
    correctly at the boundary; it is the AUDIT that must cover all of them.)
  - **The key drops the kernel PREFIX.** `TOpt.VarKernel` carries
    `Elm`/`Eco`, but both consumers pass only `(home, name)` on, so
    `Elm.Kernel.File.size` and `Eco.Kernel.File.size` are ONE row — and a
    second row would have been silently swallowed by `Dict.fromList`. That
    single collision is real today and its row covers both types explicitly;
    it was the only one across the two kernel packages as of 2026-08-20
    (`comm` over the two export name sets). Adding a kernel whose
    `(home, name)` already exists in the other package REQUIRES auditing both
    bodies under one row — or widening the key first.

@docs ParamSetFlow, KernelPlan, LicenseScope, TypeShape, License, KernelSetFact
@docs factFor, licenseApplies, shapeOfAnnotation, licensedFiles, rows

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Dict


{-| Per-position set flow (the `Positional` tier only).
-}
type ParamSetFlow
    = PSFOpaque
    | PSFApplies
    | PSFTunnels


{-| An arity-aligned per-position plan.
-}
type alias KernelPlan =
    { params : List ParamSetFlow

    -- The RESULT row: PSFOpaque = poison the result's arrows (today);
    -- PSFApplies = leave them unconstrained (the consumer then treats the
    -- result value as untracked — sound, empty-slot reads default to ⊤).
    , result : ParamSetFlow
    , evidence : String
    }


{-| How much set flow a license admits — and, inseparably, what must be
verified about an OCCURRENCE before the license may be applied to it.

The two are one decision, not two, because a license is a claim about a TYPE
and the consumers see a different type at every occurrence
(`funcMeta.tipe`/`canFuncType`, the solver-inferred type at that site). What
binds those occurrence types to the type the audit examined differs per
constructor, so each carries its own obligation:

  - **`Inert`** — the `vacuous` class: the audit found NO function-capable
    position at all, so the loaded scheme has zero FunL slots and both the
    poison and the transport are provable no-ops. `licenseApplies` re-derives
    exactly that property from the occurrence type, which is why an `Inert`
    row is safe for a kernel that would otherwise be unlicensable (a
    concrete `Task`-returning one). It is also the ONLY guard against
    Elm-annotation drift: the rot manifest hashes C++ and cannot see a
    signature growing an arrow, but this check can, and turns it back into
    LSS_004 poison instead of a silent wrong claim.

  - **`Transports`** — real function values cross the boundary and the type's
    shared variables are the edges. Used where the kernel HAS an aliasing
    annotation in package source, so the typechecker already bounds every
    occurrence to an instance of the audited type; there is nothing left for
    a runtime check to add. No obligation.

  - **`TransportsAs shape`** — the same, for a kernel with NO aliasing
    annotation. `Can.VarKernel` generates `CTrue`
    (`Type/Constrain/Typed/Expression.elm`), i.e. no constraint whatsoever, so
    an unannotated kernel is typed entirely by its context and nothing bounds
    it. Its "inferred" type is first-usage-wins bookkeeping, not a property of
    the kernel. Here the audit DECLARES the general type and
    `licenseApplies` enforces that the occurrence is an instance of it —
    turning an unenforceable assertion into a checked one. A non-instance
    occurrence falls back to poison; it never fails the build.

Ruling on constrained variables, since it decides `Inert` vs the rest: a
constrained variable is function-capable only if what it ranges over can
itself contain a function. `number` (Int | Float) and `comparable` (scalars,
and lists/tuples that bottom out in scalars) cannot; `appendable` and
`compappend` reach a bare element variable through their `List a` arm.

Roughly five in six licensed kernels are `Inert`, so the inference side must
not pay a scheme instantiation for them — that would be a fixed cost on a hot
path buying exactly nothing.
-}
type LicenseScope
    = Inert
    | Transports
    | TransportsAs TypeShape


{-| A declared kernel type, in the only detail the license needs: which
positions are arrows, which are shared variables, and what the constructors
are. Matching is one-way — the shape is the PATTERN and the occurrence type
is matched against it — with `TsVar` bound consistently, because it is
exactly the repeated variables that carry the flow the license is claiming.

Constructors are compared by NAME, not by canonical home. That is a
deliberate looseness: writing full `IO.Canonical` homes would make the table
unreadable, and kernel references are legal only inside kernel-package source,
so the names in play are unambiguous. It costs nothing in soundness that
matters — a same-named type from another module would still have to be an
opaque box to the C++, which is the only property the audits rely on.
-}
type TypeShape
    = TsVar String
    | TsFun TypeShape TypeShape
    | TsCon String (List TypeShape)


{-| A granted parametricity license.

`files` is the repo-relative KERNEL-source C++ paths whose bodies the grant
depends on — what the rot manifest pins. Globally-sanctioned runtime
machinery is deliberately absent (see the module doc). An empty `files` list
is a bug: it means the row claims an audit of nothing, and a unit test fails
on it.
-}
type alias License =
    { scope : LicenseScope
    , files : List String
    , evidence : String
    }


{-| May this license be applied to THIS occurrence? `False` ⇒ the consumer
falls back to LSS_004 full poison — fail-safe, never fail-stop: a kernel used
at a type the audit never examined is simply treated as unaudited.
-}
licenseApplies : (id -> Bool) -> License -> Can.Type id -> Bool
licenseApplies isScalarVar license occurrence =
    case license.scope of
        Inert ->
            isInertType isScalarVar occurrence

        Transports ->
            True

        TransportsAs shape ->
            matchesShape shape occurrence


{-| Does this type have NO function-capable position — no function-capable type
variable anywhere, and no arrow other than the kernel's own top-level spine?

`isScalarVar` answers "can NO function ever occur inside this type variable?",
which is ruling R1 made operational. It is not a nicety: `number` and
`comparable` bottom out in scalars, so `Utils.compare : comparable ->
comparable -> Order` and `Basics.add : number -> number -> number` have no
function-capable position at all — but their occurrences inside a polymorphic
caller are `TVar`s, and treating every `TVar` as function-capable refused their
licenses on the hottest kernels in the compiler. `appendable`/`compappend`
reach a bare element variable through their `List a` arm and must stay
function-capable. A lookup miss must answer `False` (conservative): an
unrecognised variable is treated as function-capable, so the failure direction
is a missing license, never a wrong one.

The spine is walked separately because a kernel IS a function: its own
`String -> Int` arrow is the callee position, not a place a caller's value can
inhabit. Everything reachable from an argument or from the final result is
checked with `hasFunctionCapable`, which is deliberately blunt — ANY variable
counts, including a phantom parameter of a nullary-constructor carrier, since
that is precisely the case where the type cannot describe what the C++ stores.
-}
isInertType : (id -> Bool) -> Can.Type id -> Bool
isInertType isScalarVar tipe =
    case tipe of
        Can.TLambda _ arg result ->
            not (hasFunctionCapable isScalarVar arg) && isInertType isScalarVar result

        _ ->
            not (hasFunctionCapable isScalarVar tipe)


hasFunctionCapable : (id -> Bool) -> Can.Type id -> Bool
hasFunctionCapable isScalarVar tipe =
    case tipe of
        Can.TVar v ->
            not (isScalarVar v)

        Can.TLambda _ _ _ ->
            True

        Can.TType _ _ args ->
            List.any (hasFunctionCapable isScalarVar) args

        Can.TTuple a b rest ->
            hasFunctionCapable isScalarVar a || hasFunctionCapable isScalarVar b || List.any (hasFunctionCapable isScalarVar) rest

        Can.TRecord fields ext ->
            ext /= Nothing || List.any (\(Can.FieldType _ ft) -> hasFunctionCapable isScalarVar ft) (Dict.values fields)

        Can.TAlias _ _ args real ->
            -- An alias APPLICATION is its body with `args` substituted, so the
            -- two halves must be counted differently. The args are real types
            -- and are checked as such. The body, when `Holey`, still contains
            -- the alias's own PARAMETER variables — those are placeholders for
            -- the args, NOT free variables, so counting them as
            -- function-capable rejects every parameterised alias out of hand.
            -- `Task Never String` is exactly that shape (`Holey (Platform.Task
            -- x a)`), and it refused five eco kernels whose types are entirely
            -- concrete until this was fixed. So the body is walked with the
            -- parameters treated as non-capable, their real content having
            -- already been counted through `args`.
            let
                paramIds =
                    List.map Tuple.first args

                bodyScalar v =
                    isScalarVar v || List.member v paramIds
            in
            List.any (\( _, t ) -> hasFunctionCapable isScalarVar t) args
                || hasFunctionCapable bodyScalar (aliasBody real)

        Can.TUnit ->
            False


aliasBody : Can.AliasType id -> Can.Type id
aliasBody real =
    case real of
        Can.Holey t ->
            t

        Can.Filled t ->
            t


{-| The `TypeShape` a `Can.Type` denotes, or `Nothing` for a form shapes cannot
express (records, tuples, aliases with arguments).

This exists so a `TransportsAs` shape and the intrinsic ANNOTATION for the same
kernel can be pinned equal by a test rather than kept in sync by hand — the two
tables live in different subsystems (`MonoSolver` and `Type`) and would
otherwise drift silently, with the failure mode being a license that quietly
stops applying.
-}
shapeOfAnnotation : Can.Type Name -> Maybe TypeShape
shapeOfAnnotation tipe =
    case tipe of
        Can.TVar name ->
            Just (TsVar name)

        Can.TLambda _ arg result ->
            Maybe.map2 TsFun (shapeOfAnnotation arg) (shapeOfAnnotation result)

        Can.TType _ name args ->
            Maybe.map (TsCon name) (traverseShapes args)

        Can.TUnit ->
            Just (TsCon "()" [])

        _ ->
            Nothing


traverseShapes : List (Can.Type Name) -> Maybe (List TypeShape)
traverseShapes types =
    case types of
        [] ->
            Just []

        t :: rest ->
            Maybe.map2 (::) (shapeOfAnnotation t) (traverseShapes rest)



{-| One-way match: is `occurrence` an instance of `shape`? A `TsVar` matches
any type but must match the SAME type everywhere it recurs — that consistency
is the whole point, since repeated variables are the flow edges the license
claims. Aliases are chased on the occurrence side so a declared `Value`
matches an occurrence that arrived through an alias.
-}
matchesShape : TypeShape -> Can.Type id -> Bool
matchesShape shape occurrence =
    matchShapeGo [ ( shape, occurrence ) ] []


matchShapeGo : List ( TypeShape, Can.Type id ) -> List ( String, Can.Type id ) -> Bool
matchShapeGo pending bindings =
    case pending of
        [] ->
            True

        ( shape, occurrence ) :: rest ->
            case ( shape, chaseAlias occurrence ) of
                ( TsVar name, occ ) ->
                    case lookupBinding name bindings of
                        Nothing ->
                            matchShapeGo rest (( name, occ ) :: bindings)

                        Just bound ->
                            if sameType bound occ then
                                matchShapeGo rest bindings

                            else
                                False

                ( TsFun p r, Can.TLambda _ p2 r2 ) ->
                    matchShapeGo (( p, p2 ) :: ( r, r2 ) :: rest) bindings

                ( TsCon name args, Can.TType _ name2 args2 ) ->
                    if name == name2 && List.length args == List.length args2 then
                        matchShapeGo (List.map2 Tuple.pair args args2 ++ rest) bindings

                    else
                        False

                ( TsCon name [], Can.TUnit ) ->
                    name == "()" && matchShapeGo rest bindings

                _ ->
                    False


chaseAlias : Can.Type id -> Can.Type id
chaseAlias tipe =
    case tipe of
        Can.TAlias _ _ _ real ->
            chaseAlias (aliasBody real)

        _ ->
            tipe


lookupBinding : String -> List ( String, Can.Type id ) -> Maybe (Can.Type id)
lookupBinding name bindings =
    case bindings of
        [] ->
            Nothing

        ( n, t ) :: rest ->
            if n == name then
                Just t

            else
                lookupBinding name rest


{-| Structural equality, backing the `TsVar` consistency check: two occurrences
of a declared variable must be the same type. Compared through alias chasing so
`Value` and its alias agree.

**Type VARIABLES compare by IDENTITY, not by "both are variables".** The loose
rule (any `TVar` equals any `TVar`) makes every repeated-variable claim in a
shape VACUOUS — `(a -> b) -> a -> ...` would accept an occurrence whose two `a`
positions are unrelated variables, i.e. it would assert sharing while checking
none. That was tolerable only while occurrence types were unsolved mush; with
intrinsic annotations (TYPE_KERNEL_001) the positions ARE solved, so the
identity comparison is both meaningful and satisfiable. Sound in either
direction — matching only GATES a license, it never creates sharing — but the
strict rule is the one that makes a declared shape mean what it says.

**ARROW ids are bound to `_` and MUST STAY THAT WAY (Phase 2a §4.6b).** The
strict-identity rule above is about `TVar` — SOLVER identity — and it does NOT
transfer to arrows, which carry per-OCCURRENCE identity. This function is
called from `matchShapeGo` with `id = MVarId` in production, where two
occurrence types legitimately carry DIFFERENT arrow ids for the same shape.
Anyone who "fixes" a compile error here by *comparing* the ids silently kills
the `TsVar` consistency check for every function-typed binding and un-licenses
every `TypeFaithful` kernel row — with no test failure loud enough to say so.
The function is already structural (destructure and recurse, never `==` on a
node), so binding them to `_` preserves behaviour exactly.

-}
sameType : Can.Type id -> Can.Type id -> Bool
sameType a b =
    case ( chaseAlias a, chaseAlias b ) of
        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TVar v1, Can.TVar v2 ) ->
            v1 == v2

        ( Can.TLambda _ p1 r1, Can.TLambda _ p2 r2 ) ->
            sameType p1 p2 && sameType r1 r2

        ( Can.TType _ n1 a1, Can.TType _ n2 a2 ) ->
            n1 == n2 && List.length a1 == List.length a2 && List.all identity (List.map2 sameType a1 a2)

        ( Can.TTuple x1 y1 r1, Can.TTuple x2 y2 r2 ) ->
            sameType x1 x2 && sameType y1 y2 && List.length r1 == List.length r2 && List.all identity (List.map2 sameType r1 r2)

        _ ->
            False


{-| One audited row. `Nothing` from `factFor` is the third, unrepresented
tier: LSS_004 full poison.
-}
type KernelSetFact
    = TypeFaithful License
    | Positional KernelPlan


{-| The audited fact for a kernel, or `Nothing` = unlicensed ⇒ LSS_004 full
poison.

Note the tiers differ in how the CONSUMER must qualify the answer.
`TypeFaithful` needs no qualification at all — there are no positions to
align, so partial and over-application are handled by ordinary unification.
`Positional` is arity-aligned and the consumer must fall back to full poison
when the call arity (inference side) or the loaded scheme's spine
(translation side) does not match `List.length plan.params`.
-}
factFor : Name -> Name -> Maybe KernelSetFact
factFor home name =
    Dict.get ( home, name ) facts


{-| Every C++ path any licensed row depends on, deduplicated and sorted —
the source of truth the license-rot manifest is generated from and checked
against. Positional rows are deliberately excluded: they carry no license,
only a per-position refinement, and their evidence is re-read whenever the
row is touched.
-}
licensedFiles : List String
licensedFiles =
    facts
        |> Dict.values
        |> List.concatMap
            (\fact ->
                case fact of
                    TypeFaithful license ->
                        license.files

                    Positional _ ->
                        []
            )
        |> List.sort
        |> dedupeSorted


dedupeSorted : List String -> List String
dedupeSorted xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupeSorted (b :: rest)

            else
                a :: dedupeSorted (b :: rest)

        _ ->
            xs


{-| Every row, for tests and tooling.
-}
rows : List ( ( Name, Name ), KernelSetFact )
rows =
    Dict.toList facts


{-| v1 rows (2026-08-20 C++ audit). Shared driver for map2-5 is
`kernelListMapN` (ListExports.cpp:432-590): the callback is rooted and
APPLIED via `eco_apply_closure_eval` (:567-569); the result list is built
from the callback's RETURNS only. map2-5 result rows ship `PSFOpaque`: when
the Elm `result` tvar instantiates to a function, a stored return can be a
PAP OF THE CALLBACK (`eco_apply_closure_eval` PAP chaining,
RuntimeExports.cpp:1987-2145) — result-element arrows are the callback's
inner arrows, not expressible as a v1 fact. sortBy/sortWith list-param →
result is a permutation (`listFromPermutation`) — `PSFTunnels` is the
recorded refinement; opaque is sound and ships first.
-}
facts : Dict.Dict ( Name, Name ) KernelSetFact
facts =
    Dict.fromList
        [ ( ( "Basics", "acos" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_acos:13-15 | helpers: Basics.cpp:acos:16-18 | type: elm/core/1.0.5/src/Basics.elm:718 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "add" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_add:95-100 (ABI instances :123-129) | helpers: BasicsExports.cpp anon-ns:70-91 | type: elm/core/1.0.5/src/Basics.elm:168 (number -> number -> number) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "and" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_and:220-222 | helpers: Basics.cpp:and_:153-155, ExportHelpers.hpp:80-89 | type: elm/core/1.0.5/src/Basics.elm:468 (Bool -> Bool -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "asin" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_asin:17-19 | helpers: Basics.cpp:asin:20-22 | type: elm/core/1.0.5/src/Basics.elm:728 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "atan" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_atan:21-23 | helpers: Basics.cpp:atan:24-26 | type: elm/core/1.0.5/src/Basics.elm:751 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "atan2" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_atan2:25-27 | helpers: Basics.cpp:atan2:28-30 | type: elm/core/1.0.5/src/Basics.elm:766 (Float -> Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "ceiling" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_ceiling:192-194 | helpers: Basics.cpp:ceiling:113-115 | type: elm/core/1.0.5/src/Basics.elm:300 (Float -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "cos" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_cos:29-31 | helpers: Basics.cpp:cos:32-34 | type: elm/core/1.0.5/src/Basics.elm:683 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "e" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_e:168-170 | helpers: Basics.cpp:e:60-62 | type: elm/core/1.0.5/src/Basics.elm:628 (Float, CAF arity 0) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "fdiv" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_fdiv:176-178 | helpers: Basics.cpp:fdiv:84-86 | type: elm/core/1.0.5/src/Basics.elm:203 (Float -> Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "floor" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_floor:196-198 | helpers: Basics.cpp:floor:117-119 | type: elm/core/1.0.5/src/Basics.elm:284 (Float -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "idiv" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_idiv:180-182 | helpers: Basics.cpp:idiv:88-90 | type: elm/core/1.0.5/src/Basics.elm:225 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "isInfinite" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_isInfinite:212-214 | helpers: Basics.cpp:isInfinite:141-143, ExportHelpers.hpp:80-82 | type: elm/core/1.0.5/src/Basics.elm:826 (Float -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "isNaN" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_isNaN:216-218 | helpers: Basics.cpp:isNaN:145-147, ExportHelpers.hpp:encodeBoxedBool:80-82 | type: elm/core/1.0.5/src/Basics.elm:811 (Float -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "modBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_modBy:184-186 | helpers: Basics.cpp:modBy:92-103 | type: elm/core/1.0.5/src/Basics.elm:539 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write; throw at :96 uses a literal | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "mul" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_mul:109-114 (ABI instances :139-145) | helpers: BasicsExports.cpp anon-ns:70-91 | type: elm/core/1.0.5/src/Basics.elm:186 (number -> number -> number) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "not" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_not:232-234 | helpers: Basics.cpp:not_:165-167, ExportHelpers.hpp:80-89 | type: elm/core/1.0.5/src/Basics.elm:452 (Bool -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "or" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_or:224-226 | helpers: Basics.cpp:or_:157-159, ExportHelpers.hpp:80-89 | type: elm/core/1.0.5/src/Basics.elm:484 (Bool -> Bool -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "pi" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_pi:172-174 | helpers: Basics.cpp:pi:64-66 | type: elm/core/1.0.5/src/Basics.elm:670 (Float, CAF arity 0) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "pow" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_pow:116-121 (ABI instances :149-166) | helpers: BasicsExports.cpp anon-ns:70-91 | type: elm/core/1.0.5/src/Basics.elm:235 (number -> number -> number) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "remainderBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_remainderBy:188-190 | helpers: Basics.cpp:remainderBy:105-107 | type: elm/core/1.0.5/src/Basics.elm:555 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "round" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_round:200-202 | helpers: Basics.cpp:round:121-123 | type: elm/core/1.0.5/src/Basics.elm:268 (Float -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "sin" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_sin:33-35 | helpers: Basics.cpp:sin:36-38 | type: elm/core/1.0.5/src/Basics.elm:696 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "sqrt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_sqrt:41-43 | helpers: Basics.cpp:sqrt:44-46 | type: elm/core/1.0.5/src/Basics.elm:609 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "sub" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_sub:102-107 (ABI instances :131-137) | helpers: BasicsExports.cpp anon-ns:70-91 | type: elm/core/1.0.5/src/Basics.elm:177 (number -> number -> number) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "tan" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_tan:37-39 | helpers: Basics.cpp:tan:40-42 | type: elm/core/1.0.5/src/Basics.elm:708 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "toFloat" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_toFloat:208-210 | helpers: Basics.cpp:toFloat:133-135 | type: elm/core/1.0.5/src/Basics.elm:252 (Int -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "truncate" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_truncate:204-206 | helpers: Basics.cpp:truncate:125-127 | type: elm/core/1.0.5/src/Basics.elm:316 (Float -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "xor" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_xor:228-230 | helpers: Basics.cpp:xor_:161-163, ExportHelpers.hpp:80-89 | type: elm/core/1.0.5/src/Basics.elm:496 (Bool -> Bool -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "and" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_and:10-12 | helpers: Bitwise.cpp:and_:5-16 | type: elm/core/1.0.5/src/Bitwise.elm:23 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "complement" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_complement:22-24 | helpers: Bitwise.cpp:complement:44-55 | type: elm/core/1.0.5/src/Bitwise.elm:44 (Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "or" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_or:14-16 | helpers: Bitwise.cpp:or_:18-29 | type: elm/core/1.0.5/src/Bitwise.elm:30 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "shiftLeftBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_shiftLeftBy:26-28 | helpers: Bitwise.cpp:shiftLeftBy:57-69 | type: elm/core/1.0.5/src/Bitwise.elm:55 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "shiftRightBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_shiftRightBy:30-32 | helpers: Bitwise.cpp:shiftRightBy:71-83 | type: elm/core/1.0.5/src/Bitwise.elm:73 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "shiftRightZfBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_shiftRightZfBy:34-36 | helpers: Bitwise.cpp:shiftRightZfBy:85-98 | type: elm/core/1.0.5/src/Bitwise.elm:90 (Int -> Int -> Int; uint64_t ret) | B1: vacuous (no function-capable position) | B2: no static/global write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "xor" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_xor:18-20 | helpers: Bitwise.cpp:xor_:31-42 | type: elm/core/1.0.5/src/Bitwise.elm:37 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "decode" )
          , Positional
                { params = [ PSFApplies, PSFOpaque ]
                , result = PSFOpaque
                , evidence = "class: full | entry: BytesExports.cpp:Elm_Kernel_Bytes_decode:414-463 | B1: apply-only via eco_apply_closure_typed :427, decoder never stored or copied | result opaque: A2 — :434-437 routes on an out-of-band Nothing sentinel the callback's (Int, a) type does not describe | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "encode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_encode:391-412 | helpers: encoderSize:120-138, writeEncoder:140-274 | type: elm/bytes/1.0.8/src/Bytes/Encode.elm:96 (Encoder -> Bytes) | B1: vacuous (no function-capable position) | B2: result alloc only :403-405 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "getStringWidth" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_getStringWidth:305-362 | helpers: none | type: elm/bytes/1.0.8/src/Bytes/Encode.elm:250 (String -> Int) | B1: vacuous (no function-capable position) | B2: C++-stack u16string :333, no Elm retention | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_bytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_bytes:569-580 | helpers: makeTuple2_ip:65-76 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:146 (Int -> Bytes -> Int -> (Int, Bytes)) | B1: vacuous (no function-capable position) | B2: slice + Tuple2 result only | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_f32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_f32:545-555 | helpers: makeTuple2_if:55-63 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:128 (Bool -> Bytes -> Int -> (Int, Float)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_f64" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_f64:557-567 | helpers: makeTuple2_if:55-63 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:135 (Bool -> Bytes -> Int -> (Int, Float)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_i16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_i16:503-512 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:85 (Bool -> Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_i32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_i32:514-523 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:92 (Bool -> Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_i8" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_i8:488-493 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:78 (Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only :46-47 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_string" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_string:582-709 | helpers: makeTuple2_ip:65-76 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:175 (Int -> Bytes -> Int -> (Int, String)) | B1: vacuous (no function-capable position) | B2: body + Tuple2 result rooted :666-668 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_u16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_u16:525-533 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:110 (Bool -> Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_u32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_u32:535-543 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:117 (Bool -> Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "read_u8" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_u8:495-499 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:103 (Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "width" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_width:295-297 | helpers: ElmBytesRuntime.cpp:elm_bytebuffer_len:78-85 | type: elm/bytes/1.0.8/src/Bytes.elm:77 (Bytes -> Int) | B1: vacuous (no function-capable position) | B2: read-only length probe, no statics | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_bytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_bytes:867-869 | helpers: makeEncoderBytes:817-833 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:298 (C++ Bytes -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: arg into result :831, rooted :823-827 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_f32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_f32:859-861 | helpers: makeEncoder2_pf:753-770 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:294 (C++ Endianness -> Float -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :759-763 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_f64" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_f64:863-865 | helpers: makeEncoder2_pf:753-770 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:295 (C++ Endianness -> Float -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :759-763 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_i16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_i16:839-841 | helpers: makeEncoder2_pi:734-751 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:289 (C++ Endianness -> Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :740-744 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_i32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_i32:843-845 | helpers: makeEncoder2_pi:734-751 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:290 (C++ Endianness -> Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :740-744 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_i8" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_i8:835-837 | helpers: makeEncoder1:715-725 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:288 (C++ Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :718-719 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_string" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_string:871-873 | helpers: makeEncoderUtf8:792-812 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:297 (C++ String -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: arg+width into result :809-810, rooted :800-805 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_u16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_u16:851-853 | helpers: makeEncoder2_pi:734-751 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:292 (C++ Endianness -> Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :740-744 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_u32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_u32:855-857 | helpers: makeEncoder2_pi:734-751 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:293 (C++ Endianness -> Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :740-744 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "write_u8" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_u8:847-849 | helpers: makeEncoder1:715-725 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:291 (C++ Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :718-719 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "fromCode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_fromCode:11-15 | helpers: none (inline std::max/min clamp) | type: elm/core/1.0.5/src/Char.elm:255 (Int -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toCode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toCode:28-30 | helpers: none | type: elm/core/1.0.5/src/Char.elm:235 (Char -> Int; u64 c_raw & 0xFFFF = statepoint ABI :17-27) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toLocaleLower" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp", "elm-kernel-cpp/src/core/Char.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toLocaleLower:42-45 | helpers: Char.cpp:toLocaleLower:105-122 (-> toLower) | type: elm/core/1.0.5/src/Char.elm:220 (Char -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toLocaleUpper" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp", "elm-kernel-cpp/src/core/Char.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toLocaleUpper:47-50 | helpers: Char.cpp:toLocaleUpper:124-141 (-> toUpper) | type: elm/core/1.0.5/src/Char.elm:214 (Char -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toLower" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp", "elm-kernel-cpp/src/core/Char.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toLower:32-35 | helpers: Char.cpp:toLower:61-81 (pure, calls nothing) | type: elm/core/1.0.5/src/Char.elm:208 (Char -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toUpper" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp", "elm-kernel-cpp/src/core/Char.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toUpper:37-40 | helpers: Char.cpp:toUpper:83-103 (pure, calls nothing) | type: elm/core/1.0.5/src/Char.elm:202 (Char -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Console", "log" )
          , TypeFaithful
                { scope = Transports
                , files = [ "eco-kernel-cpp/src/eco/ConsoleExports.cpp", "eco-kernel-cpp/src/eco/Console.cpp" ]
                , evidence = "class: cheap | entry: ConsoleExports.cpp:Eco_Kernel_Console_log:21-23 | helpers: Console.cpp:log:144-163 | type: Eco/Console.elm:81 (String -> a -> a, alias-seeded) | B1: B1(b)+B1(c) -- Console.cpp:162 `return value;` is the arg's ONLY use | B2: no static/global/task write in Console.cpp | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Console", "readAll" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/ConsoleExports.cpp", "eco-kernel-cpp/src/eco/Console.cpp" ]
                , evidence = "class: vacuous | entry: ConsoleExports.cpp:Eco_Kernel_Console_readAll:17-19 | helpers: Console.cpp:readAll:140-142 | type: Eco/Console.elm:71 | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :141) | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Console", "readLine" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/ConsoleExports.cpp", "eco-kernel-cpp/src/eco/Console.cpp" ]
                , evidence = "class: vacuous | entry: ConsoleExports.cpp:Eco_Kernel_Console_readLine:13-15 | helpers: Console.cpp:readLine:136-138 | type: Eco/Console.elm:63 | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :137) | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Console", "write" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/ConsoleExports.cpp", "eco-kernel-cpp/src/eco/Console.cpp" ]
                , evidence = "class: vacuous | entry: ConsoleExports.cpp:Eco_Kernel_Console_write:9-11 | helpers: Console.cpp:write:126-134 | type: Eco/Console.elm:55 | B1: vacuous (no function-capable position) | B2: String captured :129-133, set-flow inert | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Crash", "crash" )
          , TypeFaithful
                { scope = Transports
                , files = [ "eco-kernel-cpp/src/eco/CrashExports.cpp", "eco-kernel-cpp/src/eco/Crash.cpp" ]
                , evidence = "class: cheap | entry: CrashExports.cpp:Eco_Kernel_Crash_crash:9-11 | helpers: Crash.cpp:crash:20-33 | type: Eco/Crash.elm:16 (String -> a, alias-seeded) | B1: no function value enters (param is String); result `a` never inhabited -- ::exit(1) :30 | B2: no storage | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Env", "lookup" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/EnvExports.cpp", "eco-kernel-cpp/src/eco/Env.cpp" ]
                , evidence = "class: vacuous | entry: EnvExports.cpp:Eco_Kernel_Env_lookup:9-11 | helpers: Env.cpp:lookup:52-55 | type: Eco/Env.elm:20 (String -> Task Never (Maybe String), alias-seeded) | B1: vacuous (no function-capable position) | B2: String captured :54, inert; s_argv:19-20 is char** | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Env", "rawArgs" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/EnvExports.cpp", "eco-kernel-cpp/src/eco/Env.cpp" ]
                , evidence = "class: vacuous | entry: EnvExports.cpp:Eco_Kernel_Env_rawArgs:13-15 | helpers: Env.cpp:rawArgs:57-60 | type: Eco/Env.elm:27 (Task Never (List String), alias-seeded) | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :59) | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "appDataDir" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_appDataDir:77-79 | helpers: File.cpp:appDataDir:717-720 | type: Eco/File.elm:261 (String -> Task Never String, alias-seeded) | B1: vacuous (no function-capable position) | B2: String captured :719 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "canonicalize" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_canonicalize:73-75 | helpers: File.cpp:canonicalize:712-715 | type: Eco/File.elm:253 (String -> Task IOError String) | B1: vacuous (no function-capable position) | B2: String captured :714 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "close" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_close:29-31 | helpers: File.cpp:close:641-647 | type: Eco/File.elm:139 (Handle -> Task IOError (); inferred Int -> ...) | B1: vacuous (no function-capable position) | B2: only an unboxed Int captured :646 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "createDir" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_createDir:81-83 | helpers: File.cpp:createDir:722-729 | type: Eco/File.elm:269 (Bool -> String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :728, Bool decoded :576 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "dirExists" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_dirExists:49-51 | helpers: File.cpp:dirExists:682-685 | type: Eco/File.elm:194 (String -> Task Never Bool, alias-seeded) | B1: vacuous (no function-capable position) | B2: String captured :684 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "fileExists" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_fileExists:45-47 | helpers: File.cpp:fileExists:677-680 | type: Eco/File.elm:187 (String -> Task Never Bool, alias-seeded) | B1: vacuous (no function-capable position) | B2: String captured :679 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "findExecutable" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_findExecutable:53-55 | helpers: File.cpp:findExecutable:687-690 | type: Eco/File.elm:201 | B1: vacuous (no function-capable position) | B2: String captured :689; :176/:182 are static FUNCTIONS | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "getCwd" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_getCwd:65-67 | helpers: File.cpp:getCwd:702-705 | type: Eco/File.elm:238 (Task Never String, alias-seeded) | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :704) | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "hWriteString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_hWriteString:93-95 | helpers: File.cpp:hWriteString:649-657 | type: Eco/File.elm:147 | B1: vacuous (no function-capable position) | B2: String + unboxed fd in a tuple2 :656 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "list" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_list:57-59 | helpers: File.cpp:list:692-695 | type: Eco/File.elm:208 (String -> Task IOError (List String); element concrete) | B1: vacuous (no function-capable position) | B2: String captured :694; list built fresh | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "lock" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_lock:37-39 | helpers: File.cpp:lock:667-670 | type: Eco/File.elm:167 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :669, never read | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "mime" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/file/FileExports.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Elm_Kernel_File_mime:31-35 | type: elm/file/1.0.5/src/File.elm:152 (File -> String; type File = File :41 -- no arrow, no tvar) | B1: vacuous (no function-capable position) | B2: vacuous, the body performs no writes (stub: :33 asserts) | B3: no closure allocation | audited: 2026-08-20"
                }
          )
        , ( ( "File", "modificationTime" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_modificationTime:61-63 | helpers: File.cpp:modificationTime:697-700 | type: Eco/File.elm:216 (String -> Task IOError Time.Posix; inferred ok Int) | B1: vacuous (no function-capable position) | B2: String captured :699 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "name" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/file/FileExports.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Elm_Kernel_File_name:25-29 | type: elm/file/1.0.5/src/File.elm:142 (File -> String; type File = File :41 -- no arrow, no tvar) | B1: vacuous (no function-capable position) | B2: vacuous, the body performs no writes (stub: :27 asserts) | B3: no closure allocation | audited: 2026-08-20"
                }
          )
        , ( ( "File", "open" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_open:25-27 | helpers: File.cpp:open:628-639 | type: Eco/File.elm:108 | B1: vacuous (no function-capable position) | B2: tuple2 :638; fd returned as an Int :541 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "readBytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_readBytes:17-19 | helpers: File.cpp:readBytes:614-617 | type: Eco/File.elm:88 (String -> Task IOError Bytes) | B1: vacuous (no function-capable position) | B2: String captured :616 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "readString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_readString:9-11 | helpers: File.cpp:readString:600-603 | type: Eco/File.elm:72 (String -> Task IOError String) | B1: vacuous (no function-capable position) | B2: String captured :602; no object statics in File.cpp | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "removeDir" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_removeDir:89-91 | helpers: File.cpp:removeDir:736-739 | type: Eco/File.elm:285 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :738 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "removeFile" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_removeFile:85-87 | helpers: File.cpp:removeFile:731-734 | type: Eco/File.elm:277 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :733 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "setCwd" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_setCwd:69-71 | helpers: File.cpp:setCwd:707-710 | type: Eco/File.elm:245 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :709; CWD change is an OS effect | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "size" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/File.cpp", "eco-kernel-cpp/src/eco/FileExports.cpp", "elm-kernel-cpp/src/file/FileExports.cpp" ]
                , evidence = "class: vacuous | entry: eco FileExports.cpp:33-35 + elm FileExports.cpp:37-41 (both _File_size) | type: SHARED KEY -- Eco/File.elm:155 (Handle -> Task IOError Int) AND elm/file/1.0.5/src/File.elm:163 (File -> Int); both arrow-free and variable-free | B1: vacuous (no function-capable position) | B2: eco captures an Int File.cpp:664; elm no writes | B3: eco binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "touch" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_touch:97-99 | helpers: File.cpp:touch:741-744 | type: Eco/File.elm:226 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :743 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "unlock" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_unlock:41-43 | helpers: File.cpp:unlock:672-675 | type: Eco/File.elm:175 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :674, never read | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "writeBytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_writeBytes:21-23 | helpers: File.cpp:writeBytes:619-626 | type: Eco/File.elm:96 (String -> Bytes -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :625 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "writeString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/FileExports.cpp", "eco-kernel-cpp/src/eco/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_writeString:13-15 | helpers: File.cpp:writeString:605-612 | type: Eco/File.elm:80 (String -> String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: both Strings in a tuple2 :611 | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Http", "emptyBody" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/http/HttpExports.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Elm_Kernel_Http_emptyBody:658-661 | type: elm/http/2.0.0/src/Http.elm:224 | B1: vacuous (no function-capable position) | B2: :659-660 is one custom(BODY_EMPTY) alloc + return; no static/global/task | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Http", "fetch" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/HttpExports.cpp", "eco-kernel-cpp/src/eco/Http.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Eco_Kernel_Http_fetch:9-11 | type: Eco/Http.elm:22-26 | B1: vacuous (no function-capable position) | B2: three Strings in a tuple3 :415-418; parkBundle parks the runtime's OWN resume | B3: async binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Http", "getArchive" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/HttpExports.cpp", "eco-kernel-cpp/src/eco/Http.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Eco_Kernel_Http_getArchive:13-15 | helpers: Http.cpp:getArchive:421-424, parkBundle:340-349 | type: Eco/Http.elm:35-37 | B1: vacuous (no function-capable position) | B2: url captured as the async payload :423 | B3: async binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Http", "pair" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/http/HttpExports.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Elm_Kernel_Http_pair:664-672 | type: elm/http/2.0.0/src/Http.elm:249,271,286,351,368 -- ALL FIVE visible types (string/bytes/fileBody, string/filePart) confirmed arrow-free AND variable-free | B1: vacuous (no function-capable position) | B2: :666-671 writes only into the returned custom(BODY_PAIR) | B3: none | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "appendN" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_appendN:358-416 | helpers: elm_array_append_n:1036-1087 | type: elm/core/1.0.5/src/Elm/JsArray.elm:179 | B1: :382-387 copy element words verbatim, B1(b) along shared a | B2: writes confined to fresh resultArr | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "empty" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_empty:192-195 | type: elm/core/1.0.5/src/Elm/JsArray.elm:53 (JsArray a) | B1: no argument (zero-arg CAF) | B2: one allocation, no store outside result | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "foldl" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_foldl:651-653 | helpers: foldImpl:576-649 | type: elm/core/1.0.5/src/Elm/JsArray.elm:129 | B1: apply-only via eco_apply_closure_eval :184; acc by identity :638-639 | B2: roots + stack locals only :598-623 | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "foldr" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_foldr:655-657 | helpers: foldImpl:576-649 (dir :603) | type: elm/core/1.0.5/src/Elm/JsArray.elm:136 | B1: apply-only via eco_apply_closure_eval :184; acc by identity :638 | B2: roots + stack locals only :598-623 | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "indexedMap" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_indexedMap:519-560 | helpers: callBinaryIndexMapClosureTyped:152 | type: elm/core/1.0.5/src/Elm/JsArray.elm:153 | B1: apply-only via eco_apply_closure_eval :161; elems are args only | B2: no store outside result | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "initialize" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_initialize:422-455 | helpers: callUnaryInitClosureTyped:80, pushTypedResult:126 | type: elm/core/1.0.5/src/Elm/JsArray.elm:80 | B1: apply-only via eco_apply_closure_eval :89 | B2: only the result builder mutated | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "initializeFromList" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp", "elm-kernel-cpp/src/core/JsArray.cpp", "elm-kernel-cpp/src/core/JsArray.hpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_initializeFromList:457-461 | helpers: JsArray.cpp:initializeFromList:14 | type: elm/core/1.0.5/src/Elm/JsArray.elm:95 | B1: no closure param; heads by identity :40, suffix view :54-72 | B2: writes only fresh arr | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "length" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_length:204-208 | type: elm/core/1.0.5/src/Elm/JsArray.elm:67 (JsArray a -> Int) | B1: elements never read, only ElmArray::length :207 | B2: no writes of any kind | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "map" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_map:463-517 | helpers: pushTypedResult:126 | type: elm/core/1.0.5/src/Elm/JsArray.elm:143 | B1: apply-only via eco_apply_closure_eval :509; elems are args only :494-497 | B2: no store outside result | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "push" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_push:268-318 | helpers: copyAndExtendForPush:711 | type: elm/core/1.0.5/src/Elm/JsArray.elm:122 | B1: :297-299 copy words verbatim, :306 stores value unchanged | B2: writes confined to fresh dst | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "singleton" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_singleton:197-202 | helpers: elm_array_singleton_box:694 | type: elm/core/1.0.5/src/Elm/JsArray.elm:60 (a -> JsArray a) | B1: :199-200 move the arg word unchanged into elements[0] | B2: no store outside result | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "slice" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_slice:320-356 | helpers: elm_array_slice:800-833 | type: elm/core/1.0.5/src/Elm/JsArray.elm:169 | B1: :342-344 copy a contiguous run of element words verbatim, B1(b) | B2: writes confined to fresh dst | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "unsafeGet" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_unsafeGet:210-223 | type: elm/core/1.0.5/src/Elm/JsArray.elm:105 (Int -> JsArray a -> a) | B1: :215 reads the slot, :221 returns the stored word unchanged, B1(b) | B2: read-only apart from primitive boxing | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "JsArray", "unsafeSet" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_unsafeSet:225-266 | helpers: copyForUnsafeSet:888 | type: elm/core/1.0.5/src/Elm/JsArray.elm:115 | B1: :244-246 copy words verbatim, :253 stores value unchanged, B1(b) | B2: writes confined to fresh dst | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "addField" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_addField:1802-1850 | helpers: none | type: INFERRED elm/json/1.1.4/src/Json/Encode.elm:202 (String -> Value -> Value -> Value); Value nullary | B1: vacuous (no function-capable position) | B2: result-only writes :1822-1847 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "addEntry" )
          , TypeFaithful
                { scope =
                    -- UPGRADED once the occurrence became SOLVED. This shape
                    -- previously asserted only arity plus first-param-is-an-
                    -- arrow, because `emptyArray`/`wrap` are `CTrue` and left
                    -- the accumulator and result as unsolved flex vars, so a
                    -- shape naming `Value` matched nothing and the row silently
                    -- never applied. The intrinsic annotation (TYPE_KERNEL_001)
                    -- now pins those positions, so the full claim is both
                    -- checkable and true: the encoder consumes exactly the
                    -- folded element, and the accumulator, the encoder's result
                    -- and the kernel's result are all the same `Value`.
                    TransportsAs
                        (TsFun (TsFun (TsVar "a") tsValue)
                            (TsFun (TsVar "a") (TsFun tsValue tsValue))
                        )
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_addEntry:1761-1793 | type: DECLARED (a -> Value) -> a -> Value -> Value, pinned equal to the intrinsic annotation by KernelLicenseTest; no aliasing def, used partially applied at Json/Encode.elm:162/170/178 | B1: apply-only, eco_apply_closure :1772 is func's ONLY use; entry passed as its arg :1771 | B2: no static/global/task write; arrayHP/encodedHP are StackRootGuard locals :1769-1783 | B3: cons :1782 allocates a LIST CELL over the callback's RETURN, never a closure; no allocClosure/Tag_Closure in file | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "decodeBool" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeBool:1402-1404 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:86 (Decoder Bool) | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "decodeFloat" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeFloat:1410-1412 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:112 (Decoder Float) | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "decodeInt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeInt:1406-1408 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:99 (Decoder Int) | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "decodeString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeString:1398-1400 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:73 (Decoder String) | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "decodeValue" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeValue:1438-1440 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:685 (Decoder Value); Value nullary | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "emptyArray" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_emptyArray:1737-1747 | helpers: none | type: INFERRED elm/json/1.1.4/src/Json/Encode.elm:162 (() -> Value); A3: Elm applies (), C++ 0 params; inert, arity-agnostic unify | B1: vacuous (no function-capable position) | B2: fresh ENC_ARRAY, listNil :1745 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "emptyObject" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_emptyObject:1749-1759 | helpers: none | type: INFERRED elm/json/1.1.4/src/Json/Encode.elm:203 (() -> Value); A3: Elm applies (), C++ 0 params; inert, arity-agnostic unify | B1: vacuous (no function-capable position) | B2: fresh ENC_OBJECT, listNil :1757 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "encode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_encode:1577-1588 | helpers: elmToJson:1290-1386 | type: elm/json/1.1.4/src/Json/Encode.elm:61 (Int -> Value -> String) | B1: vacuous (no function-capable position) | B2: fresh String result only :1586 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Json", "encodeNull" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_encodeNull:1730-1735 | helpers: none | type: elm/json/1.1.4/src/Json/Encode.elm:141 (Value), nullary, no param | B1: vacuous (no function-capable position) | B2: embedded constant, no alloc | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "List", "cons" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp", "elm-kernel-cpp/src/core/List.cpp" ]
                , evidence = "class: cheap | entry: ListExports.cpp:Elm_Kernel_List_cons:276-283 (ABI :288-304) | helpers: List.cpp:cons:18-20 | type: elm/core/1.0.5/src/List.elm:106 | B1: head word stored verbatim in the fresh cell, B1(b) MOVE along a | B2: no static/global/cache/task write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "List", "fromArray" )
          , TypeFaithful
                { scope = TransportsAs (TsFun (tsList (TsVar "a")) (tsList (TsVar "a")))
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: cheap | entry: ListExports.cpp:Elm_Kernel_List_fromArray:306-354 | type: DECLARED List a -> List a, pinned equal to the intrinsic annotation (TYPE_KERNEL_001) which is what SOLVES the occurrence -- the earlier Array/JsArray shapes matched nothing because the non-List side was an unsolved var | B1: B1(b)/B1(c) only -- Nil and already-Cons inputs return the ARGUMENT by identity :310-330, and the conversion copies element words verbatim | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure; allocation is list cells | audited: 2026-08-20"
                }
          )
        , ( ( "List", "map2" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_map2:592-600 | helpers: kernelListMapN:432-590, appendClosureResult:233 | type: elm/core/1.0.5/src/List.elm:437 | B1: apply-only via eco_apply_closure_eval :567-569 | B2: call-local vectors, roots unwound :581 | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "List", "map3" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_map3:602-611 | helpers: kernelListMapN:432-590 (n=3 at :609) | type: elm/core/1.0.5/src/List.elm:443 | B1: apply-only via eco_apply_closure_eval :567-569 | B2: call-local vectors, roots unwound :581 | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "List", "map4" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_map4:613-623 | helpers: kernelListMapN:432-590 (n=4 at :621) | type: elm/core/1.0.5/src/List.elm:449 | B1: apply-only via eco_apply_closure_eval :567-569 | B2: call-local vectors, roots unwound :581 | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "List", "map5" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_map5:625-637 | helpers: kernelListMapN:432-590 (n=5 at :635) | type: elm/core/1.0.5/src/List.elm:455 | B1: apply-only via eco_apply_closure_eval :567-569 | B2: call-local vectors, roots unwound :581 | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "List", "toArray" )
          , TypeFaithful
                { scope = TransportsAs (TsFun (tsList (TsVar "a")) (tsList (TsVar "a")))
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: cheap | entry: ListExports.cpp:Elm_Kernel_List_toArray:356-392 | type: DECLARED List a -> List a, pinned equal to the intrinsic annotation (TYPE_KERNEL_001); the consumer StringOps::join takes a cons list (StringOps.cpp:659) | B1: B1(b)/B1(c) only -- Nil and Cons inputs return the ARGUMENT by identity :362-375; the fallback copies element words via listToVectorU64 | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "List", "sortBy" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_sortBy:759-830 | helpers: listFromPermutation:741, Utils.cpp:compare:437 | type: elm/core/1.0.5/src/List.elm:484 | B1: apply-only via eco_apply_closure :787; result = permutation :828 | B2: no retention; cmp read-only | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "List", "sortWith" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_sortWith:832-887 | helpers: listFromPermutation:741 | type: elm/core/1.0.5/src/List.elm:502 | B1: apply-only via eco_apply_closure :873; result = permutation :885 | B2: call-local buffers, roots balanced :868-883 | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "NativeDriver", "lowerAndLink" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/NativeDriverExports.cpp", "eco-kernel-cpp/src/eco/NativeDriver.cpp" ]
                , evidence = "class: vacuous | entry: NativeDriverExports.cpp:Eco_Kernel_NativeDriver_lowerAndLink:9-13 | helpers: NativeDriver.cpp:lowerAndLink:88-98 | type: Eco/NativeDriver.elm:46 | B1: vacuous (no function-capable position) | B2: three Strings in a tuple3 :94-97; no statics in the file | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "NativeDriver", "lowerAndLinkBytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/NativeDriverExports.cpp", "eco-kernel-cpp/src/eco/NativeDriver.cpp" ]
                , evidence = "class: vacuous | entry: NativeDriverExports.cpp:Eco_Kernel_NativeDriver_lowerAndLinkBytes:15-18 | helpers: NativeDriver.cpp:lowerAndLinkBytes:100-108 | type: Eco/NativeDriver.elm:58 | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :104-105; no statics | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Parser", "chompBase10" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_chompBase10:284-295 | helpers: resolveString:81-86 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:755 | B1: vacuous (no function-capable position) | B2: no cross-call storage; returns a raw int64_t | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Parser", "consumeBase" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_consumeBase:299-312 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:659 | B1: vacuous (no function-capable position) | B2: no cross-call storage in ParserExports.cpp | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Parser", "consumeBase16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_consumeBase16:316-336 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:664 | B1: vacuous (no function-capable position) | B2: no cross-call storage in ParserExports.cpp | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Parser", "findSubString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_findSubString:240-281 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:1131 | B1: vacuous (no function-capable position) | B2: no cross-call storage; StackRootGuard :246 is call-scoped | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Parser", "isAsciiCode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_isAsciiCode:129-134 | helpers: resolveString:81-86 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:1118 | B1: vacuous (no function-capable position) | B2: no cross-call storage; result is a boxed Bool :133 | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Parser", "isSubChar" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: full | entry: ParserExports.cpp:Elm_Kernel_Parser_isSubChar:142-189 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:1110 ((Char -> Bool) -> Int -> String -> Int) | B1: apply-only via eco_apply_closure_typed :179 (sole eco_apply site); decode :147, root :148 | B2: only static is the const layout array :175 | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Parser", "isSubString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_isSubString:195-233 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:1090 | B1: vacuous (no function-capable position) | B2: no cross-call storage; StackRootGuard :203 is call-scoped | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Process", "exit" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/ProcessExports.cpp", "eco-kernel-cpp/src/eco/Process.cpp" ]
                , evidence = "class: vacuous | entry: ProcessExports.cpp:Eco_Kernel_Process_exit:9-11 | helpers: Process.cpp:exit:227-234 | type: Eco/Process.elm:49 | B1: vacuous (no function-capable position) | B2: nothing captured, nothing stored; ::exit() at :231 | B3: no closure fabricated at all | audited: 2026-08-20"
                }
          )
        , ( ( "Process", "spawn" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/ProcessExports.cpp", "eco-kernel-cpp/src/eco/Process.cpp" ]
                , evidence = "class: vacuous | entry: ProcessExports.cpp:Eco_Kernel_Process_spawn:13-15 | helpers: Process.cpp:spawn:236-243 | type: Eco/Process.elm:56 | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :240-242, Strings only | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Process", "spawnProcess" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/ProcessExports.cpp", "eco-kernel-cpp/src/eco/Process.cpp" ]
                , evidence = "class: vacuous | entry: ProcessExports.cpp:Eco_Kernel_Process_spawnProcess:17-19 | type: Eco/Process.elm:67-74 | B1: vacuous (no function-capable position) | B2: 5-field record payload :253-259; s_streamHandles:154 maps int64->fd, no Elm value | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Process", "wait" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/ProcessExports.cpp", "eco-kernel-cpp/src/eco/Process.cpp" ]
                , evidence = "class: vacuous | entry: ProcessExports.cpp:Eco_Kernel_Process_wait:21-23 | type: Eco/Process.elm:93 | B1: vacuous (no function-capable position) | B2: only an unboxed Int pid captured :267-270; the resume :217 is the runtime's OWN closure | B3: async binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Regex", "contains" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_contains:223-240 | helpers: getCompiledRegex:65-78 | type: elm/regex/1.0.0/src/Regex.elm:117 | B1: vacuous (no function-capable position) | B2: the static regex table is only READ :75 | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Regex", "findAtMost" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_findAtMost:242-308 | type: elm/regex/1.0.0/src/Regex.elm:252 | B1: vacuous (no function-capable position) | B2: deque :262 is C-stack local, roots restored :298/:306, table read-only | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Regex", "fromStringWith" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_fromStringWith:176-221 | type: elm/regex/1.0.0/src/Regex.elm:82 | B1: vacuous (no function-capable position) | B2: table write :205 stores a srell::regex*, not an Elm value; result Custom is unboxed ints :212 | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Regex", "never" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_never:152-169 | helpers: registerRegex:42-46 | type: elm/regex/1.0.0/src/Regex.elm:96 | B1: vacuous (no function-capable position) | B2: table write stores a srell::regex*; result Custom is all unboxed ints :164 | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Regex", "replaceAtMost" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: full | entry: RegexExports.cpp:Elm_Kernel_Regex_replaceAtMost:310-398 | type: elm/regex/1.0.0/src/Regex.elm:264 (Int -> Regex -> (Match -> String) -> String -> String) | B1: apply-only via eco_apply_closure :378 (sole eco_apply site); decode :335, root :336 | B2: nothing outlives the call; table read-only :317 | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Regex", "splitAtMost" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_splitAtMost:400-464 | type: elm/regex/1.0.0/src/Regex.elm:240 | B1: vacuous (no function-capable position) | B2: deque :422 is call-local, roots restored :454/:462, table read-only | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Runtime", "dirname" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/RuntimeExports.cpp", "eco-kernel-cpp/src/eco/Runtime.cpp" ]
                , evidence = "class: vacuous | entry: RuntimeExports.cpp:Eco_Kernel_Runtime_dirname:9-11 | helpers: Runtime.cpp:dirname:64-67 | type: Eco/Runtime.elm:21 | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :66); s_savedState untouched | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Runtime", "random" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco/RuntimeExports.cpp", "eco-kernel-cpp/src/eco/Runtime.cpp" ]
                , evidence = "class: vacuous | entry: RuntimeExports.cpp:Eco_Kernel_Runtime_random:13-15 | helpers: Runtime.cpp:random:69-72 | type: Eco/Runtime.elm:28 | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :71); statics :41-42 are C++ PRNG state | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Scheduler", "andThen" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: full | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_andThen:30-37 | helpers: Scheduler.cpp:taskAndThen:149-152 | type: elm/core/1.0.5/src/Task.elm:207 ((a -> Task x b) -> Task x a -> Task x b) | B1: BOTH words stored VERBATIM (:33-35 decode, taskAndThen :151 allocTask(Task_AndThen, nil, callback, nil, task)); the scheduler later applies THAT callback to THAT task's value - the callback is never substituted, wrapped or re-created, so param1's `a` = param2's `a` and param1's result `Task x b` = the result, exactly as the type's variable-sharing graph states | B2: the ONLY store is into the Task this call RETURNS (alloc::allocTask, HeapHelpers.hpp:2047-2069, write :2064-2067) - no static, no mailbox, no other call's object; the scheduler reads it back out of THAT SAME Task | B3: no allocClosure/Tag_Closure - allocTask is a record constructor, not a closure mint | audited: 2026-08-25"
                }
          )
        , ( ( "Scheduler", "fail" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: cheap | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_fail:23-28 | helpers: Scheduler.cpp:taskFail:139-142 | type: elm/core/1.0.5/src/Task.elm:92 (x -> Task x a) | B1: the arg word is stored unchanged (:26, taskFail :141 allocTask(Task_Fail, error, nil, nil, nil)) and handed back at the SAME `x` the type names | B2: the ONLY store is into the Task this call RETURNS (alloc::allocTask, HeapHelpers.hpp:2047-2069, write :2064-2067) - no static, no mailbox, no other call's object; the scheduler reads it back out of THAT SAME Task | B3: no allocClosure/Tag_Closure - allocTask is a record constructor, not a closure mint | audited: 2026-08-25"
                }
          )
        , ( ( "Scheduler", "onError" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: full | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_onError:39-46 | helpers: Scheduler.cpp:taskOnError:154-157 | type: elm/core/1.0.5/src/Task.elm:227 ((x -> Task y a) -> Task x a -> Task y a) | B1: both words stored VERBATIM (:42-44, taskOnError :156); the handler is applied to the inner task's error and never substituted, and on the SUCCESS path the inner `a` passes straight through to the result's `a` - both edges are the type's shared variables | B2: the ONLY store is into the Task this call RETURNS (alloc::allocTask, HeapHelpers.hpp:2047-2069, write :2064-2067) - no static, no mailbox, no other call's object; the scheduler reads it back out of THAT SAME Task | B3: no allocClosure/Tag_Closure - allocTask is a record constructor, not a closure mint | audited: 2026-08-25"
                }
          )
        , ( ( "Scheduler", "succeed" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: cheap | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_succeed:16-21 | helpers: Scheduler.cpp:taskSucceed:123-126 | type: elm/core/1.0.5/src/Task.elm:78 (a -> Task x a) | B1: the arg word is stored unchanged (:18, taskSucceed :125 allocTask(Task_Succeed, value, nil, nil, nil)) and handed back at the SAME `a` the type names - structurally JsArray.singleton with an opaque carrier | B2: the ONLY store is into the Task this call RETURNS (alloc::allocTask, HeapHelpers.hpp:2047-2069, write :2064-2067) - no static, no mailbox, no other call's object; the scheduler reads it back out of THAT SAME Task | B3: no allocClosure/Tag_Closure - allocTask is a record constructor, not a closure mint | audited: 2026-08-25"
                }
          )
        , ( ( "String", "all" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_all:317-334 | helpers: callCharToBoolClosure:217, snapshotChars:237 | type: elm/core/1.0.5/src/String.elm:615 ((Char -> Bool) -> String -> Bool) | B1: apply-only via eco_apply_closure_typed :329 | B2: no retention | B3: embedded Bool consts | audited: 2026-08-20"
                }
          )
        , ( ( "String", "any" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_any:299-315 | helpers: callCharToBoolClosure:217, snapshotChars:237 | type: elm/core/1.0.5/src/String.elm:604 ((Char -> Bool) -> String -> Bool) | B1: apply-only via eco_apply_closure_typed :310 | B2: no retention | B3: embedded Bool consts | audited: 2026-08-20"
                }
          )
        , ( ( "String", "append" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_append:41-44 | helpers: String.cpp:append:26-28 | type: elm/core/1.0.5/src/String.elm:169 (String -> String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "cons" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_cons:52-56 | helpers: String.cpp:cons:38-40 | type: elm/core/1.0.5/src/String.elm:542 (Char -> String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "contains" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_contains:126-128 | helpers: String.cpp:contains:431-433 | type: elm/core/1.0.5/src/String.elm:299 (String -> String -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: embedded Bool consts | audited: 2026-08-20"
                }
          )
        , ( ( "String", "endsWith" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_endsWith:122-124 | helpers: String.cpp:endsWith:427-429 | type: elm/core/1.0.5/src/String.elm:319 (String -> String -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: embedded Bool consts | audited: 2026-08-20"
                }
          )
        , ( ( "String", "filter" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_filter:281-297 | helpers: callCharToBoolClosure:217, materializeString:250 | type: elm/core/1.0.5/src/String.elm:575 ((Char -> Bool) -> String -> String) | B1: apply-only via eco_apply_closure_typed :294 | B2: C-stack only | B3: string alloc only | audited: 2026-08-20"
                }
          )
        , ( ( "String", "foldl" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_foldl:336-350 | type: elm/core/1.0.5/src/String.elm:584 ((Char -> b -> b) -> b -> String -> b) | B1: apply-only :346 via callFoldClosure:226 -> eco_apply_closure_typed; acc PK_Boxed :199 -> result :338/:349, shared b | B2: accHP :347 | B3: no alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "foldr" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_foldr:352-366 | type: elm/core/1.0.5/src/String.elm:593 ((Char -> b -> b) -> b -> String -> b) | B1: apply-only :362 via callFoldClosure:226 -> eco_apply_closure_typed; acc PK_Boxed :199 -> result :354/:365, shared b | B2: accHP :363 | B3: no alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "fromList" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_fromList:63-66 | helpers: String.cpp:fromList:63-107 | type: elm/core/1.0.5/src/String.elm:520 (List Char -> String; elem type concrete) | B1: vacuous (no function-capable position) | B2: StackRootGuard :84/:99 RAII | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "fromNumber" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_fromNumber:145-151 | helpers: String.cpp:fromNumber:451 | type: 2 aliasing defs, both arrow/var-free: String.elm:458 fromInt Int->String; :494 fromFloat Float->String | B1: vacuous (no function-capable position) | B2: no static/global write | B3: no alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "indexes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_indexes:130-133 | helpers: String.cpp:indexes:435 | type: elm/core/1.0.5/src/String.elm:330 (String -> String -> List Int); alias indices :336 | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "join" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_join:46-49 | helpers: String.cpp:join:30 | type: inferred-from-usage; use-site String.elm:202 (String -> Array String -> String); arrow/var-free | B1: vacuous (no function-capable position) | B2: no static/global write | B3: no alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "length" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_length:18-27 | helpers: String.cpp:length:18-20 | type: elm/core/1.0.5/src/String.elm:112 (String -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "lines" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_lines:78-81 | helpers: String.cpp:lines:179-284 (2 arms) | type: elm/core/1.0.5/src/String.elm:218 (String -> List String) | B1: vacuous (no function-capable position) | B2: root ranges :211/:272 restored :222/:282 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "map" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_map:263-279 | helpers: callCharToCharClosure:206, materializeString:250 | type: elm/core/1.0.5/src/String.elm:566 ((Char -> Char) -> String -> String) | B1: apply-only via eco_apply_closure_eval :276 | B2: C-stack only | B3: string alloc only | audited: 2026-08-20"
                }
          )
        , ( ( "String", "reverse" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_reverse:88-91 | helpers: String.cpp:reverse:395-397 | type: elm/core/1.0.5/src/String.elm:121 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "slice" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_slice:68-71 | helpers: String.cpp:slice:167-169 | type: elm/core/1.0.5/src/String.elm:235 (Int -> Int -> String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "split" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_split:73-76 | helpers: String.cpp:split:175 | type: inferred-from-usage; use-site String.elm:191 (String -> String -> Array String); arrow/var-free | B1: vacuous (no function-capable position) | B2: no static/global write | B3: no alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "startsWith" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_startsWith:118-120 | helpers: String.cpp:startsWith:423-425 | type: elm/core/1.0.5/src/String.elm:309 (String -> String -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: embedded Bool consts, no alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "toFloat" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_toFloat:140-143 | helpers: String.cpp:toFloat:447-449 | type: elm/core/1.0.5/src/String.elm:480 (String -> Maybe Float) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "toInt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_toInt:135-138 | helpers: String.cpp:toInt:443-445 | type: elm/core/1.0.5/src/String.elm:445 (String -> Maybe Int) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "toLower" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_toLower:98-101 | helpers: String.cpp:toLower:403-405 | type: elm/core/1.0.5/src/String.elm:359 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "toUpper" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_toUpper:93-96 | helpers: String.cpp:toUpper:399-401 | type: elm/core/1.0.5/src/String.elm:350 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "trim" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_trim:103-106 | helpers: String.cpp:trim:407-409 | type: elm/core/1.0.5/src/String.elm:405 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "trimLeft" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_trimLeft:108-111 | helpers: String.cpp:trimLeft:411-413 | type: elm/core/1.0.5/src/String.elm:414 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "trimRight" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_trimRight:113-116 | helpers: String.cpp:trimRight:415-417 | type: elm/core/1.0.5/src/String.elm:423 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "uncons" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_uncons:58-61 | helpers: String.cpp:uncons:42-44 | type: elm/core/1.0.5/src/String.elm:553 (String -> Maybe (Char, String); slots concrete) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "String", "words" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_words:83-86 | helpers: String.cpp:words:286-389 (two arms) | type: elm/core/1.0.5/src/String.elm:209 (String -> List String) | B1: vacuous (no function-capable position) | B2: root ranges :321/:372 restored :334/:387 | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Url", "percentDecode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/url/UrlExports.cpp" ]
                , evidence = "class: vacuous | entry: UrlExports.cpp:Elm_Kernel_Url_percentDecode:65-101 | helpers: elmStringToStd:18-20, hexToInt:33-38 | type: elm/url/1.0.0/src/Url.elm:288 | B1: vacuous (no function-capable position) | B2: grep `static` over UrlExports.cpp: zero hits | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Url", "percentEncode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/url/UrlExports.cpp" ]
                , evidence = "class: vacuous | entry: UrlExports.cpp:Elm_Kernel_Url_percentEncode:44-63 | helpers: elmStringToStd:18-20, shouldEncode:23-30 | type: elm/url/1.0.0/src/Url.elm:255 | B1: vacuous (no function-capable position) | B2: grep `static` over UrlExports.cpp: zero hits | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "append" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: cheap | entry: UtilsExports.cpp:Elm_Kernel_Utils_append:161-171 | helpers: Utils.cpp:append:809-833 | type: elm/core/1.0.5/src/Basics.elm:510 | B1: B1(b)/(c); slots copied verbatim, b aliased as tail, no apply | B2: result is sole write target; roots balanced | B3: no closure alloc; slots unwrapped | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "compare" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_compare:14-17 | helpers: Utils.cpp:compare:437-443, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:418 (comparable -> comparable -> Order) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "equal" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: cheap | entry: UtilsExports.cpp:Elm_Kernel_Utils_equal:108-110 | helpers: Utils.cpp:eqHelp:507-720 | type: elm/core/1.0.5/src/Basics.elm:348 (a -> a -> Bool) | B1: reads only :557-696; Tag_Closure arm :713-715 | B2: no static mutable storage; dictEq scratch frame-local | B3: no allocClosure/papCreate | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "ge" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_ge:128-130 | helpers: Utils.cpp:ge:801-803, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:385 (comparable -> comparable -> Bool) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "gt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_gt:124-126 | helpers: Utils.cpp:gt:797-799, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:373 (comparable -> comparable -> Bool) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "le" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_le:120-122 | helpers: Utils.cpp:le:793-795, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:379 (comparable -> comparable -> Bool) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "lt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_lt:116-118 | helpers: Utils.cpp:lt:789-791, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:367 (comparable -> comparable -> Bool) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "notEqual" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: cheap | entry: UtilsExports.cpp:Elm_Kernel_Utils_notEqual:112-114 | helpers: Utils.cpp:eqHelp:507-720 (shared with equal) | type: elm/core/1.0.5/src/Basics.elm:357 (a -> a -> Bool) | B1: reads only :557-696; Tag_Closure arm :713-715 | B2: no static mutable storage | B3: no allocClosure/papCreate | audited: 2026-08-20"
                }
          )
        ]


{-| `List a` / `Value` as shapes. Named so the rows read like the types they
mean, and so a change lands in one place.
-}
tsList : TypeShape -> TypeShape
tsList el =
    TsCon "List" [ el ]


tsValue : TypeShape
tsValue =
    TsCon "Value" []

