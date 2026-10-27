module Builder.BackgroundWriter exposing
    ( Scope, withScope
    , writeBinary
    )

{-| Lets the builder write binary cache files without waiting for each write,
while still knowing that all of them have finished before it moves on.

A _scope_ is the set of background writes started inside one call to
`withScope`. Each `writeBinary` in the scope starts its write on a forked task
and returns as soon as the write is recorded in the scope. When the callback
given to `withScope` succeeds, `withScope` waits for every recorded write to
finish and only then returns the callback's result.

The writes are not ordered among themselves, and nothing waits for one before
the scope ends, so code inside the scope cannot rely on reading back a file it
has just written this way. A `Scope` is spent once its `withScope` returns: a
later `writeBinary` on it waits forever.


# Scope Management

@docs Scope, withScope


# Background Writing

@docs writeBinary

-}

import Builder.File as File
import Bytes.Decode
import Bytes.Encode
import System.IO as IO
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils



-- ====== BACKGROUND WRITER ======


{-| The background writes started inside one call to `withScope`, which that
call waits for before it returns. A value is obtained only from `withScope`.
-}
type Scope
    = Scope (IO.MVar (List (IO.MVar ())))


{-| Runs `callback` with a new scope and returns its result once every write
started in that scope with `writeBinary` has finished.
-}
withScope : (Scope -> Task Never a) -> Task Never a
withScope callback =
    Utils.newMVar (BE.list (\_ -> BE.unit ())) []
        |> Task.andThen (runCallbackAndWait callback)


{-| Runs `callback` with the scope whose writes are recorded in `workList`,
then waits for those writes and returns the callback's result.
-}
runCallbackAndWait : (Scope -> Task Never a) -> IO.MVar (List (IO.MVar ())) -> Task Never a
runCallbackAndWait callback workList =
    callback (Scope workList)
        |> Task.andThen (waitForAllWork workList)


{-| Takes the recorded writes out of `workList`, waits for each, and returns
`result`. The work list is left empty, so the scope cannot record another write.
-}
waitForAllWork : IO.MVar (List (IO.MVar ())) -> a -> Task Never a
waitForAllWork workList result =
    Utils.takeMVar (BD.list Utils.mVarDecoder) workList
        |> Task.andThen (waitForMVars result)


{-| Waits for each completion MVar in `mvars` to be filled, one after another,
and returns `result`.
-}
waitForMVars : a -> List (IO.MVar ()) -> Task Never a
waitForMVars result mvars =
    Utils.listTraverse_ (Utils.takeMVar (Bytes.Decode.succeed ())) mvars
        |> Task.map (\_ -> result)


{-| Starts writing `value` to `path` in the background, with the encoder
`toEncoder` builds, and records the write in the scope. It returns before the
write has finished. The write is `Builder.File.writeBinary`, so parent
directories are created and an IO error crashes the program.
-}
writeBinary : (a -> Bytes.Encode.Encoder) -> Scope -> String -> a -> Task Never ()
writeBinary toEncoder (Scope workList) path value =
    Utils.newEmptyMVar
        |> Task.andThen (forkWriteAndAddToWorkList toEncoder workList path value)


{-| Forks the write of `value` to `path`, which fills `mvar` when done, and
records `mvar` in `workList`.
-}
forkWriteAndAddToWorkList : (a -> Bytes.Encode.Encoder) -> IO.MVar (List (IO.MVar ())) -> String -> a -> IO.MVar () -> Task Never ()
forkWriteAndAddToWorkList toEncoder workList path value mvar =
    Utils.forkIO (writeAndSignalComplete toEncoder path value mvar)
        |> Task.andThen (\_ -> addMVarToWorkList workList mvar)


{-| Writes `value` to `path` and then fills `mvar` to signal that the write has
finished.
-}
writeAndSignalComplete : (a -> Bytes.Encode.Encoder) -> String -> a -> IO.MVar () -> Task Never ()
writeAndSignalComplete toEncoder path value mvar =
    File.writeBinary toEncoder path value
        |> Task.andThen (\_ -> Utils.putMVar BE.unit mvar ())


{-| Adds `mvar` to the completion MVars recorded in `workList`.
-}
addMVarToWorkList : IO.MVar (List (IO.MVar ())) -> IO.MVar () -> Task Never ()
addMVarToWorkList workList mvar =
    Utils.takeMVar (BD.list Utils.mVarDecoder) workList
        |> Task.andThen (prependAndPutBack workList mvar)


{-| Puts `mvar` followed by `oldWork` back into `workList`.
-}
prependAndPutBack : IO.MVar (List (IO.MVar ())) -> IO.MVar () -> List (IO.MVar ()) -> Task Never ()
prependAndPutBack workList mvar oldWork =
    Utils.putMVar (BE.list Utils.mVarEncoder) workList (mvar :: oldWork)
