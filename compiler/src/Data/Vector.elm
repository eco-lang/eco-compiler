module Data.Vector exposing
    ( unsafeLast, unsafeInit, unsafeFreeze
    , forM_, imapM_
    )

{-| The type checker keeps some of its working data in _vectors_, and this
module reads and walks them.

A vector is an array whose slots each hold either nothing or a list of type
variables. It lives in the type checker's table of vectors, and an `IORef`
refers to it, as `Data.IORef` describes. Reading a vector gives the array as it
stands at that moment.

The names follow Haskell's `Data.Vector`, but two of the functions do less
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
import Compiler.AST.TypeVars as Vars exposing (Variable)
import Data.IORef as IORef exposing (IORef)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Crash exposing (crash)


{-| Returns an action that gives the list in the last slot of the vector.
Crashes if the vector has no slots or its last slot is empty.
-}
unsafeLast : IORef (Array (Maybe (List Variable))) -> IO (List Variable)
unsafeLast ioRef =
    IORef.readIORefMVector ioRef
        |> IO.map
            (\array ->
                case Array.get (Array.length array - 1) array of
                    Just (Just value) ->
                        value

                    Just Nothing ->
                        crash "Data.Vector.unsafeLast: invalid value"

                    Nothing ->
                        crash "Data.Vector.unsafeLast: empty array"
            )


{-| Returns the reference unchanged. Unlike Haskell's `init`, it does not leave
out the last slot: anything given the result sees the whole vector.
-}
unsafeInit : IORef (Array (Maybe a)) -> IORef (Array (Maybe a))
unsafeInit =
    identity


{-| Returns an action that runs `action` on each filled slot of the vector, in
index order, passing the slot's index and its list, and discards the results.
Empty slots are skipped.
-}
imapM_ : (Int -> List Variable -> IO b) -> IORef (Array (Maybe (List Vars.Variable))) -> IO ()
imapM_ action ioRef =
    IORef.readIORefMVector ioRef
        |> IO.andThen
            (\value ->
                Array.foldl
                    (\( i, maybeX ) ioAcc ->
                        case maybeX of
                            Just x ->
                                ioAcc
                                    |> IO.andThen (\_ -> action i x)
                                    |> IO.map (\_ -> ())

                            Nothing ->
                                ioAcc
                    )
                    (IO.pure ())
                    (Array.indexedMap Tuple.pair value)
            )


{-| Returns an action that runs `action` on the list in each filled slot of the
vector, in index order, and discards the results. Empty slots are skipped.
-}
mapM_ : (List Vars.Variable -> IO b) -> IORef (Array (Maybe (List Vars.Variable))) -> IO ()
mapM_ action ioRef =
    imapM_ (\_ -> action) ioRef


{-| Returns an action that runs `action` on the list in each filled slot of the
vector, in index order, and discards the results. Empty slots are skipped.
-}
forM_ : IORef (Array (Maybe (List Vars.Variable))) -> (List Vars.Variable -> IO b) -> IO ()
forM_ ioRef action =
    mapM_ action ioRef


{-| Returns an action that gives back the same reference. Nothing is copied, so
a later write through the reference is seen through the result as well.
-}
unsafeFreeze : IORef (Array (Maybe a)) -> IO (IORef (Array (Maybe a)))
unsafeFreeze =
    IO.pure
