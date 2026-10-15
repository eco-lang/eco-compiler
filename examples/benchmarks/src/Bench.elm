module Bench exposing (main)

{-| Compute benchmarks: pure computation, no IO, timed inside one running program.

    eco make src/Bench.elm --output=bench && ./bench
    ./bench fib sort                     # only these workloads
    ./bench mandelbrot=800               # a different size (no checksum check)
    ./bench --warmup 10 --runs 25        # more samples
    ./bench --list                       # the workloads and what each one stresses
    ./bench --print nbody=1000           # a workload's standard benchmark output, untimed

Each workload is a module exposing `bench : Int -> Int`. It runs `--warmup` times untimed, then
`--runs` times timed; the table shows the median and fastest run in milliseconds (lower is
better; `Time.now` has 1 ms resolution). At its default size each result is checked against a
known checksum, and the program exits with status 1 if any differs.

The first nine workloads are those of the alm compute benchmarks. The next seven are standard
benchmarks from the Computer Language Benchmarks Game and the Programming Language Benchmarks
suite: each builds its benchmark's exact text output as a `String` and returns a checksum of it,
and `--print` shows that output for comparing with the suite's reference files. n-queens counts
the solutions of the n-queens puzzle.

-}

import BinaryTrees
import DictOps
import FannkuchRedux
import Fasta
import Fib
import FloatSum
import ListFilter
import ListFold
import ListMap
import Lru
import Mandelbrot
import MerkleTrees
import NBody
import NQueens
import NSieve
import Sort
import SpectralNorm
import Stream.Log
import System
import Task exposing (Task)
import Time



-- WORKLOADS


type alias Workload =
    { name : String
    , about : String
    , bench : Int -> Int
    , size : Int
    , expected : Int
    , output : Maybe (Int -> String)
    }


workloads : List Workload
workloads =
    [ Workload "fib" "naive recursion: calls and integer arithmetic" Fib.bench 35 9227465 Nothing
    , Workload "binary-trees" "allocation and GC churn: trees of depth 14, size times" BinaryTrees.bench 60 1966020 Nothing
    , Workload "list-map" "range, map, sum" ListMap.bench 1000000 1000001000000 Nothing
    , Workload "list-filter" "range, filter, sum" ListFilter.bench 1000000 166666833333 Nothing
    , Workload "list-fold" "range, fold" ListFold.bench 1000000 496500 Nothing
    , Workload "dict" "Dict build, lookup and fold" DictOps.bench 100000 995019750 Nothing
    , Workload "mandelbrot" "float arithmetic on a size x size grid" Mandelbrot.bench 400 27551 Nothing
    , Workload "sort" "List.sort of pseudo-random Ints" Sort.bench 100000 824930369 Nothing
    , Workload "float-sum" "List Float map and fold" FloatSum.bench 1000000 750001875001693696 Nothing
    , Workload "nbody" "planet simulation: Float records, size steps" NBody.bench 100000 98307606 (Just NBody.output)
    , Workload "spectral-norm" "power method on a size x size matrix: Float loops" SpectralNorm.bench 1000 763535929 (Just SpectralNorm.output)
    , Workload "fannkuch-redux" "pancake flips over every permutation of size items" FannkuchRedux.bench 8 729083194 (Just FannkuchRedux.output)
    , Workload "nsieve" "three sieves of Eratosthenes on Array Bool" NSieve.bench 4 195093995 (Just NSieve.output)
    , Workload "merkletrees" "hashed binary trees of depth up to size" MerkleTrees.bench 15 452584198 (Just MerkleTrees.output)
    , Workload "lru" "100-entry LRU cache on Dict, size rounds" Lru.bench 100000 512051825 (Just Lru.output)
    , Workload "fasta" "generate 10 x size DNA characters as text" Fasta.bench 50000 112894163 (Just Fasta.output)
    , Workload "nqueens" "count the solutions on a size x size board" NQueens.bench 11 2680 Nothing
    ]



-- OPTIONS


type alias Options =
    { warmup : Int
    , runs : Int
    , list : Bool
    , print : Bool
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


{-| Run the workload once between two clock reads, giving the elapsed milliseconds and the
result.
-}
timeOnce : (Int -> Int) -> Int -> Task x ( Int, Int )
timeOnce bench size =
    Time.now
        |> Task.andThen
            (\start ->
                let
                    result =
                        bench size

                    -- Branching on the result makes the second clock read wait for it.
                    stop =
                        if result == -1 then
                            Task.succeed start

                        else
                            Time.now
                in
                stop |> Task.map (\end -> ( Time.posixToMillis end - Time.posixToMillis start, result ))
            )


type alias Measurement =
    { result : Int
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
                { result = List.head samples |> Maybe.map Tuple.second |> Maybe.withDefault 0
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


row : String -> String -> String -> String -> String -> String -> String
row name size result check med fastest =
    String.padRight 14 ' ' name
        ++ String.padLeft 9 ' ' size
        ++ String.padLeft 20 ' ' result
        ++ String.padLeft 7 ' ' check
        ++ String.padLeft 11 ' ' med
        ++ String.padLeft 9 ' ' fastest


{-| Run one workload and print its row; succeeds with whether its checksum was wrong.
-}
runOne : System.Environment -> Options -> ( Workload, Int ) -> Task x Bool
runOne env options ( w, size ) =
    measure options w size
        |> Task.andThen
            (\m ->
                let
                    ( check, wrong ) =
                        if size /= w.size then
                            ( "-", False )

                        else if m.result == w.expected then
                            ( "ok", False )

                        else
                            ( "WRONG", True )
                in
                Stream.Log.line env.stdout
                    (row w.name (String.fromInt size) (String.fromInt m.result) check (String.fromFloat m.median) (String.fromInt m.fastest))
                    |> Task.map (\_ -> wrong)
            )


runAll : System.Environment -> Options -> Task x ()
runAll env options =
    let
        chosen =
            if List.isEmpty options.selected then
                List.map (\w -> ( w, w.size )) workloads

            else
                options.selected

        step one wrongSoFar =
            wrongSoFar |> Task.andThen (\n -> runOne env options one |> Task.map (\wrong -> if wrong then n + 1 else n))
    in
    Stream.Log.line env.stdout
        ("warmup " ++ String.fromInt options.warmup ++ ", runs " ++ String.fromInt options.runs ++ "; times in ms, lower is better\n")
        |> Task.andThen (\_ -> Stream.Log.line env.stdout (row "workload" "size" "result" "check" "median" "fastest"))
        |> Task.andThen (\_ -> List.foldl step (Task.succeed 0) chosen)
        |> Task.andThen
            (\wrong ->
                if wrong > 0 then
                    Stream.Log.line env.stderr (String.fromInt wrong ++ " workload(s) gave a wrong result")
                        |> Task.andThen (\_ -> System.setExitCode 1)

                else
                    Task.succeed ()
            )


listWorkloads : System.Environment -> Task x ()
listWorkloads env =
    workloads
        |> List.map (\w -> String.padRight 14 ' ' w.name ++ String.padLeft 9 ' ' (String.fromInt w.size) ++ "  " ++ w.about)
        |> String.join "\n"
        |> Stream.Log.line env.stdout



printOutputs : System.Environment -> Options -> Task x ()
printOutputs env options =
    case options.selected of
        [] ->
            Stream.Log.line env.stderr "bench: --print needs a workload"
                |> Task.andThen (\_ -> System.setExitCode 2)

        selected ->
            selected
                |> List.map
                    (\( w, size ) ->
                        case w.output of
                            Just output ->
                                Stream.Log.string env.stdout (output size)

                            Nothing ->
                                Stream.Log.line env.stdout (String.fromInt (w.bench size))
                    )
                |> Task.sequence
                |> Task.map (\_ -> ())



-- MAIN


main : System.SimpleProgram msg
main =
    System.defineSimpleProgram
        (\env ->
            System.endSimpleProgram
                (case parseArgs (List.drop 1 env.args) (Options 3 11 False False []) of
                    Ok options ->
                        if options.list then
                            listWorkloads env

                        else if options.print then
                            printOutputs env options

                        else
                            runAll env options

                    Err problem ->
                        Stream.Log.line env.stderr ("bench: " ++ problem)
                            |> Task.andThen (\_ -> System.setExitCode 2)
                )
        )
