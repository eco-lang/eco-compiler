module Compiler.Type.State.Vector.Mutable exposing (grow, length, modify, read, replicate, write)

{-| The type solver keeps growable, updatable vectors of variable lists, and
this module gives them the operations of a mutable vector.

A mutable vector here is an `IORef` to an array held in the type-checking state's
table of vectors, as `Compiler.Type.State.IORef` describes. Each slot of the array
holds a list of type variables. `replicate` makes a vector, `grow` adds slots
holding the empty list at the end, and `write` replaces one slot's list.

Operations act through the reference, so every holder of the same `IORef` sees
the change. Reading a slot past the end crashes; writing or modifying a slot
past the end does nothing.

@docs grow, length, modify, read, replicate, write

-}

import Array exposing (Array)
import Array.Extra as Array
import Compiler.IR.Typed.TypeVars exposing (Variable)
import Compiler.Type.State.IO as IO exposing (IO)
import Compiler.Type.State.IORef as IORef exposing (IORef)
import System.Crash exposing (crash)


{-| Returns an action that gives the number of slots in the vector.
-}
length : IORef (Array (List Variable)) -> IO Int
length =
    IORef.readIORefMVector
        >> IO.map Array.length


{-| Returns an action that creates a vector of `n` slots, each holding `e`.
-}
replicate : Int -> List Variable -> IO (IORef (Array (List Variable)))
replicate n e =
    IORef.newIORefMVector (Array.repeat n e)


{-| Returns an action that appends `length_` slots holding the empty list to the
vector and gives back the same reference, not a copy.
-}
grow : IORef (Array (List Variable)) -> Int -> IO (IORef (Array (List Variable)))
grow ioRef length_ =
    IORef.readIORefMVector ioRef
        |> IO.andThen
            (\value ->
                IORef.writeIORefMVector ioRef
                    (Array.append value (Array.repeat length_ []))
            )
        |> IO.map (\_ -> ioRef)


{-| Returns an action that gives the list in slot `i`. Crashes if `i` is out of
range.
-}
read : IORef (Array (List Variable)) -> Int -> IO (List Variable)
read ioRef i =
    IORef.readIORefMVector ioRef
        |> IO.map
            (\array ->
                case Array.get i array of
                    Just value ->
                        value

                    Nothing ->
                        crash "Compiler.Type.State.Vector.read: could not find entry"
            )


{-| Returns an action that puts `x` in slot `i`, replacing whatever it held.
If `i` is out of range the vector is left unchanged.
-}
write : IORef (Array (List Variable)) -> Int -> List Variable -> IO ()
write ioRef i x =
    IORef.modifyIORefMVector ioRef
        (Array.set i x)


{-| Returns an action that replaces the list in slot `index` with `func` applied
to it. An `index` out of range leaves the vector unchanged.

The function comes before the index, unlike `read` and `write`.

-}
modify : IORef (Array (List Variable)) -> (List Variable -> List Variable) -> Int -> IO ()
modify ioRef func index =
    IORef.modifyIORefMVector ioRef
        (Array.update index func)
