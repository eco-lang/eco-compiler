module TestLogic.Generate.CodeGen.JumpTargetCheckerTest exposing (suite)

{-| Pins the jump-target checker,
`TestLogic.Generate.CodeGen.JumpTarget.checkJumpTargets`, on hand-built MLIR,
so that `TestLogic.Generate.CodeGen.JumpTargetTest`, which runs it over the
catalogue (where the code generator emits no `eco.joinpoint`), is known to
report a bad jump when one appears.

A _jump_ is an `eco.jump` op. Its integer `target` attribute names a
_joinpoint_, an `eco.joinpoint` op that encloses the jump, by the joinpoint's
integer `id`, and its operands are the arguments it passes to the joinpoint's
parameters.

What the tests establish, on three hand-built modules of one function: a jump
inside the joinpoint it targets, with matching arguments, passes; a jump to an
id that no enclosing joinpoint has (the joinpoint is a sibling, not an
ancestor) is reported once; and a jump with an argument of the wrong type is
reported once.

Among what is not tested: the text of the reports, and jumps nested more than
one joinpoint deep.

-}

import Dict
import Expect
import Mlir.Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)
import TestLogic.Generate.CodeGen.JumpTarget exposing (checkJumpTargets)


{-| The checker on hand-built MLIR, as the module docstring describes.
-}
suite : Test
suite =
    Test.describe "checkJumpTargets on hand-built MLIR"
        [ Test.test "a jump inside its joinpoint with matching arguments passes" <|
            \_ ->
                funcModule [ joinpoint 0 (jump 0 [ "%x" ]) ]
                    |> checkJumpTargets
                    |> Expect.equal []
        , Test.test "a jump to a sibling joinpoint's id fails" <|
            \_ ->
                funcModule [ joinpoint 0 (op "eco.return" [] [] [] []), joinpoint 1 (jump 0 [ "%x" ]) ]
                    |> checkJumpTargets
                    |> List.length
                    |> Expect.equal 1
        , Test.test "a jump with an argument of the wrong type fails" <|
            \_ ->
                funcModule [ op "arith.constant" [] [ ( "%f", F64 ) ] [] [], joinpoint 0 (jump 0 [ "%f" ]) ]
                    |> checkJumpTargets
                    |> List.length
                    |> Expect.equal 1
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


{-| A region of one block with arguments `args`, body ops and a terminator.
-}
region : List ( String, MlirType ) -> List MlirOp -> MlirOp -> MlirRegion
region args body terminator =
    MlirRegion { entry = { args = args, body = body, terminator = terminator }, blocks = OrderedDict.empty }


{-| A module of one function whose body is `bodyOps` followed by a return.
-}
funcModule : List MlirOp -> MlirModule
funcModule bodyOps =
    { body =
        [ op "func.func" [] [] [ ( "sym_name", StringAttr "f" ) ] [ region [ ( "%x", I64 ) ] bodyOps (op "eco.return" [] [] [] []) ] ]
    , loc = Mlir.Loc.unknown
    }


{-| A joinpoint `id` with one `i64` parameter `%p`, whose body ends in
`bodyTerminator`.
-}
joinpoint : Int -> MlirOp -> MlirOp
joinpoint id bodyTerminator =
    op "eco.joinpoint"
        []
        []
        [ ( "id", IntAttr Nothing id ) ]
        [ region [ ( "%p", I64 ) ] [] bodyTerminator
        , region [] [] (op "eco.return" [] [] [] [])
        ]


{-| A jump to `target` passing `args`.
-}
jump : Int -> List String -> MlirOp
jump target args =
    op "eco.jump" args [] [ ( "target", IntAttr Nothing target ) ] []
