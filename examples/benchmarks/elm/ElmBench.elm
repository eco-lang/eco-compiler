port module ElmBench exposing (main)

{-| The workloads for the official Elm compiler, which cannot build `Bench.elm` (an eco/system
program). `run.mjs` sends `{ name, size }` on `toBench`; the worker runs that workload's `bench`
and sends back on `fromBench` whether its check passed (`null` for an unknown name). The names
are those of `Bench.elm`.

    elm make ElmBench.elm --optimize --output=../build/elm-bench.js

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
import Platform
import Sort
import SpectralNorm


port toBench : ({ name : String, size : Int } -> msg) -> Sub msg


port fromBench : Maybe Bool -> Cmd msg


bench : String -> Maybe (Int -> Bool)
bench name =
    case name of
        "fib" ->
            Just Fib.bench

        "binary-trees" ->
            Just BinaryTrees.bench

        "list-map" ->
            Just ListMap.bench

        "list-filter" ->
            Just ListFilter.bench

        "list-fold" ->
            Just ListFold.bench

        "dict" ->
            Just DictOps.bench

        "mandelbrot" ->
            Just Mandelbrot.bench

        "sort" ->
            Just Sort.bench

        "float-sum" ->
            Just FloatSum.bench

        "nbody" ->
            Just NBody.bench

        "spectral-norm" ->
            Just SpectralNorm.bench

        "fannkuch-redux" ->
            Just FannkuchRedux.bench

        "nsieve" ->
            Just NSieve.bench

        "merkletrees" ->
            Just MerkleTrees.bench

        "lru" ->
            Just Lru.bench

        "fasta" ->
            Just Fasta.bench

        "nqueens" ->
            Just NQueens.bench

        _ ->
            Nothing


main : Program () () { name : String, size : Int }
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update =
            \request model ->
                ( model
                , fromBench (Maybe.map (\run -> run request.size) (bench request.name))
                )
        , subscriptions = \_ -> toBench identity
        }
