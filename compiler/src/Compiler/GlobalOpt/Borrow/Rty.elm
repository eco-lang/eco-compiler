module Compiler.GlobalOpt.Borrow.Rty exposing
    ( ResVar, RTy(..)
    , freshRTy, zipRTy, topRes, allRes, rcManaged
    )

{-| Resource-typed skeleton of a `MonoType` (borrow inference, design §7.3).

Each heap position (§7.2 resource) carries one `ResVar` (dense `Int`, minted
from 0 per def-analysis). Scalars carry none (BORROW_001). The ResVar supply
is a bare `Int` counter threaded through `freshRTy` — NOT the `Gen` record —
so `Rty` imports nothing from `Constrain` (breaking a `Rty → Constrain → Rty`
cycle). The walker (`Constrain`) lifts the counter through `Gen.next`.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Dict


type alias ResVar =
    Int


type RTy
    = RScalar
    | RString ResVar
    | ROpaque ResVar -- MVar _ CEcoValue (erased eco.value; poisoned)
    | RList ResVar RTy
    | RTuple ResVar (List RTy)
    | RRecord ResVar (List ( Name, RTy )) -- ascending field order (Dict.toList)
    | RCustom ResVar (List RTy) -- type-arg positions only
    | RClosure ResVar -- env resource


{-| One `ResVar` per heap row, per the §7.2 table. Bare `Int` counter in/out.
-}
freshRTy : Mono.MonoType -> Int -> ( RTy, Int )
freshRTy ty n =
    case ty of
        Mono.MInt ->
            ( RScalar, n )

        Mono.MFloat ->
            ( RScalar, n )

        Mono.MBool ->
            ( RScalar, n )

        Mono.MChar ->
            ( RScalar, n )

        Mono.MUnit ->
            ( RScalar, n )

        Mono.MString ->
            ( RString n, n + 1 )

        Mono.MVar _ Mono.CEcoValue ->
            ( ROpaque n, n + 1 )

        Mono.MVar _ Mono.CNumber ->
            -- Defensive (fact 1): MVar _ CNumber at Phase 6 is a compiler bug;
            -- treat as a scalar rather than mint a resource.
            ( RScalar, n )

        Mono.MList _ elemT ->
            let
                ( elemRty, n1 ) =
                    freshRTy elemT (n + 1)
            in
            ( RList n elemRty, n1 )

        Mono.MTuple _ ts ->
            let
                ( rtys, n1 ) =
                    freshRTyList ts (n + 1)
            in
            ( RTuple n rtys, n1 )

        Mono.MRecord _ d ->
            let
                ( fields, n1 ) =
                    freshRTyFields (Dict.toList d) (n + 1)
            in
            ( RRecord n fields, n1 )

        Mono.MCustom _ _ _ args ->
            let
                ( rtys, n1 ) =
                    freshRTyList args (n + 1)
            in
            ( RCustom n rtys, n1 )

        Mono.MFunction _ _ _ _ ->
            ( RClosure n, n + 1 )


freshRTyList : List Mono.MonoType -> Int -> ( List RTy, Int )
freshRTyList tys n =
    case tys of
        [] ->
            ( [], n )

        t :: rest ->
            let
                ( rty, n1 ) =
                    freshRTy t n

                ( rtys, n2 ) =
                    freshRTyList rest n1
            in
            ( rty :: rtys, n2 )


freshRTyFields : List ( Name, Mono.MonoType ) -> Int -> ( List ( Name, RTy ), Int )
freshRTyFields fields n =
    case fields of
        [] ->
            ( [], n )

        ( name, t ) :: rest ->
            let
                ( rty, n1 ) =
                    freshRTy t n

                ( rtys, n2 ) =
                    freshRTyFields rest n1
            in
            ( ( name, rty ) :: rtys, n2 )


{-| The head ResVar of a row; `Nothing` for a scalar.
-}
topRes : RTy -> Maybe ResVar
topRes rty =
    case rty of
        RScalar ->
            Nothing

        RString r ->
            Just r

        ROpaque r ->
            Just r

        RList r _ ->
            Just r

        RTuple r _ ->
            Just r

        RRecord r _ ->
            Just r

        RCustom r _ ->
            Just r

        RClosure r ->
            Just r


{-| Pre-order ResVars (head then children left-to-right) — the canonical
`ResPos` ordering `freshRTy` minted in, which Phase-3 `SigTy` relies on.
-}
allRes : RTy -> List ResVar
allRes rty =
    case rty of
        RScalar ->
            []

        RString r ->
            [ r ]

        ROpaque r ->
            [ r ]

        RClosure r ->
            [ r ]

        RList r elem ->
            r :: allRes elem

        RTuple r elems ->
            r :: List.concatMap allRes elems

        RRecord r fields ->
            r :: List.concatMap (\( _, t ) -> allRes t) fields

        RCustom r args ->
            r :: List.concatMap allRes args


{-| Structurally pair two aligned ground RTys pre-order. Mismatched shapes are
unreachable (ground+equal by construction, §7.3); return `[]` (total; a dropped
flow only shortens a lifetime).
-}
zipRTy : RTy -> RTy -> List ( ResVar, ResVar )
zipRTy a b =
    case ( a, b ) of
        ( RScalar, RScalar ) ->
            []

        ( RString r, RString s ) ->
            [ ( r, s ) ]

        ( ROpaque r, ROpaque s ) ->
            [ ( r, s ) ]

        ( RClosure r, RClosure s ) ->
            [ ( r, s ) ]

        ( RList r ea, RList s eb ) ->
            ( r, s ) :: zipRTy ea eb

        ( RTuple r ea, RTuple s eb ) ->
            ( r, s ) :: zipRTyList ea eb

        ( RRecord r fa, RRecord s fb ) ->
            ( r, s ) :: zipRTyFields fa fb

        ( RCustom r fa, RCustom s fb ) ->
            ( r, s ) :: zipRTyList fa fb

        _ ->
            []


zipRTyList : List RTy -> List RTy -> List ( ResVar, ResVar )
zipRTyList a b =
    case ( a, b ) of
        ( x :: xs, y :: ys ) ->
            zipRTy x y ++ zipRTyList xs ys

        _ ->
            []


zipRTyFields : List ( Name, RTy ) -> List ( Name, RTy ) -> List ( ResVar, ResVar )
zipRTyFields a b =
    case ( a, b ) of
        ( ( _, x ) :: xs, ( _, y ) :: ys ) ->
            zipRTy x y ++ zipRTyFields xs ys

        _ ->
            []


{-| The B0-report v1 rcManaged set: `MString` only (the pointer-free flat
buffer family; §16.1). Everything else False until B4. Used for census
bucketing (`wouldFree` / RC sizing) this phase; no reify consumer yet.
-}
rcManaged : Mono.MonoType -> Bool
rcManaged ty =
    case ty of
        Mono.MString ->
            True

        _ ->
            False
