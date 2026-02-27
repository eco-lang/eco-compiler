module Builder.File exposing
    ( Time(..), getTime, zeroTime, timeEncoder, timeDecoder
    , readBinary, writeBinary
    , readUtf8, writeUtf8, readStdin
    , writePackage
    , exists, remove
    )

{-| File system operations and utilities for the Elm compiler build system.

This module provides a high-level interface for file I/O operations used throughout
the build process, including binary and UTF-8 file reading/writing, modification time
tracking, and package extraction.


# File Modification Time

@docs Time, getTime, zeroTime, timeEncoder, timeDecoder


# Binary File Operations

@docs readBinary, writeBinary


# UTF-8 File Operations

@docs readUtf8, writeUtf8, readStdin


# Package Management

@docs writePackage


# File System Queries

@docs exists, remove

-}

import Bytes.Decode
import Bytes.Encode
import Codec.Archive.Zip as Zip
import Eco.Console
import Eco.File
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Time
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils



-- ====== TIME ======


{-| Represents a file modification time.
-}
type Time
    = Time Time.Posix


{-| Gets the modification time of a file.
-}
getTime : FilePath -> Task Never Time
getTime path =
    Task.map Time (Utils.dirGetModificationTime path)


{-| Returns a zero timestamp, used to indicate a file has never been modified.
-}
zeroTime : Time
zeroTime =
    Time (Time.millisToPosix 0)



-- ====== BINARY ======


{-| Writes binary data to a file, creating parent directories if needed.
-}
writeBinary : (a -> Bytes.Encode.Encoder) -> FilePath -> a -> Task Never ()
writeBinary toEncoder path value =
    let
        dir : FilePath
        dir =
            Utils.fpDropFileName path
    in
    Utils.dirCreateDirectoryIfMissing True dir
        |> Task.andThen (\_ -> Utils.binaryEncodeFile toEncoder path value)


{-| Reads binary data from a file, returning Nothing if the file doesn't exist or is corrupt.
-}
readBinary : Bytes.Decode.Decoder a -> FilePath -> Task Never (Maybe a)
readBinary decoder path =
    Utils.dirDoesFileExist path
        |> Task.andThen
            (\pathExists ->
                if pathExists then
                    Utils.binaryDecodeFileOrFail decoder path
                        |> Task.andThen
                            (\result ->
                                case result of
                                    Ok a ->
                                        Task.succeed (Just a)

                                    Err ( offset, message ) ->
                                        IO.hPutStrLn IO.stderr
                                            (Utils.unlines
                                                [ "+-------------------------------------------------------------------------------"
                                                , "|  Corrupt File: " ++ path
                                                , "|   Byte Offset: " ++ String.fromInt offset
                                                , "|       Message: " ++ message
                                                , "|"
                                                , "| Please report this to https://github.com/elm/compiler/issues"
                                                , "| Trying to continue anyway."
                                                , "+-------------------------------------------------------------------------------"
                                                ]
                                            )
                                            |> Task.map (\_ -> Nothing)
                            )

                else
                    Task.succeed Nothing
            )



-- ====== WRITE UTF-8 ======


{-| Writes a UTF-8 encoded string to a file.
-}
writeUtf8 : FilePath -> String -> Task Never ()
writeUtf8 =
    IO.writeString



-- ====== READ UTF-8 ======


{-| Reads a UTF-8 encoded file as a string.
-}
readUtf8 : FilePath -> Task Never String
readUtf8 path =
    Eco.File.readString path


{-| Reads all input from stdin as a string.
-}
readStdin : Task Never String
readStdin =
    Eco.Console.readAll



-- ====== WRITE PACKAGE ======


{-| Extracts a package archive to a destination directory, filtering for relevant files.
-}
writePackage : FilePath -> Zip.Archive -> Task Never ()
writePackage destination archive =
    case Zip.zEntries archive of
        [] ->
            Task.succeed ()

        entry :: entries ->
            let
                root : Int
                root =
                    String.length (Zip.eRelativePath entry)
            in
            Utils.mapM_ (writeEntry destination root) entries


writeEntry : FilePath -> Int -> Zip.Entry -> Task Never ()
writeEntry destination root entry =
    let
        path : String
        path =
            String.dropLeft root (Zip.eRelativePath entry)
    in
    if
        String.startsWith "src/" path
            || (path == "LICENSE")
            || (path == "README.md")
            || (path == "elm.json")
    then
        if not (String.isEmpty path) && String.endsWith "/" path then
            Utils.dirCreateDirectoryIfMissing True (Utils.fpCombine destination path)

        else
            writeUtf8 (Utils.fpCombine destination path) (Zip.fromEntry entry)

    else
        Task.succeed ()



-- ====== EXISTS ======


{-| Checks if a file exists at the given path.
-}
exists : FilePath -> Task Never Bool
exists path =
    Utils.dirDoesFileExist path



-- ====== REMOVE FILES ======


{-| Removes a file if it exists, silently succeeding if it doesn't.
-}
remove : FilePath -> Task Never ()
remove path =
    Utils.dirDoesFileExist path
        |> Task.andThen
            (\exists_ ->
                if exists_ then
                    Utils.dirRemoveFile path

                else
                    Task.succeed ()
            )



-- ====== ENCODERS and DECODERS ======


{-| Encodes a file modification time to bytes.
-}
timeEncoder : Time -> Bytes.Encode.Encoder
timeEncoder (Time posix) =
    BE.int (Time.posixToMillis posix)


{-| Decodes a file modification time from bytes.
-}
timeDecoder : Bytes.Decode.Decoder Time
timeDecoder =
    Bytes.Decode.map (Time.millisToPosix >> Time) BD.int
