module TestLogic.Type.DeepSpineStackSafetyTest exposing (suite)

{-| Per-axis stack-safety guards for the Design-B constraint generator.

The generator (`Compiler.Type.Constrain.Typed.*`) is written as ordinary
recursive `IO` functions, with an explicit `IO.loop` spine for every axis
along which `Can.Expr_`/`Can.Pattern_` nesting depth is unbounded (see the
axis tables in the module docs of `Typed.Expression` / `Typed.Pattern`).

Each test here drives one linear-unbounded axis at depth 10,000 through BOTH
constraint-generation pathways (typed = recording on, erased = recording
off). A missing or broken spine loop shows up as a JS stack overflow.

The canonical ASTs are built directly (bypassing the parser/canonicalizer,
whose own depth behavior is out of scope here), and the tests stop after
constraint generation: solving a 10k-deep constraint tree exercises the
solver's recursion, not the generator's. Full-pipeline coverage (parse →
canonicalize → constrain → solve) for the let axis lives in
`DeepLetStackSafetyTest`.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.CanonicalBuilder as CB
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Type.Constrain.Erased.Module as ErasedConstrain
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Dict
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


depth : Int
depth =
    10000


{-| Run BOTH constraint-generation pathways to completion. Reaching the
assertion at all means neither overflowed the stack.
-}
expectGenerationCompletes : Can.Module -> Expect.Expectation
expectGenerationCompletes canonical =
    let
        ( _, typedState ) =
            IO.unsafePerformIO (ConstrainTyped.constrainWithIdsDetailed canonical)

        erasedDone =
            case IO.unsafePerformIO (ErasedConstrain.constrain canonical) of
                _ ->
                    True
    in
    Expect.equal ( True, True ) ( typedState.recording, erasedDone )



-- ====== NODE FABRICATION HELPERS ======


basics : IO.Canonical
basics =
    IO.Canonical ( "elm", "core" ) "Basics"


makeExpr : Int -> Can.Expr_ -> Can.Expr
makeExpr id node =
    A.At A.zero { id = id, node = node }


makePattern : Int -> Can.Pattern_ -> Can.Pattern
makePattern id node =
    A.At A.zero { id = id, node = node }


{-| A fabricated `+`-style annotation; constraint generation only embeds it.
-}
addAnnotation : Can.Annotation Name
addAnnotation =
    CB.makeAnnotation [] (CB.tFunc [ CB.intType, CB.intType ] CB.intType)


binop : Int -> Can.Expr -> Can.Expr -> Can.Expr
binop id left right =
    makeExpr id (Can.Binop "add" basics "add" addAnnotation left right)


ifNode : Int -> Can.Expr -> Can.Expr -> Can.Expr
ifNode id thenBranch finalBranch =
    makeExpr id (Can.If [ ( CB.intExpr (id + 100000) 1, thenBranch ) ] finalBranch)


accessNode : Int -> Can.Expr -> Can.Expr
accessNode id recordExpr =
    makeExpr id (Can.Access recordExpr (A.At A.zero "f"))


{-| Fold a chain of the given depth: level i wraps the accumulator.
Each level gets a distinct id block so node-id recording is exercised.
-}
chain : (Int -> Can.Expr -> Can.Expr) -> Can.Expr -> Can.Expr
chain mkLevel leaf =
    List.foldl (\i acc -> mkLevel i acc) leaf (List.range 1 depth)



-- ====== SUITE ======


suite : Test
suite =
    Test.describe "Deep spine constraint generation is stack-safe (10k per linear axis)"
        [ Test.test "let-chain (body axis)" <|
            \_ ->
                -- let x = 0 in let x = 0 in ... in x
                chain (\i body -> CB.letExpr i (CB.makeDef "x" [] (CB.intExpr (i + 200000) 0)) body)
                    (CB.varLocalExpr 0 "x")
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes
        , Test.test "binop chain nesting left (1 + 2 + 3 + ...)" <|
            \_ ->
                chain (\i acc -> binop i acc (CB.intExpr (i + 300000) i))
                    (CB.intExpr 0 0)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes
        , Test.test "binop chain nesting right (a ++ (b ++ (c ++ ...)))" <|
            \_ ->
                chain (\i acc -> binop i (CB.intExpr (i + 300000) i) acc)
                    (CB.intExpr 0 0)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes
        , Test.test "call chain nesting down the func (curried application)" <|
            \_ ->
                chain (\i acc -> CB.callExpr i acc [ CB.intExpr (i + 300000) i ])
                    (CB.varLocalExpr 0 "f")
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes
        , Test.test "call chain nesting down the last argument (f (f (f ...)))" <|
            \_ ->
                chain (\i acc -> CB.callExpr i (CB.varLocalExpr (i + 300000) "f") [ acc ])
                    (CB.intExpr 0 0)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes
        , Test.test "if/else-if ladder (final-branch axis)" <|
            \_ ->
                chain (\i acc -> ifNode i (CB.intExpr (i + 200000) i) acc)
                    (CB.intExpr 0 0)
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes
        , Test.test "record access chain (r.f.f.f...)" <|
            \_ ->
                chain accessNode (CB.varLocalExpr 0 "r")
                    |> CB.makeModule "testValue"
                    |> expectGenerationCompletes
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
                    |> expectGenerationCompletes
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
                    |> expectGenerationCompletes
        ]
