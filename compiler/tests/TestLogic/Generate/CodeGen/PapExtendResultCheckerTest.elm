module TestLogic.Generate.CodeGen.PapExtendResultCheckerTest exposing (suite)

{-| SD-8: pins the `eco.papExtend` result checker,
`TestLogic.Generate.CodeGen.PapExtendResult.checkPapExtendResult`, on
hand-built MLIR.

A Bool never crosses a function or closure boundary as `i1`: at every ABI
boundary it is `!eco.value` (REP\_ABI\_001, `Types.monoTypeToAbi`), no `i1`
may reach `eco.papExtend` or `eco.return` (CGEN\_009), and a typed-mode
`eco.papExtend` result is its callee's result type (CGEN\_056), which is
therefore never `i1`. A generic-mode op's result is never `i1` either
(CGEN\_034). So an `i1` result is wrong in both modes.

The checker rejects an `i1` result in generic mode, as `PapExtendOp::verify`
does, but its typed-mode allow-list (`isValidPapExtendResultType`) still
includes `i1`, so a typed-mode `i1` result passes. The first test below fails
until that is fixed; the other two pin the cases the checker already gets
right.

-}

import Dict
import Expect
import Mlir.Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendResult exposing (checkPapExtendResult)


{-| The checker on hand-built MLIR, as the module docstring describes.
-}
suite : Test
suite =
    Test.describe "SD-8: checkPapExtendResult on hand-built MLIR"
        [ Test.test "SD-8: a typed-mode papExtend with an i1 result is rejected" <|
            \_ ->
                funcModule [ papExtend [ ( "remaining_arity", IntAttr Nothing 1 ) ] I1 ]
                    |> checkPapExtendResult
                    |> List.length
                    |> Expect.equal 1
        , Test.test "a generic-mode papExtend with an i1 result is rejected" <|
            \_ ->
                funcModule [ papExtend [ ( "_call_kind", StringAttr "generic_apply" ) ] I1 ]
                    |> checkPapExtendResult
                    |> List.length
                    |> Expect.equal 1
        , Test.test "a typed-mode papExtend with an !eco.value result passes" <|
            \_ ->
                funcModule [ papExtend [ ( "remaining_arity", IntAttr Nothing 1 ) ] (NamedStruct "eco.value") ]
                    |> checkPapExtendResult
                    |> Expect.equal []
        ]


{-| A hand-built op named `name` with the given operands, results, attributes
and regions.
-}
op : String -> List String -> List ( String, MlirType ) -> List ( String, MlirAttr ) -> List MlirRegion -> MlirOp
op name operands results attrs regions =
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


{-| An `eco.papExtend` applying closure `%f` to `%x`, with the given attributes
and result type.
-}
papExtend : List ( String, MlirAttr ) -> MlirType -> MlirOp
papExtend attrs resultType =
    op "eco.papExtend" [ "%f", "%x" ] [ ( "%r", resultType ) ] attrs []


{-| A module of one function `f(%f : !eco.value, %x : i64)` whose body is
`bodyOps` followed by a return.
-}
funcModule : List MlirOp -> MlirModule
funcModule bodyOps =
    { body =
        [ op "func.func"
            []
            []
            [ ( "sym_name", StringAttr "f" ) ]
            [ MlirRegion
                { entry =
                    { args = [ ( "%f", NamedStruct "eco.value" ), ( "%x", I64 ) ]
                    , body = bodyOps
                    , terminator = op "eco.return" [] [] [] []
                    }
                , blocks = OrderedDict.empty
                }
            ]
        ]
    , loc = Mlir.Loc.unknown
    }
