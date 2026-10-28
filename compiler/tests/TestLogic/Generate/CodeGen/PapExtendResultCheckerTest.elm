module TestLogic.Generate.CodeGen.PapExtendResultCheckerTest exposing (suite)

{-| Tests that pin `TestLogic.Generate.CodeGen.PapExtendResult.checkPapExtendResult`
on hand-built MLIR, so that the checker's verdict on an `i1` result is tested
even when no compiled program produces one.

An `eco.papExtend` op gives a closure more arguments. It is in _typed mode_
when it carries an integer `remaining_arity` attribute and in _generic mode_
otherwise. A Bool crosses a closure boundary as `!eco.value`, never as `i1`,
so the checker must reject an `i1` result in either mode.

The fixture is a module of one function whose body is a single `eco.papExtend`
applying `%f` to `%x`, with the attributes and result type each test chooses.

The tests establish that:

  - a typed-mode op with an `i1` result gives exactly one violation;
  - a generic-mode op (`_call_kind` `generic_apply`) with an `i1` result gives
    exactly one violation;
  - a typed-mode op with an `!eco.value` result gives no violation.

Among what is not tested: the `i32`, `i64` and `f64` results; an op with a
result count other than one; and the missing-`remaining_arity` rule.

-}

import Dict
import Expect
import Mlir.Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendResult exposing (checkPapExtendResult)


{-| The three checker tests listed in the module docstring.
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
