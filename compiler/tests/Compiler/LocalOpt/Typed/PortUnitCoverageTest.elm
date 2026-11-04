module Compiler.LocalOpt.Typed.PortUnitCoverageTest exposing (suite)

{-| Compiles a port module whose one port sends the unit value out, so that
the typed optimizer builds the encoder of `()` (`Compiler.LocalOpt.Typed.Port`),
and pins the fix of finding F4 in that encoder.

The program is the source text of a port module named `Test`, parsed as an
application module, that declares `port out : () -> Cmd msg` and defines
`testValue` as the integer `1`. Default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks are dropped.

  - "compiles to MLIR": the program passes
    `TestLogic.TestPipeline.expectCoverageRun`.
  - "encodes its function types": the program passes
    `TestLogic.LocalOpt.FunctionTypeEncode`'s check, invariant TOPT_005. The
    encoder is the function `\_ -> Json.Encode.null`, stored as
    `() -> Json.Encode.Value`. Its body, the reference to `null`, used to carry
    the placeholder type `Can.TVar "null"` that `Port.encode` gives a
    `Json.Encode` callee, so the function's type did not match its body (F4);
    it now carries `Json.Encode.Value`.

-}

import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.LocalOpt.FunctionTypeEncode exposing (expectFunctionTypesEncoded)
import TestLogic.TestPipeline as Pipeline


{-| The two tests, under a label that contains "coverage run" so that the
coverage loop's quick run includes them.
-}
suite : Test
suite =
    Test.describe "Unit port encoder (coverage run)"
        [ Test.test "compiles to MLIR" <| \_ -> withModule Pipeline.expectCoverageRun
        , Test.test "encodes its function types" <| \_ -> withModule expectFunctionTypesEncoded
        ]


{-| Runs `expectFn` on the parsed program, or fails when it does not parse.
-}
withModule : (Src.Module -> Expectation) -> Expectation
withModule expectFn =
    case Parse.fromByteString Parse.Application source of
        Ok (Src.Module m) ->
            expectFn (Src.Module { m | imports = List.filter isMockImport m.imports })

        Err _ ->
            Expect.fail "fixture failed to parse"


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The program's source text.
-}
source : String
source =
    "port module Test exposing (..)\n\nimport Json.Encode\n\n\nport out : () -> Cmd msg\n\n\ntestValue =\n    1\n"
