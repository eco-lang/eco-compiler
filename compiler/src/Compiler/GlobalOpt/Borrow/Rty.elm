module Compiler.GlobalOpt.Borrow.Rty exposing
    ( RTy(..)
    , ResVar
    , allRes
    , freshRTy
    , rcManaged
    , topRes
    , zipRTy
    )

{-| Borrow inference reasons about the heap objects a value owns, and this module
says where those objects are in a value of a given type.

A _resource_ is one place in a type that is a heap object: a string, a list
cell, a tuple, a record, a custom-type value, a closure's environment, or an
erased value (`MVar _ CEcoValue`) whose contents the analysis cannot see. Ints,
floats, booleans, characters and unit are scalars and hold no resource. A
`ResVar` names one resource.

An `RTy` is the resource skeleton of a `MonoType`: the same shape, with a
`ResVar` at every resource. `freshRTy` builds one, numbering the resources in
pre-order (a node before its children, children left to right), and `allRes`
lists them back in that same order. That order is the canonical numbering of a
type's resource positions.

The counter that supplies fresh `ResVar`s is a plain `Int` passed in and handed
back, so this module needs nothing from the modules that use it.

`rcManaged` is a separate predicate on `MonoType`, not on skeletons.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Dict


{-| A number naming one resource in one analysis.

This is a name for `Int`, not a new type: any `Int` is accepted where a
`ResVar` is expected. Numbers are unique only among those drawn from the same
counter.

-}
type alias ResVar =
    Int


{-| The resource skeleton of a type: its shape, with a `ResVar` at each resource.

Every constructor other than `RScalar` carries the `ResVar` of the value itself
first, its _head_ resource.

`RScalar` stands for a type that holds no resource.

`ROpaque` is an erased value, `MVar _ CEcoValue`, whose contents are not
followed.

`RList` carries the skeleton of its element type, so one skeleton stands for
every element of the list.

`RRecord` carries one skeleton per field, in ascending order of field name.

`RCustom` carries one skeleton per type argument. The fields of the
constructors are not represented.

`RClosure`'s resource is the closure's environment; its argument and result
types are not followed.

-}
type RTy
    = RScalar
    | RString ResVar
    | ROpaque ResVar
    | RList ResVar RTy
    | RTuple ResVar (List RTy)
    | RRecord ResVar (List ( Name, RTy ))
    | RCustom ResVar (List RTy)
    | RClosure ResVar


{-| Builds the resource skeleton of `ty`, numbering its resources from `n` in
pre-order, and returns it with the next unused number.

`MVar _ CNumber` is treated as a scalar and gets no resource.

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
            -- Not expected this late in compilation; treated as a scalar.
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


{-| Builds the skeletons of `tys` in order, numbering from `n`, and returns them
with the next unused number.
-}
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


{-| Builds the skeleton of each field's type in list order, numbering from `n`,
and returns them, still paired with the field names, with the next unused
number.
-}
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


{-| Returns the head resource of a skeleton, or `Nothing` for `RScalar`.
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


{-| Returns every resource in a skeleton in pre-order: the head, then each
child's resources from left to right. This is the order `freshRTy` numbers them
in.
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


{-| Returns the corresponding resources of two skeletons of the same shape, as
pairs in pre-order, the first of each pair from `a`.

Where the shapes differ, nothing below that point is paired: two different
constructors give `[]`, and of two lists of children only as many as the
shorter holds are paired. Record fields are paired by position, not by name.

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


{-| Pairs the resources of two lists of skeletons element by element, stopping at
the end of the shorter.
-}
zipRTyList : List RTy -> List RTy -> List ( ResVar, ResVar )
zipRTyList a b =
    case ( a, b ) of
        ( x :: xs, y :: ys ) ->
            zipRTy x y ++ zipRTyList xs ys

        _ ->
            []


{-| Pairs the resources of two lists of fields by position, ignoring their names
and stopping at the end of the shorter.
-}
zipRTyFields : List ( Name, RTy ) -> List ( Name, RTy ) -> List ( ResVar, ResVar )
zipRTyFields a b =
    case ( a, b ) of
        ( ( _, x ) :: xs, ( _, y ) :: ys ) ->
            zipRTy x y ++ zipRTyFields xs ys

        _ ->
            []


{-| Returns whether a type is reference-count managed, which is true of
`MString` alone.
-}
rcManaged : Mono.MonoType -> Bool
rcManaged ty =
    case ty of
        Mono.MString ->
            True

        _ ->
            False
