port module ElmBench exposing (main)

{-| The workloads for the official Elm compiler, which cannot build `Bench.elm` (an eco/system
program). `run.mjs` sends `{ name, size }` on `toBench`; the worker runs that workload's `bench`
and sends back on `fromBench` whether its check passed (`null` for an unknown name). The names
are those of `Bench.elm`.

    elm make ElmBench.elm --optimize --output=../build/elm-bench.js

-}

import Base64
import BinaryTrees
import Brainfuck
import BytesCodec
import Crc32
import DictOps
import Dijkstra
import ExprParser
import FannkuchRedux
import Fasta
import Fib
import FloatSum
import FloodFill
import FloydWarshall
import JsonCoords
import JsonDecoders
import JsonParser
import JsonShapes
import KNucleotide
import Levenshtein
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
import Platform
import RevComp
import SExpr
import Sha256
import Sort
import SpectralNorm
import Sudoku
import UnicodeString
import Utf8Bytes
import WordFreq


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

        "k-nucleotide" ->
            Just KNucleotide.bench

        "life" ->
            Just Life.bench

        "brainfuck" ->
            Just Brainfuck.bench

        "revcomp" ->
            Just RevComp.bench

        "sha256" ->
            Just Sha256.bench

        "bytes-static" ->
            Just BytesCodec.benchStatic

        "bytes-dynamic" ->
            Just BytesCodec.benchDynamic

        "json" ->
            Just JsonCoords.bench

        "expr-parser" ->
            Just ExprParser.bench

        "dijkstra" ->
            Just Dijkstra.bench

        "word-freq" ->
            Just WordFreq.bench

        "sudoku" ->
            Just Sudoku.bench

        "flood-fill" ->
            Just FloodFill.bench

        "matmul" ->
            Just MatMul.bench

        "floyd-warshall" ->
            Just FloydWarshall.bench

        "levenshtein" ->
            Just Levenshtein.bench

        "unicode-string" ->
            Just UnicodeString.bench

        "nsieve-bits" ->
            Just NSieveBits.bench

        "crc32" ->
            Just Crc32.bench

        "base64" ->
            Just Base64.bench

        "utf8-bytes" ->
            Just Utf8Bytes.bench

        "json-shapes" ->
            Just JsonShapes.bench

        "json-decoders" ->
            Just JsonDecoders.bench

        "json-parser" ->
            Just JsonParser.bench

        "sexpr" ->
            Just SExpr.bench

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
