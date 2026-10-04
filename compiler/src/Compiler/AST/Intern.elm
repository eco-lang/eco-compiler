module Compiler.AST.Intern exposing
    ( Intern, empty, disabled, readOnly, size, entries
    , hashCons, widenSets
    , eqExact
    )

{-| Monomorphization builds the same `MonoType` structures over and over, and
this module lets structurally identical types share one object.

The technique is hash-consing. A table holds one object for each distinct
composite structure it has seen, its canonical copy. Code that builds a type
offers it to `hashCons`, which looks the structure up and hands back the
canonical copy if there is one. Two benefits follow. The runtime's `==` returns
at once for two references to the same object, so comparing canonical types is
cheap. And the heap holds one copy of each repeated structure instead of one
per construction.

Canonicalisation is by exact structure, `==`, never by comparable-key equality
(`Mono.eqKeySpec`, `Mono.eqKeyLayout`). The key equalities deliberately merge
structures that differ: an `MVar _ CNumber` keys as `MInt`, and variable ids
are erased. Sharing by key would hand back a type that keys the same but has a
different shape. So two types whose only difference is an arrow labelled
`LTop` in one and `LVar` in the other are two entries. The bucket hash is
`Mono.specHashOf`, which equal structures always share; `==` decides.

Only composites are canonicalised: `MList`, `MTuple`, `MRecord`, `MCustom` and
`MFunction`. Leaves and `MVar`s pass through unchanged. `hashCons` looks only
at the top node, so a whole type is shared only when it is built bottom-up,
each child consed before its parent.

A table is in one of three modes. A live table, from `empty`, looks structures
up and registers new ones. A read-only view, from `readOnly`, looks up but
never registers, for a traversal that cannot hand an updated table back. A
disabled table, `disabled`, does neither. Sharing is never needed for
correctness, so every mode gives correct types and differs only in how much
is shared.

The table also memoises `widenSets`, the table-threading form of
`Mono.widenSets`, on a live table only.

@docs Intern, empty, disabled, readOnly, size, entries
@docs hashCons, widenSets
@docs eqExact

-}

import Compiler.AST.Monomorphized as Mono exposing (MonoType)
import Data.HashMap as HashMap
import Dict


{-| A hash-consing table, in one of three modes, together with the memo of
`widenSets` results.

`Intern` is a live table. It answers a lookup with the canonical copy and
registers a structure it has not seen, so `hashCons` can return a grown table.
Only a live table memoises `widenSets`.

`ReadOnly` is a view of a live table's contents. It answers a lookup the same
way but registers nothing, and it is always returned unchanged. A traversal
given one can therefore discard the table it gets back.

`Disabled` holds nothing and shares nothing: `hashCons` returns its input. It
is for a traversal with no table to use, and costs nothing per node.

-}
type Intern
    = Intern (HashMap.HashMap Canon MonoType) (HashMap.HashMap MonoType MonoType)
    | ReadOnly (HashMap.HashMap Canon MonoType) (HashMap.HashMap MonoType MonoType)
    | Disabled


{-| The key under which a canonical type is stored: the type itself, and, for a
record, its fields in ascending name order.

The field list lets a lookup compare a freshly built record against the stored
one by walking the fresh record's fields in the same order, without a
`Dict.get` per field. `fields` is `[]` for every type other than a record. A
lookup in the table compares the bare type it was given against the stored
keys.

-}
type alias Canon =
    { node : MonoType
    , fields : List ( String, MonoType )
    }


{-| Builds the table key for a type.
-}
canonOf : MonoType -> Canon
canonOf mt =
    case mt of
        Mono.MRecord _ fields ->
            { node = mt, fields = Dict.toList fields }

        _ ->
            { node = mt, fields = [] }


{-| Returns the bucket hash of a key, the spec hash of its type.
-}
canonHash : Canon -> Int
canonHash c =
    Mono.specHashOf c.node


{-| Returns whether two keys hold exactly equal (`==`) types.
-}
canonEq : Canon -> Canon -> Bool
canonEq a b =
    eqExactAgainst a.node b


{-| An empty live table.
-}
empty : Intern
empty =
    Intern HashMap.empty HashMap.empty


{-| A table that shares nothing: `hashCons` returns its input, and `widenSets`
widens without memoising.
-}
disabled : Intern
disabled =
    Disabled


{-| Returns a read-only view of a table, for a traversal that has a table to
read but cannot hand an updated one back.

With the view, `hashCons` returns the stored copy of a structure the table
already holds, and the type as given for one it does not, without registering
it. `hashCons` and `widenSets` always return the view unchanged, so there is
nothing to write back. A view of a read-only view is the same view, and a view
of `disabled` is still disabled.

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


{-| Returns the number of distinct structures the table holds canonical copies
of. It does not count the `widenSets` memo; `entries` does.
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


{-| Returns the canonical copy of a type and the table to carry on with.

On a live table, a composite already held comes back as its stored copy, and
one not held is registered and comes back as given. On a read-only view a
composite not held also comes back as given, but is not registered. A leaf or
`MVar`, or any type given a disabled table, comes back as given.

Only the top node is looked up. Its children are compared with `==`, which is
fast when they are already canonical, so a type should be consed bottom-up.

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
                    -- Leaves and `MVar` are never registered.
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


{-| Looks a composite up in a live table's maps `m` and `w`, returning the stored
copy and `intern` unchanged on a hit, or the type and a table with it
registered on a miss.

`intern` is the table `m` and `w` came from, passed so that a hit returns it
as it is instead of building a new wrapper.

-}
probe : MonoType -> HashMap.HashMap Canon MonoType -> HashMap.HashMap MonoType MonoType -> Intern -> ( MonoType, Intern )
probe mt m w intern =
    case HashMap.getBy Mono.specHashOf eqExactAgainst mt m of
        Just canonical ->
            ( canonical, intern )

        Nothing ->
            ( mt, Intern (HashMap.insert canonHash canonEq (canonOf mt) mt m) w )


{-| Looks a composite up in a read-only view's map `m`, returning the stored copy
on a hit and the type as given on a miss. `intern` is returned unchanged
either way.
-}
probeRO : MonoType -> HashMap.HashMap Canon MonoType -> Intern -> ( MonoType, Intern )
probeRO mt m intern =
    case HashMap.getBy Mono.specHashOf eqExactAgainst mt m of
        Just canonical ->
            ( canonical, intern )

        Nothing ->
            ( mt, intern )


{-| Returns whether two types are equal under `==`, the equality the table
shares by.

It answers as `==` does, not as `Mono.eqKeySpec` does, so types that differ
only in an arrow's lambda set annotation, or only in a variable's id, are not
equal.

-}
eqExact : MonoType -> MonoType -> Bool
eqExact a b =
    eqExactAgainst a (canonOf b)


{-| Returns whether type `a` is equal under `==` to the type stored in key `c`.

It gives the same answer as `==`. A composite's stored hash is computed from
its children's hashes, so equal types always have equal hashes and comparing
the hashes first never rejects an equal pair. The remaining tests are the ones
`==` makes, in a different order. A record's fields are compared in ascending
name order against the key's field list, which compares contents as `==` on a
`Dict` does, without walking the second dictionary.

Children are compared with `==`, not with this function. That is fast when a
child is the same object as the stored one, and still correct when it is an
equal but separately built copy.

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
            -- Leaves never reach a lookup, but `eqExact` can be given one.
            a == c.node


{-| Returns whether two lists of types have the same length and are equal
element by element under `==`.
-}
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


{-| The remainder that marks a failed field comparison in `eqFieldsAgainst`.

It is non-empty, so a fold that ends with it fails. Its one field is named
`""`, which no record field is, so every later step of the fold meets a
mismatch and returns it again.

-}
failedFields : List ( String, MonoType )
failedFields =
    [ ( "", Mono.MUnit ) ]


{-| Returns whether the fields of `fresh` are exactly the `stored` list, which is
in ascending name order.

Each of `fresh`'s fields, taken in ascending name order, must match the head of
what remains of `stored`, and the fields are equal when nothing remains. Fewer
fields in `fresh` leave a remainder; more find nothing left to match.

-}
eqFieldsAgainst : Dict.Dict String MonoType -> List ( String, MonoType ) -> Bool
eqFieldsAgainst fresh stored =
    List.isEmpty (Dict.foldl eqFieldStep stored fresh)


{-| Returns the rest of `remaining` when its head is field `name` with type `t`,
and `failedFields` otherwise.
-}
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


{-| Returns the number of canonical structures plus the number of `widenSets`
memo entries in the table.

Nothing is ever removed from either, so the table `hashCons` or `widenSets`
returns is the one it was given exactly when the two have equal `entries`.
Unlike `size`, this notices a table that grew only in its memo.

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


{-| Returns the type with every arrow's annotation replaced by `Mono.topWiden`,
as `Mono.widenSets` does, with every rebuilt composite consed through the
table.

The result is `==` to what `Mono.widenSets` returns, and the two must change
together, as `Mono.widenSets` says. This one rebuilds a record by inserting its
fields into an empty `Dict` rather than with `Dict.map`, which can give a
different tree but the same contents, and `==` on a `Dict` compares contents.

On a live table, consing the result makes it the canonical copy, so later
comparisons against it can succeed on reference. A type whose arrows are all
already `topWiden` widens to a structure `==` to itself, and if that type is
canonical the lookup returns the same object.

On a live table every input is memoised, leaves and `MVar`s included, and the
memo is consulted at every node, so a repeated subterm is widened once even
within one call. A read-only view or a disabled table does not memoise.

-}
widenSets : MonoType -> Intern -> ( MonoType, Intern )
widenSets monoType intern0 =
    -- Widening is a pure function of the input, so the memo is keyed on it.
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
            -- A read-only view must not grow.
            widenSetsGo monoType intern0


{-| The key equality of the `widenSets` memo, `==` on the input type.

Two inputs that differ only in an arrow's annotation are therefore two memo
entries, which both map to the same widened type.

-}
widenEq : MonoType -> MonoType -> Bool
widenEq a b =
    a == b


{-| Records in a live table's memo that `key` widens to `widened`. Any other
table is returned unchanged.
-}
putWiden : MonoType -> MonoType -> Intern -> Intern
putWiden key widened intern =
    case intern of
        Intern m w ->
            Intern m (HashMap.insert Mono.specHashOf widenEq key widened w)

        _ ->
            intern


{-| Widens one node without consulting the memo for it: its children go through
`widenSets`, and the rebuilt composite is consed. A leaf or `MVar` is returned
unchanged.
-}
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


{-| Widens each type of a list through `widenSets`, in order, threading the
table.
-}
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
