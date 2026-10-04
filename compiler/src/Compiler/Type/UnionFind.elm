module Compiler.Type.UnionFind exposing
    ( fresh, repr, get, set, modify, unionS, equivalent, redundant
    , getS, equivalentS
    )

{-| Type inference decides which type variables must be equal, and this module
keeps track of those decisions: it is the union-find structure over the points
of the type checker's store.

A _point_ is a type variable, as `Compiler.AST.TypeVars` describes, and the points
found to be equal form one _class_. Each class has one _root_, whose cell
carries the class's descriptor and its _weight_, the number of points in the
class. Every other point's cell is a link towards the root. Asking for a
point's descriptor therefore means following links to the root, and the
descriptor read or written is always the one shared by the whole class.

Two techniques keep the links short. Joining two classes puts the root of the
lighter class under the root of the heavier one, so this is union by weight;
it is unrelated to the rank held in a descriptor. And finding a root rewrites
each cell passed on the way to point further along, which is _path
compression_. Compression is a write even when the caller only wanted to read,
but it never changes a root, a descriptor or a weight, so a caller cannot see
it.

The store is an `Eco.CellStore`, used under that module's linearity contract:
after a write, only the state the write returned may be used. On the native
build the store is changed in place, so an older state does not keep the older
cells, and a caller cannot undo a unification by going back to the state from
before it. A caller that needs to undo one brackets it with
`Compiler.MonoSolver.Engine.markStore` and `rollbackStore`.

Each operation comes in two forms with the same behaviour. The plain forms are
`IO` actions. The `S` forms take the state as an ordinary argument, which spares
a caller the closures an `IO` action costs, and return the result before the
state, `( result, State )`, the reverse of an `IO` action; `setS`, `modifyS`
and `unionS` return the state alone, and `redundantQ` returns a bare `Bool`.
The plain forms are wrappers over the `S` forms.


# Operations

@docs fresh, repr, get, set, modify, unionS, equivalent, redundant
@docs getS, equivalentS

-}

import Compiler.AST.TypeVars as Vars exposing (Descriptor)
import Data.IORef as IORef
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Crash exposing (crash)



-- IO ACTIONS


{-| Returns an action that makes a new point in a class of its own, whose
descriptor is `value`.
-}
fresh : Vars.Descriptor -> IO Vars.Point
fresh value s =
    let
        ( point, s1 ) =
            freshS value s
    in
    ( s1, point )


{-| Returns an action that finds the root of `point`'s class, compressing the
path to it.
-}
repr : Vars.Point -> IO Vars.Point
repr point s =
    let
        ( root, s1 ) =
            reprS s point
    in
    ( s1, root )


{-| Returns an action that reads the descriptor of `point`'s class.
-}
get : Vars.Point -> IO Descriptor
get point s =
    let
        ( desc, s1 ) =
            getS s point
    in
    ( s1, desc )


{-| Returns an action that replaces the descriptor of `point`'s class with
`newDesc`.
-}
set : Vars.Point -> Descriptor -> IO ()
set point newDesc s =
    ( setS point newDesc s, () )


{-| Returns an action that applies `func` to the descriptor of `point`'s class.
-}
modify : Vars.Point -> (Descriptor -> Descriptor) -> IO ()
modify point func s =
    ( modifyS point func s, () )


{-| Returns an action that tells whether `p1` and `p2` are in the same class.
-}
equivalent : Vars.Point -> Vars.Point -> IO Bool
equivalent p1 p2 s =
    let
        ( eq, s1 ) =
            equivalentS s p1 p2
    in
    ( s1, eq )


{-| Returns an action that tells whether `point` is not the root of its class.
It changes nothing.
-}
redundant : Vars.Point -> IO Bool
redundant point s =
    ( s, redundantQ s point )



-- STATE-PASSING FORMS


{-| Returns a new point in a class of its own, with weight 1 and descriptor
`value`, together with the new state.
-}
freshS : Vars.Descriptor -> IO.State -> ( Vars.Point, IO.State )
freshS value s =
    let
        ( ref, s1 ) =
            IORef.newPointCellS 1 value s
    in
    ( Vars.Pt ref, s1 )


{-| Returns the root of `point`'s class, together with the new state.

Every point passed on the way is rewritten to link to the root, so the
returned state may differ from `s` even though no class changes.

-}
reprS : IO.State -> Vars.Point -> ( Vars.Point, IO.State )
reprS s ((Vars.Pt ref) as point) =
    case IORef.readPointCellS s ref of
        Vars.Root _ _ ->
            ( point, s )

        Vars.Chain ((Vars.Pt ref1) as point1) ->
            let
                ( point2, s1 ) =
                    reprS s point1
            in
            if point2 /= point1 then
                ( point2, IORef.writePointCellS ref (IORef.readPointCellS s1 ref1) s1 )

            else
                ( point2, s1 )


{-| Returns the descriptor of `point`'s class, together with the new state.

When `point` is the root or links straight to it, the state is returned
unchanged. Only a longer path is found with `reprS`, which compresses it.

-}
getS : IO.State -> Vars.Point -> ( Descriptor, IO.State )
getS s ((Vars.Pt ref) as point) =
    case IORef.readPointCellS s ref of
        Vars.Root _ desc ->
            ( desc, s )

        Vars.Chain (Vars.Pt ref1) ->
            case IORef.readPointCellS s ref1 of
                Vars.Root _ desc ->
                    ( desc, s )

                Vars.Chain _ ->
                    let
                        ( newPoint, s1 ) =
                            reprS s point
                    in
                    getS s1 newPoint


{-| Returns the state with the descriptor of `point`'s class replaced by
`newDesc`. The class's weight is kept, and a path longer than one link is
compressed as in `reprS`.
-}
setS : Vars.Point -> Descriptor -> IO.State -> IO.State
setS ((Vars.Pt ref) as point) newDesc s =
    case IORef.readPointCellS s ref of
        Vars.Root w _ ->
            IORef.writePointCellS ref (Vars.Root w newDesc) s

        Vars.Chain (Vars.Pt ref1) ->
            case IORef.readPointCellS s ref1 of
                Vars.Root w _ ->
                    IORef.writePointCellS ref1 (Vars.Root w newDesc) s

                Vars.Chain _ ->
                    let
                        ( newPoint, s1 ) =
                            reprS s point
                    in
                    setS newPoint newDesc s1


{-| Returns the state with `func` applied to the descriptor of `point`'s class.
The class's weight is kept, and a path longer than one link is compressed as in
`reprS`.
-}
modifyS : Vars.Point -> (Descriptor -> Descriptor) -> IO.State -> IO.State
modifyS ((Vars.Pt ref) as point) func s =
    case IORef.readPointCellS s ref of
        Vars.Root w desc ->
            IORef.writePointCellS ref (Vars.Root w (func desc)) s

        Vars.Chain (Vars.Pt ref1) ->
            case IORef.readPointCellS s ref1 of
                Vars.Root w desc ->
                    IORef.writePointCellS ref1 (Vars.Root w (func desc)) s

                Vars.Chain _ ->
                    let
                        ( newPoint, s1 ) =
                            reprS s point
                    in
                    modifyS newPoint func s1


{-| Returns the state with the classes of `p1` and `p2` joined into one whose
descriptor is `newDesc`.

The root of the lighter class goes under the root of the heavier and the
survivor carries the summed weight; on equal weights `p2`'s root goes under
`p1`'s. If the two points are already in one class, only the descriptor is
replaced and the weight is kept.

-}
unionS : Vars.Point -> Vars.Point -> Vars.Descriptor -> IO.State -> IO.State
unionS p1 p2 newDesc s =
    let
        ( (Vars.Pt ref1) as point1, s1 ) =
            reprS s p1

        ( (Vars.Pt ref2) as point2, s2 ) =
            reprS s1 p2
    in
    case ( IORef.readPointCellS s2 ref1, IORef.readPointCellS s2 ref2 ) of
        ( Vars.Root weight1 _, Vars.Root weight2 _ ) ->
            if point1 == point2 then
                -- The whole cell is rewritten, so it must carry the existing
                -- weight, not the sum, which would double it.
                IORef.writePointCellS ref1 (Vars.Root weight1 newDesc) s2

            else
                let
                    newWeight : Int
                    newWeight =
                        weight1 + weight2
                in
                if weight1 >= weight2 then
                    s2
                        |> IORef.writePointCellS ref2 (Vars.Chain point1)
                        |> IORef.writePointCellS ref1 (Vars.Root newWeight newDesc)

                else
                    s2
                        |> IORef.writePointCellS ref1 (Vars.Chain point2)
                        |> IORef.writePointCellS ref2 (Vars.Root newWeight newDesc)

        _ ->
            crash "Unexpected pattern"


{-| Returns whether `p1` and `p2` have the same root, together with the new
state, in which both paths are compressed.
-}
equivalentS : IO.State -> Vars.Point -> Vars.Point -> ( Bool, IO.State )
equivalentS s p1 p2 =
    let
        ( v1, s1 ) =
            reprS s p1

        ( v2, s2 ) =
            reprS s1 p2
    in
    ( v1 == v2, s2 )


{-| Returns whether `point` is not the root of its class. It reads one cell and
changes nothing, so no state is returned.
-}
redundantQ : IO.State -> Vars.Point -> Bool
redundantQ s (Vars.Pt ref) =
    case IORef.readPointCellS s ref of
        Vars.Root _ _ ->
            False

        Vars.Chain _ ->
            True
