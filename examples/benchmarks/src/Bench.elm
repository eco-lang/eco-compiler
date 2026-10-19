module Bench exposing (main)

{-| Compute benchmarks: pure computation, no IO, timed inside one running program.

    eco make src/Bench.elm --output=bench && ./bench
    ./bench fib sort                     # only these workloads
    ./bench mandelbrot=800               # a different size
    ./bench --warmup 10 --runs 25        # more samples
    ./bench --list                       # the workloads and what each one stresses
    ./bench --print nbody=1000           # a workload's standard benchmark output, untimed
    ./bench --json                       # the results as JSON (what run.mjs reads)
    ./bench --list --json                # the workloads as JSON

Each workload is a module exposing `bench : Int -> Bool`: it does its work at the given size and
checks its own result, giving `True` if it is right. How each one checks is in its module's
documentation: a closed form or an independent recomputation where there is one, otherwise
known answers for the sizes that have them. It runs `--warmup` times untimed, then `--runs`
times timed (the check included); the table shows the median and fastest run in milliseconds
(lower is better; `Time.now` has 1 ms resolution). The program exits with status 1 if any run of
any workload fails its check.

The default sizes make every workload take at least 200 ms on the official Elm compiler's
JavaScript, each run in a process of its own (as `run.mjs` does), so that timer resolution and
start-up costs stay small next to the work.

All the chosen workloads run one after another in this one program, so a workload's timings can
depend on what ran before it (heap state, for one). `run.mjs` runs each workload in a program
of its own.

The first nine workloads are those of the alm compute benchmarks. The next seven are standard
benchmarks from the Computer Language Benchmarks Game and the Programming Language Benchmarks
suite: `--print` shows each one's exact text output, for comparing with the suite's reference
files. n-queens counts the solutions of the n-queens puzzle.

-}

import Adler32
import ArrayBuild
import Base64
import BinaryFormat
import BinaryTrees
import Brainfuck
import BytesCodec
import Crc32
import CsvParser
import CsvSplit
import DictAlgebra
import DictKeys
import DictOps
import Dijkstra
import ExprParser
import FannkuchRedux
import Fasta
import Fib
import FloatSum
import FloodFill
import FloydWarshall
import Json.Encode as Encode
import JsonCoords
import JsonDecoders
import JsonDict
import JsonEncode
import JsonParser
import JsonShapes
import KNucleotide
import Levenshtein
import Lexer
import Life
import ListFilter
import ListFold
import ListMap
import Lru
import Mandelbrot
import MatMul
import MerkleTrees
import NBody
import NQueens
import NSieve
import NSieveBits
import Popcount
import Prng
import RevComp
import SExpr
import SetAlgebra
import SetDistinct
import Sha256
import ShuffleSort
import Sort
import SpectralNorm
import Stream
import StringBuild
import Sudoku
import System
import Task exposing (Task)
import Time
import UnicodeString
import Utf8Bytes
import WordFreq



-- WORKLOADS


type alias Workload =
    { name : String
    , about : String
    , bench : Int -> Bool
    , size : Int
    , output : Maybe (Int -> String)
    }


workloads : List Workload
workloads =
    [ Workload "fib" "naive recursion: calls and integer arithmetic" Fib.bench 38 Nothing
    , Workload "binary-trees" "allocation and GC churn: trees of depth 14, size times" BinaryTrees.bench 1100 Nothing
    , Workload "list-map" "range, map, sum" ListMap.bench 2000000 Nothing
    , Workload "list-filter" "range, filter, sum" ListFilter.bench 2000000 Nothing
    , Workload "list-fold" "range, fold" ListFold.bench 3000000 Nothing
    , Workload "dict" "Dict build, lookup and fold" DictOps.bench 350000 Nothing
    , Workload "mandelbrot" "float arithmetic on a size x size grid" Mandelbrot.bench 2200 Nothing
    , Workload "sort" "List.sort of pseudo-random Ints" Sort.bench 600000 Nothing
    , Workload "float-sum" "List Float map and fold" FloatSum.bench 1000000 Nothing
    , Workload "nbody" "planet simulation: Float records, size steps" NBody.bench 100000 (Just NBody.output)
    , Workload "spectral-norm" "power method on a size x size matrix: Float loops" SpectralNorm.bench 1000 (Just SpectralNorm.output)
    , Workload "fannkuch-redux" "pancake flips over every permutation of size items" FannkuchRedux.bench 9 (Just FannkuchRedux.output)
    , Workload "nsieve" "three sieves of Eratosthenes on Array Bool" NSieve.bench 5 (Just NSieve.output)
    , Workload "merkletrees" "hashed binary trees of depth up to size" MerkleTrees.bench 16 (Just MerkleTrees.output)
    , Workload "lru" "100-entry LRU cache on Dict, size rounds" Lru.bench 120000 (Just Lru.output)
    , Workload "fasta" "generate 10 x size DNA characters as text" Fasta.bench 350000 (Just Fasta.output)
    , Workload "nqueens" "count the solutions on a size x size board" NQueens.bench 12 Nothing
    , Workload "k-nucleotide" "Dict String Int counts of k-mers in fasta's output" KNucleotide.bench 9000 (Just KNucleotide.output)
    , Workload "life" "Game of Life from an R-pentomino: Set and Dict of (Int, Int)" Life.bench 700 Nothing
    , Workload "brainfuck" "interpreter on Array Int, size runs of a 965k-step program" Brainfuck.bench 4 (Just Brainfuck.output)
    , Workload "revcomp" "reverse-complement fasta's output: String.reverse and map" RevComp.bench 70000 (Just RevComp.output)
    , Workload "sha256" "SHA-256 hash chain of size digests: Bitwise on 32-bit words" Sha256.bench 5000 (Just Sha256.output)
    , Workload "bytes-static" "encode and decode size records, decoder known at compile time" BytesCodec.benchStatic 500000 Nothing
    , Workload "bytes-dynamic" "the same, decoder chosen at run time" BytesCodec.benchDynamic 500000 Nothing
    , Workload "json" "encode, decode and average size coordinate objects" JsonCoords.bench 90000 Nothing
    , Workload "expr-parser" "elm/parser: parse and evaluate size expressions of 1,000 numbers" ExprParser.bench 160 Nothing
    , Workload "dijkstra" "shortest paths on a size x size grid: Dict of (Int, Int)" Dijkstra.bench 240 Nothing
    , Workload "word-freq" "word counts of size words: String.words and Dict String Int" WordFreq.bench 220000 Nothing
    , Workload "sudoku" "solve size puzzles: Set Int candidates, propagation and search" Sudoku.bench 340 Nothing
    , Workload "flood-fill" "flood fill of a size x size grid: Set (Int, Int)" FloodFill.bench 300 Nothing
    , Workload "matmul" "multiply two size x size Array (Array Float)" MatMul.bench 165 Nothing
    , Workload "floyd-warshall" "all-pairs shortest paths on a flat Array Int, size nodes" FloydWarshall.bench 130 Nothing
    , Workload "levenshtein" "edit distance of size pairs of ~300-character strings" Levenshtein.bench 70 Nothing
    , Workload "unicode-string" "String functions on size words of non-ASCII text" UnicodeString.bench 52000 Nothing
    , Workload "nsieve-bits" "nsieve with flags packed 32 to an Int: Bitwise" NSieveBits.bench 5 Nothing
    , Workload "crc32" "CRC-32 of size bytes: Bitwise and a table lookup" Crc32.bench 1000000 Nothing
    , Workload "base64" "Base64 encode and decode size bytes" Base64.bench 190000 Nothing
    , Workload "utf8-bytes" "Encode.string and Decode.string of size code points" Utf8Bytes.bench 500000 Nothing
    , Workload "json-shapes" "canada, twitter and citm-shaped JSON round trips, scaled by size" JsonShapes.bench 6000 Nothing
    , Workload "json-decoders" "andMap, andThen, oneOf and lazy decoders over size items" JsonDecoders.bench 35000 Nothing
    , Workload "json-parser" "elm/parser JSON parser on json's document of size objects" JsonParser.bench 10000 Nothing
    , Workload "sexpr" "read and evaluate size Lisp programs with elm/parser" SExpr.bench 230 Nothing
    , Workload "dict-algebra" "Dict union, intersect, diff and merge over size keys" DictAlgebra.bench 56000 Nothing
    , Workload "dict-int" "Dict build and lookup of size Int keys" DictKeys.benchInt 200000 Nothing
    , Workload "dict-string" "the same with String keys" DictKeys.benchString 130000 Nothing
    , Workload "dict-tuple" "the same with (Int, Int) keys" DictKeys.benchTuple 150000 Nothing
    , Workload "set-algebra" "Set union, intersect, diff and filter over size members" SetAlgebra.bench 70000 Nothing
    , Workload "set-distinct" "Set.fromList of size values, mostly duplicates" SetDistinct.bench 230000 Nothing
    , Workload "shuffle-sort" "Fisher-Yates shuffle of an Array of size, then List.sort" ShuffleSort.bench 210000 Nothing
    , Workload "array-build" "Array.push size elements, then slice and append rounds" ArrayBuild.bench 140000 Nothing
    , Workload "csv-split" "String.split CSV: size documents of 400 rows" CsvSplit.bench 800 Nothing
    , Workload "string-append" "build text from size pieces with ++" StringBuild.benchAppend 300000 Nothing
    , Workload "string-join" "the same with String.join" StringBuild.benchJoin 300000 Nothing
    , Workload "string-concat" "the same with String.concat" StringBuild.benchConcat 250000 Nothing
    , Workload "prng" "xorshift32 and xorshift128, size steps: Bitwise" Prng.bench 2000000 Nothing
    , Workload "popcount" "popcount, trailing zeros and bit reversal over 0 .. size-1" Popcount.bench 1200000 Nothing
    , Workload "binary-format" "encode and decode a chunked binary file of size chunks" BinaryFormat.bench 13000 Nothing
    , Workload "adler32" "Adler-32 of size bytes, read with Decode.loop" Adler32.bench 1000000 Nothing
    , Workload "json-dict" "Decode.dict and keyValuePairs over an object of size keys" JsonDict.bench 43000 Nothing
    , Workload "json-encode" "Encode.encode 0 and 4 of size nested objects" JsonEncode.bench 7000 Nothing
    , Workload "csv-parser" "elm/parser CSV: size documents of 400 rows" CsvParser.bench 340 Nothing
    , Workload "lexer" "elm/parser lexer: size documents of 600 tokens" Lexer.bench 125 Nothing
    ]



-- OPTIONS


type alias Options =
    { warmup : Int
    , runs : Int
    , list : Bool
    , print : Bool
    , json : Bool
    , selected : List ( Workload, Int )
    }


parseArgs : List String -> Options -> Result String Options
parseArgs args options =
    case args of
        [] ->
            Ok options

        "--list" :: rest ->
            parseArgs rest { options | list = True }

        "--print" :: rest ->
            parseArgs rest { options | print = True }

        "--json" :: rest ->
            parseArgs rest { options | json = True }

        "--warmup" :: n :: rest ->
            count "--warmup" 0 n |> Result.andThen (\w -> parseArgs rest { options | warmup = w })

        "--runs" :: n :: rest ->
            count "--runs" 1 n |> Result.andThen (\r -> parseArgs rest { options | runs = r })

        arg :: rest ->
            if String.startsWith "-" arg then
                Err ("unknown option " ++ arg)

            else
                selection arg |> Result.andThen (\s -> parseArgs rest { options | selected = options.selected ++ [ s ] })


{-| `NAME` or `NAME=SIZE`.
-}
selection : String -> Result String ( Workload, Int )
selection arg =
    let
        ( name, size ) =
            case String.split "=" arg of
                [ n, s ] ->
                    ( n, Just s )

                _ ->
                    ( arg, Nothing )
    in
    case List.filter (\w -> w.name == String.toLower name) workloads of
        w :: _ ->
            case size of
                Nothing ->
                    Ok ( w, w.size )

                Just s ->
                    count name 1 s |> Result.map (\n -> ( w, n ))

        [] ->
            Err ("unknown workload " ++ name ++ " (see --list)")


count : String -> Int -> String -> Result String Int
count what least s =
    case String.toInt s of
        Just n ->
            if n >= least then
                Ok n

            else
                Err (what ++ " must be at least " ++ String.fromInt least)

        Nothing ->
            Err (what ++ " needs a number, not " ++ s)



-- TIMING


{-| Run the workload once between two clock reads, giving the elapsed milliseconds and whether
its check passed.
-}
timeOnce : (Int -> Bool) -> Int -> Task x ( Int, Bool )
timeOnce bench size =
    Time.now
        |> Task.andThen
            (\start ->
                let
                    ok =
                        bench size

                    -- Branching on the result makes the second clock read wait for it.
                    stop =
                        if ok then
                            Time.now

                        else
                            Task.map identity Time.now
                in
                stop |> Task.map (\end -> ( Time.posixToMillis end - Time.posixToMillis start, ok ))
            )


type alias Measurement =
    { ok : Bool
    , median : Float
    , fastest : Int
    }


measure : Options -> Workload -> Int -> Task x Measurement
measure options w size =
    Task.sequence (List.repeat options.warmup (timeOnce w.bench size))
        |> Task.andThen (\_ -> Task.sequence (List.repeat options.runs (timeOnce w.bench size)))
        |> Task.map
            (\samples ->
                let
                    times =
                        List.sort (List.map Tuple.first samples)
                in
                { ok = List.all Tuple.second samples
                , median = median times
                , fastest = List.head times |> Maybe.withDefault 0
                }
            )


median : List Int -> Float
median sorted =
    let
        n =
            List.length sorted

        at i =
            List.drop i sorted |> List.head |> Maybe.withDefault 0 |> toFloat
    in
    if modBy 2 n == 1 then
        at (n // 2)

    else
        (at (n // 2 - 1) + at (n // 2)) / 2



-- OUTPUT


row : String -> String -> String -> String -> String -> String
row name size check med fastest =
    String.padRight 14 ' ' name
        ++ String.padLeft 9 ' ' size
        ++ String.padLeft 7 ' ' check
        ++ String.padLeft 11 ' ' med
        ++ String.padLeft 9 ' ' fastest


type alias Outcome =
    { workload : Workload
    , size : Int
    , measurement : Measurement
    }


{-| Run one workload; in table mode, print its row as soon as it is done.
-}
runOne : System.Environment -> Options -> ( Workload, Int ) -> Task x Outcome
runOne env options ( w, size ) =
    measure options w size
        |> Task.andThen
            (\m ->
                let
                    outcome =
                        Outcome w size m
                in
                if options.json then
                    Task.succeed outcome

                else
                    Stream.logLine (row w.name (String.fromInt size) (checkText m.ok) (String.fromFloat m.median) (String.fromInt m.fastest)) env.stdout
                        |> Task.map (\_ -> outcome)
            )


checkText : Bool -> String
checkText ok =
    if ok then
        "ok"

    else
        "WRONG"


encodeOutcomes : Options -> List Outcome -> String
encodeOutcomes options outcomes =
    let
        encodeOutcome o =
            Encode.object
                [ ( "name", Encode.string o.workload.name )
                , ( "size", Encode.int o.size )
                , ( "ok", Encode.bool o.measurement.ok )
                , ( "medianMs", Encode.float o.measurement.median )
                , ( "fastestMs", Encode.int o.measurement.fastest )
                ]
    in
    Encode.encode 2
        (Encode.object
            [ ( "warmup", Encode.int options.warmup )
            , ( "runs", Encode.int options.runs )
            , ( "workloads", Encode.list encodeOutcome outcomes )
            ]
        )


runAll : System.Environment -> Options -> Task x ()
runAll env options =
    let
        chosen =
            if List.isEmpty options.selected then
                List.map (\w -> ( w, w.size )) workloads

            else
                options.selected

        step one doneSoFar =
            doneSoFar |> Task.andThen (\done -> runOne env options one |> Task.map (\o -> o :: done))

        header =
            if options.json then
                Task.succeed ()

            else
                Stream.logLine ("warmup " ++ String.fromInt options.warmup ++ ", runs " ++ String.fromInt options.runs ++ "; times in ms, lower is better\n") env.stdout
                    |> Task.andThen (\_ -> Stream.logLine (row "workload" "size" "check" "median" "fastest") env.stdout)
    in
    header
        |> Task.andThen (\_ -> List.foldl step (Task.succeed []) chosen)
        |> Task.map List.reverse
        |> Task.andThen
            (\outcomes ->
                let
                    wrong =
                        List.length (List.filter (\o -> not o.measurement.ok) outcomes)

                    report =
                        if options.json then
                            Stream.logLine (encodeOutcomes options outcomes) env.stdout

                        else
                            Task.succeed ()
                in
                report
                    |> Task.andThen
                        (\_ ->
                            if wrong > 0 then
                                Stream.logLine (String.fromInt wrong ++ " workload(s) gave a wrong result") env.stderr
                                    |> Task.andThen (\_ -> System.setExitCode 1)

                            else
                                Task.succeed ()
                        )
            )


listWorkloads : System.Environment -> Options -> Task x ()
listWorkloads env options =
    if options.json then
        Encode.object
            [ ( "workloads"
              , Encode.list
                    (\w -> Encode.object [ ( "name", Encode.string w.name ), ( "size", Encode.int w.size ), ( "about", Encode.string w.about ) ])
                    workloads
              )
            ]
            |> Encode.encode 2
            |> (\json -> Stream.logLine json env.stdout)

    else
        workloads
            |> List.map (\w -> String.padRight 14 ' ' w.name ++ String.padLeft 9 ' ' (String.fromInt w.size) ++ "  " ++ w.about)
            |> String.join "\n"
            |> (\listing -> Stream.logLine listing env.stdout)



printOutputs : System.Environment -> Options -> Task x ()
printOutputs env options =
    case options.selected of
        [] ->
            Stream.logLine "bench: --print needs a workload" env.stderr
                |> Task.andThen (\_ -> System.setExitCode 2)

        selected ->
            selected
                |> List.map
                    (\( w, size ) ->
                        case w.output of
                            Just output ->
                                Stream.logString (output size) env.stdout

                            Nothing ->
                                Stream.logLine (checkText (w.bench size)) env.stdout
                    )
                |> Task.sequence
                |> Task.map (\_ -> ())



-- MAIN


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram
        (\env ->
            case parseArgs (List.drop 1 env.args) (Options 3 11 False False False []) of
                Ok options ->
                    if options.list then
                        listWorkloads env options

                    else if options.print then
                        printOutputs env options

                    else
                        runAll env options

                Err problem ->
                    Stream.logLine ("bench: " ++ problem) env.stderr
                        |> Task.andThen (\_ -> System.setExitCode 2)
        )
