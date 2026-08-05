module Compiler.AST.Intern exposing
    ( Intern, empty, disabled, size
    , hashCons, widenSets
    )

{-| Construction-time hash-consing for `MonoType` (K6 of
`plans/mono-comparable-key-optimization.md`).

A self-compile builds **14,778,865 type nodes for 116,322 distinct types —
99.2% duplicates** (plan §13). This table makes the duplicates share one
object: a constructor probes for the structure it is about to return and hands
back the canonical copy if it already exists.

Two consequences, and the second is the one that matters:

1.  Equality gets cheap. The runtime's structural equality short-circuits on
    pointer identity (`elm-kernel-cpp/src/core/Utils.cpp`), so two canonical
    types compare in O(1) — which is why `eqKeySpec`/`eqKeyLayout` try `==`
    first.
2.  **Retention collapses.** 14.8M live type objects become 116K shared ones.
    GC cost here follows SURVIVORS, not allocation volume — that is exactly
    why K4 cut allocation 21% and bought nothing (plan §11) — so sharing is
    the mechanism with a plausible path to wall time.

**Canonicalisation is by EXACT structure (`==`), never by comparable-key
equality.** The key equivalences deliberately merge distinct structures —
`MVar _ CNumber` keys as `MInt` (D4), `MVar` ids are erased (MONO\_003) — so
canonicalising by them would hand back a type that is *keyed* the same but
*shaped* differently, silently changing what the compiler emits. The bucket
hash is `specHashOf` (equal structure implies equal hash, which is all a hash
must promise); `==` decides.

@docs Intern, empty, disabled, size
@docs hashCons, widenSets

-}

import Compiler.AST.Monomorphized as Mono exposing (MonoType)
import Data.HashMap as HashMap
import Dict


{-| Structure → canonical object, or `Disabled`.

`Disabled` exists because the threaded traversal in
`Compiler.Monomorphize.TypeSubst` has callers that cannot supply a table:
`applySubstPure` is public and is called from `Specialize`, `Analysis` and
`Monomorphize` in positions with no state to thread. Those callers run the same
traversal with `disabled`, which makes every `hashCons` an identity — sound
(sharing is never required for correctness), and cheaper than handing them a
throwaway table that would allocate an insert per node.

-}
type Intern
    = Intern (HashMap.HashMap MonoType MonoType)
    | Disabled


{-| An empty table.
-}
empty : Intern
empty =
    Intern HashMap.empty


{-| A table that never canonicalises. See the `Intern` docs.
-}
disabled : Intern
disabled =
    Disabled


{-| Number of distinct structures canonicalised so far.
-}
size : Intern -> Int
size intern =
    case intern of
        Intern m ->
            HashMap.size m

        Disabled ->
            0


{-| Return the canonical copy of a type, registering it if this structure has
not been seen. Only the TOP node is considered — callers hash-cons bottom-up,
so the children are already canonical and `==` on them short-circuits on
pointer identity.
-}
hashCons : MonoType -> Intern -> ( MonoType, Intern )
hashCons mt intern =
    case intern of
        Disabled ->
            ( mt, intern )

        Intern m ->
            case mt of
                Mono.MList _ _ ->
                    probe mt m intern

                Mono.MTuple _ _ ->
                    probe mt m intern

                Mono.MRecord _ _ ->
                    probe mt m intern

                Mono.MCustom _ _ _ _ ->
                    probe mt m intern

                Mono.MFunction _ _ _ _ ->
                    probe mt m intern

                _ ->
                    -- Leaves and `MVar`: nothing to share beyond the two words
                    -- they already occupy.
                    ( mt, intern )


{-| `intern` is passed alongside its own unwrapped map so a HIT can hand the
caller back the very table value it was given. Rebuilding `Intern m` there would
allocate one wrapper per hit — and hits are ~99% of calls (plan §13).
-}
probe : MonoType -> HashMap.HashMap MonoType MonoType -> Intern -> ( MonoType, Intern )
probe mt m intern =
    case HashMap.get Mono.specHashOf eqExact mt m of
        Just canonical ->
            ( canonical, intern )

        Nothing ->
            ( mt, Intern (HashMap.insert Mono.specHashOf eqExact mt mt m) )


{-| EXACT structural equality — deliberately `==`, not `eqKeySpec`. See the
module docs: the key equivalences merge structures that must not be
substituted for one another.
-}
eqExact : MonoType -> MonoType -> Bool
eqExact a b =
    a == b


{-| `Mono.widenSets` threading the table — the hash-consed twin of the pure
rebuilder in `Compiler.AST.Monomorphized` (it lives HERE because that module
cannot import this one: `Intern` imports it).

Its output is the annotation-insensitive **spec-registry key**
(`Engine.enqueueSpec` / `enqueueSpecKeyed` under LSS), and the registry probes
that key through `Mono.eqKeySpec`, whose `identicalOr` fast path compares
pointers first. A freshly rebuilt key can never take that path, so an
uncanonicalised widen forces a full structural walk on every enqueue.
Canonicalising it also makes the common no-op case free: a type whose arrows are
already `LTop` widens to a structure that is `==` to itself, so the probe hands
back the very object that came in.

Keep this in step with `Mono.widenSets` — same arms, same order, `LTop` on every
arrow. A divergence produces a different widened structure and therefore a
different registry key, changing specialization identity with no compile error;
the bootstrap is the gate.

**One deliberate divergence, and it is safe.** `Mono.widenSets` rebuilds a
record with `Dict.map`, which preserves the input dictionary's red-black tree
SHAPE; threading state forces `Dict.foldl` + `insert` from empty here, which
gives the canonical ascending-insert shape instead. Elm's `==` on `Dict` is
structural over that tree, so the two can differ for an extension record whose
base fields were inserted out of order — but only in the `==` direction that
matters least: this form makes MORE content-equal records compare equal, never
fewer. `eqKeySpec` decides record equality on `Dict.toList` (content, not
shape), so the set of colliding spec keys is identical either way and only the
probe gets faster. `specHashOf` folds with `Dict.foldl` (ascending), so the
bucket hash is shape-independent too.

-}
widenSets : MonoType -> Intern -> ( MonoType, Intern )
widenSets monoType intern0 =
    case monoType of
        Mono.MFunction _ _ args result ->
            let
                ( args1, i1 ) =
                    widenList args intern0

                ( result1, i2 ) =
                    widenSets result i1
            in
            hashCons (Mono.mFunction Mono.LTop args1 result1) i2

        Mono.MList _ inner ->
            let
                ( inner1, i1 ) =
                    widenSets inner intern0
            in
            hashCons (Mono.mList inner1) i1

        Mono.MTuple _ elems ->
            let
                ( elems1, i1 ) =
                    widenList elems intern0
            in
            hashCons (Mono.mTuple elems1) i1

        Mono.MRecord _ fields ->
            let
                ( fields1, i1 ) =
                    Dict.foldl
                        (\k t ( acc, i ) ->
                            let
                                ( t1, i2 ) =
                                    widenSets t i
                            in
                            ( Dict.insert k t1 acc, i2 )
                        )
                        ( Dict.empty, intern0 )
                        fields
            in
            hashCons (Mono.mRecord fields1) i1

        Mono.MCustom _ home name args ->
            let
                ( args1, i1 ) =
                    widenList args intern0
            in
            hashCons (Mono.mCustom home name args1) i1

        _ ->
            ( monoType, intern0 )


widenList : List MonoType -> Intern -> ( List MonoType, Intern )
widenList types intern0 =
    case types of
        [] ->
            ( [], intern0 )

        t :: rest ->
            let
                ( t1, i1 ) =
                    widenSets t intern0

                ( rest1, i2 ) =
                    widenList rest i1
            in
            ( t1 :: rest1, i2 )
