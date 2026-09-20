module Compiler.AST.Intern exposing
    ( Intern, empty, disabled, readOnly, size, entries
    , hashCons, widenSets
    , eqExact
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
canonicalising by them would hand back a type that is _keyed_ the same but
_shaped_ differently, silently changing what the compiler emits. The bucket
hash is `specHashOf` (equal structure implies equal hash, which is all a hash
must promise); `==` decides.

The table has three modes, and which one a traversal gets is purely about what
its callers can carry (plan §16): a live `Intern` reads and registers,
`readOnly` reads without registering, `disabled` does neither.

@docs Intern, empty, disabled, readOnly, size
@docs hashCons, widenSets

-}

import Compiler.AST.Monomorphized as Mono exposing (MonoType)
import Data.HashMap as HashMap
import Dict


{-| Structure → canonical object, a read-only view of one, or `Disabled`.

`Disabled` exists because the threaded traversals here
(`TypeSubst.applySubstPure`, `Zonk.canTypeToMono`) have callers with no table in
reach at all — `Analysis.buildCtorShapeFromUnion` runs from `Prune`, after the
monomorphizer's state is gone, and `Monomorphize`'s entry seeding runs before it
exists. Those callers run the same traversal with `disabled`, which makes every
`hashCons` an identity: sound (sharing is never required for correctness), and
cheaper than handing them a throwaway table that would allocate an insert per
node.

`ReadOnly` (K7) is for the callers that DO hold a table but have nowhere to put
an updated one — `Specialize`, which has `MonoState` in scope throughout and can
therefore lend `accum.intern` to a traversal whose result is a bare type. It
probes and hands back the canonical object on a hit, and on a miss keeps the
freshly built node without inserting it. Because it never inserts, it never
produces a new table, so a read-only traversal needs no state threading at any
call site — only an extra ARGUMENT. See `readOnly`.

Coverage measured on a self-compile (plan §16): before K7, 42.04% of composite
`hashCons` calls under the subst engine arrived `Disabled` and were therefore
never shared; the solver engine was already at 1.52% after §15.

-}
type Intern
    = Intern (HashMap.HashMap Canon MonoType) (HashMap.HashMap MonoType MonoType)
    | ReadOnly (HashMap.HashMap Canon MonoType) (HashMap.HashMap MonoType MonoType)
    | Disabled


{-| One table entry: the canonical node, plus — for a record only — its fields
in ascending name order, so that a probe can walk a FRESH record's `Dict.foldl`
(also ascending) in lockstep against it without allocating and without a
`Dict.get` per field. `fields` is `[]` for every other kind.

Built once per canonical node, on the MISS path only (~1 % of probes). The whole
point of the split key type is that the 99 % hit path never builds one: the probe
stays a bare `MonoType` and `HashMap.getBy` compares it against the stored
`Canon` directly.

-}
type alias Canon =
    { node : MonoType
    , fields : List ( String, MonoType )
    }


canonOf : MonoType -> Canon
canonOf mt =
    case mt of
        Mono.MRecord _ fields ->
            { node = mt, fields = Dict.toList fields }

        _ ->
            { node = mt, fields = [] }


canonHash : Canon -> Int
canonHash c =
    Mono.specHashOf c.node


canonEq : Canon -> Canon -> Bool
canonEq a b =
    eqExactAgainst a.node b


{-| An empty table.
-}
empty : Intern
empty =
    Intern HashMap.empty HashMap.empty


{-| A table that never canonicalises. See the `Intern` docs.
-}
disabled : Intern
disabled =
    Disabled


{-| A probe-only view of a table (K7 of
`plans/mono-comparable-key-optimization.md`).

Hand this to a traversal that has a table available but no way to thread an
updated one back — `TypeSubst.applySubstPureRO` and its callers in
`Monomorphize.Specialize`. Every composite the traversal builds is still offered
to `hashCons`, so a structure the table already holds is returned as the
EXISTING object (real sharing, and therefore real retention collapse); a
structure it does not hold is kept as built and NOT registered.

The table is never modified, so `hashCons` always returns the very value it was
given and no caller has anything to write back.

Idempotent, and `Disabled` stays disabled: the conversion is a view, not a
decision about whether interning is wanted.

-}
readOnly : Intern -> Intern
readOnly intern =
    case intern of
        Intern m w ->
            ReadOnly m w

        ReadOnly _ _ ->
            intern

        Disabled ->
            intern


{-| Number of distinct structures canonicalised so far.
-}
size : Intern -> Int
size intern =
    case intern of
        Intern m _ ->
            HashMap.size m

        ReadOnly m _ ->
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

        Intern m w ->
            case mt of
                Mono.MList _ _ ->
                    probe mt m w intern

                Mono.MTuple _ _ ->
                    probe mt m w intern

                Mono.MRecord _ _ ->
                    probe mt m w intern

                Mono.MCustom _ _ _ _ ->
                    probe mt m w intern

                Mono.MFunction _ _ _ _ ->
                    probe mt m w intern

                _ ->
                    -- Leaves and `MVar`: nothing to share beyond the two words
                    -- they already occupy.
                    ( mt, intern )

        ReadOnly m _ ->
            case mt of
                Mono.MList _ _ ->
                    probeRO mt m intern

                Mono.MTuple _ _ ->
                    probeRO mt m intern

                Mono.MRecord _ _ ->
                    probeRO mt m intern

                Mono.MCustom _ _ _ _ ->
                    probeRO mt m intern

                Mono.MFunction _ _ _ _ ->
                    probeRO mt m intern

                _ ->
                    ( mt, intern )


{-| `intern` is passed alongside its own unwrapped map so a HIT can hand the
caller back the very table value it was given. Rebuilding `Intern m` there would
allocate one wrapper per hit — and hits are ~99% of calls (plan §13).
-}
probe : MonoType -> HashMap.HashMap Canon MonoType -> HashMap.HashMap MonoType MonoType -> Intern -> ( MonoType, Intern )
probe mt m w intern =
    case HashMap.getBy Mono.specHashOf eqExactAgainst mt m of
        Just canonical ->
            ( canonical, intern )

        Nothing ->
            ( mt, Intern (HashMap.insert canonHash canonEq (canonOf mt) mt m) w )


{-| The read-only probe: identical to `probe` on a hit, and a no-op on a miss.

The table value is returned unchanged on BOTH paths, which is what makes a
read-only traversal free of state threading — and it also means
`Engine.withIntern`'s "did the table grow?" guard can never fire for one.

-}
probeRO : MonoType -> HashMap.HashMap Canon MonoType -> Intern -> ( MonoType, Intern )
probeRO mt m intern =
    case HashMap.getBy Mono.specHashOf eqExactAgainst mt m of
        Just canonical ->
            ( canonical, intern )

        Nothing ->
            ( mt, intern )


{-| EXACT structural equality — deliberately `==`, not `eqKeySpec`. See the
module docs: the key equivalences merge structures that must not be
substituted for one another.

Consequence of the Phase-1/3 `LTop`/`LVar` split
(`plans/lss-unknown-elimination.md`), noted so it is not mistaken for a bug:
`==` separates the two ⊤ labels, so an `LTop`-labelled and an
`LVar`-labelled twin of one structure become two intern entries. Since Phase 3
they also hash differently (`Mono.annoHash` separates `LVar n` from `LTop`), so
they land in different buckets rather than colliding in one — cheaper than the
Phase-1 situation, and still not an artifact change.

-}
eqExact : MonoType -> MonoType -> Bool
eqExact a b =
    eqExactAgainst a (canonOf b)


{-| EXACT structural equality of a FRESH node against a stored entry: decides
precisely what `==` decides, but shaped so that on the hit path it is one packed
`Int` compare plus one word compare per slot, with no descent into the children.

Why that is a saving at all: `==` on a composite reaches the kernel's structural
walk, and for `MRecord` that means comparing two red-black trees — two vector
allocations, an in-order walk of both, and a string compare per field name — even
though the children on both sides are already canonical and would have compared
equal on the first word. The container shells were the entire cost.

Why it is still exactly `==` (the byte-identity argument): the leading packed hash
is computed from the children's stored hashes, so equal structures always produce
equal packed hashes and the test can never reject an equal pair; what follows is
the same field-wise `==` tests in a different order, and `&&` may be reordered
freely for total, pure predicates. The record arm is content equality between two
ascending in-order sequences, which is what the kernel's `dictEq` decides as well.
Children are compared with `==`, NOT with this function, because a caller may cons
a node whose children were rebuilt by a pure rebuilder and are therefore
structurally equal to the canonical ones without being the same object; `==` still
answers correctly there, it is merely slower.

-}
eqExactAgainst : MonoType -> Canon -> Bool
eqExactAgainst a c =
    case a of
        Mono.MRecord ha fa ->
            case c.node of
                Mono.MRecord hb _ ->
                    ha == hb && eqFieldsAgainst fa c.fields

                _ ->
                    False

        Mono.MCustom ha homeA nameA argsA ->
            case c.node of
                Mono.MCustom hb homeB nameB argsB ->
                    ha == hb && nameA == nameB && homeA == homeB && eqChildren argsA argsB

                _ ->
                    False

        Mono.MFunction ha annoA argsA retA ->
            case c.node of
                Mono.MFunction hb annoB argsB retB ->
                    ha == hb && annoA == annoB && retA == retB && eqChildren argsA argsB

                _ ->
                    False

        Mono.MTuple ha xs ->
            case c.node of
                Mono.MTuple hb ys ->
                    ha == hb && eqChildren xs ys

                _ ->
                    False

        Mono.MList ha x ->
            case c.node of
                Mono.MList hb y ->
                    ha == hb && x == y

                _ ->
                    False

        _ ->
            -- Leaves never reach a probe (`hashCons` filters them out), but the
            -- function must stay total and `==`-exact.
            a == c.node


eqChildren : List MonoType -> List MonoType -> Bool
eqChildren xs ys =
    case xs of
        [] ->
            List.isEmpty ys

        x :: restX ->
            case ys of
                y :: restY ->
                    x == y && eqChildren restX restY

                [] ->
                    False


{-| Sentinel parked in the accumulator after the first field mismatch. A record
field name is a lower-case identifier and can never be `""`, so once this is in
the accumulator every later step returns it again and the fold finishes
non-empty, i.e. failed.
-}
failedFields : List ( String, MonoType )
failedFields =
    [ ( "", Mono.MUnit ) ]


{-| The fresh record equals the stored one iff walking it in ascending name order
consumes the stored list EXACTLY. Size equality is implied: fewer fresh fields
leave a non-empty remainder, more fresh fields run into `[]`.
-}
eqFieldsAgainst : Dict.Dict String MonoType -> List ( String, MonoType ) -> Bool
eqFieldsAgainst fresh stored =
    List.isEmpty (Dict.foldl eqFieldStep stored fresh)


eqFieldStep : String -> MonoType -> List ( String, MonoType ) -> List ( String, MonoType )
eqFieldStep name t remaining =
    case remaining of
        ( n, ct ) :: more ->
            if n == name && ct == t then
                more

            else
                failedFields

        [] ->
            failedFields


{-| An EXACT "has the table changed" stamp for the write-back guards.

`size` counts canonicalised structures and is report semantics; it deliberately
ignores the widen memo. A guard must not, or a run that only added memo entries
would write nothing back and throw them away. Both tables only ever grow, so
equal counts imply the same value.

-}
entries : Intern -> Int
entries intern =
    case intern of
        Intern m w ->
            HashMap.size m + HashMap.size w

        ReadOnly m w ->
            HashMap.size m + HashMap.size w

        Disabled ->
            0


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
    -- Step 11b: memoised per INPUT node. Widening is a pure function of the
    -- input, and the input is canonical (every producer hash-conses bottom
    -- up), so one entry answers every later enqueue of the same demand type.
    -- Leaves and `MVar` are the identity and never enter the memo.
    case intern0 of
        Intern _ w ->
            case HashMap.get Mono.specHashOf widenEq monoType w of
                Just widened ->
                    ( widened, intern0 )

                Nothing ->
                    let
                        ( widened, intern1 ) =
                            widenSetsGo monoType intern0
                    in
                    ( widened, putWiden monoType widened intern1 )

        _ ->
            -- ReadOnly and Disabled do not memoise: the first must not grow,
            -- and the second canonicalises nothing, so there is no canonical
            -- input to key on.
            widenSetsGo monoType intern0


{-| The memo's key equality. `==` on the input node, which is pointer-fast for a
canonical input and correctly SEPARATES differently-annotated twins: two inputs
that differ only in an arrow's label are two entries mapping to the same widened
object, which is exact.
-}
widenEq : MonoType -> MonoType -> Bool
widenEq a b =
    a == b


putWiden : MonoType -> MonoType -> Intern -> Intern
putWiden key widened intern =
    case intern of
        Intern m w ->
            Intern m (HashMap.insert Mono.specHashOf widenEq key widened w)

        _ ->
            intern


widenSetsGo : MonoType -> Intern -> ( MonoType, Intern )
widenSetsGo monoType intern0 =
    case monoType of
        Mono.MFunction _ _ args result ->
            let
                ( args1, i1 ) =
                    widenList args intern0

                ( result1, i2 ) =
                    widenSets result i1
            in
            hashCons (Mono.mFunction Mono.topWiden args1 result1) i2

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
