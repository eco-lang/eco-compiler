module Builder.BackgroundWriter exposing
    ( Scope
    , withScope
    , writeBinary
    )

import Builder.File as File
import Bytes.Decode
import Bytes.Encode
import Task exposing (Task)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils



-- BACKGROUND WRITER


type Scope
    = Scope (Utils.MVar (List (Utils.MVar ())))


withScope : (Scope -> Task Never a) -> Task Never a
withScope callback =
    Utils.newMVar (BE.list (\_ -> BE.unit ())) []
        |> Task.andThen (runCallbackAndWait callback)


runCallbackAndWait : (Scope -> Task Never a) -> Utils.MVar (List (Utils.MVar ())) -> Task Never a
runCallbackAndWait callback workList =
    callback (Scope workList)
        |> Task.andThen (waitForAllWork workList)


waitForAllWork : Utils.MVar (List (Utils.MVar ())) -> a -> Task Never a
waitForAllWork workList result =
    Utils.takeMVar (BD.list Utils.mVarDecoder) workList
        |> Task.andThen (waitForMVars result)


waitForMVars : a -> List (Utils.MVar ()) -> Task Never a
waitForMVars result mvars =
    Utils.listTraverse_ (Utils.takeMVar (Bytes.Decode.succeed ())) mvars
        |> Task.map (\_ -> result)


writeBinary : (a -> Bytes.Encode.Encoder) -> Scope -> String -> a -> Task Never ()
writeBinary toEncoder (Scope workList) path value =
    Utils.newEmptyMVar
        |> Task.andThen (forkWriteAndAddToWorkList toEncoder workList path value)


forkWriteAndAddToWorkList : (a -> Bytes.Encode.Encoder) -> Utils.MVar (List (Utils.MVar ())) -> String -> a -> Utils.MVar () -> Task Never ()
forkWriteAndAddToWorkList toEncoder workList path value mvar =
    Utils.forkIO (writeAndSignalComplete toEncoder path value mvar)
        |> Task.andThen (\_ -> addMVarToWorkList workList mvar)


writeAndSignalComplete : (a -> Bytes.Encode.Encoder) -> String -> a -> Utils.MVar () -> Task Never ()
writeAndSignalComplete toEncoder path value mvar =
    File.writeBinary toEncoder path value
        |> Task.andThen (\_ -> Utils.putMVar BE.unit mvar ())


addMVarToWorkList : Utils.MVar (List (Utils.MVar ())) -> Utils.MVar () -> Task Never ()
addMVarToWorkList workList mvar =
    Utils.takeMVar (BD.list Utils.mVarDecoder) workList
        |> Task.andThen (prependAndPutBack workList mvar)


prependAndPutBack : Utils.MVar (List (Utils.MVar ())) -> Utils.MVar () -> List (Utils.MVar ()) -> Task Never ()
prependAndPutBack workList mvar oldWork =
    Utils.putMVar (BE.list Utils.mVarEncoder) workList (mvar :: oldWork)
