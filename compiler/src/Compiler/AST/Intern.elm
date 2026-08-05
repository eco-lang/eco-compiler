module Compiler.AST.Intern exposing
    ( Intern, empty, disabled, size
    , hashCons
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
@docs hashCons

-}

import Compiler.AST.Monomorphized as Mono exposing (MonoType)
import Data.HashMap as HashMap


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
                    probe mt m

                Mono.MTuple _ _ ->
                    probe mt m

                Mono.MRecord _ _ ->
                    probe mt m

                Mono.MCustom _ _ _ _ ->
                    probe mt m

                Mono.MFunction _ _ _ _ ->
                    probe mt m

                _ ->
                    -- Leaves and `MVar`: nothing to share beyond the two words
                    -- they already occupy.
                    ( mt, intern )


probe : MonoType -> HashMap.HashMap MonoType MonoType -> ( MonoType, Intern )
probe mt m =
    case HashMap.get Mono.specHashOf eqExact mt m of
        Just canonical ->
            ( canonical, Intern m )

        Nothing ->
            ( mt, Intern (HashMap.insert Mono.specHashOf eqExact mt mt m) )


{-| EXACT structural equality — deliberately `==`, not `eqKeySpec`. See the
module docs: the key equivalences merge structures that must not be
substituted for one another.
-}
eqExact : MonoType -> MonoType -> Bool
eqExact a b =
    a == b
