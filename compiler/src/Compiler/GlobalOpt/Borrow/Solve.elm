module Compiler.GlobalOpt.Borrow.Solve exposing
    ( solve, Solved
    , alphaOf, accessMode, ltAOf, ltPOf, storageOwnedOf, reifiedOwned
    )

{-| Borrow inference generates constraints for one definition, and this module
turns them into answers about each resource: whether it must be treated as
owned, how long it is live, and which parameters may reach it.

A _resource_ (`ResVar`) is a number naming one heap object inside a value, as
`Compiler.GlobalOpt.Borrow.Rty` lays it out. The constraints come
from `Compiler.GlobalOpt.Borrow.Constrain`; the central ones are _flows_, pairs
of a binding and a use of it. A resource's _storage class_ is the set of
resources that may share storage with it, and a class is _owned-storing_ when
any member is forced owned. An _access mode_ (`Compiler.GlobalOpt.Borrow.Mode`)
says whether a resource must be treated as owned. Lifetimes are the lattice of
`Compiler.GlobalOpt.Borrow.Lifetime`.

Solving runs in stages. Stage A is one pass; the others are fixpoints, in
which values only grow:

  - Stage A, storage classes: a union-find over every `storageEq` pair and
    every flow, with a class owned-storing when it holds a `forcedOwned`
    resource.
  - Stage B, approximate lifetimes `ltA`: each resource starts at the join of
    its seeds, and a binding absorbs the lifetime of each of its uses.
  - Parameter coupling, the _alpha set_: the parameter positions in
    `paramSeeds` are carried the other way, from a binding to its uses.
  - Stage C, access modes: a resource starts `Owned` when solve is asked to
    make every resource owned, its class is owned-storing, or it is forced
    owned, and `Borrowed` otherwise. A binding
    then becomes `Owned` when a use of it is, and a use whose `ltA` does not
    end before the binding's scope becomes `Owned` when the binding is.
  - Stage D, precise lifetimes `ltP`: the same seeds as `ltA`, carried only
    from `Borrowed` uses to their bindings, and from a `Borrowed` value read
    out of a container to an `Owned` container, since an owned use consumes
    the value.

Each fixpoint sweeps its constraints until a sweep changes nothing, but stops
after `nRes * 2 + 16` sweeps whether or not it has converged, and gives no sign
that it stopped early. The sweeps are tail-recursive, so the number of sweeps
does not grow the call stack.

All result arrays have room for at least one resource; a query for a resource
outside them gets the bottom value: `Borrowed`, `LEmpty`, an empty set, or not
owned.


# Solving

@docs solve, Solved


# Queries

@docs alphaOf, accessMode, ltAOf, ltPOf, storageOwnedOf, reifiedOwned

-}

import Array exposing (Array)
import Compiler.GlobalOpt.Borrow.Constrain exposing (Constraints)
import Compiler.GlobalOpt.Borrow.Dsu as Dsu
import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Lifetime)
import Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..), lub)
import Compiler.GlobalOpt.Borrow.Rty exposing (ResVar)
import Dict
import Set exposing (Set)


{-| The solution for one definition: the storage classes and, for each
resource, whether its class is owned-storing, its access mode, its approximate
and precise lifetimes, and its alpha set.

`storageOwned` is indexed by resource, not by class root.

-}
type alias Solved =
    { dsu : Dsu.Dsu
    , storageOwned : Array Bool
    , access : Array Mode
    , ltA : Array Lifetime
    , ltP : Array Lifetime
    , alpha : Array (Set Int)
    , nRes : Int
    }


{-| Solves the constraints `cs` of a definition whose resources are numbered
from `0` to `nRes - 1`. When `allOwnedFlag` is `True`, every resource starts
Stage C `Owned`, so every access mode is `Owned`.
-}
solve : Int -> Bool -> Constraints -> Solved
solve nRes allOwnedFlag cs =
    let
        dsuA =
            List.foldl (\( a, b ) d -> Dsu.union a b d)
                (List.foldl (\( a, b ) d -> Dsu.union a b d)
                    (Dsu.empty (max 1 nRes))
                    cs.storageEq
                )
                cs.flows

        ownedClass =
            List.foldl
                (\( r, _ ) arr -> Array.set (Dsu.findRoot r dsuA) True arr)
                (Array.repeat (max 1 nRes) False)
                cs.forcedOwned

        storageOwnedArr =
            Array.initialize (max 1 nRes)
                (\r -> Maybe.withDefault False (Array.get (Dsu.findRoot r dsuA) ownedClass))

        ltASeeded =
            List.foldl
                (\( r, p ) arr -> arrJoin r (L.fromPath p) arr)
                (Array.repeat (max 1 nRes) L.LEmpty)
                cs.seeds

        ltAFinal =
            fixLifetimes cs.flows ltASeeded (iterBudget nRes)

        -- Carried from binding to use, the opposite way to lifetimes.
        alphaFinal =
            fixAlpha cs.flows
                (List.foldl (\( r, i ) arr -> arrAlphaInsert r i arr)
                    (Array.repeat (max 1 nRes) Set.empty)
                    cs.paramSeeds
                )
                (iterBudget nRes)

        accessInit =
            Array.initialize (max 1 nRes)
                (\r ->
                    if allOwnedFlag || Maybe.withDefault False (Array.get r storageOwnedArr) then
                        Owned

                    else
                        Borrowed
                )

        accessForced =
            List.foldl (\( r, _ ) arr -> Array.set r Owned arr) accessInit cs.forcedOwned

        accessFinal =
            fixAccess cs ltAFinal accessForced (iterBudget nRes)

        ltPFinal =
            fixLtP cs accessFinal ltASeeded (iterBudget nRes)
    in
    { dsu = dsuA
    , storageOwned = storageOwnedArr
    , access = accessFinal
    , ltA = ltAFinal
    , ltP = ltPFinal
    , alpha = alphaFinal
    , nRes = nRes
    }


{-| Returns the largest number of sweeps a fixpoint over `nRes` resources may
run.
-}
iterBudget : Int -> Int
iterBudget nRes =
    nRes * 2 + 16



-- STAGE B FIXPOINT


{-| Returns the lifetimes in `arr` after each binding has absorbed the lifetimes
of its uses along `flows`, sweeping until nothing changes or `budget` sweeps
have run.
-}
fixLifetimes : List ( ResVar, ResVar ) -> Array Lifetime -> Int -> Array Lifetime
fixLifetimes flows arr budget =
    if budget <= 0 then
        arr

    else
        let
            ( arr1, changed ) =
                List.foldl
                    (\( b, u ) ( acc, ch ) ->
                        let
                            cur =
                                arrGet b acc

                            ltu =
                                arrGet u acc
                        in
                        -- Testing `leq` first rewrites the array only when the
                        -- binding's lifetime grows.
                        if L.leq ltu cur then
                            ( acc, ch )

                        else
                            ( Array.set b (L.join cur ltu) acc, True )
                    )
                    ( arr, False )
                    flows
        in
        if changed then
            fixLifetimes flows arr1 (budget - 1)

        else
            arr1



-- STAGE D: PRECISE LIFETIME FIXPOINT


{-| Returns the precise lifetimes grown from `arr`, sweeping until nothing
changes or `budget` sweeps have run. A binding absorbs a use's lifetime only
when the use is `Borrowed` in `access`, and an `Owned` container absorbs the
lifetime of a `Borrowed` value read out of it.
-}
fixLtP : Constraints -> Array Mode -> Array Lifetime -> Int -> Array Lifetime
fixLtP cs access arr budget =
    if budget <= 0 then
        arr

    else
        let
            ( arr1, ch1 ) =
                List.foldl
                    (\( b, u ) ( acc, ch ) ->
                        if accGet u access == Borrowed then
                            joinInto b u acc ch

                        else
                            ( acc, ch )
                    )
                    ( arr, False )
                    cs.flows

            -- An owned container must live as long as a borrowed value read out of it.
            ( arr2, ch2 ) =
                List.foldl
                    (\get accCh ->
                        List.foldl
                            (\( src, dst ) ( acc, ch ) ->
                                if accGet src access == Owned && accGet dst access == Borrowed then
                                    joinInto src dst acc ch

                                else
                                    ( acc, ch )
                            )
                            accCh
                            get.out
                    )
                    ( arr1, ch1 )
                    cs.gets
        in
        if ch2 then
            fixLtP cs access arr2 (budget - 1)

        else
            arr2


{-| Returns `acc` with the lifetime of `target` joined with that of `source`,
and `ch` set to `True` when that changed it.
-}
joinInto : ResVar -> ResVar -> Array Lifetime -> Bool -> ( Array Lifetime, Bool )
joinInto target source acc ch =
    let
        cur =
            arrGet target acc

        src =
            arrGet source acc
    in
    if L.leq src cur then
        ( acc, ch )

    else
        ( Array.set target (L.join cur src) acc, True )



-- α-COUPLING FIXPOINT (forward: use absorbs bind's α)


{-| Returns the alpha sets in `arr` after each use has absorbed the set of its
binding along `flows`, sweeping until nothing changes or `budget` sweeps have
run.
-}
fixAlpha : List ( ResVar, ResVar ) -> Array (Set Int) -> Int -> Array (Set Int)
fixAlpha flows arr budget =
    if budget <= 0 then
        arr

    else
        let
            ( arr1, changed ) =
                List.foldl
                    (\( b, u ) ( acc, ch ) ->
                        let
                            bs =
                                arrAlphaGet b acc

                            cur =
                                arrAlphaGet u acc
                        in
                        -- Testing the subset first builds a union only when the
                        -- use's set grows.
                        if subsetOf bs cur then
                            ( acc, ch )

                        else
                            ( Array.set u (Set.union cur bs) acc, True )
                    )
                    ( arr, False )
                    flows
        in
        if changed then
            fixAlpha flows arr1 (budget - 1)

        else
            arr1


{-| Returns the alpha set of a resource, empty when it is out of range.
-}
arrAlphaGet : ResVar -> Array (Set Int) -> Set Int
arrAlphaGet r arr =
    Maybe.withDefault Set.empty (Array.get r arr)


{-| Returns whether every member of `small` is in `big`, without building a
set.
-}
subsetOf : Set Int -> Set Int -> Bool
subsetOf small big =
    Set.foldl (\x ok -> ok && Set.member x big) True small


{-| Returns `arr` with parameter position `i` added to the alpha set of `r`.
-}
arrAlphaInsert : ResVar -> Int -> Array (Set Int) -> Array (Set Int)
arrAlphaInsert r i arr =
    Array.set r (Set.insert i (arrAlphaGet r arr)) arr



-- STAGE C FIXPOINT


{-| Returns the access modes grown from `arr` along the flows of `cs`, sweeping
until nothing changes or `budget` sweeps have run. A binding becomes `Owned`
when its use is. A use becomes `Owned` when its binding is and its lifetime in
`ltA` does not end before the binding's scope; a binding with no entry in
`scopes` is given the empty path as its scope.
-}
fixAccess : Constraints -> Array Lifetime -> Array Mode -> Int -> Array Mode
fixAccess cs ltA arr budget =
    if budget <= 0 then
        arr

    else
        let
            ( arr1, changed ) =
                List.foldl
                    (\( b, u ) ( acc, ch ) ->
                        let
                            ab =
                                accGet b acc

                            au =
                                accGet u acc

                            newB =
                                lub ab au

                            acc1 =
                                if newB == ab then
                                    ( acc, ch )

                                else
                                    ( Array.set b newB acc, True )

                            ( acc2, ch2 ) =
                                acc1

                            scopeB =
                                Maybe.withDefault [] (Dict.get b cs.scopes)

                            escapes =
                                not (L.endsBefore (arrGet u ltA) scopeB)

                            newU =
                                if escapes then
                                    lub au newB

                                else
                                    au
                        in
                        if newU == au then
                            ( acc2, ch2 )

                        else
                            ( Array.set u newU acc2, True )
                    )
                    ( arr, False )
                    cs.flows
        in
        if changed then
            fixAccess cs ltA arr1 (budget - 1)

        else
            arr1



-- ARRAY ACCESSORS


{-| Returns the lifetime of a resource, `LEmpty` when it is out of range.
-}
arrGet : ResVar -> Array Lifetime -> Lifetime
arrGet r arr =
    Maybe.withDefault L.LEmpty (Array.get r arr)


{-| Returns `arr` with the lifetime of `r` joined with `lt`.
-}
arrJoin : ResVar -> Lifetime -> Array Lifetime -> Array Lifetime
arrJoin r lt arr =
    Array.set r (L.join (arrGet r arr) lt) arr


{-| Returns the access mode of a resource, `Borrowed` when it is out of range.
-}
accGet : ResVar -> Array Mode -> Mode
accGet r arr =
    Maybe.withDefault Borrowed (Array.get r arr)



-- READBACK API


{-| Returns the solved access mode of a resource, `Borrowed` when it is out of
range.
-}
accessMode : ResVar -> Solved -> Mode
accessMode r s =
    accGet r s.access


{-| Returns whether the storage class of a resource is owned-storing, `False`
when it is out of range.
-}
storageOwnedOf : ResVar -> Solved -> Bool
storageOwnedOf r s =
    Maybe.withDefault False (Array.get (Dsu.findRoot r s.dsu) s.storageOwned)


{-| Returns whether a resource must be treated as owned at all: its access mode
is `Owned` or its storage class is owned-storing.
-}
reifiedOwned : ResVar -> Solved -> Bool
reifiedOwned r s =
    accessMode r s == Owned || storageOwnedOf r s


{-| Returns the approximate lifetime of a resource, `LEmpty` when it is out of
range.
-}
ltAOf : ResVar -> Solved -> Lifetime
ltAOf r s =
    arrGet r s.ltA


{-| Returns the precise lifetime of a resource, `LEmpty` when it is out of
range. Unlike the approximate lifetime, it is not extended by `Owned` uses.
-}
ltPOf : ResVar -> Solved -> Lifetime
ltPOf r s =
    arrGet r s.ltP


{-| Returns the alpha set of a resource: the parameter positions from
`paramSeeds` whose values can reach it along flows. It is empty when the
resource is out of range.
-}
alphaOf : ResVar -> Solved -> Set Int
alphaOf r s =
    arrAlphaGet r s.alpha
