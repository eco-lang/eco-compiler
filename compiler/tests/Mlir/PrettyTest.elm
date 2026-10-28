module Mlir.PrettyTest exposing (suite)

{-| Regression tests for `Mlir.Pretty`. EXPECTED TO FAIL until the bugs they
reproduce are fixed.

Bugs reproduced (each output checked against `mlir-opt`):

  - An op with a `callee` attribute prints its attributes as `<{...}>`
    properties, but after its regions; MLIR's generic form wants properties
    before the regions (`"op"() <{callee = @f}> ({...}) : ...`). The current
    output `"op"() ({...}) <{callee = @f}>` is rejected by the MLIR parser.
  - A `UnitAttr` element of an array prints as nothing (`[]` or `[, ...]`)
    instead of `unit`.
  - Without `_operand_types`, an operand whose type is not in the environment
    of its own block (a value defined in an enclosing region, or by an earlier
    top-level op) is silently left out of the signature, which then has fewer
    types than operands.

-}

import Dict
import Expect
import Mlir.Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirBlock, MlirOp, MlirRegion(..), MlirType(..))
import Mlir.Pretty as Pretty
import OrderedDict
import Test exposing (Test)


mkOp : String -> List String -> List ( String, MlirType ) -> List MlirRegion -> List ( String, MlirAttr ) -> MlirOp
mkOp name operands results regions attrs =
    { name = name
    , id = name
    , operands = operands
    , results = results
    , attrs = Dict.fromList attrs
    , regions = regions
    , isTerminator = False
    , loc = Mlir.Loc.unknown
    , successors = []
    }


term : List String -> MlirOp
term operands =
    let
        o =
            mkOp "test.yield" operands [] [] []
    in
    { o | isTerminator = True }


region : List MlirOp -> MlirOp -> MlirRegion
region body t =
    MlirRegion { entry = { args = [], body = body, terminator = t }, blocks = OrderedDict.empty }


suite : Test
suite =
    Test.describe "Mlir.Pretty regressions"
        [ Test.test "callee properties are printed before the regions" <|
            \_ ->
                let
                    text =
                        Pretty.ppTopLevelOp
                            (mkOp "test.op" [] [] [ region [] (term []) ] [ ( "callee", SymbolRefAttr "f" ) ])
                in
                Expect.equal True (String.contains "\"test.op\"() <{callee = @f}> ({" text)
                    |> Expect.onFail ("printed as: " ++ text)
        , Test.test "a UnitAttr array element prints as unit" <|
            \_ ->
                let
                    text =
                        Pretty.ppTopLevelOp (mkOp "test.op" [] [] [] [ ( "v", ArrayAttr Nothing [ UnitAttr ] ) ])
                in
                Expect.equal True (String.contains "v = [unit]" text)
                    |> Expect.onFail ("printed as: " ++ text)
        , Test.test "an operand defined in an enclosing region keeps its type" <|
            \_ ->
                let
                    inner =
                        mkOp "test.inner" [] [] [ region [] (term [ "%x" ]) ] []

                    outer =
                        mkOp "test.outer" [] [] [ region [ mkOp "test.def" [] [ ( "%x", I64 ) ] [] [], inner ] (term []) ] []

                    text =
                        Pretty.ppTopLevelOp outer
                in
                Expect.equal True (String.contains "\"test.yield\"(%x) : (i64) -> ()" text)
                    |> Expect.onFail ("printed as: " ++ text)
        , Test.test "an operand defined by an earlier top-level op keeps its type" <|
            \_ ->
                let
                    text =
                        Pretty.ppModule
                            { body = [ mkOp "test.def" [] [ ( "%x", I64 ) ] [] [], mkOp "test.use" [ "%x" ] [] [] [] ]
                            , loc = Mlir.Loc.unknown
                            }
                in
                Expect.equal True (String.contains "\"test.use\"(%x) : (i64) -> ()" text)
                    |> Expect.onFail ("printed as: " ++ text)
        ]
