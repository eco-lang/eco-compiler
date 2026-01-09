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

import Data.IORef as IORef exposing (IORef(..))
import System.TypeCheck.IO as IO exposing (Descriptor, IO)
import Utils.Crash exposing (crash)



-- ====== HELPERS ======


{-| Create a fresh union-find point containing the given descriptor.
This initializes a new singleton set with weight 1.
-}
fresh : IO.Descriptor -> IO IO.Point
fresh value =
    IORef.newIORefWeight 1
        |> IO.andThen
            (\(IORef weight) ->
                IORef.newIORefDescriptor value
                    |> IO.andThen (\(IORef desc) -> IORef.newIORefPointInfo (IO.Info weight desc))
                    |> IO.map (\(IORef link) -> IO.Pt link)
            )


repr : IO.Point -> IO IO.Point
repr ((IO.Pt ref) as point) =
    IORef.readIORefPointInfo (IORef ref)
        |> IO.andThen
            (\pInfo ->
                case pInfo of
                    IO.Info _ _ ->
                        IO.pure point

                    IO.Link ((IO.Pt ref1) as point1) ->
                        repr point1
                            |> IO.andThen
                                (\point2 ->
                                    if point2 /= point1 then
                                        IORef.readIORefPointInfo (IORef ref1)
                                            |> IO.andThen
                                                (\pInfo1 ->
                                                    IORef.writeIORefPointInfo (IORef ref) pInfo1
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
    IORef.readIORefPointInfo (IORef ref)
        |> IO.andThen
            (\pInfo ->
                case pInfo of
                    IO.Info _ descRef ->
                        IORef.readIORefDescriptor (IORef descRef)

                    IO.Link (IO.Pt ref1) ->
                        IORef.readIORefPointInfo (IORef ref1)
                            |> IO.andThen
                                (\link_ ->
                                    case link_ of
                                        IO.Info _ descRef ->
                                            IORef.readIORefDescriptor (IORef descRef)

                                        IO.Link _ ->
                                            repr point |> IO.andThen get
                                )
            )


{-| Set the descriptor stored in a union-find point.
Follows links to update the representative element's descriptor.
-}
set : IO.Point -> Descriptor -> IO ()
set ((IO.Pt ref) as point) newDesc =
    IORef.readIORefPointInfo (IORef ref)
        |> IO.andThen
            (\pInfo ->
                case pInfo of
                    IO.Info _ descRef ->
                        IORef.writeIORefDescriptor (IORef descRef) newDesc

                    IO.Link (IO.Pt ref1) ->
                        IORef.readIORefPointInfo (IORef ref1)
                            |> IO.andThen
                                (\link_ ->
                                    case link_ of
                                        IO.Info _ descRef ->
                                            IORef.writeIORefDescriptor (IORef descRef) newDesc

                                        IO.Link _ ->
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
    IORef.readIORefPointInfo (IORef ref)
        |> IO.andThen
            (\pInfo ->
                case pInfo of
                    IO.Info _ descRef ->
                        IORef.modifyIORefDescriptor (IORef descRef) func

                    IO.Link (IO.Pt ref1) ->
                        IORef.readIORefPointInfo (IORef ref1)
                            |> IO.andThen
                                (\link_ ->
                                    case link_ of
                                        IO.Info _ descRef ->
                                            IORef.modifyIORefDescriptor (IORef descRef) func

                                        IO.Link _ ->
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
                            IORef.readIORefPointInfo (IORef ref1)
                                |> IO.andThen
                                    (\pointInfo1 ->
                                        IORef.readIORefPointInfo (IORef ref2)
                                            |> IO.andThen
                                                (\pointInfo2 ->
                                                    case ( pointInfo1, pointInfo2 ) of
                                                        ( IO.Info w1 d1, IO.Info w2 d2 ) ->
                                                            if point1 == point2 then
                                                                IORef.writeIORefDescriptor (IORef d1) newDesc

                                                            else
                                                                IORef.readIORefWeight (IORef w1)
                                                                    |> IO.andThen
                                                                        (\weight1 ->
                                                                            IORef.readIORefWeight (IORef w2)
                                                                                |> IO.andThen
                                                                                    (\weight2 ->
                                                                                        let
                                                                                            newWeight : Int
                                                                                            newWeight =
                                                                                                weight1 + weight2
                                                                                        in
                                                                                        if weight1 >= weight2 then
                                                                                            IORef.writeIORefPointInfo (IORef ref2) (IO.Link point1)
                                                                                                |> IO.andThen (\_ -> IORef.writeIORefWeight (IORef w1) newWeight)
                                                                                                |> IO.andThen (\_ -> IORef.writeIORefDescriptor (IORef d1) newDesc)

                                                                                        else
                                                                                            IORef.writeIORefPointInfo (IORef ref1) (IO.Link point2)
                                                                                                |> IO.andThen (\_ -> IORef.writeIORefWeight (IORef w2) newWeight)
                                                                                                |> IO.andThen (\_ -> IORef.writeIORefDescriptor (IORef d2) newDesc)
                                                                                    )
                                                                        )

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
    IORef.readIORefPointInfo (IORef ref)
        |> IO.map
            (\pInfo ->
                case pInfo of
                    IO.Info _ _ ->
                        False

                    IO.Link _ ->
                        True
            )
