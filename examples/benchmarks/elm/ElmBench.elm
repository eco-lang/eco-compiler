port module ElmBench exposing (main)

{-| The workloads for the official Elm compiler, which cannot build `Bench.elm` (an eco/system
program). `run.mjs` sends `{ name, size }` on `toBench`; the worker runs that workload's `bench`
and sends back on `fromBench` whether its check passed (`null` for an unknown name). The names
are those of `Bench.elm`.

    elm make ElmBench.elm --optimize --output=../build/elm-bench.js

-}

import Adler32
import ArrayBuild
import Base64
import BinaryFormat
import BinaryTrees
import Brainfuck
import BytesCodec
import BytesFrame
import BytesRows
import Crc32
import CsvParser
import CsvSplit
import DecodedSnapshot
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
import CtorLoops
import HotLambda
import JsonCoords
import JsonDecoders
import JsonDict
import JsonEncode
import JsonParser
import JsonShapes
import KNucleotide
import KernelCallbacks
import Levenshtein
import Lexer
import Life
import ListFilter
import ListFold
import ListMap
import ListOrigin
import Lru
import Mandelbrot
import MatMul
import MerkleTrees
import NBody
import NQueens
import NSieve
import NSieveBits
import PairKeys
import Platform
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
import StringBuild
import StringCallbacks
import StringCompare
import Sudoku
import TypeKeys
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

        "dict-algebra" ->
            Just DictAlgebra.bench

        "dict-int" ->
            Just DictKeys.benchInt

        "dict-string" ->
            Just DictKeys.benchString

        "dict-tuple" ->
            Just DictKeys.benchTuple

        "set-algebra" ->
            Just SetAlgebra.bench

        "set-distinct" ->
            Just SetDistinct.bench

        "shuffle-sort" ->
            Just ShuffleSort.bench

        "array-build" ->
            Just ArrayBuild.bench

        "csv-split" ->
            Just CsvSplit.bench

        "string-append" ->
            Just StringBuild.benchAppend

        "string-join" ->
            Just StringBuild.benchJoin

        "string-concat" ->
            Just StringBuild.benchConcat

        "prng" ->
            Just Prng.bench

        "popcount" ->
            Just Popcount.bench

        "binary-format" ->
            Just BinaryFormat.bench

        "adler32" ->
            Just Adler32.bench

        "json-dict" ->
            Just JsonDict.bench

        "json-encode" ->
            Just JsonEncode.bench

        "csv-parser" ->
            Just CsvParser.bench

        "lexer" ->
            Just Lexer.bench

        "list-walk-map" ->
            Just ListOrigin.benchMap

        "list-walk-take" ->
            Just ListOrigin.benchTake

        "bytes-f32-rows" ->
            Just BytesRows.benchF32

        "bytes-u8-rows" ->
            Just BytesRows.benchU8

        "decoded-snapshot" ->
            Just DecodedSnapshot.bench

        "bytes-frame" ->
            Just BytesFrame.bench

        "bytes-frame-prefixed" ->
            Just BytesFrame.benchPrefixed

        "string-callbacks" ->
            Just StringCallbacks.bench

        "dict-char-pairs" ->
            Just PairKeys.benchCharPairs

        "set-float-pairs" ->
            Just PairKeys.benchFloatPairs

        "kernel-callbacks" ->
            Just KernelCallbacks.bench

        "hot-lambda" ->
            Just HotLambda.bench

        "ctor-wrapper" ->
            Just CtorLoops.benchWrapper

        "ctor-maybe" ->
            Just CtorLoops.benchMaybe

        "ctor-step" ->
            Just CtorLoops.benchStep

        "ctor-tokens" ->
            Just CtorLoops.benchTokens

        "ctor-sret" ->
            Just CtorLoops.benchSret

        "ctor-known" ->
            Just CtorLoops.benchKnown

        "dict-union-small" ->
            Just DictAlgebra.benchUnionSmall

        "dict-longkey" ->
            Just TypeKeys.benchDictLongKey

        "intern-cached-hash" ->
            Just TypeKeys.benchInternCached

        "intern-rehash" ->
            Just TypeKeys.benchInternRehash

        "string-eq-prefix" ->
            Just StringCompare.benchEqPrefix

        "string-eq-same" ->
            Just StringCompare.benchEqSame

        "string-compare-prefix" ->
            Just StringCompare.benchComparePrefix

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
