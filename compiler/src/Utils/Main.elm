module Utils.Main exposing
    ( fpCombine, fpAddExtension, fpDropExtension, fpDropFileName, fpSplitExtension
    , fpSplitFileName, fpSplitDirectories, fpJoinPath, fpMakeRelative, fpAddTrailingPathSeparator
    , fpPathSeparator, fpIsRelative, fpTakeFileName, fpTakeExtension, fpTakeDirectory
    , dirDoesFileExist, dirDoesDirectoryExist, dirFindExecutable, dirCreateDirectoryIfMissing
    , dirGetCurrentDirectory, dirGetAppUserDataDirectory, dirGetModificationTime, dirListDirectory
    , dirRemoveFile, dirCanonicalizePath, dirWithCurrentDirectory
    , envLookupEnv, envGetProgName, envGetArgs
    , lockWithFileLock
    , binaryDecodeFileOrFail, binaryEncodeFile, builderHPutBuilder
    , HttpExceptionContent(..), HttpResponse(..), HttpResponseHeaders, HttpStatus(..)
    , httpResponseStatus, httpResponseHeaders, httpHLocation
    , httpExceptionContentEncoder, httpExceptionContentDecoder
    , SomeException(..)
    , someExceptionEncoder, someExceptionDecoder
    , ThreadId, forkIO
    , newMVar, newEmptyMVar, readMVar, takeMVar, putMVar
    , mVarEncoder, mVarDecoder
    , Chan, newChan, readChan, writeChan
    , ReplInputT
    , replRunInputT, replWithInterrupt, replGetInputLine
    , replGetInputLineWithInitial, liftInputT, liftIOInputT
    , nodeGetDirname, nodeMathRandom
    , mapFromListWith, mapFromKeys, mapInsertWith, mapIntersectionWith, mapIntersectionWithKey
    , mapUnionWith, mapUnions, mapUnionsWith, mapLookupMin, mapFindMin, mapMinViewWithKey
    , mapMapKeys, mapMapMaybe, find, findMax, keysSet
    , mapTraverse, mapTraverseWithKey, mapTraverseResult, mapTraverseWithKeyResult, dictMapM_
    , eitherLefts, filterM, listGroupBy, listLookup, listMaximum, foldl1_, foldr1
    , listTraverse, listTraverse_, lines, unlines, zipWithM, mapM_
    , maybeEncoder, maybeMapM, maybeTraverseTask
    , nonEmptyListTraverse
    , sequenceADict, sequenceDictMaybe, sequenceDictResult, sequenceDictResult_
    , sequenceListMaybe, sequenceNonemptyListResult
    , foldM
    )

{-| Utility module providing data structure utilities, HTTP types, and pure helper functions.

IO-related types (FilePath, MVar, ChItem, Stream, ReplSettings, LockSharedExclusive) are
defined in System.IO.


# File Path Operations

@docs fpCombine, fpAddExtension, fpDropExtension, fpDropFileName, fpSplitExtension
@docs fpSplitFileName, fpSplitDirectories, fpJoinPath, fpMakeRelative, fpAddTrailingPathSeparator
@docs fpPathSeparator, fpIsRelative, fpTakeFileName, fpTakeExtension, fpTakeDirectory


# Directory Operations

@docs dirDoesFileExist, dirDoesDirectoryExist, dirFindExecutable, dirCreateDirectoryIfMissing
@docs dirGetCurrentDirectory, dirGetAppUserDataDirectory, dirGetModificationTime, dirListDirectory
@docs dirRemoveFile, dirCanonicalizePath, dirWithCurrentDirectory


# Environment Operations

@docs envLookupEnv, envGetProgName, envGetArgs


# File Locking

@docs lockWithFileLock


# Binary Serialization

@docs binaryDecodeFileOrFail, binaryEncodeFile, builderHPutBuilder


# HTTP Types and Operations

@docs HttpExceptionContent, HttpResponse, HttpResponseHeaders, HttpStatus
@docs httpResponseStatus, httpResponseHeaders, httpHLocation
@docs httpExceptionContentEncoder, httpExceptionContentDecoder


# Exception Types

@docs SomeException
@docs someExceptionEncoder, someExceptionDecoder


# Concurrency Primitives

@docs ThreadId, forkIO


# MVar Operations

@docs newMVar, newEmptyMVar, readMVar, takeMVar, putMVar
@docs mVarEncoder, mVarDecoder


# Channel Operations

@docs Chan, newChan, readChan, writeChan


# REPL Support

@docs ReplInputT
@docs replRunInputT, replWithInterrupt, replGetInputLine
@docs replGetInputLineWithInitial, liftInputT, liftIOInputT


# Node.js Integration

@docs nodeGetDirname, nodeMathRandom


# Dictionary Utilities

@docs mapFromListWith, mapFromKeys, mapInsertWith, mapIntersectionWith, mapIntersectionWithKey
@docs mapUnionWith, mapUnions, mapUnionsWith, mapLookupMin, mapFindMin, mapMinViewWithKey
@docs mapMapKeys, mapMapMaybe, find, findMax, keysSet


# Dictionary Traversal

@docs mapTraverse, mapTraverseWithKey, mapTraverseResult, mapTraverseWithKeyResult, dictMapM_


# List Utilities

@docs eitherLefts, filterM, listGroupBy, listLookup, listMaximum, foldl1_, foldr1
@docs listTraverse, listTraverse_, lines, unlines, zipWithM, mapM_


# Maybe Utilities

@docs maybeEncoder, maybeMapM, maybeTraverseTask


# NonEmptyList Traversal

@docs nonEmptyListTraverse


# Sequence Operations

@docs sequenceADict, sequenceDictMaybe, sequenceDictResult, sequenceDictResult_
@docs sequenceListMaybe, sequenceNonemptyListResult


# Indexed Operations

@docs foldM

-}

import Basics.Extra exposing (flip)
import Bytes.Decode
import Bytes.Encode
import Compiler.Data.NonEmptyList as NE
import Compiler.Reporting.Result as ReportingResult
import Control.Monad.State.Strict as State
import Data.Map as Map exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Eco.Console
import Eco.Env
import Eco.File
import Eco.MVar
import Eco.Runtime
import Maybe.Extra as Maybe
import Prelude
import Process
import System.Exit as Exit
import System.IO as IO exposing (ChItem(..), FilePath, LockSharedExclusive(..), MVar(..), ReplSettings, Stream)
import Task exposing (Task)
import Time
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import Utils.Task.Extra as Task


{-| Lift a Task into the REPL input monad (no-op in this implementation).
-}
liftInputT : Task Never () -> ReplInputT ()
liftInputT =
    identity


{-| Lift an IO Task into the REPL input monad (no-op in this implementation).
-}
liftIOInputT : Task Never a -> ReplInputT a
liftIOInputT =
    identity


{-| Remove the file name component from a file path, leaving only the directory path.
-}
fpDropFileName : FilePath -> FilePath
fpDropFileName path =
    case List.reverse (String.split "/" path) of
        _ :: tail ->
            List.reverse ("" :: tail)
                |> String.join "/"

        [] ->
            ""


{-| An alias for `</>`.

Combine two paths with a path separator. If the second path starts with a
path separator or a drive letter, then it returns the second.
The intention is that readFile `(dir </> file)` will access the same file
as `setCurrentDirectory dir; readFile file`.

-}
fpCombine : FilePath -> FilePath -> FilePath
fpCombine path1 path2 =
    if String.startsWith "/" path2 || String.startsWith path1 path2 then
        path2

    else
        path1 ++ "/" ++ path2


{-| Add a file extension to a path. Automatically adds a dot if not present in the extension.
-}
fpAddExtension : FilePath -> String -> FilePath
fpAddExtension path extension =
    if String.startsWith "." extension then
        path ++ extension

    else
        path ++ "." ++ extension


{-| Build a dictionary from a list of key-value pairs, combining values with the same key using the provided function.
-}
mapFromListWith : (k -> comparable) -> (a -> a -> a) -> List ( k, a ) -> Dict comparable k a
mapFromListWith toComparable f =
    List.foldl
        (\( k, a ) ->
            Map.update toComparable k (Maybe.map (flip f a))
        )
        Map.empty


{-| Encode a Maybe value to bytes using the provided encoder for the inner value.
-}
maybeEncoder : (a -> Bytes.Encode.Encoder) -> Maybe a -> Bytes.Encode.Encoder
maybeEncoder =
    BE.maybe


{-| Extract all error values from a list of Results, discarding the Ok values.
-}
eitherLefts : List (Result e a) -> List e
eitherLefts =
    List.filterMap
        (\res ->
            case res of
                Ok _ ->
                    Nothing

                Err e ->
                    Just e
        )


{-| Build a dictionary from a list of keys by applying a function to each key to produce its value.
-}
mapFromKeys : (k -> comparable) -> (k -> v) -> List k -> Dict comparable k v
mapFromKeys toComparable f =
    List.map (\k -> ( k, f k ))
        >> Map.fromList toComparable


{-| Filter a list using a monadic predicate, preserving elements where the predicate returns True.
-}
filterM : (a -> Task Never Bool) -> List a -> Task Never (List a)
filterM p =
    List.foldr
        (\x acc ->
            Task.apply acc
                (Task.map
                    (\flg ->
                        if flg then
                            (::) x

                        else
                            identity
                    )
                    (p x)
                )
        )
        (Task.succeed [])


{-| Find a value by key in a dictionary, crashing if the key is not present. Use with caution.
-}
find : (k -> comparable) -> k -> Dict comparable k a -> a
find toComparable k items =
    case Map.get toComparable k items of
        Just item ->
            item

        Nothing ->
            crash "Map.!: given key is not an element in the map"


{-| Find the maximum key-value pair in a dictionary, crashing if the dictionary is empty.
-}
findMax : (k -> k -> Order) -> Dict comparable k a -> ( k, a )
findMax keyComparison items =
    case List.reverse (Map.toList keyComparison items) of
        item :: _ ->
            item

        _ ->
            crash "Error: empty map has no maximal element"


{-| Find the minimum key-value pair in a dictionary, returning Nothing if the dictionary is empty.
-}
mapLookupMin : Dict comparable comparable a -> Maybe ( comparable, a )
mapLookupMin dict =
    case Map.toList compare dict |> List.sortBy Tuple.first of
        firstElem :: _ ->
            Just firstElem

        _ ->
            Nothing


{-| Find the minimum key-value pair in a dictionary, crashing if the dictionary is empty.
-}
mapFindMin : Dict comparable comparable a -> ( comparable, a )
mapFindMin dict =
    case Map.toList compare dict |> List.sortBy Tuple.first of
        firstElem :: _ ->
            firstElem

        _ ->
            crash "Error: empty map has no minimal element"


{-| Insert a key-value pair into a dictionary, combining with existing value using the provided function if the key already exists.
-}
mapInsertWith : (k -> comparable) -> (a -> a -> a) -> k -> a -> Dict comparable k a -> Dict comparable k a
mapInsertWith toComparable f k a =
    Map.update toComparable k (Maybe.map (f a) >> Maybe.withDefault a >> Just)


{-| Compute the intersection of two dictionaries, combining values from both using the provided function.
-}
mapIntersectionWith : (k -> comparable) -> (k -> k -> Order) -> (a -> b -> c) -> Dict comparable k a -> Dict comparable k b -> Dict comparable k c
mapIntersectionWith toComparable keyComparison func =
    mapIntersectionWithKey toComparable keyComparison (\_ -> func)


{-| Compute the intersection of two dictionaries, combining values using a function that has access to the key.
-}
mapIntersectionWithKey : (k -> comparable) -> (k -> k -> Order) -> (k -> a -> b -> c) -> Dict comparable k a -> Dict comparable k b -> Dict comparable k c
mapIntersectionWithKey toComparable keyComparison func dict1 dict2 =
    Map.merge keyComparison (\_ _ -> identity) (\k v1 v2 -> Map.insert toComparable k (func k v1 v2)) (\_ _ -> identity) dict1 dict2 Map.empty


{-| Compute the union of two dictionaries, combining values with the same key using the provided function.
-}
mapUnionWith : (k -> comparable) -> (k -> k -> Order) -> (a -> a -> a) -> Dict comparable k a -> Dict comparable k a -> Dict comparable k a
mapUnionWith toComparable keyComparison f a b =
    Map.merge keyComparison (Map.insert toComparable) (\k va vb -> Map.insert toComparable k (f va vb)) (Map.insert toComparable) a b Map.empty


{-| Compute the union of multiple dictionaries, combining values with the same key using the provided function.
-}
mapUnionsWith : (k -> comparable) -> (k -> k -> Order) -> (a -> a -> a) -> List (Dict comparable k a) -> Dict comparable k a
mapUnionsWith toComparable keyComparison f =
    List.foldl (mapUnionWith toComparable keyComparison f) Map.empty


{-| Compute the union of multiple dictionaries, preferring values from later dictionaries for duplicate keys.
-}
mapUnions : List (Dict comparable k a) -> Dict comparable k a
mapUnions =
    List.foldr Map.union Map.empty


{-| Fold a list from the left using a monadic function, accumulating results in the RResult monad.
-}
foldM : (b -> a -> ReportingResult.RResult info warnings error b) -> b -> List a -> ReportingResult.RResult info warnings error b
foldM f b =
    List.foldl (\a -> ReportingResult.andThen (\acc -> f acc a)) (ReportingResult.ok b)


{-| Sequence a dictionary of RResults into an RResult of a dictionary, collecting all errors and warnings.
-}
sequenceADict : (k -> comparable) -> (k -> k -> Order) -> Dict comparable k (ReportingResult.RResult i w e v) -> ReportingResult.RResult i w e (Dict comparable k v)
sequenceADict toComparable keyComparison =
    Map.foldr keyComparison (\k x acc -> ReportingResult.apply acc (ReportingResult.map (Map.insert toComparable k) x)) (ReportingResult.ok Map.empty)


{-| Sequence a dictionary of Maybes into a Maybe dictionary, returning Nothing if any value is Nothing.
-}
sequenceDictMaybe : (k -> comparable) -> (k -> k -> Order) -> Dict comparable k (Maybe a) -> Maybe (Dict comparable k a)
sequenceDictMaybe toComparable keyComparison =
    Map.foldr keyComparison (\k -> Maybe.map2 (Map.insert toComparable k)) (Just Map.empty)


{-| Sequence a dictionary of Results into a Result of a dictionary, failing at the first error.
-}
sequenceDictResult : (k -> comparable) -> (k -> k -> Order) -> Dict comparable k (Result e v) -> Result e (Dict comparable k v)
sequenceDictResult toComparable keyComparison =
    Map.foldr keyComparison (\k -> Result.map2 (Map.insert toComparable k)) (Ok Map.empty)


{-| Sequence a dictionary of Results, discarding the values and returning () on success.
-}
sequenceDictResult_ : (k -> comparable) -> (k -> k -> Order) -> Dict comparable k (Result e a) -> Result e ()
sequenceDictResult_ toComparable keyComparison =
    sequenceDictResult toComparable keyComparison >> Result.map (\_ -> ())


{-| Sequence a list of Maybes into a Maybe list, returning Nothing if any value is Nothing.
-}
sequenceListMaybe : List (Maybe a) -> Maybe (List a)
sequenceListMaybe =
    List.foldr (Maybe.map2 (::)) (Just [])


{-| Sequence a non-empty list of Results into a Result of a non-empty list, failing at the first error.
-}
sequenceNonemptyListResult : NE.Nonempty (Result e v) -> Result e (NE.Nonempty v)
sequenceNonemptyListResult (NE.Nonempty x xs) =
    List.foldl (\a acc -> Result.map2 NE.snoc a acc) (Result.map NE.singleton x) xs


{-| Extract all keys from a dictionary as a set.
-}
keysSet : (k -> comparable) -> (k -> k -> Order) -> Dict comparable k a -> EverySet comparable k
keysSet toComparable keyComparison =
    Map.keys keyComparison >> EverySet.fromList toComparable


{-| Map a monadic function over a list, discarding the results and returning ().
-}
mapM_ : (a -> Task Never b) -> List a -> Task Never ()
mapM_ f =
    let
        c : a -> Task Never () -> Task Never ()
        c x k =
            f x |> Task.andThen (\_ -> k)
    in
    List.foldr c (Task.succeed ())


{-| Map a monadic function over dictionary values, discarding the results and returning ().
-}
dictMapM_ : (k -> k -> Order) -> (a -> Task Never b) -> Dict c k a -> Task Never ()
dictMapM_ keyComparison f =
    let
        c : k -> a -> Task Never () -> Task Never ()
        c _ x k =
            f x |> Task.andThen (\_ -> k)
    in
    Map.foldl keyComparison c (Task.succeed ())


{-| Map a Maybe-producing function over a list, returning Nothing if any application returns Nothing.
-}
maybeMapM : (a -> Maybe b) -> List a -> Maybe (List b)
maybeMapM =
    listMaybeTraverse


{-| Transform all keys in a dictionary using the provided function.
-}
mapMapKeys : (k2 -> comparable) -> (k1 -> k1 -> Order) -> (k1 -> k2) -> Dict comparable k1 a -> Dict comparable k2 a
mapMapKeys toComparable keyComparison f =
    Map.foldl keyComparison (\k x xs -> ( f k, x ) :: xs) [] >> Map.fromList toComparable


{-| Extract the minimum key-value pair from a dictionary, returning it along with the remaining dictionary.
-}
mapMinViewWithKey : (k -> comparable) -> (k -> k -> Order) -> (( k, a ) -> comparable) -> Dict comparable k a -> Maybe ( ( k, a ), Dict comparable k a )
mapMinViewWithKey toComparable keyComparison compare dict =
    case Map.toList keyComparison dict |> List.sortBy compare of
        first :: tail ->
            Just ( first, Map.fromList toComparable tail )

        _ ->
            Nothing


{-| Map a Maybe-producing function over dictionary values, keeping only the Just results.
-}
mapMapMaybe : (k -> comparable) -> (k -> k -> Order) -> (a -> Maybe b) -> Dict comparable k a -> Dict comparable k b
mapMapMaybe toComparable keyComparison func =
    Map.toList keyComparison
        >> List.filterMap (\( k, a ) -> Maybe.map (Tuple.pair k) (func a))
        >> Map.fromList toComparable


{-| Traverse a dictionary with a Task-producing function, collecting results into a new dictionary.
-}
mapTraverse : (k -> comparable) -> (k -> k -> Order) -> (a -> Task Never b) -> Dict comparable k a -> Task Never (Dict comparable k b)
mapTraverse toComparable keyComparison f =
    mapTraverseWithKey toComparable keyComparison (\_ -> f)


{-| Traverse a dictionary with a Task-producing function that has access to the key.
-}
mapTraverseWithKey : (k -> comparable) -> (k -> k -> Order) -> (k -> a -> Task Never b) -> Dict comparable k a -> Task Never (Dict comparable k b)
mapTraverseWithKey toComparable keyComparison f =
    Map.foldl keyComparison
        (\k a -> Task.andThen (\c -> Task.map (\va -> Map.insert toComparable k va c) (f k a)))
        (Task.succeed Map.empty)


{-| Traverse a dictionary with a Result-producing function, failing at the first error.
-}
mapTraverseResult : (k -> comparable) -> (k -> k -> Order) -> (a -> Result e b) -> Dict comparable k a -> Result e (Dict comparable k b)
mapTraverseResult toComparable keyComparison f =
    mapTraverseWithKeyResult toComparable keyComparison (\_ -> f)


{-| Traverse a dictionary with a Result-producing function that has access to the key.
-}
mapTraverseWithKeyResult : (k -> comparable) -> (k -> k -> Order) -> (k -> a -> Result e b) -> Dict comparable k a -> Result e (Dict comparable k b)
mapTraverseWithKeyResult toComparable keyComparison f =
    Map.foldl keyComparison
        (\k a -> Result.map2 (Map.insert toComparable k) (f k a))
        (Ok Map.empty)


{-| Traverse a list with a Task-producing function, collecting results into a new list.
-}
listTraverse : (a -> Task Never b) -> List a -> Task Never (List b)
listTraverse =
    Task.mapM


{-| Traverse a list with a Maybe-producing function, returning Nothing if any application returns Nothing.
-}
listMaybeTraverse : (a -> Maybe b) -> List a -> Maybe (List b)
listMaybeTraverse f =
    List.foldr (\a -> Maybe.andThen (\c -> Maybe.map (\va -> va :: c) (f a)))
        (Just [])


{-| Traverse a non-empty list with a Task-producing function, preserving the non-empty structure.
-}
nonEmptyListTraverse : (a -> Task Never b) -> NE.Nonempty a -> Task Never (NE.Nonempty b)
nonEmptyListTraverse f (NE.Nonempty x list) =
    List.foldl (\a -> Task.andThen (\c -> Task.map (\va -> NE.snoc va c) (f a)))
        (Task.map NE.singleton (f x))
        list


{-| Traverse a list with a Task-producing function, discarding the results and returning ().
-}
listTraverse_ : (a -> Task Never b) -> List a -> Task Never ()
listTraverse_ f =
    listTraverse f
        >> Task.map (\_ -> ())


{-| Traverse a Maybe value with a Task-producing function, preserving the Maybe structure.
-}
maybeTraverseTask : (a -> Task x b) -> Maybe a -> Task x (Maybe b)
maybeTraverseTask f a =
    case Maybe.map f a of
        Just b ->
            Task.map Just b

        Nothing ->
            Task.succeed Nothing


{-| Zip two lists with a Maybe-producing function, returning Nothing if any application returns Nothing.
-}
zipWithM : (a -> b -> Maybe c) -> List a -> List b -> Maybe (List c)
zipWithM f xs ys =
    List.map2 f xs ys
        |> Maybe.combine


{-| Group consecutive elements in a list that satisfy the binary predicate.
-}
listGroupBy : (a -> a -> Bool) -> List a -> List (List a)
listGroupBy p list =
    case list of
        [] ->
            []

        x :: xs ->
            xs
                |> List.foldl
                    (\current ( previous, ys, acc ) ->
                        if p previous current then
                            ( current, current :: ys, acc )

                        else
                            ( current, [ current ], ys :: acc )
                    )
                    ( x, [ x ], [] )
                |> (\( _, ys, acc ) ->
                        ys :: acc
                   )
                |> List.map List.reverse
                |> List.reverse


{-| Find the maximum element in a list using the provided comparison function, crashing if the list is empty.
-}
listMaximum : (a -> a -> Order) -> List a -> a
listMaximum compare xs =
    case List.sortWith (flip compare) xs of
        x :: _ ->
            x

        [] ->
            crash "maximum: empty structure"


{-| Look up a key in an association list, returning the first matching value.
-}
listLookup : a -> List ( a, b ) -> Maybe b
listLookup key list =
    case list of
        [] ->
            Nothing

        ( x, y ) :: xys ->
            if key == x then
                Just y

            else
                listLookup key xys


{-| Fold a non-empty list from the left, using the first element as the initial accumulator. Crashes if the list is empty.
-}
foldl1 : (a -> a -> a) -> List a -> a
foldl1 f xs =
    let
        mf : a -> Maybe a -> Maybe a
        mf x m =
            Just
                (case m of
                    Nothing ->
                        x

                    Just y ->
                        f x y
                )
    in
    case List.foldl mf Nothing xs of
        Just a ->
            a

        Nothing ->
            crash "foldl1: empty structure"


{-| Fold a non-empty list from the left with argument order flipped. Crashes if the list is empty.
-}
foldl1_ : (a -> a -> a) -> List a -> a
foldl1_ f =
    foldl1 (\a b -> f b a)


{-| Fold a non-empty list from the right, using the last element as the initial accumulator. Crashes if the list is empty.
-}
foldr1 : (a -> a -> a) -> List a -> a
foldr1 f xs =
    let
        mf : a -> Maybe a -> Maybe a
        mf x m =
            Just
                (case m of
                    Nothing ->
                        x

                    Just y ->
                        f x y
                )
    in
    case List.foldr mf Nothing xs of
        Just a ->
            a

        Nothing ->
            crash "foldr1: empty structure"


{-| Split a string into lines at newline characters.
-}
lines : String -> List String
lines =
    String.split "\n"


{-| Join a list of strings with newlines, adding a final newline at the end.
-}
unlines : List String -> String
unlines xs =
    String.join "\n" xs ++ "\n"



-- System.FilePath


{-| Split a file path into its directory components.
-}
fpSplitDirectories : String -> List String
fpSplitDirectories path =
    String.split "/" path
        |> List.filter ((/=) "")
        |> (\a ->
                (if String.startsWith "/" path then
                    [ "/" ]

                 else
                    []
                )
                    ++ a
           )


{-| Split a file path into the base name and extension (including the dot).
-}
fpSplitExtension : String -> ( String, String )
fpSplitExtension filename =
    case List.reverse (String.split "/" filename) of
        lastPart :: otherParts ->
            case List.reverse (String.indexes "." lastPart) of
                index :: _ ->
                    ( (String.left index lastPart :: otherParts)
                        |> List.reverse
                        |> String.join "/"
                    , String.dropLeft index lastPart
                    )

                [] ->
                    ( filename, "" )

        [] ->
            ( "", "" )


{-| Join a list of path components into a single path, handling leading slashes.
-}
fpJoinPath : List String -> String
fpJoinPath paths =
    case paths of
        "/" :: tail ->
            "/" ++ String.join "/" tail

        _ ->
            String.join "/" paths


{-| Make a path relative to a root directory by removing the root prefix if present.
-}
fpMakeRelative : FilePath -> FilePath -> FilePath
fpMakeRelative root path =
    if String.startsWith root path then
        String.dropLeft (String.length root + 1) path

    else
        path


{-| Ensure a path ends with a trailing path separator.
-}
fpAddTrailingPathSeparator : FilePath -> FilePath
fpAddTrailingPathSeparator path =
    if String.endsWith "/" path then
        path

    else
        path ++ "/"


{-| The path separator character used by the file system (forward slash on Unix-like systems).
-}
fpPathSeparator : Char
fpPathSeparator =
    '/'


{-| Check if a path is relative (does not start with a slash).
-}
fpIsRelative : FilePath -> Bool
fpIsRelative =
    String.startsWith "/" >> not


{-| Extract just the file name from a path (everything after the last slash).
-}
fpTakeFileName : FilePath -> FilePath
fpTakeFileName filename =
    Prelude.last (String.split "/" filename)


{-| Split a path into the directory part and the file name part.
-}
fpSplitFileName : FilePath -> ( String, String )
fpSplitFileName filename =
    case List.reverse (String.indexes "/" filename) of
        index :: _ ->
            ( String.left (index + 1) filename, String.dropLeft (index + 1) filename )

        _ ->
            ( "./", filename )


{-| Extract just the extension from a path (including the dot).
-}
fpTakeExtension : FilePath -> String
fpTakeExtension =
    fpSplitExtension >> Tuple.second


{-| Remove the extension from a path.
-}
fpDropExtension : FilePath -> FilePath
fpDropExtension =
    fpSplitExtension >> Tuple.first


{-| Extract the directory part of a path (everything before the last slash).
-}
fpTakeDirectory : FilePath -> FilePath
fpTakeDirectory filename =
    case List.reverse (String.split "/" filename) of
        [] ->
            "."

        "" :: "" :: [] ->
            "/"

        "" :: _ :: other ->
            String.join "/" (List.reverse other)

        _ :: other ->
            String.join "/" (List.reverse other)



-- System.FileLock


{-| Execute an action while holding an exclusive file lock, releasing the lock when done.
-}
lockWithFileLock : String -> LockSharedExclusive -> (() -> Task Never a) -> Task Never a
lockWithFileLock path mode ioFunc =
    case mode of
        LockExclusive ->
            lockFile path
                |> Task.andThen ioFunc
                |> Task.andThen
                    (\a ->
                        unlockFile path
                            |> Task.map (\_ -> a)
                    )


lockFile : FilePath -> Task Never ()
lockFile path =
    Eco.File.lock path


unlockFile : FilePath -> Task Never ()
unlockFile path =
    Eco.File.unlock path



-- System.Directory


{-| Check if a file exists at the given path.
-}
dirDoesFileExist : FilePath -> Task Never Bool
dirDoesFileExist filename =
    Eco.File.fileExists filename


{-| Search for an executable in the system PATH, returning its full path if found.
-}
dirFindExecutable : FilePath -> Task Never (Maybe FilePath)
dirFindExecutable filename =
    Eco.File.findExecutable filename


{-| Create a directory if it doesn't exist, optionally creating parent directories.
-}
dirCreateDirectoryIfMissing : Bool -> FilePath -> Task Never ()
dirCreateDirectoryIfMissing createParents filename =
    Eco.File.createDir createParents filename


{-| Get the current working directory.
-}
dirGetCurrentDirectory : Task Never String
dirGetCurrentDirectory =
    Eco.File.getCwd


{-| Get the application-specific user data directory for the given application name.
-}
dirGetAppUserDataDirectory : FilePath -> Task Never FilePath
dirGetAppUserDataDirectory filename =
    Eco.File.appDataDir filename


{-| Get the last modification time of a file or directory.
-}
dirGetModificationTime : FilePath -> Task Never Time.Posix
dirGetModificationTime filename =
    Eco.File.modificationTime filename


{-| Remove a file at the given path.
-}
dirRemoveFile : FilePath -> Task Never ()
dirRemoveFile path =
    Eco.File.removeFile path


{-| Check if a directory exists at the given path.
-}
dirDoesDirectoryExist : FilePath -> Task Never Bool
dirDoesDirectoryExist path =
    Eco.File.dirExists path


{-| Convert a path to its canonical form, resolving symbolic links and removing redundant components.
-}
dirCanonicalizePath : FilePath -> Task Never FilePath
dirCanonicalizePath path =
    Eco.File.canonicalize path


{-| Run an action with a temporarily changed current directory, restoring the original directory afterward.
-}
dirWithCurrentDirectory : FilePath -> Task Never a -> Task Never a
dirWithCurrentDirectory dir action =
    dirGetCurrentDirectory
        |> Task.andThen
            (\currentDir ->
                bracket_
                    (Eco.File.setCwd dir)
                    (Eco.File.setCwd currentDir)
                    action
            )


{-| List all files and directories in the given directory path.
-}
dirListDirectory : FilePath -> Task Never (List FilePath)
dirListDirectory path =
    Eco.File.list path



-- System.Environment


{-| Look up an environment variable by name, returning Nothing if not found.
-}
envLookupEnv : String -> Task Never (Maybe String)
envLookupEnv name =
    Eco.Env.lookup name


{-| Get the program name (hardcoded as "eco" in this implementation).
-}
envGetProgName : Task Never String
envGetProgName =
    Task.succeed "eco"


{-| Get the command-line arguments passed to the program.
-}
envGetArgs : Task Never (List String)
envGetArgs =
    Eco.Env.rawArgs



-- Codec.Archive.Zip
-- Network.HTTP.Client


{-| Content describing an HTTP exception that occurred during a request.
-}
type HttpExceptionContent
    = StatusCodeException (HttpResponse ()) String
    | TooManyRedirects (List (HttpResponse ()))
    | ConnectionFailure SomeException


{-| An HTTP response with status, headers, and optional body.
-}
type HttpResponse body
    = HttpResponse
        { responseStatus : HttpStatus
        , responseHeaders : HttpResponseHeaders
        }


{-| HTTP response headers as a list of key-value pairs.
-}
type alias HttpResponseHeaders =
    List ( String, String )


{-| Extract the status from an HTTP response.
-}
httpResponseStatus : HttpResponse body -> HttpStatus
httpResponseStatus (HttpResponse { responseStatus }) =
    responseStatus


{-| Extract the headers from an HTTP response.
-}
httpResponseHeaders : HttpResponse body -> HttpResponseHeaders
httpResponseHeaders (HttpResponse { responseHeaders }) =
    responseHeaders


{-| The "Location" HTTP header name constant.
-}
httpHLocation : String
httpHLocation =
    "Location"


{-| HTTP status with code and message.
-}
type HttpStatus
    = HttpStatus Int String



-- Control.Exception


{-| A generic exception type representing any exception.
-}
type SomeException
    = SomeException


{-| Execute an action with resource acquisition and cleanup, ensuring cleanup runs even if the action fails.
-}
bracket : Task Never a -> (a -> Task Never b) -> (a -> Task Never c) -> Task Never c
bracket before after thing =
    before
        |> Task.andThen
            (\a ->
                thing a
                    |> Task.andThen
                        (\r ->
                            after a
                                |> Task.map (\_ -> r)
                        )
            )


{-| Execute an action with setup and cleanup tasks, discarding the setup result.
-}
bracket_ : Task Never a -> Task Never b -> Task Never c -> Task Never c
bracket_ before after thing =
    bracket before (always after) (always thing)



-- Control.Concurrent


{-| A thread identifier for concurrent execution.
-}
type alias ThreadId =
    Process.Id


{-| Fork a new thread to execute the given task concurrently, returning the thread ID.
-}
forkIO : Task Never () -> Task Never ThreadId
forkIO =
    Process.spawn



-- Control.Concurrent.MVar


{-| Create a new MVar with an initial value.
-}
newMVar : (a -> Bytes.Encode.Encoder) -> a -> Task Never (MVar a)
newMVar toEncoder value =
    newEmptyMVar
        |> Task.andThen
            (\mvar ->
                putMVar toEncoder mvar value
                    |> Task.map (\_ -> mvar)
            )


{-| Read the current value of an MVar without removing it, blocking if the MVar is empty.
-}
readMVar : Bytes.Decode.Decoder a -> MVar a -> Task Never a
readMVar decoder (MVar ref) =
    Eco.MVar.read decoder (Eco.MVar.MVar ref)


modifyMVar : Bytes.Decode.Decoder a -> (a -> Bytes.Encode.Encoder) -> MVar a -> (a -> Task Never ( a, b )) -> Task Never b
modifyMVar decoder toEncoder m io =
    takeMVar decoder m
        |> Task.andThen io
        |> Task.andThen
            (\( a, b ) ->
                putMVar toEncoder m a
                    |> Task.map (\_ -> b)
            )


{-| Take the value from an MVar, removing it and blocking if the MVar is empty.
-}
takeMVar : Bytes.Decode.Decoder a -> MVar a -> Task Never a
takeMVar decoder (MVar ref) =
    Eco.MVar.take decoder (Eco.MVar.MVar ref)


{-| Put a value into an MVar, blocking if the MVar is already full.
-}
putMVar : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
putMVar encoder (MVar ref) value =
    Eco.MVar.put encoder (Eco.MVar.MVar ref) value


{-| Create a new empty MVar.
-}
newEmptyMVar : Task Never (MVar a)
newEmptyMVar =
    Eco.MVar.new |> Task.map (\(Eco.MVar.MVar id) -> MVar id)



-- Control.Concurrent.Chan


{-| A thread-safe channel for communication between threads, implemented using MVars.
-}
type Chan a
    = Chan (MVar (Stream a)) (MVar (Stream a))


{-| Create a new empty channel.
-}
newChan : (MVar (ChItem a) -> Bytes.Encode.Encoder) -> Task Never (Chan a)
newChan toEncoder =
    newEmptyMVar
        |> Task.andThen
            (\hole ->
                newMVar toEncoder hole
                    |> Task.andThen
                        (\readVar ->
                            newMVar toEncoder hole
                                |> Task.map
                                    (\writeVar ->
                                        Chan readVar writeVar
                                    )
                        )
            )


{-| Read a value from a channel, blocking if the channel is empty.
-}
readChan : Bytes.Decode.Decoder a -> Chan a -> Task Never a
readChan decoder (Chan readVar _) =
    modifyMVar mVarDecoder mVarEncoder readVar <|
        \read_end ->
            readMVar (chItemDecoder decoder) read_end
                |> Task.map
                    (\(ChItem val new_read_end) ->
                        -- Use readMVar here, not takeMVar,
                        -- else dupChan doesn't work
                        ( new_read_end, val )
                    )


{-| Write a value to a channel.
-}
writeChan : (a -> Bytes.Encode.Encoder) -> Chan a -> a -> Task Never ()
writeChan toEncoder (Chan _ writeVar) val =
    newEmptyMVar
        |> Task.andThen
            (\new_hole ->
                takeMVar mVarDecoder writeVar
                    |> Task.andThen
                        (\old_hole ->
                            putMVar (chItemEncoder toEncoder) old_hole (ChItem val new_hole)
                                |> Task.andThen (\_ -> putMVar mVarEncoder writeVar new_hole)
                        )
            )



-- Data.ByteString.Builder


{-| Write a string to a file handle.
-}
builderHPutBuilder : IO.Handle -> String -> Task Never ()
builderHPutBuilder =
    IO.write



-- Data.Binary


{-| Decode a binary file using the provided decoder, returning an error with position and message on failure.
-}
binaryDecodeFileOrFail : Bytes.Decode.Decoder a -> FilePath -> Task Never (Result ( Int, String ) a)
binaryDecodeFileOrFail decoder filename =
    Eco.File.readBytes filename
        |> Task.map
            (\bytes ->
                case Bytes.Decode.decode decoder bytes of
                    Just value ->
                        Ok value

                    Nothing ->
                        Err ( 0, "binary decode failed" )
            )


{-| Encode a value to binary and write it to a file.
-}
binaryEncodeFile : (a -> Bytes.Encode.Encoder) -> FilePath -> a -> Task Never ()
binaryEncodeFile toEncoder path value =
    Eco.File.writeBytes path (Bytes.Encode.encode (toEncoder value))



-- System.Console.Haskeline


{-| The REPL input monad, which is just a Task in this implementation.
-}
type alias ReplInputT a =
    Task Never a


{-| Run a REPL input task with the given settings.
-}
replRunInputT : ReplSettings -> ReplInputT Exit.ExitCode -> State.StateT s Exit.ExitCode
replRunInputT _ io =
    State.liftIO io


{-| Wrap a REPL action to enable interrupt handling (no-op in this implementation).
-}
replWithInterrupt : ReplInputT a -> ReplInputT a
replWithInterrupt =
    identity


{-| Read a line of input from the REPL with the given prompt, returning Nothing on EOF.
-}
replGetInputLine : String -> ReplInputT (Maybe String)
replGetInputLine prompt =
    Eco.Console.write Eco.Console.stdout prompt
        |> Task.andThen (\_ -> Eco.Console.readLine)
        |> Task.map Just


{-| Read a line of input with initial text on the left and right of the cursor.
-}
replGetInputLineWithInitial : String -> ( String, String ) -> ReplInputT (Maybe String)
replGetInputLineWithInitial prompt ( left, right ) =
    replGetInputLine (left ++ prompt ++ right)



-- ====== NODE ======


{-| Get the directory name of the current module (Node.js \_\_dirname equivalent).
-}
nodeGetDirname : Task Never String
nodeGetDirname =
    Eco.Runtime.dirname


{-| Generate a random float between 0 and 1 using Node.js Math.random().
-}
nodeMathRandom : Task Never Float
nodeMathRandom =
    Eco.Runtime.random



-- ====== ENCODERS and DECODERS ======


{-| Decoder for MVar references from binary data.
-}
mVarDecoder : Bytes.Decode.Decoder (MVar a)
mVarDecoder =
    Bytes.Decode.map MVar BD.int


{-| Encoder for MVar references to binary data.
-}
mVarEncoder : MVar a -> Bytes.Encode.Encoder
mVarEncoder (MVar ref) =
    BE.int ref


{-| Encoder for channel items to binary data.
-}
chItemEncoder : (a -> Bytes.Encode.Encoder) -> ChItem a -> Bytes.Encode.Encoder
chItemEncoder valueEncoder (ChItem value hole) =
    Bytes.Encode.sequence
        [ valueEncoder value
        , mVarEncoder hole
        ]


{-| Decoder for channel items from binary data.
-}
chItemDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (ChItem a)
chItemDecoder decoder =
    Bytes.Decode.map2 ChItem
        decoder
        mVarDecoder


{-| Encoder for exceptions to binary data.
-}
someExceptionEncoder : SomeException -> Bytes.Encode.Encoder
someExceptionEncoder _ =
    Bytes.Encode.unsignedInt8 0


{-| Decoder for exceptions from binary data.
-}
someExceptionDecoder : Bytes.Decode.Decoder SomeException
someExceptionDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.map (\_ -> SomeException)


httpResponseEncoder : HttpResponse body -> Bytes.Encode.Encoder
httpResponseEncoder (HttpResponse httpResponse) =
    Bytes.Encode.sequence
        [ httpStatusEncoder httpResponse.responseStatus
        , httpResponseHeadersEncoder httpResponse.responseHeaders
        ]


httpResponseDecoder : Bytes.Decode.Decoder (HttpResponse body)
httpResponseDecoder =
    Bytes.Decode.map2
        (\responseStatus responseHeaders ->
            HttpResponse
                { responseStatus = responseStatus
                , responseHeaders = responseHeaders
                }
        )
        httpStatusDecoder
        httpResponseHeadersDecoder


httpStatusEncoder : HttpStatus -> Bytes.Encode.Encoder
httpStatusEncoder (HttpStatus statusCode statusMessage) =
    Bytes.Encode.sequence
        [ BE.int statusCode
        , BE.string statusMessage
        ]


httpStatusDecoder : Bytes.Decode.Decoder HttpStatus
httpStatusDecoder =
    Bytes.Decode.map2 HttpStatus
        BD.int
        BD.string


httpResponseHeadersEncoder : HttpResponseHeaders -> Bytes.Encode.Encoder
httpResponseHeadersEncoder =
    BE.list (BE.jsonPair BE.string BE.string)


httpResponseHeadersDecoder : Bytes.Decode.Decoder HttpResponseHeaders
httpResponseHeadersDecoder =
    BD.list (BD.jsonPair BD.string BD.string)


{-| Encoder for HTTP exception content to binary data.
-}
httpExceptionContentEncoder : HttpExceptionContent -> Bytes.Encode.Encoder
httpExceptionContentEncoder httpExceptionContent =
    case httpExceptionContent of
        StatusCodeException response body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , httpResponseEncoder response
                , BE.string body
                ]

        TooManyRedirects responses ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.list httpResponseEncoder responses
                ]

        ConnectionFailure someException ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , someExceptionEncoder someException
                ]


{-| Decoder for HTTP exception content from binary data.
-}
httpExceptionContentDecoder : Bytes.Decode.Decoder HttpExceptionContent
httpExceptionContentDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 StatusCodeException
                            httpResponseDecoder
                            BD.string

                    1 ->
                        Bytes.Decode.map TooManyRedirects (BD.list httpResponseDecoder)

                    2 ->
                        Bytes.Decode.map ConnectionFailure someExceptionDecoder

                    _ ->
                        Bytes.Decode.fail
            )
