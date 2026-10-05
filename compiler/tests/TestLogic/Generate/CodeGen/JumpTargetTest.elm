module TestLogic.Generate.CodeGen.JumpTargetTest exposing (suite)

{-| A jump in generated MLIR that names no enclosing joinpoint, or passes it the
wrong arguments, is a broken program that no type in `Mlir.Mlir` rules out.
This module runs the check for such jumps,
`TestLogic.Generate.CodeGen.JumpTarget.expectJumpTarget`, on every program of
the standard `SourceIR` catalogue, and pins the checker itself on hand-built
MLIR.

A _jump_ is an `eco.jump` op. Its integer `target` attribute names a
_joinpoint_, an `eco.joinpoint` op that encloses the jump, by the joinpoint's
integer `id`, and its operands are the arguments it passes to the joinpoint's
parameters.

What the tests establish:

  - `suite` compiles each catalogue program to MLIR with `runToMlir`, and
    passes for it when compilation succeeds and every jump targets an
    enclosing joinpoint with as many parameters as it has operands, each of
    the operand's defined type. The code generator emits no `eco.joinpoint`
    (tail recursion becomes `scf.while`), so on these programs the check
    amounts to: no `eco.jump` is generated, which would mean the dangling
    `Expr.generateTailCall` fallback was reached.
  - `checkerTests` runs `checkJumpTargets` on three hand-built modules: a jump
    inside the joinpoint it targets, with matching arguments, passes; a jump
    to an id that no enclosing joinpoint has (the joinpoint is a sibling, not
    an ancestor) fails; and a jump with an argument of the wrong type fails.

Among what is not tested: whether joinpoint ids are unique within a function.

-}

import Dict
import Expect
import Mlir.Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.JumpTarget exposing (checkJumpTargets, expectJumpTarget)


{-| The test group of this module: the standard catalogue's suites, each
applying `expectJumpTarget` to its programs.
-}
suite : Test
suite =
    Test.describe "CGEN_030: Jump Target Validity"
        [ StandardTestSuites.expectSuite expectJumpTarget "passes jump target invariant"
        , checkerTests
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


{-| The checker on hand-built MLIR, as the module docstring describes.
-}
checkerTests : Test
checkerTests =
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
