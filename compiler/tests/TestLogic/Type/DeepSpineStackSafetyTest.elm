module TestLogic.Type.DeepSpineStackSafetyTest exposing (suite)

{-| Without these tests, a change that makes constraint generation recurse once
per level along one of the chains built here would go unnoticed until a large
program overflowed the JavaScript stack.

An _axis_ is one of the directions of nesting that the module docstrings of
`Compiler.Type.Constrain.Typed.Expression` and
`Compiler.Type.Constrain.Typed.Pattern` classify as unbounded in practice, such
as down the body of a `let` or down the tail of a cons pattern. Those docstrings
list the axes and the function that walks each. The constraint generator walks
each axis with a _spine_: a loop that descends the chain one level at a time
instead of recursing, so its stack use does not grow with the depth. Other
nesting is walked by ordinary recursion. Each test but the last builds one
chain, 10,000 deep, along one axis and runs constraint generation over it; the
last nests chains along three axes, none deeper than 2,000. A walk that recursed
once per level would need a stack frame per level.

The fixtures are canonical ASTs built directly, without the parser or the
canonicalizer, each wrapped as the body of the one definition `testValue` in a
module of its own. Every node in a fixture has its own id. Some fixtures are not
well-typed Elm: the call, field-access, `case` and mixed fixtures refer to names
nothing binds (`f`, `r` and `xs`), and the `if` fixture tests an `Int` as its
condition. Generation does not look names up or check types, so this does not
stop it.

Each test runs both pathways of the one generator over its fixture:
`ConstrainTyped.constrainWithIdsDetailed`, the typed pathway, which records a
solver variable for each node id, and `ConstrainTyped.constrainErased`, the
erased pathway, which runs with recording off and so takes the recording-off
branches of the spines. A test passes when both return, the erased constraint
is not the empty `CTrue`, and the typed pathway recorded a variable for at
least as many node ids as the fixture has levels, so that the walk reached
the bottom of the chain rather than stopping early.
The chains are:

  - a `let` chain 10,000 deep, nesting down the body: `let x = 0 in let x = 0 in ... x`;
  - 10,000 additions nesting down the left operand;
  - 10,000 additions nesting down the right operand;
  - 10,000 calls nesting down the function, `((f 1) 2) ...`;
  - 10,000 calls of `f` nesting down the last argument, `f (f (f ...))`;
  - an `if` ladder 10,000 deep, nesting down the final `else` branch;
  - 10,000 field accesses, `r.f.f.f...`;
  - a `case` whose one branch has a cons pattern 10,000 deep, `_ :: _ :: ... :: _`;
  - a 2,000-deep `let` chain, each definition a five-deep left-nested addition
    chain, whose body is a 2,000-deep chain of calls of `f` nesting down the
    last argument.

Among what is not tested: `let` chains built from `Can.LetRec` or
`Can.LetDestruct` nodes, which the let spine handles separately from
`Can.Let`; anything about the constraints produced or the variables recorded
beyond their count; solving the constraints; and parsing or canonicalizing
deep source.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.CanonicalBuilder as CB
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Type as Type
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


{-| The number of levels in each single-axis chain.
-}
depth : Int
depth =
    10000


{-| Runs constraint generation over `canonical` on both pathways, and passes
when the erased constraint is not `CTrue` and the typed pathway recorded a
solver variable for at least `minRecorded` node ids.
-}
expectGenerationCompletes : Int -> Can.Module -> Expect.Expectation
expectGenerationCompletes minRecorded canonical =
    let
        ( _, typedState ) =
            IO.unsafePerformIO (ConstrainTyped.constrainWithIdsDetailed canonical)

        erasedConstraint =
            IO.unsafePerformIO (ConstrainTyped.constrainErased canonical)

        recorded =
            Array.foldl
                (\maybeVar n ->
                    case maybeVar of
                        Just _ ->
                            n + 1

                        Nothing ->
                            n
                )
                0
                typedState.mapping
    in
    Expect.all
        [ \() ->
            case erasedConstraint of
                Type.CTrue ->
                    Expect.fail "the erased pathway produced no constraint"

                _ ->
                    Expect.pass
        , \() ->
            recorded
                |> Expect.atLeast minRecorded
                |> Expect.onFail
                    ("the typed pathway recorded " ++ String.fromInt recorded ++ " node variables, fewer than the " ++ String.fromInt minRecorded ++ " levels of the fixture")
        ]
        ()



-- ====== NODE FABRICATION HELPERS ======


{-| The home module, `elm/core`'s `Basics`, that the fabricated addition nodes
name.
-}
basics : ModuleName.Canonical
basics =
    ModuleName.Canonical ( "elm", "core" ) "Basics"


{-| Builds an expression with id `id` and contents `node`, placed at `A.zero`.
-}
makeExpr : Int -> Can.Expr_ -> Can.Expr
makeExpr id node =
    A.At A.zero { id = id, node = node }


{-| Builds a pattern with id `id` and contents `node`, placed at `A.zero`.
-}
makePattern : Int -> Can.Pattern_ -> Can.Pattern
makePattern id node =
    A.At A.zero { id = id, node = node }


{-| The annotation `Int -> Int -> Int` with no type variables, attached to
every fabricated addition node.
-}
addAnnotation : Can.Annotation Name
addAnnotation =
    CB.makeAnnotation [] (CB.tFunc [ CB.intType, CB.intType ] CB.intType)


{-| Builds an addition node with id `id` applying `Basics.add` to `left` and
`right`.
-}
binop : Int -> Can.Expr -> Can.Expr -> Can.Expr
binop id left right =
    makeExpr id (Can.Binop "add" basics "add" addAnnotation left right)


{-| Builds `if 1 then thenBranch else finalBranch` with id `id`. The condition
is an `Int` literal with id `id + 100000`.
-}
ifNode : Int -> Can.Expr -> Can.Expr -> Can.Expr
ifNode id thenBranch finalBranch =
    makeExpr id (Can.If [ ( CB.intExpr (id + 100000) 1, thenBranch ) ] finalBranch)


{-| Builds the access of field `f` on `recordExpr`, with id `id`.
-}
accessNode : Int -> Can.Expr -> Can.Expr
accessNode id recordExpr =
    makeExpr id (Can.Access recordExpr (A.At A.zero "f"))


{-| Returns `leaf` wrapped `depth` times by `mkLevel`, with level 1 innermost
and level `depth` outermost. `mkLevel` receives the level number, which the
tests use to give each level's nodes their own ids.
-}
chain : (Int -> Can.Expr -> Can.Expr) -> Can.Expr -> Can.Expr
chain mkLevel leaf =
    List.foldl (\i acc -> mkLevel i acc) leaf (List.range 1 depth)



-- ====== SUITE ======


{-| The stack-safety tests, one per chain described in the module docstring.
-}
suite : Test
suite =
    Test.describe "Deep spine constraint generation is stack-safe (10k per linear axis)"
        [ Test.test "let-chain (body axis)" <|
            \_ ->
                -- let x = 0 in let x = 0 in ... in x
                chain (\i body -> CB.letExpr i (CB.makeDef "x" [] (CB.intExpr (i + 200000) 0)) body)
                    (CB.varLocalExpr 0 "x")
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes depth
        , Test.test "binop chain nesting left (1 + 2 + 3 + ...)" <|
            \_ ->
                chain (\i acc -> binop i acc (CB.intExpr (i + 300000) i))
                    (CB.intExpr 0 0)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes depth
        , Test.test "binop chain nesting right (a ++ (b ++ (c ++ ...)))" <|
            \_ ->
                chain (\i acc -> binop i (CB.intExpr (i + 300000) i) acc)
                    (CB.intExpr 0 0)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes depth
        , Test.test "call chain nesting down the func (curried application)" <|
            \_ ->
                chain (\i acc -> CB.callExpr i acc [ CB.intExpr (i + 300000) i ])
                    (CB.varLocalExpr 0 "f")
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes depth
        , Test.test "call chain nesting down the last argument (f (f (f ...)))" <|
            \_ ->
                chain (\i acc -> CB.callExpr i (CB.varLocalExpr (i + 300000) "f") [ acc ])
                    (CB.intExpr 0 0)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes depth
        , Test.test "if/else-if ladder (final-branch axis)" <|
            \_ ->
                chain (\i acc -> ifNode i (CB.intExpr (i + 200000) i) acc)
                    (CB.intExpr 0 0)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes depth
        , Test.test "record access chain (r.f.f.f...)" <|
            \_ ->
                chain accessNode (CB.varLocalExpr 0 "r")
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes depth
        , Test.test "cons-pattern chain (h :: h :: ... :: t)" <|
            \_ ->
                let
                    deepConsPattern : Can.Pattern
                    deepConsPattern =
                        List.foldl
                            (\i tail ->
                                makePattern i (Can.PCons (makePattern (i + 400000) Can.PAnything) tail)
                            )
                            (makePattern 0 Can.PAnything)
                            (List.range 1 depth)

                    caseNode : Can.Expr
                    caseNode =
                        makeExpr 900000
                            (Can.Case (CB.varLocalExpr 900001 "xs")
                                [ Can.CaseBranch deepConsPattern (CB.intExpr 900002 0) ]
                            )
                in
                CB.makeModule "testValue" caseNode
                    |> expectGenerationCompletes depth
        , Test.test "mixed spines: lets containing binop chains containing calls" <|
            \_ ->
                -- 2k lets, each def RHS a 5-long binop chain, body ends in a 2k call chain
                let
                    smallBinopChain : Int -> Can.Expr
                    smallBinopChain base =
                        List.foldl (\i acc -> binop (base + i) acc (CB.intExpr (base + i + 50) i))
                            (CB.intExpr base 0)
                            (List.range 1 5)

                    callTail : Can.Expr
                    callTail =
                        List.foldl (\i acc -> CB.callExpr (600000 + i) (CB.varLocalExpr (700000 + i) "f") [ acc ])
                            (CB.intExpr 0 0)
                            (List.range 1 2000)
                in
                List.foldl
                    (\i body -> CB.letExpr (800000 + i) (CB.makeDef "x" [] (smallBinopChain (i * 100))) body)
                    callTail
                    (List.range 1 2000)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes 4000
        ]
