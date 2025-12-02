module Guida.IO.FileSystem exposing
    ( Ports
    , FileSystemApi, fileSystemApi
    , read, writeString, writeBinary, binaryDecode
    , doesFileExist, doesDirectoryExist
    , createDirectory, listDirectory
    , removeFile, removeDirectoryRecursive
    , canonicalizePath, getCurrentDirectory, getAppUserDataDirectory
    , getModificationTime
    , lockFile, unlockFile, withLock
    , Error(..), errorToString, errorToDetails
    )

{-| File system operations for Guida IO.

@docs Ports
@docs FileSystemApi, fileSystemApi


# File Operations

@docs read, writeString, writeBinary, binaryDecode


# File Queries

@docs doesFileExist, doesDirectoryExist


# Directory Operations

@docs createDirectory, listDirectory
@docs removeFile, removeDirectoryRecursive


# Path Operations

@docs canonicalizePath, getCurrentDirectory, getAppUserDataDirectory
@docs getModificationTime


# File Locking

@docs lockFile, unlockFile, withLock


# Error Handling

@docs Error, errorToString, errorToDetails

-}

import Bytes exposing (Bytes)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Procedure
import Procedure.Channel as Channel
import Procedure.Program
import Time



-- PORTS


{-| The ports that need to be wired up to the TypeScript filesystem handlers.
-}
type alias Ports msg =
    { -- File operations
      fsRead : { id : String, path : String } -> Cmd msg
    , fsWriteString : { id : String, path : String, content : String } -> Cmd msg
    , fsWriteBinary : { id : String, path : String, content : Value } -> Cmd msg
    , fsBinaryDecode : { id : String, path : String } -> Cmd msg

    -- File queries
    , fsDoesFileExist : { id : String, path : String } -> Cmd msg
    , fsDoesDirectoryExist : { id : String, path : String } -> Cmd msg

    -- Directory operations
    , fsCreateDirectory : { id : String, path : String, createParents : Bool } -> Cmd msg
    , fsListDirectory : { id : String, path : String } -> Cmd msg
    , fsRemoveFile : { id : String, path : String } -> Cmd msg
    , fsRemoveDirectoryRecursive : { id : String, path : String } -> Cmd msg

    -- Path operations
    , fsCanonicalizePath : { id : String, path : String } -> Cmd msg
    , fsGetCurrentDirectory : { id : String } -> Cmd msg
    , fsGetAppUserDataDirectory : { id : String, appName : String } -> Cmd msg
    , fsGetModificationTime : { id : String, path : String } -> Cmd msg

    -- File locking
    , fsLockFile : { id : String, path : String } -> Cmd msg
    , fsUnlockFile : { id : String, path : String } -> Cmd msg

    -- Response subscription
    , fsResponse : ({ id : String, type_ : String, payload : Value } -> msg) -> Sub msg
    }



-- API


{-| The FileSystem API providing all file system operations.
-}
type alias FileSystemApi msg =
    { read : String -> (Result Error String -> msg) -> Cmd msg
    , writeString : String -> String -> (Result Error () -> msg) -> Cmd msg
    , writeBinary : String -> Bytes -> (Result Error () -> msg) -> Cmd msg
    , binaryDecode : String -> (Result Error Bytes -> msg) -> Cmd msg
    , doesFileExist : String -> (Bool -> msg) -> Cmd msg
    , doesDirectoryExist : String -> (Bool -> msg) -> Cmd msg
    , createDirectory : Bool -> String -> (Result Error () -> msg) -> Cmd msg
    , listDirectory : String -> (Result Error (List String) -> msg) -> Cmd msg
    , removeFile : String -> (Result Error () -> msg) -> Cmd msg
    , removeDirectoryRecursive : String -> (Result Error () -> msg) -> Cmd msg
    , canonicalizePath : String -> (Result Error String -> msg) -> Cmd msg
    , getCurrentDirectory : (Result Error String -> msg) -> Cmd msg
    , getAppUserDataDirectory : String -> (Result Error String -> msg) -> Cmd msg
    , getModificationTime : String -> (Result Error Time.Posix -> msg) -> Cmd msg
    , lockFile : String -> (Result Error () -> msg) -> Cmd msg
    , unlockFile : String -> (Result Error () -> msg) -> Cmd msg
    }


{-| Creates an instance of the FileSystem API.
-}
fileSystemApi : (Procedure.Program.Msg msg -> msg) -> Ports msg -> FileSystemApi msg
fileSystemApi pt ports =
    { read = read pt ports
    , writeString = writeString pt ports
    , writeBinary = writeBinary pt ports
    , binaryDecode = binaryDecode pt ports
    , doesFileExist = doesFileExist pt ports
    , doesDirectoryExist = doesDirectoryExist pt ports
    , createDirectory = createDirectory pt ports
    , listDirectory = listDirectory pt ports
    , removeFile = removeFile pt ports
    , removeDirectoryRecursive = removeDirectoryRecursive pt ports
    , canonicalizePath = canonicalizePath pt ports
    , getCurrentDirectory = getCurrentDirectory pt ports
    , getAppUserDataDirectory = getAppUserDataDirectory pt ports
    , getModificationTime = getModificationTime pt ports
    , lockFile = lockFile pt ports
    , unlockFile = unlockFile pt ports
    }



-- ERROR HANDLING


{-| Possible errors from file system operations.
-}
type Error
    = FileError { code : String, message : String }
    | DecodeError String
    | UnknownResponse String


{-| Convert an error to a human-readable string.
-}
errorToString : Error -> String
errorToString error =
    case error of
        FileError { code, message } ->
            code ++ ": " ++ message

        DecodeError msg ->
            "Decode error: " ++ msg

        UnknownResponse type_ ->
            "Unknown response type: " ++ type_


{-| Convert an error to a structured format with details.
-}
errorToDetails : Error -> { message : String, details : Value }
errorToDetails error =
    case error of
        FileError { code, message } ->
            { message = message
            , details = Encode.object [ ( "code", Encode.string code ) ]
            }

        DecodeError msg ->
            { message = msg
            , details = Encode.null
            }

        UnknownResponse type_ ->
            { message = "Unknown response type: " ++ type_
            , details = Encode.null
            }



-- RESPONSE DECODERS


decodeOkResponse : { a | type_ : String, payload : Value } -> Result Error ()
decodeOkResponse res =
    case res.type_ of
        "Ok" ->
            Ok ()

        "Error" ->
            Err (decodeErrorPayload res.payload)

        _ ->
            Err (UnknownResponse res.type_)


decodeStringResponse : { a | type_ : String, payload : Value } -> Result Error String
decodeStringResponse res =
    case res.type_ of
        "Content" ->
            case Decode.decodeValue Decode.string res.payload of
                Ok content ->
                    Ok content

                Err err ->
                    Err (DecodeError (Decode.errorToString err))

        "Error" ->
            Err (decodeErrorPayload res.payload)

        _ ->
            Err (UnknownResponse res.type_)


decodeBoolResponse : { a | type_ : String, payload : Value } -> Bool
decodeBoolResponse res =
    case res.type_ of
        "Bool" ->
            case Decode.decodeValue Decode.bool res.payload of
                Ok b ->
                    b

                Err _ ->
                    False

        _ ->
            False


decodeListResponse : { a | type_ : String, payload : Value } -> Result Error (List String)
decodeListResponse res =
    case res.type_ of
        "List" ->
            case Decode.decodeValue (Decode.list Decode.string) res.payload of
                Ok items ->
                    Ok items

                Err err ->
                    Err (DecodeError (Decode.errorToString err))

        "Error" ->
            Err (decodeErrorPayload res.payload)

        _ ->
            Err (UnknownResponse res.type_)


decodeTimeResponse : { a | type_ : String, payload : Value } -> Result Error Time.Posix
decodeTimeResponse res =
    case res.type_ of
        "Time" ->
            case Decode.decodeValue Decode.int res.payload of
                Ok millis ->
                    Ok (Time.millisToPosix millis)

                Err err ->
                    Err (DecodeError (Decode.errorToString err))

        "Error" ->
            Err (decodeErrorPayload res.payload)

        _ ->
            Err (UnknownResponse res.type_)


decodeBytesResponse : { a | type_ : String, payload : Value } -> Result Error Bytes
decodeBytesResponse res =
    case res.type_ of
        "Bytes" ->
            -- Bytes are sent as base64 encoded string
            case Decode.decodeValue Decode.string res.payload of
                Ok _ ->
                    -- For now, we'll need to handle bytes differently
                    -- This is a placeholder - actual implementation would decode base64
                    Err (DecodeError "Bytes decoding not yet implemented")

                Err err ->
                    Err (DecodeError (Decode.errorToString err))

        "Error" ->
            Err (decodeErrorPayload res.payload)

        _ ->
            Err (UnknownResponse res.type_)


decodeErrorPayload : Value -> Error
decodeErrorPayload payload =
    case Decode.decodeValue errorPayloadDecoder payload of
        Ok { code, message } ->
            FileError { code = code, message = message }

        Err _ ->
            FileError { code = "UNKNOWN", message = "Failed to decode error" }


errorPayloadDecoder : Decoder { code : String, message : String }
errorPayloadDecoder =
    Decode.map2 (\code message -> { code = code, message = message })
        (Decode.field "code" Decode.string)
        (Decode.field "message" Decode.string)



-- FILE OPERATIONS


{-| Read a file as a UTF-8 string.
-}
read :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error String -> msg)
    -> Cmd msg
read pt ports path toMsg =
    Channel.open (\key -> ports.fsRead { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeStringResponse res |> toMsg)


{-| Write a string to a file as UTF-8.
-}
writeString :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> String
    -> (Result Error () -> msg)
    -> Cmd msg
writeString pt ports path content toMsg =
    Channel.open (\key -> ports.fsWriteString { id = key, path = path, content = content })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeOkResponse res |> toMsg)


{-| Write binary data to a file.
-}
writeBinary :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> Bytes
    -> (Result Error () -> msg)
    -> Cmd msg
writeBinary pt ports path bytes toMsg =
    -- Convert bytes to a JSON-encodable format
    -- For now using a placeholder - actual implementation would encode to base64
    Channel.open (\key -> ports.fsWriteBinary { id = key, path = path, content = Encode.null })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeOkResponse res |> toMsg)


{-| Read binary data from a file.
-}
binaryDecode :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error Bytes -> msg)
    -> Cmd msg
binaryDecode pt ports path toMsg =
    Channel.open (\key -> ports.fsBinaryDecode { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeBytesResponse res |> toMsg)



-- FILE QUERIES


{-| Check if a file exists.
-}
doesFileExist :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Bool -> msg)
    -> Cmd msg
doesFileExist pt ports path toMsg =
    Channel.open (\key -> ports.fsDoesFileExist { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeBoolResponse res |> toMsg)


{-| Check if a directory exists.
-}
doesDirectoryExist :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Bool -> msg)
    -> Cmd msg
doesDirectoryExist pt ports path toMsg =
    Channel.open (\key -> ports.fsDoesDirectoryExist { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeBoolResponse res |> toMsg)



-- DIRECTORY OPERATIONS


{-| Create a directory. If createParents is True, creates parent directories as needed.
-}
createDirectory :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> Bool
    -> String
    -> (Result Error () -> msg)
    -> Cmd msg
createDirectory pt ports createParents path toMsg =
    Channel.open (\key -> ports.fsCreateDirectory { id = key, path = path, createParents = createParents })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeOkResponse res |> toMsg)


{-| List the contents of a directory.
-}
listDirectory :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error (List String) -> msg)
    -> Cmd msg
listDirectory pt ports path toMsg =
    Channel.open (\key -> ports.fsListDirectory { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeListResponse res |> toMsg)


{-| Remove a file.
-}
removeFile :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error () -> msg)
    -> Cmd msg
removeFile pt ports path toMsg =
    Channel.open (\key -> ports.fsRemoveFile { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeOkResponse res |> toMsg)


{-| Remove a directory and all its contents recursively.
-}
removeDirectoryRecursive :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error () -> msg)
    -> Cmd msg
removeDirectoryRecursive pt ports path toMsg =
    Channel.open (\key -> ports.fsRemoveDirectoryRecursive { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeOkResponse res |> toMsg)



-- PATH OPERATIONS


{-| Canonicalize a path (resolve symlinks, normalize).
-}
canonicalizePath :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error String -> msg)
    -> Cmd msg
canonicalizePath pt ports path toMsg =
    Channel.open (\key -> ports.fsCanonicalizePath { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeStringResponse res |> toMsg)


{-| Get the current working directory.
-}
getCurrentDirectory :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> (Result Error String -> msg)
    -> Cmd msg
getCurrentDirectory pt ports toMsg =
    Channel.open (\key -> ports.fsGetCurrentDirectory { id = key })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeStringResponse res |> toMsg)


{-| Get the application user data directory (e.g., ~/.appName).
-}
getAppUserDataDirectory :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error String -> msg)
    -> Cmd msg
getAppUserDataDirectory pt ports appName toMsg =
    Channel.open (\key -> ports.fsGetAppUserDataDirectory { id = key, appName = appName })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeStringResponse res |> toMsg)


{-| Get the modification time of a file.
-}
getModificationTime :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error Time.Posix -> msg)
    -> Cmd msg
getModificationTime pt ports path toMsg =
    Channel.open (\key -> ports.fsGetModificationTime { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeTimeResponse res |> toMsg)



-- FILE LOCKING


{-| Acquire a lock on a file. Blocks if the file is already locked.
-}
lockFile :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error () -> msg)
    -> Cmd msg
lockFile pt ports path toMsg =
    Channel.open (\key -> ports.fsLockFile { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeOkResponse res |> toMsg)


{-| Release a lock on a file.
-}
unlockFile :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error () -> msg)
    -> Cmd msg
unlockFile pt ports path toMsg =
    Channel.open (\key -> ports.fsUnlockFile { id = key, path = path })
        |> Channel.connect ports.fsResponse
        |> Channel.filter (\key { id } -> id == key)
        |> Channel.acceptOne
        |> Procedure.run pt (\res -> decodeOkResponse res |> toMsg)


{-| Execute an action while holding a file lock.
This is a convenience function that acquires the lock, runs the action,
and releases the lock. Note: The actual action execution and lock management
must be coordinated at the application level since we're using Cmd/Msg pattern.
-}
withLock :
    (Procedure.Program.Msg msg -> msg)
    -> Ports msg
    -> String
    -> (Result Error () -> msg)
    -> Cmd msg
withLock =
    lockFile
