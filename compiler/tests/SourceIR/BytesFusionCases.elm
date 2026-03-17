module SourceIR.BytesFusionCases exposing (expectSuite)

{-| Test cases for bytes fusion compilation paths.

Uses Bytes.Encode and Bytes.Decode functions via qualVarExpr to exercise
the BytesFusion Reify/Emit codegen in MLIR Expr.

Tests both the VarForeign path (via imported Bytes.Encode module functions)
and the VarKernel path (via Elm.Kernel.Bytes encode/decode).
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


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Bytes fusion " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


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


encodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeU8 expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 42 ]))


encodeI8 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeI8 expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "signedInt8") [ intExpr -1 ]))


encodeU16BE : (Src.Module -> Expectation) -> (() -> Expectation)
encodeU16BE expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "unsignedInt16")
            [ ctorExpr "BE", intExpr 1000 ]))


encodeU32LE : (Src.Module -> Expectation) -> (() -> Expectation)
encodeU32LE expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "unsignedInt32")
            [ ctorExpr "LE", intExpr 100000 ]))


encodeF32BE : (Src.Module -> Expectation) -> (() -> Expectation)
encodeF32BE expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "float32")
            [ ctorExpr "BE", floatExpr 3.14 ]))


encodeF64LE : (Src.Module -> Expectation) -> (() -> Expectation)
encodeF64LE expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "float64")
            [ ctorExpr "LE", floatExpr 2.718281828 ]))


encodeString : (Src.Module -> Expectation) -> (() -> Expectation)
encodeString expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "string") [ strExpr "hello" ]))


encodeSequence : (Src.Module -> Expectation) -> (() -> Expectation)
encodeSequence expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "sequence")
            [ listExpr
                [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 1 ]
                , callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 2 ]
                , callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 3 ]
                ]
            ]))


encodeEncodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeEncodeU8 expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "encode")
            [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 255 ]
            ]))


encodeEncodeSequence : (Src.Module -> Expectation) -> (() -> Expectation)
encodeEncodeSequence expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Encode" "encode")
            [ callExpr (qualVarExpr "Bytes.Encode" "sequence")
                [ listExpr
                    [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 0 ]
                    , callExpr (qualVarExpr "Bytes.Encode" "unsignedInt16") [ ctorExpr "BE", intExpr 256 ]
                    , callExpr (qualVarExpr "Bytes.Encode" "float64") [ ctorExpr "LE", floatExpr 1.0 ]
                    ]
                ]
            ]))



-- ============================================================================
-- DECODER CASES (Bytes.Decode.* via VarForeign)
-- ============================================================================


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


decodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
decodeU8 expectFn _ =
    expectFn (makeKernelModule "testValue" (qualVarExpr "Bytes.Decode" "unsignedInt8"))


decodeI8 : (Src.Module -> Expectation) -> (() -> Expectation)
decodeI8 expectFn _ =
    expectFn (makeKernelModule "testValue" (qualVarExpr "Bytes.Decode" "signedInt8"))


decodeU16BE : (Src.Module -> Expectation) -> (() -> Expectation)
decodeU16BE expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "unsignedInt16") [ ctorExpr "BE" ]))


decodeU32LE : (Src.Module -> Expectation) -> (() -> Expectation)
decodeU32LE expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "unsignedInt32") [ ctorExpr "LE" ]))


decodeF32BE : (Src.Module -> Expectation) -> (() -> Expectation)
decodeF32BE expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "float32") [ ctorExpr "BE" ]))


decodeF64LE : (Src.Module -> Expectation) -> (() -> Expectation)
decodeF64LE expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "float64") [ ctorExpr "LE" ]))


decodeString : (Src.Module -> Expectation) -> (() -> Expectation)
decodeString expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "string") [ intExpr 5 ]))


decodeSucceed : (Src.Module -> Expectation) -> (() -> Expectation)
decodeSucceed expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "succeed") [ intExpr 42 ]))


decodeMap : (Src.Module -> Expectation) -> (() -> Expectation)
decodeMap expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "map")
            [ lambdaExpr [ pVar "x" ] (varExpr "x")
            , qualVarExpr "Bytes.Decode" "unsignedInt8"
            ]))


decodeMap2 : (Src.Module -> Expectation) -> (() -> Expectation)
decodeMap2 expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "map2")
            [ lambdaExpr [ pVar "a", pVar "b" ] (varExpr "a")
            , qualVarExpr "Bytes.Decode" "unsignedInt8"
            , qualVarExpr "Bytes.Decode" "unsignedInt8"
            ]))


decodeAndThen : (Src.Module -> Expectation) -> (() -> Expectation)
decodeAndThen expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Bytes.Decode" "andThen")
            [ lambdaExpr [ pVar "n" ] (callExpr (qualVarExpr "Bytes.Decode" "succeed") [ varExpr "n" ])
            , qualVarExpr "Bytes.Decode" "unsignedInt8"
            ]))



-- ============================================================================
-- KERNEL BYTES CALLS (Elm.Kernel.Bytes.encode/decode via VarKernel)
-- ============================================================================


kernelBytesCases : (Src.Module -> Expectation) -> List TestCase
kernelBytesCases expectFn =
    [ { label = "Kernel Bytes.encode with u8", run = kernelBytesEncodeU8 expectFn }
    , { label = "Kernel Bytes.encode with sequence", run = kernelBytesEncodeSeq expectFn }
    , { label = "Kernel Bytes.decode with u8 decoder", run = kernelBytesDecodeU8 expectFn }
    ]


kernelBytesEncodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
kernelBytesEncodeU8 expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.Bytes" "encode")
            [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 42 ]
            ]))


kernelBytesEncodeSeq : (Src.Module -> Expectation) -> (() -> Expectation)
kernelBytesEncodeSeq expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.Bytes" "encode")
            [ callExpr (qualVarExpr "Bytes.Encode" "sequence")
                [ listExpr
                    [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 1 ]
                    , callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 2 ]
                    ]
                ]
            ]))


kernelBytesDecodeU8 : (Src.Module -> Expectation) -> (() -> Expectation)
kernelBytesDecodeU8 expectFn _ =
    expectFn (makeKernelModule "testValue"
        (callExpr (qualVarExpr "Elm.Kernel.Bytes" "decode")
            [ qualVarExpr "Bytes.Decode" "unsignedInt8"
            , callExpr (qualVarExpr "Elm.Kernel.Bytes" "encode")
                [ callExpr (qualVarExpr "Bytes.Encode" "unsignedInt8") [ intExpr 99 ] ]
            ]))
