module SourceIR.BytesFusionCases exposing (expectSuite)

{-| Small programs that use the elm/bytes API, for the compiler's stage tests,
so that a stage which mishandles one of these programs fails a test instead of
going unnoticed, if that stage is one the caller's `expectFn` checks.

This module only builds the programs. `expectSuite` takes the check from its
caller as `expectFn`, which decides which stages a program is compiled through
and what counts as passing, so what is established depends on the caller.

The cases are named for _bytes fusion_: the MLIR back end's handling of a call
that encodes with an elm/bytes encoder or decodes with an elm/bytes decoder,
which it tries to compile from the structure of that encoder or decoder
(`Compiler.Generate.MLIR.Expr`, `Compiler.Generate.MLIR.BytesFusion.Reify`).
Only a call to `encode` or `decode` is such a call; most cases below build a
bare encoder or decoder value instead.

Every program comes from `Compiler.AST.SourceBuilder.makeKernelModule`: a module
`Test` with one top-level value, `testValue`, and no annotation. Its imports
include `Bytes`, `Bytes.Encode` and `Bytes.Decode`, each opened with
`exposing (..)`, which is why `BE` and `LE` appear unqualified. Below,
"the program `e`" means that module with `testValue = e`. All cases run as one
elm-test test through `Compiler.BulkCheck.bulkCheck`, so only the first failing
case is reported.

The cases, in the order they run:

  - Encoders, referenced through the imported `Bytes.Encode`:
    `unsignedInt8 42`, `signedInt8 -1`, `unsignedInt16 BE 1000`,
    `unsignedInt32 LE 100000`, `float32 BE 3.14`, `float64 LE 2.718281828`,
    `string "hello"`, and `sequence` of three `unsignedInt8` encoders. Then
    `encode` applied to `unsignedInt8 255`, and `encode` applied to a
    `sequence` of an `unsignedInt8`, an `unsignedInt16 BE` and a
    `float64 LE`.
  - Decoders, referenced through the imported `Bytes.Decode`:
    `unsignedInt8`, `signedInt8`, `unsignedInt16 BE`, `unsignedInt32 LE`,
    `float32 BE`, `float64 LE`, `string 5`, `succeed 42`, `map` of an
    identity lambda over `unsignedInt8`, `map2` of a lambda returning its first
    argument over two `unsignedInt8` decoders, and `andThen` of a lambda that
    `succeed`s with the decoded value, over `unsignedInt8`.
  - Kernel calls, written as references qualified with `Elm.Kernel.Bytes`,
    which is not imported: `encode` of `unsignedInt8 42`, `encode` of a
    `sequence` of two `unsignedInt8` encoders, and `decode` of the
    `unsignedInt8` decoder against the `encode` of `unsignedInt8 99`. The
    canonicalizer reads an `Elm.Kernel.`-qualified name as a kernel reference
    only in a module of a kernel package (`Compiler.Elm.Package.isKernel`);
    elsewhere it is a name that is not found.

Among what is not tested: a call to `Bytes.Decode.decode`, the `signedInt16`,
`signedInt32` and `bytes` encoders and decoders, and the decoders `fail`,
`loop`, `map3` and the later `map`s.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , ctorExpr
        , floatExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeKernelModule
        , pVar
        , qualVarExpr
        , strExpr
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named "Bytes fusion " followed by `condStr`, that gives
`expectFn` the programs in this module in order, stopping at the first one it
rejects, and fails with a message that begins with that case's label.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Bytes fusion " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case in this module, encoders first, then decoders, then
kernel calls, each checking its program with `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ encoderCases expectFn
        , decoderCases expectFn
        , kernelBytesCases expectFn
        ]



-- ============================================================================
-- ENCODER CASES (Bytes.Encode.* via VarForeign)
-- ============================================================================


{-| Returns the cases whose programs use encoders from the imported
`Bytes.Encode`, each checking its program with `expectFn`.
-}
encoderCases : (Src.Module -> Expectation) -> List TestCase
encoderCases expectFn =
    [ { label = "Bytes.Encode.unsignedInt8", run = encodeU8 expectFn }
    , { label = "Bytes.Encode.signedInt8", run = encodeI8 expectFn }
    , { label = "Bytes.Encode.unsignedInt16 BE", run = encodeU16BE expectFn }
    , { label = "Bytes.Encode.unsignedInt32 LE", run = encodeU32LE expectFn }
    , { label = "Bytes.Encode.float32 BE", run = encodeF32BE expectFn }
    , { label = "Bytes.Encode.float64 LE", run = encodeF64LE expectFn }
    , { label = "Bytes.Encode.string", run = encodeString expectFn }
    , { label = "Bytes.Encode.sequence of u8s", run = encodeSequence expectFn }
    , { label = "Bytes.Encode.encode with u8", run = encodeEncodeU8 expectFn }
    , { label = "Bytes.Encode.encode with sequence", run = encodeEncodeSequence expectFn }
    ]


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.unsignedInt8 42`.
-}
encodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeU8 expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 42 ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.signedInt8 -1`, where `-1` is an integer literal rather than a
negation.
-}
encodeI8 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeI8 expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "signedInt8") [ intExpr -1 ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.unsignedInt16 BE 1000`.
-}
encodeU16BE : (Src.Module -> Expectation) -> (() -> Expectation)
encodeU16BE expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "unsignedInt16")
                [ ctorExpr "BE", intExpr 1000 ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.unsignedInt32 LE 100000`.
-}
encodeU32LE : (Src.Module -> Expectation) -> (() -> Expectation)
encodeU32LE expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "unsignedInt32")
                [ ctorExpr "LE", intExpr 100000 ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.float32 BE 3.14`.
-}
encodeF32BE : (Src.Module -> Expectation) -> (() -> Expectation)
encodeF32BE expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "float32")
                [ ctorExpr "BE", floatExpr 3.14 ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.float64 LE 2.718281828`.
-}
encodeF64LE : (Src.Module -> Expectation) -> (() -> Expectation)
encodeF64LE expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "float64")
                [ ctorExpr "LE", floatExpr 2.718281828 ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.string "hello"`.
-}
encodeString : (Src.Module -> Expectation) -> (() -> Expectation)
encodeString expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "string") [ strExpr "hello" ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.sequence` of a list of three `Bytes.Encode.unsignedInt8`
encoders, for 1, 2 and 3.
-}
encodeSequence : (Src.Module -> Expectation) -> (() -> Expectation)
encodeSequence expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "sequence")
                [ listExpr
                    [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 1 ]
                    , callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 2 ]
                    , callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 3 ]
                    ]
                ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.encode` applied to `Bytes.Encode.unsignedInt8 255`.
-}
encodeEncodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeEncodeU8 expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "encode")
                [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 255 ]
                ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Encode.encode` applied to a `Bytes.Encode.sequence` of three encoders
of different widths: `unsignedInt8 0`, `unsignedInt16 BE 256` and
`float64 LE 1.0`.
-}
encodeEncodeSequence : (Src.Module -> Expectation) -> (() -> Expectation)
encodeEncodeSequence expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Encode" "encode")
                [ callExpr (qualVarExpr "Bytes.Encode" "sequence")
                    [ listExpr
                        [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 0 ]
                        , callExpr (qualVarExpr "Bytes.Encode" "unsignedInt16") [ ctorExpr "BE", intExpr 256 ]
                        , callExpr (qualVarExpr "Bytes.Encode" "float64") [ ctorExpr "LE", floatExpr 1.0 ]
                        ]
                    ]
                ]
            )
        )



-- ============================================================================
-- DECODER CASES (Bytes.Decode.* via VarForeign)
-- ============================================================================


{-| Returns the cases whose programs use decoders from the imported
`Bytes.Decode`, each checking its program with `expectFn`. None of these
programs decodes anything; each value is a decoder.
-}
decoderCases : (Src.Module -> Expectation) -> List TestCase
decoderCases expectFn =
    [ { label = "Bytes.Decode.unsignedInt8", run = decodeU8 expectFn }
    , { label = "Bytes.Decode.signedInt8", run = decodeI8 expectFn }
    , { label = "Bytes.Decode.unsignedInt16 BE", run = decodeU16BE expectFn }
    , { label = "Bytes.Decode.unsignedInt32 LE", run = decodeU32LE expectFn }
    , { label = "Bytes.Decode.float32 BE", run = decodeF32BE expectFn }
    , { label = "Bytes.Decode.float64 LE", run = decodeF64LE expectFn }
    , { label = "Bytes.Decode.string", run = decodeString expectFn }
    , { label = "Bytes.Decode.succeed", run = decodeSucceed expectFn }
    , { label = "Bytes.Decode.map", run = decodeMap expectFn }
    , { label = "Bytes.Decode.map2", run = decodeMap2 expectFn }
    , { label = "Bytes.Decode.andThen", run = decodeAndThen expectFn }
    ]


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.unsignedInt8`.
-}
decodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
decodeU8 expectFn _ =
    expectFn (makeKernelModule "testValue" (qualVarExpr "Bytes.Decode" "unsignedInt8"))


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.signedInt8`.
-}
decodeI8 : (Src.Module -> Expectation) -> (() -> Expectation)
decodeI8 expectFn _ =
    expectFn (makeKernelModule "testValue" (qualVarExpr "Bytes.Decode" "signedInt8"))


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.unsignedInt16 BE`.
-}
decodeU16BE : (Src.Module -> Expectation) -> (() -> Expectation)
decodeU16BE expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "unsignedInt16") [ ctorExpr "BE" ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.unsignedInt32 LE`.
-}
decodeU32LE : (Src.Module -> Expectation) -> (() -> Expectation)
decodeU32LE expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "unsignedInt32") [ ctorExpr "LE" ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.float32 BE`.
-}
decodeF32BE : (Src.Module -> Expectation) -> (() -> Expectation)
decodeF32BE expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "float32") [ ctorExpr "BE" ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.float64 LE`.
-}
decodeF64LE : (Src.Module -> Expectation) -> (() -> Expectation)
decodeF64LE expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "float64") [ ctorExpr "LE" ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.string 5`.
-}
decodeString : (Src.Module -> Expectation) -> (() -> Expectation)
decodeString expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "string") [ intExpr 5 ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.succeed 42`.
-}
decodeSucceed : (Src.Module -> Expectation) -> (() -> Expectation)
decodeSucceed expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "succeed") [ intExpr 42 ])
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.map (\x -> x) Bytes.Decode.unsignedInt8`.
-}
decodeMap : (Src.Module -> Expectation) -> (() -> Expectation)
decodeMap expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "map")
                [ lambdaExpr [ pVar "x" ] (varExpr "x")
                , qualVarExpr "Bytes.Decode" "unsignedInt8"
                ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.map2 (\a b -> a) Bytes.Decode.unsignedInt8 Bytes.Decode.unsignedInt8`.
-}
decodeMap2 : (Src.Module -> Expectation) -> (() -> Expectation)
decodeMap2 expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "map2")
                [ lambdaExpr [ pVar "a", pVar "b" ] (varExpr "a")
                , qualVarExpr "Bytes.Decode" "unsignedInt8"
                , qualVarExpr "Bytes.Decode" "unsignedInt8"
                ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Bytes.Decode.andThen (\n -> Bytes.Decode.succeed n) Bytes.Decode.unsignedInt8`.
-}
decodeAndThen : (Src.Module -> Expectation) -> (() -> Expectation)
decodeAndThen expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Bytes.Decode" "andThen")
                [ lambdaExpr [ pVar "n" ] (callExpr (qualVarExpr "Bytes.Decode" "succeed") [ varExpr "n" ])
                , qualVarExpr "Bytes.Decode" "unsignedInt8"
                ]
            )
        )



-- ============================================================================
-- KERNEL BYTES CALLS (Elm.Kernel.Bytes.encode/decode, not imported)
-- ============================================================================


{-| Returns the cases whose programs call `Elm.Kernel.Bytes.encode` or
`Elm.Kernel.Bytes.decode` by their qualified names, without an import, each
checking its program with `expectFn`.
-}
kernelBytesCases : (Src.Module -> Expectation) -> List TestCase
kernelBytesCases expectFn =
    [ { label = "Kernel Bytes.encode with u8", run = kernelBytesEncodeU8 expectFn }
    , { label = "Kernel Bytes.encode with sequence", run = kernelBytesEncodeSeq expectFn }
    , { label = "Kernel Bytes.decode with u8 decoder", run = kernelBytesDecodeU8 expectFn }
    ]


{-| Returns the check for a case: it gives `expectFn` the program
`Elm.Kernel.Bytes.encode (Bytes.Encode.unsignedInt8 42)`.
-}
kernelBytesEncodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
kernelBytesEncodeU8 expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Bytes" "encode")
                [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 42 ]
                ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Elm.Kernel.Bytes.encode` applied to a `Bytes.Encode.sequence` of two
`Bytes.Encode.unsignedInt8` encoders, for 1 and 2.
-}
kernelBytesEncodeSeq : (Src.Module -> Expectation) -> (() -> Expectation)
kernelBytesEncodeSeq expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Bytes" "encode")
                [ callExpr (qualVarExpr "Bytes.Encode" "sequence")
                    [ listExpr
                        [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 1 ]
                        , callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 2 ]
                        ]
                    ]
                ]
            )
        )


{-| Returns the check for a case: it gives `expectFn` the program
`Elm.Kernel.Bytes.decode Bytes.Decode.unsignedInt8 b`, where `b` is
`Elm.Kernel.Bytes.encode (Bytes.Encode.unsignedInt8 99)`.
-}
kernelBytesDecodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
kernelBytesDecodeU8 expectFn _ =
    expectFn
        (makeKernelModule "testValue"
            (callExpr (qualVarExpr "Elm.Kernel.Bytes" "decode")
                [ qualVarExpr "Bytes.Decode" "unsignedInt8"
                , callExpr (qualVarExpr "Elm.Kernel.Bytes" "encode")
                    [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 99 ] ]
                ]
            )
        )
