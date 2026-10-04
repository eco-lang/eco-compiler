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
    , newMVar, newEmptyMVar, readMVar, takeMVar, putMVar, dropMVar
    , mVarEncoder, mVarDecoder
    , Chan, newChan, readChan, writeChan
    , ReplInputT
    , replRunInputT, replWithInterrupt, replGetInputLine
    , replGetInputLineWithInitial, liftInputT, liftIOInputT
    , nodeGetDirname, nodeMathRandom
    , mapFindMin
    , dictMapKeys, find, dictFind
    , mapTraverse
    , eitherLefts, filterM, listGroupBy, listLookup, listMaximum, foldl1_, foldr1
    , listTraverse, listTraverse_, lines, unlines, zipWithM, mapM_
    , maybeEncoder, maybeMapM, maybeTraverseTask
    , nonEmptyListTraverse
    , sequenceListMaybe, sequenceNonemptyListResult
    , foldM
    , dictFromListWith, dictInsertWith, dictIntersectionWith, dictIntersectionWithKey, dictMapMaybe, dictSequenceResult, dictSequenceMaybe, dictTraverse, dictTraverseWithKey, dictTraverseResult, dictTraverseWithKeyResult, dictUnionWith, dictMapM__, dictFromKeysA
    )

{-| Stands in for the parts of Haskell's libraries that the compiler was ported
from, so that code written in their shape runs on the `Eco.*` modules that do
this program's IO.

Most names here are a Haskell name with a prefix saying where it comes from:
`fp` for file paths, `dir` for directories, `env` for the environment, `repl`
for line input, `http` for HTTP errors, and `dict`, `map`, `list` and so on for
helpers over those structures. Such a name says which Haskell function a value
stands in for, not that it behaves the same way. Where one differs from what
its name suggests, its docstring says so.

File paths are plain strings, and the `fp` functions work on their text alone:
they never ask the file system anything. They take `/` as the only separator.
`fpIsRelative`, which `fpCombine` uses, is the one place that also recognises
the Windows forms of an absolute path.

The `dir` and `env` functions, `lockWithFileLock`, the binary file functions
and the REPL input functions are tasks over `Eco.File`, `Eco.Env` and
`Eco.Console`, and none of them can fail. Where the operation
underneath can fail with an `IOError`, the failure crashes the program through
`System.IO.crashOnError`. `binaryDecodeFileOrFail` is the exception: there, a
failure to read the file becomes an `Err`.

An _MVar_ is a cell, held outside the program, that is either empty or holds
one value, as `Eco.MVar` describes. The MVar functions here take an encoder or
a decoder for what the MVar holds because `Eco.MVar`'s operations do. A
_channel_ (`Chan`) is an unbounded first-in, first-out queue built from MVars,
through which concurrent tasks hand values to one another.

`HttpExceptionContent` and the types it is built from describe a failed HTTP
request, and come with binary codecs.

The rest are pure helpers over `Dict`, `Data.Map`, `List`, `Maybe`, `Result`,
non-empty lists and `Compiler.Reporting.Result`, most of them traversals. Those
that take a function giving a `Task` perform the tasks one after another, in
the order each docstring gives. `find`, `dictFind`, `mapFindMin`,
`listMaximum`, `foldl1_` and `foldr1` crash the program, through
`Utils.Crash.crash`, on a missing key or an empty input.

The types `FilePath`, `MVar`, `ChItem`, `Stream`, `ReplSettings` and
`LockSharedExclusive` used here are defined in `System.IO`.


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

@docs newMVar, newEmptyMVar, readMVar, takeMVar, putMVar, dropMVar
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

@docs mapFindMin
@docs dictMapKeys, find, dictFind


# Dictionary Traversal

@docs mapTraverse


# List Utilities

@docs eitherLefts, filterM, listGroupBy, listLookup, listMaximum, foldl1_, foldr1
@docs listTraverse, listTraverse_, lines, unlines, zipWithM, mapM_


# Maybe Utilities

@docs maybeEncoder, maybeMapM, maybeTraverseTask


# NonEmptyList Traversal

@docs nonEmptyListTraverse


# Sequence Operations

@docs sequenceListMaybe, sequenceNonemptyListResult


# Indexed Operations

@docs foldM


# Stdlib Dict Utilities

@docs dictFromListWith, dictInsertWith, dictIntersectionWith, dictIntersectionWithKey, dictMapMaybe, dictSequenceResult, dictSequenceMaybe, dictTraverse, dictTraverseWithKey, dictTraverseResult, dictTraverseWithKeyResult, dictUnionWith, dictMapM__, dictFromKeysA

-}

import Basics.Extra exposing (flip)
import Bytes.Decode
import Bytes.Encode
import Compiler.Data.NonEmptyList as NE
import Compiler.Reporting.Result as ReportingResult
import Control.Monad.State.Strict as State
import Data.Map as Map
import Dict exposing (Dict)
import Eco.Console
import Eco.Env
import Eco.File
import Eco.IO.Error as IOErr
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


{-| Returns the task as it is, since a `ReplInputT` is a `Task Never`.
-}
liftInputT : Task Never () -> ReplInputT ()
liftInputT =
    identity


{-| Returns the task as it is, since a `ReplInputT` is a `Task Never`.
-}
liftIOInputT : Task Never a -> ReplInputT a
liftIOInputT =
    identity


{-| Returns `path` with everything after its last `/` removed, keeping that `/`,
so `"a/b.elm"` gives `"a/"`. A path with no `/` gives `""`.
-}
fpDropFileName : FilePath -> FilePath
fpDropFileName path =
    case List.reverse (String.split "/" path) of
        _ :: tail ->
            List.reverse ("" :: tail)
                |> String.join "/"

        [] ->
            ""


{-| Returns `path2` appended to `path1` with a `/` between them, standing in for
Haskell's `</>`.

`path2` is returned unchanged when `fpIsRelative` says it is absolute, and also
whenever it begins with the text of `path1`, whether or not that text ends at a
`/`: `fpCombine "src" "srcgen/A.elm"` is `"srcgen/A.elm"`.

-}
fpCombine : FilePath -> FilePath -> FilePath
fpCombine path1 path2 =
    if not (fpIsRelative path2) || String.startsWith path1 path2 then
        path2

    else
        path1 ++ "/" ++ path2


{-| Returns `path` with `extension` appended, putting a `.` between them unless
`extension` already starts with one. An empty `extension` gives `path` followed
by a `.`.
-}
fpAddExtension : FilePath -> String -> FilePath
fpAddExtension path extension =
    if String.startsWith "." extension then
        path ++ extension

    else
        path ++ "." ++ extension


{-| Encodes a `Maybe`, writing the value in a `Just` with the given encoder. It is
`Utils.Bytes.Encode.maybe`, which describes the format.
-}
maybeEncoder : (a -> Bytes.Encode.Encoder) -> Maybe a -> Bytes.Encode.Encoder
maybeEncoder =
    BE.maybe


{-| Returns the errors in the list, in list order, leaving out every `Ok`.
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


{-| Returns a task that performs the predicate `p` on each element, first to last,
and succeeds with the elements for which it gave `True`, in their original
order.
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


{-| Returns the value filed under key `k` in a `Data.Map` dictionary, looked up
through the key projection `toComparable`, and crashes the program if there is
none.
-}
find : (k -> comparable) -> k -> Map.Dict comparable k a -> a
find toComparable k items =
    case Map.get toComparable k items of
        Just item ->
            item

        Nothing ->
            crash "Map.!: given key is not an element in the map"


{-| Returns the value under key `k`, and crashes the program if there is none.
-}
dictFind : comparable -> Dict.Dict comparable a -> a
dictFind k items =
    case Dict.get k items of
        Just item ->
            item

        Nothing ->
            crash "Map.!: given key is not an element in the map"


{-| Returns the entry with the lowest key, and crashes the program if the
dictionary is empty.
-}
mapFindMin : Dict.Dict comparable a -> ( comparable, a )
mapFindMin dict =
    case Dict.toList dict of
        firstElem :: _ ->
            firstElem

        _ ->
            crash "Error: empty map has no minimal element"


{-| Returns the result of folding `f` over the list from the left, starting from
`b`. The steps are joined with `Compiler.Reporting.Result.andThen`, so a step
that fails ends the fold, and the elements after it are never given to `f`.
-}
foldM : (b -> a -> ReportingResult.RResult info warnings error b) -> b -> List a -> ReportingResult.RResult info warnings error b
foldM f b =
    List.foldl (\a -> ReportingResult.andThen (\acc -> f acc a)) (ReportingResult.ok b)


{-| Returns the values in the `Just`s, in order, or `Nothing` if any element is
`Nothing`.
-}
sequenceListMaybe : List (Maybe a) -> Maybe (List a)
sequenceListMaybe =
    List.foldr (Maybe.map2 (::)) (Just [])


{-| Returns the values in the `Ok`s, in order, or an error if any element is an
`Err`.

When several elements are `Err`s, the error returned is that of the last of
them, not the first.

-}
sequenceNonemptyListResult : NE.Nonempty (Result e v) -> Result e (NE.Nonempty v)
sequenceNonemptyListResult (NE.Nonempty x xs) =
    List.foldl (\a acc -> Result.map2 NE.snoc a acc) (Result.map NE.singleton x) xs


{-| Returns a task that performs the task `f` gives for each element, first to
last, and discards their results.
-}
mapM_ : (a -> Task Never b) -> List a -> Task Never ()
mapM_ f =
    let
        c : a -> Task Never () -> Task Never ()
        c x k =
            f x |> Task.andThen (\_ -> k)
    in
    List.foldr c (Task.succeed ())


{-| Returns the results of the function on each element, in order, or `Nothing` if
it gives `Nothing` for any of them.
-}
maybeMapM : (a -> Maybe b) -> List a -> Maybe (List b)
maybeMapM =
    listMaybeTraverse


{-| Returns a core `Dict` holding each entry of a `Data.Map` dictionary under its
key as `f` turns it into a `comparable`.

The ordering function is ignored. When `f` gives two keys the same result, the
entry whose key comes first in the dictionary's order is kept.

-}
dictMapKeys : (k1 -> k1 -> Order) -> (k1 -> comparable) -> Map.Dict c k1 a -> Dict.Dict comparable a
dictMapKeys keyComparison f =
    Map.foldl keyComparison (\k x xs -> ( f k, x ) :: xs) [] >> Dict.fromList


{-| Returns a task that performs the task `f` gives for each value of a `Data.Map`
dictionary, in the dictionary's order, and succeeds with a dictionary of the
results under the same keys. The ordering function is ignored.
-}
mapTraverse : (k -> comparable) -> (k -> k -> Order) -> (a -> Task Never b) -> Map.Dict comparable k a -> Task Never (Map.Dict comparable k b)
mapTraverse toComparable keyComparison f =
    mapTraverseWithKey toComparable keyComparison (\_ -> f)


{-| Returns a task that performs the task `f` gives for each key and value of a
`Data.Map` dictionary, in the dictionary's order, and succeeds with a
dictionary of the results under the same keys. The ordering function is
ignored.
-}
mapTraverseWithKey : (k -> comparable) -> (k -> k -> Order) -> (k -> a -> Task Never b) -> Map.Dict comparable k a -> Task Never (Map.Dict comparable k b)
mapTraverseWithKey toComparable keyComparison f =
    Map.foldl keyComparison
        (\k a -> Task.andThen (\c -> Task.map (\va -> Map.insert toComparable k va c) (f k a)))
        (Task.succeed Map.empty)


{-| Returns an empty `Dict`, whatever the list holds.

Each pair only updates a key that is already in the dictionary, and the fold
starts from an empty one, so no key is ever added and `f` is never called.

-}
dictFromListWith : (a -> a -> a) -> List ( comparable, a ) -> Dict comparable a
dictFromListWith f =
    List.foldl
        (\( k, a ) ->
            Dict.update k (Maybe.map (flip f a))
        )
        Dict.empty


{-| Inserts `a` under `k`. When `k` already has a value, the value stored is
`f a old`, where `old` is the value it had.
-}
dictInsertWith : (a -> a -> a) -> comparable -> a -> Dict comparable a -> Dict comparable a
dictInsertWith f k a =
    Dict.update k (Maybe.map (f a) >> Maybe.withDefault a >> Just)


{-| Returns every entry of `a` and of `b`. A key in both holds `f` applied to its
value in `a` and then its value in `b`.
-}
dictUnionWith : (a -> a -> a) -> Dict comparable a -> Dict comparable a -> Dict comparable a
dictUnionWith f a b =
    Dict.merge Dict.insert (\k va vb acc -> Dict.insert k (f va vb) acc) Dict.insert a b Dict.empty


{-| Returns the entries for which `func` gives `Just`, each holding the value in
that `Just`.
-}
dictMapMaybe : (a -> Maybe b) -> Dict comparable a -> Dict comparable b
dictMapMaybe func =
    Dict.toList
        >> List.filterMap (\( k, a ) -> Maybe.map (Tuple.pair k) (func a))
        >> Dict.fromList


{-| Returns a task that performs the task `f` gives for each value, in ascending
key order, and succeeds with a `Dict` of the results under the same keys.
-}
dictTraverse : (a -> Task Never b) -> Dict comparable a -> Task Never (Dict comparable b)
dictTraverse f =
    dictTraverseWithKey (\_ -> f)


{-| Returns a task that performs the task `f` gives for each key and value, in
ascending key order, and succeeds with a `Dict` of the results under the same
keys.
-}
dictTraverseWithKey : (comparable -> a -> Task Never b) -> Dict comparable a -> Task Never (Dict comparable b)
dictTraverseWithKey f =
    Dict.foldl
        (\k a -> Task.andThen (\c -> Task.map (\va -> Dict.insert k va c) (f k a)))
        (Task.succeed Dict.empty)


{-| Returns the keys present in both `a` and `b`, each holding `f` applied to its
value in `a` and then its value in `b`.
-}
dictIntersectionWith : (a -> b -> c) -> Dict comparable a -> Dict comparable b -> Dict comparable c
dictIntersectionWith f a b =
    Dict.merge (\_ _ acc -> acc) (\k va vb acc -> Dict.insert k (f va vb) acc) (\_ _ acc -> acc) a b Dict.empty


{-| Returns the values in the `Ok`s under their keys, or an error if any value is
an `Err`.

When several values are `Err`s, the error returned is that of the one with the
highest key, not the lowest.

-}
dictSequenceResult : Dict comparable (Result e a) -> Result e (Dict comparable a)
dictSequenceResult =
    Dict.foldl (\k v acc -> Result.map2 (Dict.insert k) v acc) (Ok Dict.empty)


{-| Returns the values in the `Just`s under their keys, or `Nothing` if any value
is `Nothing`.
-}
dictSequenceMaybe : Dict comparable (Maybe a) -> Maybe (Dict comparable a)
dictSequenceMaybe =
    Dict.foldl (\k v acc -> Maybe.map2 (Dict.insert k) v acc) (Just Dict.empty)


{-| Returns the results of `f` on each value under the same keys, or an error if
`f` gives an `Err` for any value.

`f` is applied to every value, and when several give an `Err`, the error
returned is that of the one with the highest key, not the lowest.

-}
dictTraverseResult : (a -> Result e b) -> Dict comparable a -> Result e (Dict comparable b)
dictTraverseResult f =
    dictTraverseWithKeyResult (\_ -> f)


{-| Returns the results of `f` on each key and value under the same keys, or an
error if `f` gives an `Err` for any entry.

`f` is applied to every entry, and when several give an `Err`, the error
returned is that of the one with the highest key, not the lowest.

-}
dictTraverseWithKeyResult : (comparable -> a -> Result e b) -> Dict comparable a -> Result e (Dict comparable b)
dictTraverseWithKeyResult f =
    Dict.foldl (\k a acc -> Result.map2 (Dict.insert k) (f k a) acc) (Ok Dict.empty)


{-| Returns the keys present in both `a` and `b`, each holding `f` applied to the
key, its value in `a` and its value in `b`.
-}
dictIntersectionWithKey : (comparable -> a -> b -> c) -> Dict comparable a -> Dict comparable b -> Dict comparable c
dictIntersectionWithKey f a b =
    Dict.merge (\_ _ acc -> acc) (\k va vb acc -> Dict.insert k (f k va vb) acc) (\_ _ acc -> acc) a b Dict.empty


{-| Returns a task that performs the task `f` gives for each value and discards
their results. The tasks are performed in descending key order, highest key
first.
-}
dictMapM__ : (a -> Task Never b) -> Dict comparable a -> Task Never ()
dictMapM__ f =
    Dict.foldl (\_ x k -> f x |> Task.andThen (\_ -> k)) (Task.succeed ())


{-| Returns a task that performs the task `toValue` gives for each key, first to
last, and succeeds with a `Dict` from each key to its value. A key listed twice
keeps the value from its last appearance.
-}
dictFromKeysA : (comparable -> Task Never v) -> List comparable -> Task Never (Dict comparable v)
dictFromKeysA toValue keys =
    listTraverse (\k -> Task.map (Tuple.pair k) (toValue k)) keys
        |> Task.map Dict.fromList


{-| Returns a task that performs the task the function gives for each element,
first to last, and succeeds with their results in the same order. It is
`Utils.Task.Extra.mapM`.
-}
listTraverse : (a -> Task Never b) -> List a -> Task Never (List b)
listTraverse =
    Task.mapM


{-| Returns the results of `f` on each element, in order, or `Nothing` if `f`
gives `Nothing` for any of them.
-}
listMaybeTraverse : (a -> Maybe b) -> List a -> Maybe (List b)
listMaybeTraverse f =
    List.foldr (\a -> Maybe.andThen (\c -> Maybe.map (\va -> va :: c) (f a)))
        (Just [])


{-| Returns a task that performs the task `f` gives for each element, first to
last, and succeeds with their results in the same order.
-}
nonEmptyListTraverse : (a -> Task Never b) -> NE.Nonempty a -> Task Never (NE.Nonempty b)
nonEmptyListTraverse f (NE.Nonempty x list) =
    List.foldl (\a -> Task.andThen (\c -> Task.map (\va -> NE.snoc va c) (f a)))
        (Task.map NE.singleton (f x))
        list


{-| Returns a task that performs the task `f` gives for each element, first to
last, and discards their results.
-}
listTraverse_ : (a -> Task Never b) -> List a -> Task Never ()
listTraverse_ f =
    listTraverse f
        >> Task.map (\_ -> ())


{-| Returns a task that performs the task `f` gives for the value in a `Just` and
succeeds with its result in a `Just`, or, given `Nothing`, a task that succeeds
with `Nothing`.
-}
maybeTraverseTask : (a -> Task x b) -> Maybe a -> Task x (Maybe b)
maybeTraverseTask f a =
    case Maybe.map f a of
        Just b ->
            Task.map Just b

        Nothing ->
            Task.succeed Nothing


{-| Returns `f` applied to the elements of `xs` and `ys` pair by pair, or
`Nothing` if `f` gives `Nothing` for any pair. The extra elements of the longer
list are ignored.
-}
zipWithM : (a -> b -> Maybe c) -> List a -> List b -> Maybe (List c)
zipWithM f xs ys =
    List.map2 f xs ys
        |> Maybe.combine


{-| Splits the list into runs of consecutive elements, keeping their order.

An element joins the run of the element just before it when `p` holds for that
element and then this one. Each element is compared with its neighbour, not
with the first element of its run.

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


{-| Returns the largest element as `compare` orders them, and crashes the program
if the list is empty.
-}
listMaximum : (a -> a -> Order) -> List a -> a
listMaximum compare xs =
    case List.sortWith (flip compare) xs of
        x :: _ ->
            x

        [] ->
            crash "maximum: empty structure"


{-| Returns the value paired with the first occurrence of `key` in the list, or
`Nothing` if there is none.
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


{-| Folds `f` over a list from the left, starting from its first element, and
crashes the program if the list is empty.

`f` takes the element first and the accumulator second, so `[ a, b, c ]` gives
`f c (f b a)`.

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


{-| Folds `f` over a list from the left, starting from its first element, and
crashes the program if the list is empty.

`f` takes the accumulator first and the element second, so `[ a, b, c ]` gives
`f (f a b) c`, as Haskell's `foldl1` does.

-}
foldl1_ : (a -> a -> a) -> List a -> a
foldl1_ f =
    foldl1 (\a b -> f b a)


{-| Folds `f` over a list from the right, starting from its last element, and
crashes the program if the list is empty. `[ a, b, c ]` gives `f a (f b c)`.
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


{-| Splits the text at each newline. A newline at the end gives a final empty
string.
-}
lines : String -> List String
lines =
    String.split "\n"


{-| Joins the strings with newlines, and ends the result with one more newline.
-}
unlines : List String -> String
unlines xs =
    String.join "\n" xs ++ "\n"



-- System.FilePath


{-| Returns the components of `path` between its `/`s, leaving out empty ones, with
`"/"` first when `path` starts with `/`.
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


{-| Splits a path before the last `.` in its last component, giving the path
without its extension and the extension with its `.`. When the last component
has no `.`, the extension is `""`; a `.` in a directory name never starts one.
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


{-| Joins path components with `/`. A first component of `"/"` is the root, so
`[ "/", "a" ]` gives `"/a"` rather than `"//a"`.
-}
fpJoinPath : List String -> String
fpJoinPath paths =
    case paths of
        "/" :: tail ->
            "/" ++ String.join "/" tail

        _ ->
            String.join "/" paths


{-| Returns `path` with `root` and the one character after it removed when `path`
starts with the text of `root`, and `path` unchanged otherwise.

Nothing checks that the character removed is a `/`. A `root` of `"src"` turns
`"srcgen/A.elm"` into `"en/A.elm"`, and a `root` ending in `/` loses the first
character after it.

-}
fpMakeRelative : FilePath -> FilePath -> FilePath
fpMakeRelative root path =
    if String.startsWith root path then
        String.dropLeft (String.length root + 1) path

    else
        path


{-| Returns `path` ending in a `/`, adding one if it does not already.
-}
fpAddTrailingPathSeparator : FilePath -> FilePath
fpAddTrailingPathSeparator path =
    if String.endsWith "/" path then
        path

    else
        path ++ "/"


{-| The character that separates the components of a path in this module.
-}
fpPathSeparator : Char
fpPathSeparator =
    '/'


{-| Returns whether `path` is relative, meaning not absolute.

A path is absolute when it starts with `/` or `\`, or with an ASCII letter, a
`:` and then a `/` or `\`, as `C:/` does. Anything else is relative, a bare
drive such as `C:` included.

-}
fpIsRelative : FilePath -> Bool
fpIsRelative path =
    not (isAbsolutePath path)


{-| Returns whether `path` is absolute, as `fpIsRelative` describes.
-}
isAbsolutePath : String -> Bool
isAbsolutePath path =
    if String.startsWith "/" path then
        True

    else if String.startsWith "\\" path then
        -- UNC root or backslash-rooted Windows absolute path.
        True

    else
        case String.toList (String.left 3 path) of
            -- Windows drive prefix: ASCII letter, colon, separator.
            letter :: ':' :: sep :: _ ->
                isAsciiLetter letter && (sep == '/' || sep == '\\')

            _ ->
                False


{-| Returns whether the character is an ASCII letter, upper or lower case.
-}
isAsciiLetter : Char -> Bool
isAsciiLetter c =
    let
        code =
            Char.toCode c
    in
    (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A)


{-| Returns what follows the last `/` of the path, or the whole path when it has
no `/`. A path ending in `/` gives `""`.
-}
fpTakeFileName : FilePath -> FilePath
fpTakeFileName filename =
    Prelude.last (String.split "/" filename)


{-| Splits the path after its last `/`, giving the directory with that `/` and the
file name. A path with no `/` gives `"./"` as the directory.
-}
fpSplitFileName : FilePath -> ( String, String )
fpSplitFileName filename =
    case List.reverse (String.indexes "/" filename) of
        index :: _ ->
            ( String.left (index + 1) filename, String.dropLeft (index + 1) filename )

        _ ->
            ( "./", filename )


{-| Returns the extension of the path with its `.`, as `fpSplitExtension` finds
it, or `""` if there is none.
-}
fpTakeExtension : FilePath -> String
fpTakeExtension =
    fpSplitExtension >> Tuple.second


{-| Returns the path without its extension, as `fpSplitExtension` finds it.
-}
fpDropExtension : FilePath -> FilePath
fpDropExtension =
    fpSplitExtension >> Tuple.first


{-| Returns the directory part of a path, which is everything before its last
component.

A path with no `/` gives `"."`, and `"/"` gives `"/"`. A path ending in `/`
loses its last named component as well, so `"a/b/"` gives `"a"` and `"a/"`
gives `""`. A component directly under the root gives `""`, not `"/"`, so
`"/foo"` gives `""`.

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
            -- A bare file name has no `/`, so `other` is empty and joining it
            -- would give "". "." is returned instead, so that a caller that
            -- creates the directory does not ask for "". This is an `if`
            -- rather than a separate `_ :: []` arm because the current
            -- self-hosted Eco compiler miscompiles such an arm.
            if List.isEmpty other then
                "."

            else
                String.join "/" (List.reverse other)



-- System.FileLock


{-| Returns a task that locks the file at `path`, performs `ioFunc`, unlocks the
file, and succeeds with what `ioFunc` gave.

Locking and unlocking are done by `Eco.File.lock` and `Eco.File.unlock`, whose
docstrings say what a lock achieves. A failure of either crashes the program.

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


{-| Locks the file at `path` with `Eco.File.lock`, and crashes the program if
that fails.
-}
lockFile : FilePath -> Task Never ()
lockFile path =
    Eco.File.lock path
        |> IO.crashOnError


{-| Unlocks the file at `path` with `Eco.File.unlock`, and crashes the program if
that fails.
-}
unlockFile : FilePath -> Task Never ()
unlockFile path =
    Eco.File.unlock path
        |> IO.crashOnError



-- System.Directory


{-| Returns whether `filename` names a file, as `Eco.File.fileExists` decides. A
directory is not a file here.
-}
dirDoesFileExist : FilePath -> Task Never Bool
dirDoesFileExist filename =
    Eco.File.fileExists filename


{-| Returns the path of the executable called `filename` that the system's search
path finds, or `Nothing` if it finds none.
-}
dirFindExecutable : FilePath -> Task Never (Maybe FilePath)
dirFindExecutable filename =
    Eco.File.findExecutable filename


{-| Creates the directory `filename`, and its missing parents too when
`createParents` is `True`. An empty `filename` does nothing.

Any failure crashes the program. As `Eco.File.createDir` describes, an existing
directory is not a failure when `createParents` is `True`; with `False` it can
be.

-}
dirCreateDirectoryIfMissing : Bool -> FilePath -> Task Never ()
dirCreateDirectoryIfMissing createParents filename =
    -- A directory computed from a bare file name, as fpDropFileName
    -- computes it, is "", and the layer below fails to create "".
    if String.length filename == 0 then
        Task.succeed ()

    else
        Eco.File.createDir createParents filename
            |> IO.crashOnError


{-| A task that gives the current working directory, as `Eco.File.getCwd` reads
it.
-}
dirGetCurrentDirectory : Task Never String
dirGetCurrentDirectory =
    Eco.File.getCwd


{-| Returns the directory where the application called `filename` keeps its data
for the current user, as `Eco.File.appDataDir` gives it. The directory need not
exist.
-}
dirGetAppUserDataDirectory : FilePath -> Task Never FilePath
dirGetAppUserDataDirectory filename =
    Eco.File.appDataDir filename


{-| Returns when the file at `filename` was last modified, and crashes the program
if that cannot be read.
-}
dirGetModificationTime : FilePath -> Task Never Time.Posix
dirGetModificationTime filename =
    Eco.File.modificationTime filename
        |> IO.crashOnError


{-| Removes the file at `path`, and crashes the program if that fails.
-}
dirRemoveFile : FilePath -> Task Never ()
dirRemoveFile path =
    Eco.File.removeFile path
        |> IO.crashOnError


{-| Returns whether `path` names a directory, as `Eco.File.dirExists` decides.
-}
dirDoesDirectoryExist : FilePath -> Task Never Bool
dirDoesDirectoryExist path =
    Eco.File.dirExists path


{-| Returns `path` made absolute, as `Eco.File.canonicalize` gives it, with its
symbolic links resolved where that can resolve them: a path that does not exist
is only made absolute and normalized. Crashes the program if the request fails.
-}
dirCanonicalizePath : FilePath -> Task Never FilePath
dirCanonicalizePath path =
    Eco.File.canonicalize path
        |> IO.crashOnError


{-| Returns a task that makes `dir` the current working directory, performs
`action`, changes back to the directory that was current before, and succeeds
with what `action` gave. A failure to change directory crashes the program.
-}
dirWithCurrentDirectory : FilePath -> Task Never a -> Task Never a
dirWithCurrentDirectory dir action =
    dirGetCurrentDirectory
        |> Task.andThen
            (\currentDir ->
                bracket_
                    (Eco.File.setCwd dir |> IO.crashOnError)
                    (Eco.File.setCwd currentDir |> IO.crashOnError)
                    action
            )


{-| Returns the names of the entries in the directory at `path`, as
`Eco.File.list` gives them, and crashes the program if it cannot be listed.
-}
dirListDirectory : FilePath -> Task Never (List FilePath)
dirListDirectory path =
    Eco.File.list path
        |> IO.crashOnError



-- System.Environment


{-| Returns the value of the environment variable `name`, or `Nothing` if it is not
set.
-}
envLookupEnv : String -> Task Never (Maybe String)
envLookupEnv name =
    Eco.Env.lookup name


{-| A task that gives the program's name, which is always `"eco"`. Nothing is read
from the environment.
-}
envGetProgName : Task Never String
envGetProgName =
    Task.succeed "eco"


{-| A task that gives the command-line arguments, as `Eco.Env.rawArgs` reports
them.
-}
envGetArgs : Task Never (List String)
envGetArgs =
    Eco.Env.rawArgs



-- Codec.Archive.Zip
-- Network.HTTP.Client


{-| The reason an HTTP request failed, standing in for the type of the same name in
Haskell's `http-client`.

`StatusCodeException` carries the response (its status and headers) and,
separately, a body as a `String`.

`TooManyRedirects` carries a list of responses.

`ConnectionFailure` carries a `SomeException`, which says nothing about what
went wrong.

-}
type HttpExceptionContent
    = StatusCodeException (HttpResponse ()) String
    | TooManyRedirects (List (HttpResponse ()))
    | ConnectionFailure SomeException


{-| The status and headers of an HTTP response.

Nothing uses the type parameter `body`: no body is held, whatever `body` is.

-}
type HttpResponse body
    = HttpResponse
        { responseStatus : HttpStatus
        , responseHeaders : HttpResponseHeaders
        }


{-| The headers of an HTTP response, as pairs of a header name and its value.

This is a name for a list of pairs, not a new type.

-}
type alias HttpResponseHeaders =
    List ( String, String )


{-| Returns the status of the response.
-}
httpResponseStatus : HttpResponse body -> HttpStatus
httpResponseStatus (HttpResponse { responseStatus }) =
    responseStatus


{-| Returns the headers of the response.
-}
httpResponseHeaders : HttpResponse body -> HttpResponseHeaders
httpResponseHeaders (HttpResponse { responseHeaders }) =
    responseHeaders


{-| The name of the HTTP header that gives the target of a redirect.
-}
httpHLocation : String
httpHLocation =
    "Location"


{-| The status of an HTTP response: its code and the message that comes with it.
-}
type HttpStatus
    = HttpStatus Int String



-- Control.Exception


{-| An exception of any kind, standing in for Haskell's `SomeException`. Its one
constructor carries nothing, so a value says that something went wrong, not
what.
-}
type SomeException
    = SomeException


{-| Returns a task that performs `before`, then `thing` with its result, then
`after` with the same result, and succeeds with what `thing` gave.

A `Task Never` cannot fail, so `after` runs whenever `thing` finishes. If the
program crashes in `thing`, `after` does not run.

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


{-| Returns a task that performs `before`, `thing` and `after`, in that order, and
succeeds with what `thing` gave.
-}
bracket_ : Task Never a -> Task Never b -> Task Never c -> Task Never c
bracket_ before after thing =
    bracket before (always after) (always thing)



-- Control.Concurrent


{-| The identifier of a task started by `forkIO`.

This is a name for `Process.Id`, not a new type.

-}
type alias ThreadId =
    Process.Id


{-| Returns a task that starts the given task running concurrently, as
`Process.spawn` does, and succeeds at once with its identifier.
-}
forkIO : Task Never () -> Task Never ThreadId
forkIO =
    Process.spawn



-- Control.Concurrent.MVar


{-| Returns a task that creates an MVar holding `value`, written with `toEncoder`.
-}
newMVar : (a -> Bytes.Encode.Encoder) -> a -> Task Never (MVar a)
newMVar toEncoder value =
    newEmptyMVar
        |> Task.andThen
            (\mvar ->
                putMVar toEncoder mvar value
                    |> Task.map (\_ -> mvar)
            )


{-| Returns the MVar's value, read with `decoder`, and leaves the MVar full. Waits
while the MVar is empty.
-}
readMVar : Bytes.Decode.Decoder a -> MVar a -> Task Never a
readMVar decoder (MVar ref) =
    Eco.MVar.read decoder (Eco.MVar.MVar ref)


{-| Returns a task that takes the MVar's value, gives it to `io`, puts the first
part of `io`'s result back into the MVar, and succeeds with the second part.
While `io` runs the MVar is empty, so another task that reads or takes it
waits.
-}
modifyMVar : Bytes.Decode.Decoder a -> (a -> Bytes.Encode.Encoder) -> MVar a -> (a -> Task Never ( a, b )) -> Task Never b
modifyMVar decoder toEncoder m io =
    takeMVar decoder m
        |> Task.andThen io
        |> Task.andThen
            (\( a, b ) ->
                putMVar toEncoder m a
                    |> Task.map (\_ -> b)
            )


{-| Returns the MVar's value, read with `decoder`, and leaves the MVar empty.
Waits while the MVar is empty.
-}
takeMVar : Bytes.Decode.Decoder a -> MVar a -> Task Never a
takeMVar decoder (MVar ref) =
    Eco.MVar.take decoder (Eco.MVar.MVar ref)


{-| Puts `value`, written with `encoder`, into the MVar. Waits while the MVar is
full.
-}
putMVar : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
putMVar encoder (MVar ref) value =
    Eco.MVar.put encoder (Eco.MVar.MVar ref) value


{-| A task that creates a new, empty MVar.
-}
newEmptyMVar : Task Never (MVar a)
newEmptyMVar =
    Eco.MVar.new |> Task.map (\(Eco.MVar.MVar id) -> MVar id)


{-| Discards the MVar, together with any value it holds. Use it only when nothing
will use the MVar again.
-}
dropMVar : MVar a -> Task Never ()
dropMVar (MVar ref) =
    Eco.MVar.drop (Eco.MVar.MVar ref)



-- Control.Concurrent.Chan


{-| An unbounded first-in, first-out channel, through which concurrent tasks hand
values to one another.

A channel is made by `newChan`. Writing to it does not wait for a reader, and
reading waits until there is a value to read. Each value written is returned
by one `readChan`, in the order the values were written.

-}
type Chan a
    = Chan (MVar (Stream a)) (MVar (Stream a))


{-| Returns a task that creates an empty channel. `toEncoder` writes the channel's
own references to MVars, and `mVarEncoder` is such an encoder.
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


{-| Returns the oldest value in the channel that no `readChan` has yet returned,
read with `decoder`. Waits while there is none.

A channel is a chain of MVars called holes. A hole, once filled, holds a value
and the next hole. The channel keeps the hole to be read next and the hole to
be filled next. A read takes the value out of the first, drops that hole, and
moves on to the next.

The hole is dropped because an MVar keeps its value until it is dropped, so a
hole left behind would keep its value for as long as the program runs. Nothing
else refers to it: only one read takes from a given hole, and a write fills
each hole once.

-}
readChan : Bytes.Decode.Decoder a -> Chan a -> Task Never a
readChan decoder (Chan readVar _) =
    modifyMVar mVarDecoder mVarEncoder readVar <|
        \read_end ->
            takeMVar (chItemDecoder decoder) read_end
                |> Task.andThen
                    (\(ChItem val new_read_end) ->
                        dropMVar read_end
                            |> Task.map (\_ -> ( new_read_end, val ))
                    )


{-| Adds `val`, written with `toEncoder`, to the end of the channel. It does not
wait for a reader.
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


{-| Writes the text to the stream the handle names. It is `System.IO.write`, so it
cannot fail and any error is discarded.
-}
builderHPutBuilder : IO.Handle -> String -> Task Never ()
builderHPutBuilder =
    IO.write



-- Data.Binary


{-| Returns the value `decoder` reads from the file at `filename`, or an error as a
position and a message.

The position is always 0. A file `decoder` cannot read gives the message
`"binary decode failed"`. A failure to read the file is an `Err` too, not a
crash, with the `IOError` as `Eco.IO.Error.toString` renders it. Bytes left
over after the value are ignored.

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
        |> Task.onError (\err -> Task.succeed (Err ( 0, IOErr.toString err )))


{-| Writes `value`, encoded with `toEncoder`, to the file at `path` with
`Eco.File.writeBytesAtomic`, and crashes the program if that fails.
-}
binaryEncodeFile : (a -> Bytes.Encode.Encoder) -> FilePath -> a -> Task Never ()
binaryEncodeFile toEncoder path value =
    Eco.File.writeBytesAtomic path (Bytes.Encode.encode (toEncoder value))
        |> IO.crashOnError



-- System.Console.Haskeline


{-| A computation that reads REPL input, standing in for Haskeline's `InputT`.

This is a name for `Task Never a`, not a new type, which is why
`liftInputT`, `liftIOInputT` and `replWithInterrupt` return their argument as
it is.

-}
type alias ReplInputT a =
    Task Never a


{-| Returns a state computation that performs `io` and produces its exit code,
leaving the state unchanged. The settings are ignored.
-}
replRunInputT : ReplSettings -> ReplInputT Exit.ExitCode -> State.StateT s Exit.ExitCode
replRunInputT _ io =
    State.liftIO io


{-| Returns the computation as it is. Nothing here handles an interrupt.
-}
replWithInterrupt : ReplInputT a -> ReplInputT a
replWithInterrupt =
    identity


{-| Writes `prompt` to standard output, reads a line of standard input, and
returns the line in a `Just`.

The result is never `Nothing`: `Eco.Console.readLine` has no separate value for
the end of input, and a failure to write or read crashes the program.

-}
replGetInputLine : String -> ReplInputT (Maybe String)
replGetInputLine prompt =
    Eco.Console.write Eco.Console.stdout prompt
        |> Task.andThen (\_ -> Eco.Console.readLine)
        |> Task.map Just
        |> IO.crashOnError


{-| Reads a line as `replGetInputLine` does, with `left`, `prompt` and `right`
written together as the prompt. The text of `left` and `right` is only printed;
it is not part of the line returned.
-}
replGetInputLineWithInitial : String -> ( String, String ) -> ReplInputT (Maybe String)
replGetInputLineWithInitial prompt ( left, right ) =
    replGetInputLine (left ++ prompt ++ right)



-- ====== NODE ======


{-| A task that gives the directory `Eco.Runtime.dirname` returns, standing in for
Node's `__dirname`.
-}
nodeGetDirname : Task Never String
nodeGetDirname =
    Eco.Runtime.dirname


{-| A task that gives a random number from `Eco.Runtime.random`, expected to be at
least 0 and less than 1. Nothing checks the range.
-}
nodeMathRandom : Task Never Float
nodeMathRandom =
    Eco.Runtime.random



-- ====== ENCODERS and DECODERS ======


{-| A decoder for a reference to an MVar, as `mVarEncoder` writes it. It reads the
reference, not the MVar's contents.
-}
mVarDecoder : Bytes.Decode.Decoder (MVar a)
mVarDecoder =
    Bytes.Decode.map MVar BD.int


{-| Encodes a reference to an MVar, not its contents, as the MVar's number.
-}
mVarEncoder : MVar a -> Bytes.Encode.Encoder
mVarEncoder (MVar ref) =
    BE.int ref


{-| Encodes one link of a channel as its value, written with `valueEncoder`,
followed by the reference to the next hole.
-}
chItemEncoder : (a -> Bytes.Encode.Encoder) -> ChItem a -> Bytes.Encode.Encoder
chItemEncoder valueEncoder (ChItem value hole) =
    Bytes.Encode.sequence
        [ valueEncoder value
        , mVarEncoder hole
        ]


{-| Produces a decoder for one link of a channel, as `chItemEncoder` writes it,
reading the value with `decoder`.
-}
chItemDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (ChItem a)
chItemDecoder decoder =
    Bytes.Decode.map2 ChItem
        decoder
        mVarDecoder


{-| Encodes a `SomeException` as the single byte 0.
-}
someExceptionEncoder : SomeException -> Bytes.Encode.Encoder
someExceptionEncoder _ =
    Bytes.Encode.unsignedInt8 0


{-| A decoder for a `SomeException`, which reads one byte and accepts any value in
it.
-}
someExceptionDecoder : Bytes.Decode.Decoder SomeException
someExceptionDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.map (\_ -> SomeException)


{-| Encodes a response as its status followed by its headers.
-}
httpResponseEncoder : HttpResponse body -> Bytes.Encode.Encoder
httpResponseEncoder (HttpResponse httpResponse) =
    Bytes.Encode.sequence
        [ httpStatusEncoder httpResponse.responseStatus
        , httpResponseHeadersEncoder httpResponse.responseHeaders
        ]


{-| A decoder for a response, as `httpResponseEncoder` writes it.
-}
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


{-| Encodes a status as its code followed by its message.
-}
httpStatusEncoder : HttpStatus -> Bytes.Encode.Encoder
httpStatusEncoder (HttpStatus statusCode statusMessage) =
    Bytes.Encode.sequence
        [ BE.int statusCode
        , BE.string statusMessage
        ]


{-| A decoder for a status, as `httpStatusEncoder` writes it.
-}
httpStatusDecoder : Bytes.Decode.Decoder HttpStatus
httpStatusDecoder =
    Bytes.Decode.map2 HttpStatus
        BD.int
        BD.string


{-| Encodes headers as a list of name and value pairs.
-}
httpResponseHeadersEncoder : HttpResponseHeaders -> Bytes.Encode.Encoder
httpResponseHeadersEncoder =
    BE.list (BE.jsonPair BE.string BE.string)


{-| A decoder for headers, as `httpResponseHeadersEncoder` writes them.
-}
httpResponseHeadersDecoder : Bytes.Decode.Decoder HttpResponseHeaders
httpResponseHeadersDecoder =
    BD.list (BD.jsonPair BD.string BD.string)


{-| Encodes an `HttpExceptionContent` as a tag byte, 0 for `StatusCodeException`,
1 for `TooManyRedirects` and 2 for `ConnectionFailure`, followed by what the
constructor carries.
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


{-| A decoder for an `HttpExceptionContent`, as `httpExceptionContentEncoder`
writes it. It fails on a tag byte other than 0, 1 or 2.
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
