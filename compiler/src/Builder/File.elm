module Builder.File exposing
    ( Time(..), getTime, zeroTime, timeEncoder, timeDecoder
    , readBinary, writeBinary
    , readUtf8, writeUtf8
    , writePackage, copyPackageSource
    , exists, remove
    , withStreamingWriter
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

@docs readUtf8, writeUtf8


# Package Management

@docs writePackage, copyPackageSource


# File System Queries

@docs exists, remove


# Streaming Output

@docs withStreamingWriter

-}

import Bytes.Decode
import Bytes.Encode
import Codec.Archive.Zip as Zip
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
                                        IO.writeLn IO.stderr
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


{-| Writes a UTF-8 encoded string to a file, creating parent directories
if needed. Mirrors `writeBinary`'s parent-dir creation so callers don't have
to pre-create the destination directory (in particular `writePackage`, where
the per-entry iteration order can put a file write ahead of its containing
directory entry).

For a path with no directory component (e.g. a bare "hello.js"),
`fpDropFileName` returns the empty string; skip the mkdir in that case so
the kernel doesn't see `mkdir("")` and reject it with EINVAL.

-}
writeUtf8 : FilePath -> String -> Task Never ()
writeUtf8 path content =
    let
        dir : FilePath
        dir =
            Utils.fpDropFileName path

        write : Task Never ()
        write =
            IO.writeString path content |> IO.crashOnError
    in
    if String.isEmpty dir then
        write

    else
        Utils.dirCreateDirectoryIfMissing True dir
            |> Task.andThen (\_ -> write)



-- ====== READ UTF-8 ======


{-| Reads a UTF-8 encoded file as a string.
-}
readUtf8 : FilePath -> Task Never String
readUtf8 path =
    Eco.File.readString path
        |> IO.crashOnError



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



-- ====== COPY PACKAGE SOURCE ======


{-| Copies a package's source from a read-only seed directory into a writable
cache directory. Mirrors the `writePackage` whitelist (`src/`, `elm.json`,
`LICENSE`, `README.md`); pre-built `.dat` artifacts and `docs.json` are
deliberately not copied so the package is rebuilt in the cache. Used to seed a
`--local-package` whose source path may be read-only (e.g. an installed kernel).
-}
copyPackageSource : FilePath -> FilePath -> Task Never ()
copyPackageSource source destination =
    Utils.mapM_
        (\name ->
            copyPath (Utils.fpCombine source name) (Utils.fpCombine destination name)
        )
        [ "elm.json", "LICENSE", "README.md", "src" ]


{-| Recursively copies a file or directory tree. Paths that do not exist are
skipped, so optional top-level entries (e.g. `LICENSE`) may be absent.
-}
copyPath : FilePath -> FilePath -> Task Never ()
copyPath source destination =
    Utils.dirDoesDirectoryExist source
        |> Task.andThen
            (\isDir ->
                if isDir then
                    Utils.dirCreateDirectoryIfMissing True destination
                        |> Task.andThen (\_ -> Utils.dirListDirectory source)
                        |> Task.andThen
                            (Utils.mapM_
                                (\name ->
                                    copyPath (Utils.fpCombine source name) (Utils.fpCombine destination name)
                                )
                            )

                else
                    Utils.dirDoesFileExist source
                        |> Task.andThen
                            (\isFile ->
                                if isFile then
                                    readUtf8 source
                                        |> Task.andThen (writeUtf8 destination)

                                else
                                    Task.succeed ()
                            )
            )



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



-- ====== STREAMING ======


{-| Opens a file for writing, passes a write-chunk function to the callback,
and ensures the handle is closed after.
-}
withStreamingWriter :
    FilePath
    -> ((String -> Task Never ()) -> Task Never a)
    -> Task Never a
withStreamingWriter path callback =
    (Eco.File.open path Eco.File.WriteMode |> IO.crashOnError)
        |> Task.andThen
            (\handle ->
                callback (\chunk -> Eco.File.hWriteString handle chunk |> IO.crashOnError)
                    |> Task.andThen
                        (\result ->
                            (Eco.File.close handle |> IO.crashOnError)
                                |> Task.map (\_ -> result)
                        )
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
