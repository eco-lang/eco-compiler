module Compiler.Type.State.Vector exposing
    ( unsafeLast, unsafeInit, unsafeFreeze
    , forM_, imapM_
    )

{-| The type checker keeps some of its working data in _vectors_, and this
module reads and walks them.

A vector is an array whose slots each hold a list of type variables. It lives in the type checker's table of vectors, and an `IORef`
refers to it, as `Compiler.Type.State.IORef` describes. Reading a vector gives the array as it
stands at that moment.

The names follow Haskell's `Compiler.Type.State.Vector`, but two of the functions do less
than their names suggest. `unsafeInit` gives back the same reference, so it
does not leave out the last slot, and `unsafeFreeze` copies nothing. The
`unsafe` prefix otherwise marks a function that crashes when what it expects is
not there.


# Vector Operations

@docs unsafeLast, unsafeInit, unsafeFreeze


# Monadic Iteration

@docs forM_, imapM_

-}

import Array exposing (Array)
import Compiler.IR.Typed.TypeVars as Vars exposing (Variable)
import Compiler.Type.State.IO as IO exposing (IO)
import Compiler.Type.State.IORef as IORef exposing (IORef)
import System.Crash exposing (crash)


{-| Returns an action that gives the list in the last slot of the vector.
Crashes if the vector has no slots.
-}
unsafeLast : IORef (Array (List Variable)) -> IO (List Variable)
unsafeLast ioRef =
    IORef.readIORefMVector ioRef
        |> IO.map
            (\array ->
                case Array.get (Array.length array - 1) array of
                    Just value ->
                        value

                    Nothing ->
                        crash "Compiler.Type.State.Vector.unsafeLast: empty array"
            )


{-| Returns the reference unchanged. Unlike Haskell's `init`, it does not leave
out the last slot: anything given the result sees the whole vector.
-}
unsafeInit : IORef (Array a) -> IORef (Array a)
unsafeInit =
    identity


{-| Returns an action that runs `action` on each slot of the vector, in index
order, passing the slot's index and its list, and discards the results.
-}
imapM_ : (Int -> List Variable -> IO b) -> IORef (Array (List Vars.Variable)) -> IO ()
imapM_ action ioRef =
    IORef.readIORefMVector ioRef
        |> IO.andThen
            (\value ->
                Array.foldl
                    (\( i, x ) ioAcc ->
                        ioAcc
                            |> IO.andThen (\_ -> action i x)
                            |> IO.map (\_ -> ())
                    )
                    (IO.pure ())
                    (Array.indexedMap Tuple.pair value)
            )


{-| Returns an action that runs `action` on the list in each slot of the
vector, in index order, and discards the results.
-}
mapM_ : (List Vars.Variable -> IO b) -> IORef (Array (List Vars.Variable)) -> IO ()
mapM_ action ioRef =
    imapM_ (\_ -> action) ioRef


{-| Returns an action that runs `action` on the list in each slot of the
vector, in index order, and discards the results.
-}
forM_ : IORef (Array (List Vars.Variable)) -> (List Vars.Variable -> IO b) -> IO ()
forM_ ioRef action =
    mapM_ action ioRef


{-| Returns an action that gives back the same reference. Nothing is copied, so
a later write through the reference is seen through the result as well.
-}
unsafeFreeze : IORef (Array a) -> IO (IORef (Array a))
unsafeFreeze =
    IO.pure
