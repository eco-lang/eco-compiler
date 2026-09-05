module Compiler.Type.UnionFind exposing
    ( fresh, repr, get, set, modify, union, equivalent, redundant
    , freshS, reprS, getS, setS, modifyS, unionS, equivalentS, redundantQ
    )

{-| Union-Find data structure for efficient type unification.

This module implements a union-find (disjoint-set) data structure optimized for type
inference. It allows efficient tracking of type variable equivalences and supports
path compression for fast lookups. The implementation uses mutable references (IORef)
to achieve efficient updates while maintaining a pure interface through the IO monad.

Union-find is critical for type inference performance, allowing near-constant-time
operations for unifying type variables and checking equivalence.


# Operations

@docs fresh, repr, get, set, modify, union, equivalent, redundant
@docs freshS, reprS, getS, setS, modifyS, unionS, equivalentS, redundantQ

-}

{- This is based on the following implementations:

     - https://hackage.haskell.org/package/union-find-0.2/docs/src/Data-UnionFind-IO.html
     - http://yann.regis-gianas.org/public/mini/code_UnionFind.html

   It seems like the OCaml one came first, but I am not sure.

   Compared to the Haskell implementation, the major changes here include:

     1. No more reallocating PointInfo when changing the weight
     2. Using the strict modifyIORef

-}

import Data.IORef as IORef
import System.TypeCheck.IO as IO exposing (Descriptor, IO)
import Utils.Crash exposing (crash)



-- ====== HELPERS ======


{-| Create a fresh union-find point containing the given descriptor.
This initializes a new singleton set with weight 1.
-}
fresh : IO.Descriptor -> IO IO.Point
fresh value s =
    let
        ( point, s1 ) =
            freshS value s
    in
    ( s1, point )


repr : IO.Point -> IO IO.Point
repr point s =
    let
        ( root, s1 ) =
            reprS s point
    in
    ( s1, root )


{-| Get the descriptor stored in a union-find point.
-}
get : IO.Point -> IO Descriptor
get point s =
    let
        ( desc, s1 ) =
            getS s point
    in
    ( s1, desc )


{-| Set the descriptor stored in a union-find point.
-}
set : IO.Point -> Descriptor -> IO ()
set point newDesc s =
    ( setS point newDesc s, () )


{-| Modify the descriptor stored in a union-find point using a transformation function.
Follows links to modify the representative element's descriptor in place.
-}
modify : IO.Point -> (Descriptor -> Descriptor) -> IO ()
modify point func s =
    ( modifyS point func s, () )


{-| Unite two union-find points into the same equivalence class with a new descriptor.
Uses weighted union to keep the tree balanced - the lighter tree becomes a child of the heavier tree.
If the points are already equivalent, just updates the descriptor.
-}
union : IO.Point -> IO.Point -> IO.Descriptor -> IO ()
union p1 p2 newDesc s =
    ( unionS p1 p2 newDesc s, () )


{-| Check if two union-find points are in the same equivalence class.
Returns True if they share the same representative element.
-}
equivalent : IO.Point -> IO.Point -> IO Bool
equivalent p1 p2 s =
    let
        ( eq, s1 ) =
            equivalentS s p1 p2
    in
    ( s1, eq )


{-| Check if a union-find point is redundant (i.e., it is a link to another point).
Returns True if the point has been merged into another equivalence class.
-}
redundant : IO.Point -> IO Bool
redundant point s =
    ( s, redundantQ s point )



-- ====== DIRECT STATE-PASSING CORE (plans/io-monad-dispatch-reduction.md P1) ======
--
-- The union-find primitives are the compiler's hottest code: a caller-side
-- dispatch census of a self-compile put `System.TypeCheck.IO`'s andThen/map at
-- 55.3 % of ALL generic dispatch (1.41e9 of 2.56e9), and the hot `andThen`
-- specializations were called from exactly these functions. The reason is
-- visible above: `IORef.readPointCell` returns the state UNCHANGED — it is an
-- array index — yet wrapping it in `IO` cost a closure for the action, a closure
-- for the `andThen`, a continuation closure, a result tuple and two indirect
-- calls PER READ.
--
-- So the bodies below thread `State` as an ordinary parameter. `( a, State )`
-- results follow the convention already used by `MonoSolver.Store.freshVarS` and
-- friends, and Eco gives such a return a `$sret` twin (two SSA values, no heap
-- tuple). `redundantQ` needs no state result at all: it is a pure query.
--
-- Behaviour is preserved EXACTLY, path compression included — these are the same
-- reads and writes in the same order, with the monad removed. The `IO`-shaped
-- exports above are thin wrappers, so no caller had to change.


{-| Allocate a fresh point. Writes (pushes a cell).
-}
freshS : IO.Descriptor -> IO.State -> ( IO.Point, IO.State )
freshS value s =
    let
        ( ref, s1 ) =
            IORef.newPointCellS 1 value s
    in
    ( IO.Pt ref, s1 )


{-| Find the representative, compressing the path behind it (so this WRITES;
it is not a pure query).
-}
reprS : IO.State -> IO.Point -> ( IO.Point, IO.State )
reprS s ((IO.Pt ref) as point) =
    case IORef.readPointCellS s ref of
        IO.Root _ _ ->
            ( point, s )

        IO.Chain ((IO.Pt ref1) as point1) ->
            let
                ( point2, s1 ) =
                    reprS s point1
            in
            if point2 /= point1 then
                ( point2, IORef.writePointCellS ref (IORef.readPointCellS s1 ref1) s1 )

            else
                ( point2, s1 )


{-| Read a descriptor. Pure for a root or a one-link chain — the overwhelmingly
common case — and only falls through to `reprS` (which compresses, and so
writes) for a chain two or more deep.
-}
getS : IO.State -> IO.Point -> ( Descriptor, IO.State )
getS s ((IO.Pt ref) as point) =
    case IORef.readPointCellS s ref of
        IO.Root _ desc ->
            ( desc, s )

        IO.Chain (IO.Pt ref1) ->
            case IORef.readPointCellS s ref1 of
                IO.Root _ desc ->
                    ( desc, s )

                IO.Chain _ ->
                    let
                        ( newPoint, s1 ) =
                            reprS s point
                    in
                    getS s1 newPoint


setS : IO.Point -> Descriptor -> IO.State -> IO.State
setS ((IO.Pt ref) as point) newDesc s =
    case IORef.readPointCellS s ref of
        IO.Root w _ ->
            IORef.writePointCellS ref (IO.Root w newDesc) s

        IO.Chain (IO.Pt ref1) ->
            case IORef.readPointCellS s ref1 of
                IO.Root w _ ->
                    IORef.writePointCellS ref1 (IO.Root w newDesc) s

                IO.Chain _ ->
                    let
                        ( newPoint, s1 ) =
                            reprS s point
                    in
                    setS newPoint newDesc s1


modifyS : IO.Point -> (Descriptor -> Descriptor) -> IO.State -> IO.State
modifyS ((IO.Pt ref) as point) func s =
    case IORef.readPointCellS s ref of
        IO.Root w desc ->
            IORef.writePointCellS ref (IO.Root w (func desc)) s

        IO.Chain (IO.Pt ref1) ->
            case IORef.readPointCellS s ref1 of
                IO.Root w desc ->
                    IORef.writePointCellS ref1 (IO.Root w (func desc)) s

                IO.Chain _ ->
                    let
                        ( newPoint, s1 ) =
                            reprS s point
                    in
                    modifyS newPoint func s1


unionS : IO.Point -> IO.Point -> IO.Descriptor -> IO.State -> IO.State
unionS p1 p2 newDesc s =
    let
        ( (IO.Pt ref1) as point1, s1 ) =
            reprS s p1

        ( (IO.Pt ref2) as point2, s2 ) =
            reprS s1 p2
    in
    case ( IORef.readPointCellS s2 ref1, IORef.readPointCellS s2 ref2 ) of
        ( IO.Root weight1 _, IO.Root weight2 _ ) ->
            if point1 == point2 then
                -- Descriptor-only update. The whole cell is rewritten now, so it
                -- must carry the EXISTING weight: writing newWeight here would
                -- double a self-union's weight and change the union-by-weight
                -- tree shape.
                IORef.writePointCellS ref1 (IO.Root weight1 newDesc) s2

            else
                let
                    newWeight : Int
                    newWeight =
                        weight1 + weight2
                in
                if weight1 >= weight2 then
                    s2
                        |> IORef.writePointCellS ref2 (IO.Chain point1)
                        |> IORef.writePointCellS ref1 (IO.Root newWeight newDesc)

                else
                    s2
                        |> IORef.writePointCellS ref1 (IO.Chain point2)
                        |> IORef.writePointCellS ref2 (IO.Root newWeight newDesc)

        _ ->
            crash "Unexpected pattern"


equivalentS : IO.State -> IO.Point -> IO.Point -> ( Bool, IO.State )
equivalentS s p1 p2 =
    let
        ( v1, s1 ) =
            reprS s p1

        ( v2, s2 ) =
            reprS s1 p2
    in
    ( v1 == v2, s2 )


{-| A genuine query: reads one cell and changes nothing, so it takes no state
result at all.
-}
redundantQ : IO.State -> IO.Point -> Bool
redundantQ s (IO.Pt ref) =
    case IORef.readPointCellS s ref of
        IO.Root _ _ ->
            False

        IO.Chain _ ->
            True
