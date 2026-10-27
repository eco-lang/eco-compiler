module Builder.File exposing
    ( Time(..), getTime, zeroTime, timeEncoder, timeDecoder
    , readBinary, writeBinary
    , readUtf8, writeUtf8
    , writePackage, copyPackageSource, fingerprintPackageSource
    , exists, remove
    , withStreamingWriter
    )

{-| The builder keeps caches on disk and decides what to rebuild by comparing
files, and this module is the small set of file operations it does that with.

Three facts shape the module. A cache file may be missing or damaged, and either
way the builder should rebuild rather than stop, so `readBinary` treats both as
absent. Every other read or write here is expected to succeed, and an IO error
crashes the program instead of being returned. And a package's source is text,
so it is copied as UTF-8 strings, and only the files a build needs are kept:
`src/`, `elm.json`, `LICENSE` and `README.md`.

A modification time (`Time`) is what staleness is judged by. It is stored in
cache files as a count of milliseconds since the epoch.


# File Modification Time

@docs Time, getTime, zeroTime, timeEncoder, timeDecoder


# Binary File Operations

@docs readBinary, writeBinary


# UTF-8 File Operations

@docs readUtf8, writeUtf8


# Package Management

@docs writePackage, copyPackageSource, fingerprintPackageSource


# File System Queries

@docs exists, remove


# Streaming Output

@docs withStreamingWriter

-}

import Bytes.Decode
import Bytes.Encode
import Codec.Archive.Zip as Zip
import Eco.File
import Eco.Hash
import System.IO as IO exposing (FilePath)
import Task exposing (Task)
import Time
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Main as Utils



-- ====== TIME ======


{-| The time a file was last modified, to the millisecond.
-}
type Time
    = Time Time.Posix


{-| Reads when the file at `path` was last modified. The program crashes if
that cannot be read, including when the file does not exist.
-}
getTime : FilePath -> Task Never Time
getTime path =
    Task.map Time (Utils.dirGetModificationTime path)


{-| The modification time at the epoch, 0 milliseconds. It stands in where
there is no file to take a time from.
-}
zeroTime : Time
zeroTime =
    Time (Time.millisToPosix 0)



-- ====== BINARY ======


{-| Writes `value` to `path` with the encoder `toEncoder` builds, creating the
parent directories first. The program crashes on an IO error.
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


{-| Reads and decodes the file at `path`, giving `Nothing` when there is no
file there, when it cannot be read, or when `decoder` fails on it.

In the last two cases a "Corrupt File" box naming the path and the error is
printed to stderr first. Its byte offset is always 0, because
`Utils.Main.binaryDecodeFileOrFail` reports no position. A caller cannot tell a
damaged file from a missing one.

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


{-| Writes `content` to `path` as UTF-8, creating the parent directories
first. The program crashes on an IO error.

Creating the parents means a caller need not, which matters for
`writePackage`: an archive can list a file before the entry for its directory.
A path with no directory part, such as a bare `hello.js`, has an empty parent,
and the file is written with no directory created.

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


{-| Reads the file at `path` as a UTF-8 string. The program crashes on an IO
error, including when the file does not exist.
-}
readUtf8 : FilePath -> Task Never String
readUtf8 path =
    Eco.File.readString path
        |> IO.crashOnError



-- ====== WRITE PACKAGE ======


{-| Unpacks a package archive into `destination`, keeping only `src/`,
`elm.json`, `LICENSE` and `README.md`.

The first entry of the archive is taken to be its root directory, and its path
is cut from the front of every other entry's path. The files are written as
UTF-8 text. An empty archive writes nothing.

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


{-| Writes one archive entry under `destination`, after cutting the first `root`
characters from its path, if what remains is one of the kept files or under
`src/`. A path ending in `/` is a directory and is created; anything else is
written as a file. Other entries are skipped.
-}
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


{-| Copies a package's source from the directory `source` into
`destination`, keeping the same files as `writePackage`: `elm.json`, `LICENSE`,
`README.md` and everything under `src/`. Nothing else is copied, so build
artifacts in `source` are left behind and the package is built afresh from the
copy. This lets a package whose source may be read-only, such as an installed
kernel, be built in a writable cache.

Any of the four that does not exist is skipped. Files are copied as UTF-8 text,
and the program crashes on an IO error.

-}
copyPackageSource : FilePath -> FilePath -> Task Never ()
copyPackageSource source destination =
    Utils.mapM_
        (\name ->
            copyPath (Utils.fpCombine source name) (Utils.fpCombine destination name)
        )
        [ "elm.json", "LICENSE", "README.md", "src" ]


{-| Computes a short string that changes when the package source in `source`
changes. It is built from the relative path, size and modification time of
`elm.json` and of every file under `src/`, sorted by path, and records how many
files there were and two hashes of that list. An edit that changes a file's size
or modification time, an addition, a removal or a rename changes it, barring a
hash collision. `LICENSE` and `README.md` are not part of it.

A missing `elm.json` or `src/` is skipped rather than reported, so a directory
with neither still gets a fingerprint.

The hashes are the narrow `Eco.Hash.stringWithSeed`, whose results the
`Eco.Hash` docstring says agree between the compiler's builds for strings with
no character above U+FFFF, so for such paths a fingerprint written by one build
matches the one another computes.

-}
fingerprintPackageSource : FilePath -> Task Never String
fingerprintPackageSource source =
    fingerprintPath source "elm.json" []
        |> Task.andThen (fingerprintPath source "src")
        |> Task.map
            (\entries ->
                let
                    rendered : String
                    rendered =
                        entries
                            |> List.sortBy (\( path, _, _ ) -> path)
                            |> List.map (\( path, size, mtime ) -> path ++ "\t" ++ String.fromInt size ++ "\t" ++ String.fromInt mtime ++ "\n")
                            |> String.concat
                in
                "v1:"
                    ++ String.fromInt (List.length entries)
                    ++ ":"
                    ++ String.fromInt (Eco.Hash.stringWithSeed 23 rendered)
                    ++ ":"
                    ++ String.fromInt (Eco.Hash.stringWithSeed 7919 rendered)
            )


{-| Adds the fingerprint entries of `relPath` (relative to `root`) to `acc`: one
entry of path, size in bytes and modification time in milliseconds for a file,
the entries of everything below it for a directory, and none when nothing is
there. Existence is checked first because reading the size or modification time
of a missing file crashes.
-}
fingerprintPath : FilePath -> FilePath -> List ( FilePath, Int, Int ) -> Task Never (List ( FilePath, Int, Int ))
fingerprintPath root relPath acc =
    let
        fullPath : FilePath
        fullPath =
            Utils.fpCombine root relPath
    in
    Utils.dirDoesDirectoryExist fullPath
        |> Task.andThen
            (\isDir ->
                if isDir then
                    Utils.dirListDirectory fullPath
                        |> Task.andThen
                            (List.foldl
                                (\name accTask ->
                                    accTask |> Task.andThen (fingerprintPath root (relPath ++ "/" ++ name))
                                )
                                (Task.succeed acc)
                            )

                else
                    Utils.dirDoesFileExist fullPath
                        |> Task.andThen
                            (\isFile ->
                                if isFile then
                                    Utils.dirGetFileSize fullPath
                                        |> Task.andThen
                                            (\size ->
                                                Utils.dirGetModificationTime fullPath
                                                    |> Task.map (\mtime -> ( relPath, size, Time.posixToMillis mtime ) :: acc)
                                            )

                                else
                                    Task.succeed acc
                            )
            )


{-| Copies the file or directory tree at `source` to `destination`, reading
and writing each file as UTF-8 text. Nothing is done when `source` does not
exist, so an optional entry such as `LICENSE` may be absent.
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


{-| Tells whether a file exists at `path`.
-}
exists : FilePath -> Task Never Bool
exists path =
    Utils.dirDoesFileExist path



-- ====== REMOVE FILES ======


{-| Removes the file at `path`, doing nothing when there is no file there.
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


{-| Opens `path` for writing, runs `callback` with a function that appends a
string to the file, closes the file, and gives the callback's result.

The program crashes on an IO error, and a crash inside `callback` leaves the
file unclosed.

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


{-| Encodes a modification time as its count of milliseconds since the epoch.
-}
timeEncoder : Time -> Bytes.Encode.Encoder
timeEncoder (Time posix) =
    BE.int (Time.posixToMillis posix)


{-| A decoder for a modification time written by `timeEncoder`.
-}
timeDecoder : Bytes.Decode.Decoder Time
timeDecoder =
    Bytes.Decode.map (Time.millisToPosix >> Time) BD.int
