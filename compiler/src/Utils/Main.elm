module Utils.Main exposing
    ( fpCombine, fpAddExtension, fpDropExtension, fpDropFileName, fpSplitExtension
    , fpSplitFileName, fpSplitDirectories, fpJoinPath, fpMakeRelative, fpAddTrailingPathSeparator
    , fpPathSeparator, fpIsRelative, fpTakeFileName, fpTakeExtension, fpTakeDirectory
    , dirDoesFileExist, dirDoesDirectoryExist, dirCreateDirectoryIfMissing
    , dirGetCurrentDirectory, dirGetAppUserDataDirectory, dirGetModificationTime, dirListDirectory
    , dirRemoveFile, dirRemoveDirectoryRecursive, dirGetFileSize, dirCanonicalizePath, dirTouch
    , appDataDirFor
    , envLookupEnv, envGetProgName, envGetArgs
    , lockWithFileLock
    , binaryDecodeFileOrFail, binaryEncodeFile, builderHPutBuilder
    , ThreadId, forkIO
    , newMVar, newEmptyMVar, readMVar, takeMVar, putMVar, dropMVar
    , mVarEncoder, mVarDecoder
    , Chan, newChan, readChan, writeChan
    , nodeGetDirname
    , mapFindMin
    , dictMapKeys, find, dictFind
    , mapTraverse
    , eitherLefts, filterM, listGroupBy, listLookup, listMaximum, foldl1_, foldr1
    , listTraverse, listTraverse_, unlines, zipWithM, mapM_
    , maybeEncoder, maybeMapM
    , nonEmptyListTraverse
    , sequenceListMaybe, sequenceNonemptyListResult
    , dictFromListWith, dictInsertWith, dictIntersectionWith, dictIntersectionWithKey, dictMapMaybe, dictSequenceResult, dictSequenceMaybe, dictTraverse, dictTraverseWithKey, dictTraverseResult, dictTraverseWithKeyResult, dictUnionWith, dictMapM__, dictFromKeysA
    )

{-| Stands in for the parts of Haskell's libraries that the compiler was ported
from, so that code written in their shape runs on eco/system, which does this
program's IO, and on the `Eco.*` modules of eco/kernel that the compiler still
uses (MVars).

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

The `dir` and `env` functions and the binary file functions are tasks over
eco/system's `FileSystem` and `System`, and none of them can fail. Where the operation underneath
can fail, the failure, as a `System.IOError.IOError`, crashes the program
through `System.IO.crashOnError`. `binaryDecodeFileOrFail` is the exception:
there, a failure to read the file becomes an `Err`. Paths are converted with
`System.OsPath`, and an empty path, which eco/system would read as the current
directory, fails as a missing file does (or is no file, for the existence
queries).

An _MVar_ is a cell, held outside the program, that is either empty or holds
one value, as `Eco.MVar` describes. The MVar functions here take an encoder or
a decoder for what the MVar holds because `Eco.MVar`'s operations do. A
_channel_ (`Chan`) is an unbounded first-in, first-out queue built from MVars,
through which concurrent tasks hand values to one another.

The rest are pure helpers over `Dict`, `Data.Map`, `List`, `Maybe`, `Result`,
non-empty lists and `Compiler.Reporting.Result`, most of them traversals. Those
that take a function giving a `Task` perform the tasks one after another, in
the order each docstring gives. `find`, `dictFind`, `mapFindMin`, `foldl1_`
and `foldr1` crash the program, through `System.Crash.crash`, on a missing key
or an empty input.

The types `FilePath`, `MVar`, `ChItem`, `Stream` and `LockSharedExclusive` used
here are defined in `System.IO`.


# File Path Operations

@docs fpCombine, fpAddExtension, fpDropExtension, fpDropFileName, fpSplitExtension
@docs fpSplitFileName, fpSplitDirectories, fpJoinPath, fpMakeRelative, fpAddTrailingPathSeparator
@docs fpPathSeparator, fpIsRelative, fpTakeFileName, fpTakeExtension, fpTakeDirectory


# Directory Operations

@docs dirDoesFileExist, dirDoesDirectoryExist, dirCreateDirectoryIfMissing
@docs dirGetCurrentDirectory, dirGetAppUserDataDirectory, dirGetModificationTime, dirListDirectory
@docs dirRemoveFile, dirRemoveDirectoryRecursive, dirGetFileSize, dirCanonicalizePath, dirTouch
@docs appDataDirFor


# Environment Operations

@docs envLookupEnv, envGetProgName, envGetArgs


# File Locking

@docs lockWithFileLock


# Binary Serialization

@docs binaryDecodeFileOrFail, binaryEncodeFile, builderHPutBuilder


# Concurrency Primitives

@docs ThreadId, forkIO


# MVar Operations

@docs newMVar, newEmptyMVar, readMVar, takeMVar, putMVar, dropMVar
@docs mVarEncoder, mVarDecoder


# Channel Operations

@docs Chan, newChan, readChan, writeChan


# Node.js Integration

@docs nodeGetDirname


# Dictionary Utilities

@docs mapFindMin
@docs dictMapKeys, find, dictFind


# Dictionary Traversal

@docs mapTraverse


# List Utilities

@docs eitherLefts, filterM, listGroupBy, listLookup, listMaximum, foldl1_, foldr1
@docs listTraverse, listTraverse_, unlines, zipWithM, mapM_


# Maybe Utilities

@docs maybeEncoder, maybeMapM


# NonEmptyList Traversal

@docs nonEmptyListTraverse


# Sequence Operations

@docs sequenceListMaybe, sequenceNonemptyListResult


# Stdlib Dict Utilities

@docs dictFromListWith, dictInsertWith, dictIntersectionWith, dictIntersectionWithKey, dictMapMaybe, dictSequenceResult, dictSequenceMaybe, dictTraverse, dictTraverseWithKey, dictTraverseResult, dictTraverseWithKeyResult, dictUnionWith, dictMapM__, dictFromKeysA

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Data.Map as Map
import Data.NonEmptyList as NE
import Dict exposing (Dict)
import Eco.MVar
import FileSystem
import Maybe.Extra as Maybe
import Path
import Prelude
import Process
import System
import System.Crash exposing (crash)
import System.IO as IO exposing (ChItem(..), FilePath, LockSharedExclusive(..), MVar(..), Stream)
import System.IOError as IOErr exposing (IOError)
import System.OsPath as OsPath
import Task exposing (Task)
import Time
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Task.Extra as Task


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
dictMapKeys : (k1 -> comparable) -> Map.Dict c k1 a -> Dict.Dict comparable a
dictMapKeys f =
    Map.foldl (\k x xs -> ( f k, x ) :: xs) [] >> Dict.fromList


{-| Returns a task that performs the task `f` gives for each value of a `Data.Map`
dictionary, in the dictionary's order, and succeeds with a dictionary of the
results under the same keys. The ordering function is ignored.
-}
mapTraverse : (k -> comparable) -> (a -> Task Never b) -> Map.Dict comparable k a -> Task Never (Map.Dict comparable k b)
mapTraverse toComparable f =
    mapTraverseWithKey toComparable (\_ -> f)


{-| Returns a task that performs the task `f` gives for each key and value of a
`Data.Map` dictionary, in the dictionary's order, and succeeds with a
dictionary of the results under the same keys. The ordering function is
ignored.
-}
mapTraverseWithKey : (k -> comparable) -> (k -> a -> Task Never b) -> Map.Dict comparable k a -> Task Never (Map.Dict comparable k b)
mapTraverseWithKey toComparable f =
    Map.foldl
        (\k a -> Task.andThen (\c -> Task.map (\va -> Map.insert toComparable k va c) (f k a)))
        (Task.succeed Map.empty)


{-| Returns a `Dict` of every key in the list. A key that appears once holds its
value; a repeated key holds `f old new` folded in list order, where `old` is the
value gathered so far and `new` the later one.
-}
dictFromListWith : (a -> a -> a) -> List ( comparable, a ) -> Dict comparable a
dictFromListWith f =
    List.foldl
        (\( k, a ) ->
            Dict.update k
                (\maybeOld ->
                    case maybeOld of
                        Just old ->
                            Just (f old a)

                        Nothing ->
                            Just a
                )
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


{-| Returns the largest of `first` and the elements of `rest` as `compare`
orders them; of several equal largest elements, the earliest.
-}
listMaximum : (a -> a -> Order) -> a -> List a -> a
listMaximum compare first rest =
    List.foldl
        (\x acc ->
            if compare x acc == GT then
                x

            else
                acc
        )
        first
        rest


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


{-| Returns a task that performs `ioFunc` and succeeds with what it gave.

No lock is taken, whatever `path` and the mode: the compiler's native and
JavaScript builds never locked anything here (eco/kernel's `Eco.File.lock` did
nothing), and the operation was dropped with eco/kernel's file IO
(plans/compiler-io-on-eco-system.md §10). Exclusion between concurrent `eco`
processes would need a lock on eco/system's `FileSystem.Handle`.

-}
lockWithFileLock : String -> LockSharedExclusive -> (() -> Task Never a) -> Task Never a
lockWithFileLock _ mode ioFunc =
    case mode of
        LockExclusive ->
            ioFunc ()



-- System.Directory


{-| Runs the file system task `toTask` on the path `path`, as eco/system reads it,
with a failure as an `IOError` about `path`. An empty `path` fails with
`FileNotFound ""` instead, since eco/system would read it as the current
directory.
-}
onPath : FilePath -> (Path.Path -> Task FileSystem.Error a) -> Task IOError a
onPath path toTask =
    if String.isEmpty path then
        Task.fail (IOErr.FileNotFound path)

    else
        toTask (OsPath.toPath path)
            |> Task.mapError (IOErr.fromFileSystem path)


{-| Returns the entity type of what `path` names, following symbolic links, or
`Nothing` if that cannot be read (nothing there, no permission, an empty path).
-}
entityType : FilePath -> Task Never (Maybe FileSystem.EntityType)
entityType path =
    onPath path (FileSystem.metadata { resolveLink = True })
        |> Task.map (\meta -> Just meta.entityType)
        |> Task.onError (\_ -> Task.succeed Nothing)


{-| Returns whether `filename` names a file, following symbolic links. A directory
is not a file here, and anything that cannot be read is not one either.
-}
dirDoesFileExist : FilePath -> Task Never Bool
dirDoesFileExist filename =
    entityType filename
        |> Task.map (\t -> t == Just FileSystem.File)


{-| Creates the directory `filename`, and its missing parents too when
`createParents` is `True`. An empty `filename` does nothing.

Any failure crashes the program. An existing directory is not a failure when
`createParents` is `True`; with `False` it is.

-}
dirCreateDirectoryIfMissing : Bool -> FilePath -> Task Never ()
dirCreateDirectoryIfMissing createParents filename =
    -- A directory computed from a bare file name, as fpDropFileName
    -- computes it, is "", which names no directory to create.
    if String.length filename == 0 then
        Task.succeed ()

    else
        onPath filename (FileSystem.makeDirectory { recursive = createParents })
            |> Task.map (\_ -> ())
            |> IO.crashOnError


{-| A task that gives the current working directory, and crashes the program if
it cannot be read (for instance after the directory was removed).
-}
dirGetCurrentDirectory : Task Never String
dirGetCurrentDirectory =
    currentDirectory
        |> IO.crashOnError


{-| The current working directory, with `/` separators, or `FileNotFound ""` when
it cannot be read: eco/system reports that as `Path.empty`.
-}
currentDirectory : Task IOError String
currentDirectory =
    IO.environment
        |> Task.andThen
            (\env ->
                FileSystem.currentWorkingDirectory
                    |> Task.andThen
                        (\cwd ->
                            if cwd == Path.empty then
                                Task.fail (IOErr.FileNotFound "")

                            else
                                Task.succeed (OsPath.fromPath env.platform cwd)
                        )
            )


{-| Returns the directory where the application called `filename` keeps its data
for the current user. The directory need not exist.

It is `<home>/.<filename>` on Linux and other POSIX systems,
`<home>/Library/Application Support/<filename>` on macOS, and
`<APPDATA>/<filename>` on Windows, or `<home>/<filename>` there when `APPDATA`
is not set. `<home>` is `FileSystem.homeDirectory`: `HOME` when it is set and
not empty, otherwise the user's home directory as the system records it.
Crashes the program, with the error `FileNotFound ""`, when there is no home
directory.

-}
dirGetAppUserDataDirectory : FilePath -> Task Never FilePath
dirGetAppUserDataDirectory filename =
    IO.environment
        |> Task.andThen
            (\env ->
                Task.map2
                    (\home vars ->
                        appDataDirFor env.platform vars (OsPath.fromPath env.platform home) filename
                    )
                    FileSystem.homeDirectory
                    System.environmentVariables
            )
        |> Task.andThen
            (\result ->
                case result of
                    Ok dir ->
                        Task.succeed dir

                    Err err ->
                        Task.fail err
            )
        |> IO.crashOnError


{-| The application data directory of `name` on `platform`, given the
environment variables and the home directory (`""` for none), as
`dirGetAppUserDataDirectory` describes it.
-}
appDataDirFor : System.Platform -> Dict String String -> String -> String -> Result IOError String
appDataDirFor platform vars home name =
    let
        appData : String
        appData =
            Dict.get "APPDATA" vars |> Maybe.withDefault ""
    in
    case platform of
        System.Win32 ->
            if appData /= "" then
                Ok (fpCombine (String.replace "\\" "/" appData) name)

            else if home /= "" && home /= "." then
                Ok (fpCombine home name)

            else
                Err (IOErr.FileNotFound "")

        System.Darwin ->
            if home /= "" && home /= "." then
                Ok (fpCombine home ("Library/Application Support/" ++ name))

            else
                Err (IOErr.FileNotFound "")

        _ ->
            if home /= "" && home /= "." then
                Ok (fpCombine home ("." ++ name))

            else
                Err (IOErr.FileNotFound "")


{-| Returns when the file at `filename` was last modified, and crashes the program
if that cannot be read.
-}
dirGetModificationTime : FilePath -> Task Never Time.Posix
dirGetModificationTime filename =
    onPath filename (FileSystem.metadata { resolveLink = True })
        |> Task.map .lastModified
        |> IO.crashOnError


{-| Sets the access and modification times of the file at `path` to now,
creating an empty file there first if there is none. Crashes the program if
that fails.
-}
dirTouch : FilePath -> Task Never ()
dirTouch path =
    Time.now
        |> Task.andThen
            (\now ->
                let
                    setTimes : Task IOError ()
                    setTimes =
                        onPath path (FileSystem.changeTimes { lastAccessed = now, lastModified = now, resolveLink = True })
                            |> Task.map (\_ -> ())
                in
                setTimes
                    |> Task.onError
                        (\err ->
                            case err of
                                IOErr.FileNotFound _ ->
                                    onPath path (FileSystem.appendToFile (Bytes.Encode.encode (Bytes.Encode.sequence [])))
                                        |> Task.andThen (\_ -> setTimes)

                                _ ->
                                    Task.fail err
                        )
            )
        |> IO.crashOnError


{-| Removes the file at `path`, and crashes the program if that fails.
-}
dirRemoveFile : FilePath -> Task Never ()
dirRemoveFile path =
    onPath path (FileSystem.remove { recursive = False })
        |> Task.map (\_ -> ())
        |> IO.crashOnError


{-| Removes the directory at `path` together with everything in it. Nothing at
`path` is not a failure; any other failure crashes the program.
-}
dirRemoveDirectoryRecursive : FilePath -> Task Never ()
dirRemoveDirectoryRecursive path =
    onPath path (FileSystem.remove { recursive = True })
        |> Task.map (\_ -> ())
        |> Task.onError
            (\err ->
                case err of
                    IOErr.FileNotFound _ ->
                        Task.succeed ()

                    _ ->
                        Task.fail err
            )
        |> IO.crashOnError


{-| Returns the size in bytes of the file at `path`. Crashes the program if it
cannot be read, so check that it exists first.
-}
dirGetFileSize : FilePath -> Task Never Int
dirGetFileSize path =
    onPath path (FileSystem.metadata { resolveLink = True })
        |> Task.map .byteSize
        |> IO.crashOnError


{-| Returns whether `path` names a directory, following symbolic links.
-}
dirDoesDirectoryExist : FilePath -> Task Never Bool
dirDoesDirectoryExist path =
    entityType path
        |> Task.map (\t -> t == Just FileSystem.Directory)


{-| Returns `path` made absolute, with its symbolic links resolved. A path that
cannot be resolved, as one that does not exist, is only made absolute, against
the current directory, and normalized. Crashes the program for an empty path,
and when the current directory is needed and cannot be read.
-}
dirCanonicalizePath : FilePath -> Task Never FilePath
dirCanonicalizePath path =
    IO.environment
        |> Task.andThen
            (\env ->
                onPath path FileSystem.realPath
                    |> Task.map (OsPath.fromPath env.platform)
                    |> Task.onError
                        (\_ ->
                            if String.isEmpty path then
                                Task.fail (IOErr.FileNotFound path)

                            else
                                currentDirectory
                                    |> Task.map (\cwd -> canonicalizeMissing env.platform cwd path)
                        )
            )
        |> IO.crashOnError


{-| The absolute, normalized form of `path`, which could not be resolved, against
the current directory `cwd`.
-}
canonicalizeMissing : System.Platform -> String -> FilePath -> FilePath
canonicalizeMissing platform cwd path =
    let
        absolute : FilePath
        absolute =
            if fpIsRelative path then
                fpCombine cwd path

            else
                path
    in
    OsPath.fromPath platform (OsPath.toPath absolute)


{-| Returns the names of the entries in the directory at `path`, sorted, and
crashes the program if it cannot be listed.
-}
dirListDirectory : FilePath -> Task Never (List FilePath)
dirListDirectory path =
    onPath path FileSystem.listDirectory
        |> Task.map (List.map (\entry -> Path.toPosixString entry.path))
        |> IO.crashOnError



-- System.Environment


{-| Returns the value of the environment variable `name`, or `Nothing` if it is not
set.
-}
envLookupEnv : String -> Task Never (Maybe String)
envLookupEnv name =
    System.environmentVariables
        |> Task.map (Dict.get name)


{-| A task that gives the program's name, which is always `"eco"`. Nothing is read
from the environment.
-}
envGetProgName : Task Never String
envGetProgName =
    Task.succeed "eco"


{-| A task that gives the command-line arguments, without the program's own
name (on the JavaScript backend, without the script).
-}
envGetArgs : Task Never (List String)
envGetArgs =
    IO.environment
        |> Task.map (\env -> List.drop 1 env.args)



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
while the MVar is empty. Crashes the program if the MVar was dropped.
-}
readMVar : Bytes.Decode.Decoder a -> MVar a -> Task Never a
readMVar decoder (MVar ref) =
    Eco.MVar.read decoder (Eco.MVar.MVar ref)
        |> Task.mapError IOErr.fromKernel
        |> IO.crashOnError


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
Waits while the MVar is empty. Crashes the program if the MVar was dropped.
-}
takeMVar : Bytes.Decode.Decoder a -> MVar a -> Task Never a
takeMVar decoder (MVar ref) =
    Eco.MVar.take decoder (Eco.MVar.MVar ref)
        |> Task.mapError IOErr.fromKernel
        |> IO.crashOnError


{-| Puts `value`, written with `encoder`, into the MVar. Waits while the MVar is
full. Crashes the program if the MVar was dropped.
-}
putMVar : (a -> Bytes.Encode.Encoder) -> MVar a -> a -> Task Never ()
putMVar encoder (MVar ref) value =
    Eco.MVar.put encoder (Eco.MVar.MVar ref) value
        |> Task.mapError IOErr.fromKernel
        |> IO.crashOnError


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
crash, with the `IOError` as `System.IOError.toString` renders it. Bytes left
over after the value are ignored.

-}
binaryDecodeFileOrFail : Bytes.Decode.Decoder a -> FilePath -> Task Never (Result ( Int, String ) a)
binaryDecodeFileOrFail decoder filename =
    onPath filename FileSystem.readFile
        |> Task.map
            (\bytes ->
                case Bytes.Decode.decode decoder bytes of
                    Just value ->
                        Ok value

                    Nothing ->
                        Err ( 0, "binary decode failed" )
            )
        |> Task.onError (\err -> Task.succeed (Err ( 0, IOErr.toString err )))


{-| Writes `value`, encoded with `toEncoder`, to the file at `path`, replacing it
in one step, and crashes the program if that fails.
-}
binaryEncodeFile : (a -> Bytes.Encode.Encoder) -> FilePath -> a -> Task Never ()
binaryEncodeFile toEncoder path value =
    writeBytesAtomic path (Bytes.Encode.encode (toEncoder value))
        |> IO.crashOnError


{-| Writes `bytes` to the file at `path` so that a reader sees either the old file
or the whole new one, never part of it.

The bytes go to a new temporary file next to it, `<path>.tmp-<n>`, created only
if nothing is there (so two processes never share one) and flushed to the
storage device, which is then moved over `path`. `n` starts from the program's
start time and goes up past any name already taken. If the move fails, the
temporary file is removed.

-}
writeBytesAtomic : FilePath -> Bytes -> Task IOError ()
writeBytesAtomic path bytes =
    IO.environment
        |> Task.andThen
            (\env ->
                Time.now
                    |> Task.andThen
                        (\now ->
                            writeBytesAtomicFrom path
                                bytes
                                (Time.posixToMillis env.startTime * 1000 + modBy 1000 (Time.posixToMillis now))
                                100
                        )
            )


{-| Tries `writeBytesAtomic` with the temporary name number `n`, and up to
`triesLeft - 1` higher numbers while the name is taken.
-}
writeBytesAtomicFrom : FilePath -> Bytes -> Int -> Int -> Task IOError ()
writeBytesAtomicFrom path bytes n triesLeft =
    let
        tmp : FilePath
        tmp =
            path ++ ".tmp-" ++ String.fromInt n
    in
    onPath tmp (FileSystem.writeFileWith { createNew = True, sync = True } bytes)
        |> Task.andThen
            (\_ ->
                onPath path (\target -> FileSystem.move target (OsPath.toPath tmp))
                    |> Task.map (\_ -> ())
                    |> Task.onError
                        (\err ->
                            onPath tmp (FileSystem.remove { recursive = False })
                                |> Task.onError (\_ -> Task.succeed (OsPath.toPath tmp))
                                |> Task.andThen (\_ -> Task.fail err)
                        )
            )
        |> Task.onError
            (\err ->
                case err of
                    IOErr.AlreadyExists _ ->
                        if triesLeft > 1 then
                            writeBytesAtomicFrom path bytes (n + 1) (triesLeft - 1)

                        else
                            Task.fail err

                    _ ->
                        Task.fail err
            )



-- System.Console.Haskeline
-- ====== NODE ======


{-| A task that gives the directory that holds the running program, standing in
for Node's `__dirname`: the directory of the executable on the native backend,
and of the compiled JavaScript file on the JavaScript backend (with symbolic
links resolved). Crashes the program, with the error `FileNotFound ""`, when the
program's path cannot be read.
-}
nodeGetDirname : Task Never String
nodeGetDirname =
    IO.environment
        |> Task.andThen
            (\env ->
                let
                    application : String
                    application =
                        OsPath.fromPath env.platform env.applicationPath
                in
                if application == "" || application == "." then
                    Task.fail (IOErr.FileNotFound "")

                else
                    Task.succeed (fpTakeDirectory application)
            )
        |> IO.crashOnError



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
