module Compiler.Type.UnionFind exposing (fresh, get, set, modify, union, equivalent, redundant)

{-| Union-Find data structure for efficient type unification.

This module implements a union-find (disjoint-set) data structure optimized for type
inference. It allows efficient tracking of type variable equivalences and supports
path compression for fast lookups. The implementation uses mutable references (IORef)
to achieve efficient updates while maintaining a pure interface through the IO monad.

Union-find is critical for type inference performance, allowing near-constant-time
operations for unifying type variables and checking equivalence.


# Operations

@docs fresh, get, set, modify, union, equivalent, redundant

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
fresh value =
    IORef.newPointCell 1 value |> IO.map IO.Pt


repr : IO.Point -> IO IO.Point
repr ((IO.Pt ref) as point) =
    IORef.readPointCell ref
        |> IO.andThen
            (\cell ->
                case cell of
                    IO.Root _ _ ->
                        IO.pure point

                    IO.Chain ((IO.Pt ref1) as point1) ->
                        repr point1
                            |> IO.andThen
                                (\point2 ->
                                    if point2 /= point1 then
                                        IORef.readPointCell ref1
                                            |> IO.andThen
                                                (\cell1 ->
                                                    IORef.writePointCell ref cell1
                                                        |> IO.map (\_ -> point2)
                                                )

                                    else
                                        IO.pure point2
                                )
            )


{-| Get the descriptor stored in a union-find point.
Follows links to find the representative element's descriptor.
-}
get : IO.Point -> IO Descriptor
get ((IO.Pt ref) as point) =
    IORef.readPointCell ref
        |> IO.andThen
            (\cell ->
                case cell of
                    IO.Root _ desc ->
                        IO.pure desc

                    IO.Chain (IO.Pt ref1) ->
                        IORef.readPointCell ref1
                            |> IO.andThen
                                (\cell1 ->
                                    case cell1 of
                                        IO.Root _ desc ->
                                            IO.pure desc

                                        IO.Chain _ ->
                                            repr point |> IO.andThen get
                                )
            )


{-| Set the descriptor stored in a union-find point.
Follows links to update the representative element's descriptor.
-}
set : IO.Point -> Descriptor -> IO ()
set ((IO.Pt ref) as point) newDesc =
    IORef.readPointCell ref
        |> IO.andThen
            (\cell ->
                case cell of
                    IO.Root w _ ->
                        IORef.writePointCell ref (IO.Root w newDesc)

                    IO.Chain (IO.Pt ref1) ->
                        IORef.readPointCell ref1
                            |> IO.andThen
                                (\cell1 ->
                                    case cell1 of
                                        IO.Root w _ ->
                                            IORef.writePointCell ref1 (IO.Root w newDesc)

                                        IO.Chain _ ->
                                            repr point
                                                |> IO.andThen
                                                    (\newPoint ->
                                                        set newPoint newDesc
                                                    )
                                )
            )


{-| Modify the descriptor stored in a union-find point using a transformation function.
Follows links to modify the representative element's descriptor in place.
-}
modify : IO.Point -> (Descriptor -> Descriptor) -> IO ()
modify ((IO.Pt ref) as point) func =
    IORef.readPointCell ref
        |> IO.andThen
            (\cell ->
                case cell of
                    IO.Root w desc ->
                        IORef.writePointCell ref (IO.Root w (func desc))

                    IO.Chain (IO.Pt ref1) ->
                        IORef.readPointCell ref1
                            |> IO.andThen
                                (\cell1 ->
                                    case cell1 of
                                        IO.Root w desc ->
                                            IORef.writePointCell ref1 (IO.Root w (func desc))

                                        IO.Chain _ ->
                                            repr point
                                                |> IO.andThen (\newPoint -> modify newPoint func)
                                )
            )


{-| Unite two union-find points into the same equivalence class with a new descriptor.
Uses weighted union to keep the tree balanced - the lighter tree becomes a child of the heavier tree.
If the points are already equivalent, just updates the descriptor.
-}
union : IO.Point -> IO.Point -> IO.Descriptor -> IO ()
union p1 p2 newDesc =
    repr p1
        |> IO.andThen
            (\((IO.Pt ref1) as point1) ->
                repr p2
                    |> IO.andThen
                        (\((IO.Pt ref2) as point2) ->
                            IORef.readPointCell ref1
                                |> IO.andThen
                                    (\cell1 ->
                                        IORef.readPointCell ref2
                                            |> IO.andThen
                                                (\cell2 ->
                                                    case ( cell1, cell2 ) of
                                                        ( IO.Root weight1 _, IO.Root weight2 _ ) ->
                                                            if point1 == point2 then
                                                                -- Descriptor-only update. The whole cell is
                                                                -- rewritten now, so it must carry the EXISTING
                                                                -- weight: writing newWeight here would double
                                                                -- a self-union's weight and change the
                                                                -- union-by-weight tree shape.
                                                                IORef.writePointCell ref1 (IO.Root weight1 newDesc)

                                                            else
                                                                let
                                                                    newWeight : Int
                                                                    newWeight =
                                                                        weight1 + weight2
                                                                in
                                                                if weight1 >= weight2 then
                                                                    IORef.writePointCell ref2 (IO.Chain point1)
                                                                        |> IO.andThen (\_ -> IORef.writePointCell ref1 (IO.Root newWeight newDesc))

                                                                else
                                                                    IORef.writePointCell ref1 (IO.Chain point2)
                                                                        |> IO.andThen (\_ -> IORef.writePointCell ref2 (IO.Root newWeight newDesc))

                                                        _ ->
                                                            crash "Unexpected pattern"
                                                )
                                    )
                        )
            )


{-| Check if two union-find points are in the same equivalence class.
Returns True if they share the same representative element.
-}
equivalent : IO.Point -> IO.Point -> IO Bool
equivalent p1 p2 =
    repr p1
        |> IO.andThen
            (\v1 ->
                repr p2
                    |> IO.map (\v2 -> v1 == v2)
            )


{-| Check if a union-find point is redundant (i.e., it is a link to another point).
Returns True if the point has been merged into another equivalence class.
-}
redundant : IO.Point -> IO Bool
redundant (IO.Pt ref) =
    IORef.readPointCell ref
        |> IO.map
            (\cell ->
                case cell of
                    IO.Root _ _ ->
                        False

                    IO.Chain _ ->
                        True
            )
