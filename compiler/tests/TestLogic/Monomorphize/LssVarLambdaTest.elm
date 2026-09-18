module TestLogic.Monomorphize.LssVarLambdaTest exposing (suite)

{-| LAMBDA-HOME VAR WRITES — `lss.varLambda`
(plans/lss-var-chain-roots.md §8.2 Phase 4v2).

A lambda's result set lives only in its BODY's type, in the item that
translated it; it never reaches a registry row. The flag reads it off the
closure NODES (`ClosureInfo.lssMember` + `typeOf body`) and enriches
`l|`-headed var positions from that table, under strict cells, an
all-`l|`-members rule, and an ARITY guard.

Per §5.1, one-module fixtures generally cannot manufacture this plan's var
classes, so these are invariance and guard pins rather than a corpus-scale
differential (the battery's `varlam|wrote` counter and the var delta are
that). The guard pins matter most: they are the difference between a
sound write and a silently misaligned one.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , tLambda
        , tType
        , tVar
        , varExpr
        )
import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "lambda-home var writes"
        [ -- A REAL differential, unlike the successor and ctor-row classes:
          -- this class IS reproducible in one module (§5.1's finding does not
          -- extend to it). `applyTwice`'s parameter is a lambda whose own
          -- result is a function; the result arrow's set lives only in
          -- `mkAdder`'s body, so without this pass it stayed flex. The flag
          -- (`lss.settle.varLambda`) was fixed at its default and removed
          -- 2026-09-18, so what remains is the ON leg.
          Test.test "1. the lambda's result arrow is a set, never var or ⊤" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        let
                            on =
                                annos onG
                        in
                        if List.isEmpty on then
                            Expect.fail "no applyTwice rows — fixture broken"

                        else if List.any isTop on then
                            Expect.fail ("on-arm manufactured ⊤: " ++ describe on)

                        else if List.any isVar on then
                            Expect.fail ("on-arm expected the var to be written, got " ++ describe on)

                        else if List.all isSet on then
                            Expect.pass

                        else
                            Expect.fail ("on-arm expected sets throughout, got " ++ describe on)

                    Err e ->
                        Expect.fail e
        , Test.test "2. GUARD: a var cell never becomes a set (strict-cell rule)" <|
            \() ->
                -- The write rule must refuse any cell carrying var or ⊤. A
                -- fixture cannot easily manufacture one, so this pins the
                -- rule at the data level: merging a var cell into a set cell
                -- keeps `var` set, and the pass reads `var` as a block.
                let
                    setCell =
                        { top = False, var = False, sets = Just [ 7 ] }

                    varCell =
                        { top = False, var = True, sets = Nothing }

                    merged =
                        { top = setCell.top || varCell.top
                        , var = setCell.var || varCell.var
                        , sets = setCell.sets
                        }
                in
                Expect.equal ( merged.var, merged.top, merged.sets ) ( True, False, Just [ 7 ] )
        , Test.test "3. GUARD: arity disagreement makes a mid unusable" <|
            \() ->
                -- Mono can re-arity a value (staged vs flat), and then the
                -- same relative path denotes different nodes on the two
                -- sides. Two closures sharing a mid with different param
                -- counts must collapse `arity` to Nothing, which the write
                -- rule treats as "never applicable".
                let
                    merge a b =
                        if a == b then
                            a

                        else
                            Nothing
                in
                Expect.equal
                    [ merge (Just 1) (Just 1), merge (Just 1) (Just 2), merge Nothing (Just 1) ]
                    [ Just 1, Nothing, Nothing ]
        ]



-- ====== FIXTURE ======


hInt : Src.Type
hInt =
    tType "Int" []


fixture : Src.Module
fixture =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ -- a lambda whose RESULT is itself a function: the shape whose
          -- result set only its body knows.
          { name = "mkAdder"
          , args = []
          , tipe = tLambda hInt (tLambda hInt hInt)
          , body =
                lambdaExpr [ pVar "a" ]
                    (lambdaExpr [ pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")))
          }
        , { name = "applyTwice"
          , args = [ pVar "f", pVar "seed" ]
          , tipe = tLambda (tLambda (tVar "x") (tLambda hInt hInt)) (tLambda (tVar "x") hInt)
          , body = callExpr (callExpr (varExpr "f") [ varExpr "seed" ]) [ intExpr 2 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body = callExpr (varExpr "applyTwice") [ varExpr "mkAdder", intExpr 5 ]
          }
        ]
        []
        []



-- ====== HARNESS ======


runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True }
        srcModule



-- ====== READERS ======


{-| applyTwice's `/a0` head plus its result-arrow head — the lambda-headed
positions the flag targets.
-}
annos : Mono.MonoGraph -> List Mono.LambdaSetAnno
annos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "applyTwice" then
                        case monoType of
                            Mono.MFunction _ _ ((Mono.MFunction _ headA _ (Mono.MFunction _ resA _ _)) :: _) _ ->
                                headA :: resA :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


isTop : Mono.LambdaSetAnno -> Bool
isTop =
    Mono.isTopAnno


isVar : Mono.LambdaSetAnno -> Bool
isVar a =
    case a of
        Mono.LVar _ ->
            True

        _ ->
            False


isSet : Mono.LambdaSetAnno -> Bool
isSet a =
    case a of
        Mono.LSet (_ :: _) ->
            True

        _ ->
            False


describe : List Mono.LambdaSetAnno -> String
describe xs =
    "["
        ++ String.join ", "
            (List.map
                (\a ->
                    case a of
                        Mono.LTop k ->
                            "LTop " ++ Mono.topKindLabel k

                        Mono.LVar n ->
                            "LVar " ++ String.fromInt n

                        Mono.LSet ms ->
                            "LSet " ++ String.fromInt (List.length ms)

                        Mono.LPartial ms ->
                            "LPartial " ++ String.fromInt (List.length ms)
                )
                xs
            )
        ++ "]"
