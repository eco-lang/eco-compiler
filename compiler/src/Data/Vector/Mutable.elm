module Data.Vector.Mutable exposing (grow, length, modify, read, replicate, write)

{-| The type solver keeps growable, updatable vectors of variable lists, and
this module gives them the operations of a mutable vector.

A mutable vector here is an `IORef` to an array held in the type-checking state's
table of vectors, as `Data.IORef` describes. Each slot of the array is either
filled, holding a list of type variables, or empty (`Nothing`). A vector made by
`replicate` starts with every slot filled; `grow` adds empty slots at the end,
and `write` fills one.

Operations act through the reference, so every holder of the same `IORef` sees
the change. Reading a slot that is empty, or past the end, crashes; writing or
modifying a slot past the end does nothing, and so does modifying an empty slot.

@docs grow, length, modify, read, replicate, write

-}

import Array exposing (Array)
import Array.Extra as Array
import Compiler.Type.Vars as Vars exposing (Variable)
import Data.IORef as IORef exposing (IORef)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Crash exposing (crash)


{-| Returns an action that gives the number of slots in the vector, filled or
empty.
-}
length : IORef (Array (Maybe (List Variable))) -> IO Int
length =
    IORef.readIORefMVector
        >> IO.map Array.length


{-| Returns an action that creates a vector of `n` slots, each filled with `e`.
-}
replicate : Int -> List Variable -> IO (IORef (Array (Maybe (List Variable))))
replicate n e =
    IORef.newIORefMVector (Array.repeat n (Just e))


{-| Returns an action that appends `length_` empty slots to the vector and gives
back the same reference, not a copy.
-}
grow : IORef (Array (Maybe (List Variable))) -> Int -> IO (IORef (Array (Maybe (List Variable))))
grow ioRef length_ =
    IORef.readIORefMVector ioRef
        |> IO.andThen
            (\value ->
                IORef.writeIORefMVector ioRef
                    (Array.append value (Array.repeat length_ Nothing))
            )
        |> IO.map (\_ -> ioRef)


{-| Returns an action that gives the list in slot `i`. Crashes if the slot is
empty or `i` is out of range.
-}
read : IORef (Array (Maybe (List Variable))) -> Int -> IO (List Variable)
read ioRef i =
    IORef.readIORefMVector ioRef
        |> IO.map
            (\array ->
                case Array.get i array of
                    Just (Just value) ->
                        value

                    Just Nothing ->
                        crash "Data.Vector.read: invalid value"

                    Nothing ->
                        crash "Data.Vector.read: could not find entry"
            )


{-| Returns an action that fills slot `i` with `x`, replacing whatever it held.
If `i` is out of range the vector is left unchanged.
-}
write : IORef (Array (Maybe (List Variable))) -> Int -> List Variable -> IO ()
write ioRef i x =
    IORef.modifyIORefMVector ioRef
        (Array.set i (Just x))


{-| Returns an action that replaces the list in slot `index` with `func` applied
to it. An empty slot, or an `index` out of range, is left unchanged.

The function comes before the index, unlike `read` and `write`.

-}
modify : IORef (Array (Maybe (List Variable))) -> (List Variable -> List Variable) -> Int -> IO ()
modify ioRef func index =
    IORef.modifyIORefMVector ioRef
        (Array.update index (Maybe.map func))
