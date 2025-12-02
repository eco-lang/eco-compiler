module Guida.IO exposing
    ( Ports
    , IOApi, ioApi
    , FileSystemApi, ConsoleApi, ProcessApi, ConcurrencyApi, NetworkApi
    , Handle, stdout, stderr
    , MVar, Chan, ChItem(..)
    , Archive, ArchiveEntry
    , Error(..), errorToString
    )

{-| Re-exports for Guida IO library.

This module provides convenient access to all IO operations.


# Combined Ports

@docs Ports


# Combined API

@docs IOApi, ioApi


# Individual APIs

@docs FileSystemApi, ConsoleApi, ProcessApi, ConcurrencyApi, NetworkApi


# Console Handles

@docs Handle, stdout, stderr


# Concurrency Types

@docs MVar, Chan, ChItem


# Network Types

@docs Archive, ArchiveEntry


# Error Handling

@docs Error, errorToString

-}

import Guida.IO.Concurrency as Concurrency
import Guida.IO.Console as Console
import Guida.IO.FileSystem as FileSystem
import Guida.IO.Network as Network
import Guida.IO.Process as Process
import Json.Encode exposing (Value)
import Procedure.Program



-- RE-EXPORTS


{-| Re-export FileSystemApi
-}
type alias FileSystemApi msg =
    FileSystem.FileSystemApi msg


{-| Re-export ConsoleApi
-}
type alias ConsoleApi msg =
    Console.ConsoleApi msg


{-| Re-export ProcessApi
-}
type alias ProcessApi msg =
    Process.ProcessApi msg


{-| Re-export ConcurrencyApi
-}
type alias ConcurrencyApi msg =
    Concurrency.ConcurrencyApi msg


{-| Re-export NetworkApi
-}
type alias NetworkApi msg =
    Network.NetworkApi msg


{-| Re-export Handle
-}
type alias Handle =
    Console.Handle


{-| Re-export stdout
-}
stdout : Handle
stdout =
    Console.stdout


{-| Re-export stderr
-}
stderr : Handle
stderr =
    Console.stderr


{-| Re-export MVar
-}
type alias MVar a =
    Concurrency.MVar a


{-| Re-export Chan
-}
type alias Chan a =
    Concurrency.Chan a


{-| Re-export ChItem
-}
type ChItem a
    = ChItem a (MVar (ChItem a))


{-| Re-export Archive
-}
type alias Archive =
    Network.Archive


{-| Re-export ArchiveEntry
-}
type alias ArchiveEntry =
    Network.ArchiveEntry



-- COMBINED PORTS


{-| Combined ports type for all IO modules.
Wire this up to your Elm application's ports.
-}
type alias Ports msg =
    { -- FileSystem ports
      fsRead : { id : String, path : String } -> Cmd msg
    , fsWriteString : { id : String, path : String, content : String } -> Cmd msg
    , fsWriteBinary : { id : String, path : String, content : Value } -> Cmd msg
    , fsBinaryDecode : { id : String, path : String } -> Cmd msg
    , fsDoesFileExist : { id : String, path : String } -> Cmd msg
    , fsDoesDirectoryExist : { id : String, path : String } -> Cmd msg
    , fsCreateDirectory : { id : String, path : String, createParents : Bool } -> Cmd msg
    , fsListDirectory : { id : String, path : String } -> Cmd msg
    , fsRemoveFile : { id : String, path : String } -> Cmd msg
    , fsRemoveDirectoryRecursive : { id : String, path : String } -> Cmd msg
    , fsCanonicalizePath : { id : String, path : String } -> Cmd msg
    , fsGetCurrentDirectory : { id : String } -> Cmd msg
    , fsGetAppUserDataDirectory : { id : String, appName : String } -> Cmd msg
    , fsGetModificationTime : { id : String, path : String } -> Cmd msg
    , fsLockFile : { id : String, path : String } -> Cmd msg
    , fsUnlockFile : { id : String, path : String } -> Cmd msg
    , fsResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg

    -- Console ports
    , consoleWrite : { fd : Int, content : String } -> Cmd msg
    , consoleGetLine : { id : String } -> Cmd msg
    , consoleReplGetInputLine : { id : String, prompt : String } -> Cmd msg
    , consoleResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg

    -- Process ports
    , procLookupEnv : { id : String, name : String } -> Cmd msg
    , procGetArgs : { id : String } -> Cmd msg
    , procFindExecutable : { id : String, name : String } -> Cmd msg
    , procExit : { response : Value } -> Cmd msg
    , procResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg

    -- Concurrency ports
    , concNewEmptyMVar : { id : String } -> Cmd msg
    , concReadMVar : { id : String, mvarId : Int } -> Cmd msg
    , concTakeMVar : { id : String, mvarId : Int } -> Cmd msg
    , concPutMVar : { id : String, mvarId : Int, value : Value } -> Cmd msg
    , concResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg

    -- Network ports
    , netGetArchive : { id : String, url : String } -> Cmd msg
    , netResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg
    }



-- COMBINED API


{-| Combined IO API providing access to all IO operations.
-}
type alias IOApi msg =
    { fileSystem : FileSystemApi msg
    , console : ConsoleApi msg
    , process : ProcessApi msg
    , concurrency : ConcurrencyApi msg
    , network : NetworkApi msg
    }


{-| Create a combined IO API from ports.
-}
ioApi : (Procedure.Program.Msg msg -> msg) -> Ports msg -> IOApi msg
ioApi pt ports =
    { fileSystem = FileSystem.fileSystemApi pt (toFileSystemPorts ports)
    , console = Console.consoleApi pt (toConsolePorts ports)
    , process = Process.processApi pt (toProcessPorts ports)
    , concurrency = Concurrency.concurrencyApi pt (toConcurrencyPorts ports)
    , network = Network.networkApi pt (toNetworkPorts ports)
    }



-- PORT ADAPTERS


toFileSystemPorts : Ports msg -> FileSystem.Ports msg
toFileSystemPorts ports =
    { fsRead = ports.fsRead
    , fsWriteString = ports.fsWriteString
    , fsWriteBinary = ports.fsWriteBinary
    , fsBinaryDecode = ports.fsBinaryDecode
    , fsDoesFileExist = ports.fsDoesFileExist
    , fsDoesDirectoryExist = ports.fsDoesDirectoryExist
    , fsCreateDirectory = ports.fsCreateDirectory
    , fsListDirectory = ports.fsListDirectory
    , fsRemoveFile = ports.fsRemoveFile
    , fsRemoveDirectoryRecursive = ports.fsRemoveDirectoryRecursive
    , fsCanonicalizePath = ports.fsCanonicalizePath
    , fsGetCurrentDirectory = ports.fsGetCurrentDirectory
    , fsGetAppUserDataDirectory = ports.fsGetAppUserDataDirectory
    , fsGetModificationTime = ports.fsGetModificationTime
    , fsLockFile = ports.fsLockFile
    , fsUnlockFile = ports.fsUnlockFile
    , fsResponse = ports.fsResponse
    }


toConsolePorts : Ports msg -> Console.Ports msg
toConsolePorts ports =
    { consoleWrite = ports.consoleWrite
    , consoleGetLine = ports.consoleGetLine
    , consoleReplGetInputLine = ports.consoleReplGetInputLine
    , consoleResponse = ports.consoleResponse
    }


toProcessPorts : Ports msg -> Process.Ports msg
toProcessPorts ports =
    { procLookupEnv = ports.procLookupEnv
    , procGetArgs = ports.procGetArgs
    , procFindExecutable = ports.procFindExecutable
    , procExit = ports.procExit
    , procResponse = ports.procResponse
    }


toConcurrencyPorts : Ports msg -> Concurrency.Ports msg
toConcurrencyPorts ports =
    { concNewEmptyMVar = ports.concNewEmptyMVar
    , concReadMVar = ports.concReadMVar
    , concTakeMVar = ports.concTakeMVar
    , concPutMVar = ports.concPutMVar
    , concResponse = ports.concResponse
    }


toNetworkPorts : Ports msg -> Network.Ports msg
toNetworkPorts ports =
    { netGetArchive = ports.netGetArchive
    , netResponse = ports.netResponse
    }



-- ERROR TYPE


{-| Unified error type for all IO operations.
-}
type Error
    = FileSystemError FileSystem.Error
    | ConsoleError Console.Error
    | ProcessError Process.Error
    | ConcurrencyError Concurrency.Error
    | NetworkError Network.Error


{-| Convert any IO error to a human-readable string.
-}
errorToString : Error -> String
errorToString error =
    case error of
        FileSystemError e ->
            FileSystem.errorToString e

        ConsoleError e ->
            Console.errorToString e

        ProcessError e ->
            Process.errorToString e

        ConcurrencyError e ->
            Concurrency.errorToString e

        NetworkError e ->
            Network.errorToString e
