module Compiler.GlobalOpt.Borrow.Solve exposing
    ( Solved
    , solve
    , accessMode, storageOwnedOf, reifiedOwned, ltAOf, ltPOf, alphaOf
    )

{-| Staged borrow solving (design §9), two-index-space model (§7.1): the DSU
carries storage classes only; access modes and lifetimes are raw-ResVar
`Array`s. All fixpoints are finite (monotone over a finite lattice); the loops
are tail-recursive so the fixpoint dimension never uses the JS call stack.

  - Stage A — storage classes (DSU union over `storageEq` + `flows`; owned
    classes from `forcedOwned`).
  - Stage B — approximate lifetimes `ltA` (seed + join along flows).
  - Stage C — access modes (owned flows down; escape from an owned binding
    forces the use owned; store obligation).
  - Stage D — precise lifetimes `ltP` (v1: computed as `ltA`; the precise
    lateral/vertical refinement is a Phase-5 concern, not needed for the
    B2 census).

-}

import Array exposing (Array)
import Compiler.GlobalOpt.Borrow.Constrain as C exposing (Constraints)
import Compiler.GlobalOpt.Borrow.Dsu as Dsu
import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Lifetime)
import Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..), lub)
import Compiler.GlobalOpt.Borrow.Rty exposing (ResVar)
import Dict
import Set exposing (Set)


type alias Solved =
    { dsu : Dsu.Dsu
    , storageOwned : Array Bool -- indexed by resvar; True iff its DSU class is owned-storing
    , access : Array Mode -- raw resvar
    , ltA : Array Lifetime -- raw resvar
    , ltP : Array Lifetime -- raw resvar
    , alpha : Array (Set Int) -- raw resvar: param positions this resource couples to
    , nRes : Int
    }


solve : Int -> Bool -> Constraints -> Solved
solve nRes allOwnedFlag cs =
    let
        -- Stage A: storage classes. (item 24: fold storageEq then flows into the
        -- same DSU accumulator — union is order-independent for the partition —
        -- instead of allocating a fresh `storageEq ++ flows` concat per solve.)
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

        -- Stage B: approximate lifetimes.
        ltASeeded =
            List.foldl
                (\( r, p ) arr -> arrJoin r (L.fromPath p) arr)
                (Array.repeat (max 1 nRes) L.LEmpty)
                cs.seeds

        ltAFinal =
            fixLifetimes cs.flows ltASeeded (iterBudget nRes)

        -- α-coupling: which param positions a resource couples to. Seeded on
        -- param resources, propagated FORWARD (bind→use) — the opposite
        -- direction from lifetimes — so a returned value inherits its params'
        -- α, read back as `resultLts`.
        alphaFinal =
            fixAlpha cs.flows
                (List.foldl (\( r, i ) arr -> arrAlphaInsert r i arr)
                    (Array.repeat (max 1 nRes) Set.empty)
                    cs.paramSeeds
                )
                (iterBudget nRes)

        -- Stage C: access modes.
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

        -- Stage D: precise lifetimes. Same seeds as ltA, but propagate ONLY
        -- through BORROWED uses (a borrowed use keeps the value live; an owned
        -- use consumes it) + vertical borrowed projections. ltP ⊑-ish ltA and
        -- governs drop placement / borrow-extension precision.
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


iterBudget : Int -> Int
iterBudget nRes =
    nRes * 2 + 16



-- STAGE B FIXPOINT


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
                        -- item 8: join cur ltu == cur iff ltu ⊑ cur, so test
                        -- `leq ltu cur` (one walk) and only join/allocate when it
                        -- grows — exactly equivalent to the old `eq (join…) cur`
                        -- (join is LUB ⇒ new ≥ cur always), on the hottest loop.
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


fixLtP : Constraints -> Array Mode -> Array Lifetime -> Int -> Array Lifetime
fixLtP cs access arr budget =
    if budget <= 0 then
        arr

    else
        let
            -- lateral: (bind,use) flows whose use side is Borrowed (an owned
            -- use consumes the value, so it doesn't extend the borrow lifetime).
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

            -- vertical: Get.out (src,dst) where src is Owned and dst Borrowed —
            -- an owned container must live as long as a borrowed projection.
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


{-| `ltP[target] ⊔= ltP[source]`, reporting whether it changed.
-}
joinInto : ResVar -> ResVar -> Array Lifetime -> Bool -> ( Array Lifetime, Bool )
joinInto target source acc ch =
    let
        cur =
            arrGet target acc

        src =
            arrGet source acc
    in
    -- item 8: only join/allocate when `src` actually grows `cur` (leq = one walk,
    -- exactly equivalent to the old `eq (join cur src) cur`).
    if L.leq src cur then
        ( acc, ch )

    else
        ( Array.set target (L.join cur src) acc, True )



-- α-COUPLING FIXPOINT (forward: use absorbs bind's α)


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

                            new =
                                Set.union cur bs
                        in
                        if Set.size new == Set.size cur then
                            ( acc, ch )

                        else
                            ( Array.set u new acc, True )
                    )
                    ( arr, False )
                    flows
        in
        if changed then
            fixAlpha flows arr1 (budget - 1)

        else
            arr1


arrAlphaGet : ResVar -> Array (Set Int) -> Set Int
arrAlphaGet r arr =
    Maybe.withDefault Set.empty (Array.get r arr)


arrAlphaInsert : ResVar -> Int -> Array (Set Int) -> Array (Set Int)
arrAlphaInsert r i arr =
    Array.set r (Set.insert i (arrAlphaGet r arr)) arr



-- STAGE C FIXPOINT


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

                            -- rule 2: ownedness flows down into the binding.
                            newB =
                                lub ab au

                            acc1 =
                                if newB == ab then
                                    ( acc, ch )

                                else
                                    ( Array.set b newB acc, True )

                            ( acc2, ch2 ) =
                                acc1

                            -- rule 1: a use that escapes b's scope must be owned if b is.
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


arrGet : ResVar -> Array Lifetime -> Lifetime
arrGet r arr =
    Maybe.withDefault L.LEmpty (Array.get r arr)


arrJoin : ResVar -> Lifetime -> Array Lifetime -> Array Lifetime
arrJoin r lt arr =
    Array.set r (L.join (arrGet r arr) lt) arr


accGet : ResVar -> Array Mode -> Mode
accGet r arr =
    Maybe.withDefault Borrowed (Array.get r arr)



-- READBACK API


accessMode : ResVar -> Solved -> Mode
accessMode r s =
    accGet r s.access


storageOwnedOf : ResVar -> Solved -> Bool
storageOwnedOf r s =
    Maybe.withDefault False (Array.get (Dsu.findRoot r s.dsu) s.storageOwned)


{-| A resource needs owning (RC management) if its access is Owned or its
storage class is owned.
-}
reifiedOwned : ResVar -> Solved -> Bool
reifiedOwned r s =
    accessMode r s == Owned || storageOwnedOf r s


ltAOf : ResVar -> Solved -> Lifetime
ltAOf r s =
    arrGet r s.ltA


ltPOf : ResVar -> Solved -> Lifetime
ltPOf r s =
    arrGet r s.ltP


alphaOf : ResVar -> Solved -> Set Int
alphaOf r s =
    arrAlphaGet r s.alpha
