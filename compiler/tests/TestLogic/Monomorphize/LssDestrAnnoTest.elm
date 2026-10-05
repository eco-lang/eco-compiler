module TestLogic.Monomorphize.LssDestrAnnoTest exposing (suite)

{-| Checks that the solver engine keeps the lambda set of a function that a
`case` takes out of a constructor and puts back into it, instead of leaving the
constructor's registry entries with ⊤ for that field.

A _lambda set_ is the annotation on the arrow of a monomorphized function type
naming the function values that can reach it (`Mono.LambdaSetAnno`): `LSet`
names them exactly, `LPartial` names some of them, `LVar` is not yet
determined, and `LTop`, written ⊤, means the set was widened. Outside the
analysis, `LVar` and `LTop` name no members, and only a one-member `LSet` is
read as a single known callee. A _registry entry_ is one specialization of a
global together with its type, as the monomorphized graph's
`registry.reverseMapping` holds it.

When a `case` branch binds a constructor's function-typed field to a variable,
the solver engine first types the variable from its canonical type alone, which
puts ⊤ on the arrows written in that type. It then recovers sets in two places:
from the type of the value being destructured, followed down to the field (in
`Compiler.MonoSolver.Translate`, the private `specializeDestructor`), and, once
every work item is done, for each constructor registry entry still carrying ⊤,
from the union of all entries of that constructor (in
`Compiler.MonoSolver.Monomorphize`, the private `settleCtorRows`). The first
merge, and the building of that union, use `Mono.enrichAnnotations`; the union
is written into each entry with `Mono.enrichAnnotationsTopOnly`, which leaves
an `LVar` position of the entry as it is.

The fixture is a module `Test` declaring `type PS x = Mk Int (Int -> x) | Nope`
and four annotated definitions:

  - `mkBox : PS Int` is `Mk 3 (\x -> x + 1)`.
  - `useBox : PS Int -> Int` matches `Mk r f` and gives `r + f 2`, and `0` for
    `Nope`.
  - `rebox : PS Int -> PS Int` matches `Mk r f` and gives `Mk r f`, and its
    argument for `Nope`. It is the definition that puts a bound field back into
    `Mk`.
  - `testValue : Int` is `useBox mkBox + useBox (rebox mkBox)`.

What the tests establish:

  - Test 1 compiles the fixture with the solver engine under the default
    lambda-set configuration and reads the annotation on the `Int -> x` arrow
    from every registry entry of a global named `Mk`. It requires at least one
    such annotation, at least one `LSet` with a member among them, and no
    `LTop`; an `LVar` or `LPartial` passes. It reads only the final registry.
  - Test 2 checks `enrichAnnotations` on one-arrow `Int -> Int` types, through
    the head annotation: a set is kept against `LVar` or `LTop` on the other
    side, a set on the other side replaces `LVar` or `LTop`, and two sets give
    their union (`[ 7 ]` and `[ 9 ]` give `[ 7, 9 ]`).
  - Test 3 checks that `enrichAnnotations` returns its first type unchanged
    when the second has a different number of parameters at the head arrow.

Among what is not tested: which members the set holds, the annotations
`useBox` and `rebox` themselves carry, `LPartial` in `enrichAnnotations`,
shape mismatches other than a parameter count, a function field inside a tuple
or record, and the substitution engine.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
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


{-| The three tests the module docstring describes.
-}
suite : Test
suite =
    Test.describe "destructor-bound annotations"
        [ Test.test "1. the destructured payload arrow carries a SET, never ⊤" <|
            \() ->
                case runWith fixture of
                    Ok onG ->
                        case unboxArgAnnos onG of
                            [] ->
                                Expect.fail "no Box /a0 position — fixture broken"

                            onA ->
                                if List.any isSet onA && not (List.any isTop onA) then
                                    Expect.pass

                                else
                                    Expect.fail ("expected SETs and no ⊤, got " ++ describe onA)

                    Err e ->
                        Expect.fail e
        , Test.test "2. enrichAnnotations never downgrades a set (re-landed pin)" <|
            \() ->
                let
                    setSide =
                        Mono.mFunction (Mono.LSet [ 7 ]) [ Mono.MInt ] Mono.MInt

                    varSide =
                        Mono.mFunction (Mono.LVar 3) [ Mono.MInt ] Mono.MInt

                    topSide =
                        Mono.mFunction Mono.topPoison [ Mono.MInt ] Mono.MInt

                    twoSide =
                        Mono.mFunction (Mono.LSet [ 9 ]) [ Mono.MInt ] Mono.MInt
                in
                Expect.equal
                    [ Mono.headAnno (Mono.enrichAnnotations setSide varSide)
                    , Mono.headAnno (Mono.enrichAnnotations setSide topSide)
                    , Mono.headAnno (Mono.enrichAnnotations varSide setSide)
                    , Mono.headAnno (Mono.enrichAnnotations topSide setSide)
                    , Mono.headAnno (Mono.enrichAnnotations setSide twoSide)
                    ]
                    [ Mono.LSet [ 7 ]
                    , Mono.LSet [ 7 ]
                    , Mono.LSet [ 7 ]
                    , Mono.LSet [ 7 ]
                    , Mono.LSet [ 7, 9 ]
                    ]
        , Test.test "3. structure is untouched on shape mismatch (MONO_029 pin)" <|
            \() ->
                let
                    structural =
                        Mono.mFunction Mono.topAbi [ Mono.MInt, Mono.MInt ] Mono.MInt

                    mismatched =
                        Mono.mFunction (Mono.LSet [ 5 ]) [ Mono.MInt ] Mono.MInt
                in
                Expect.equal structural (Mono.enrichAnnotations structural mismatched)
        ]



-- ====== FIXTURE ======


{-| The source type `Int`.
-}
hInt : Src.Type
hInt =
    tType "Int" []


{-| The source type `PS Int`, the one instantiation of `PS` the fixture uses.
-}
boxOfFn : Src.Type
boxOfFn =
    tType "PS" [ hInt ]


{-| The source type `Int -> x`, the type of `Mk`'s second field, written with
`PS`'s own parameter `x`.
-}
psFieldFn : Src.Type
psFieldFn =
    tLambda hInt (tVar "x")


{-| The test program the module docstring describes.
-}
fixture : Src.Module
fixture =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkBox"
          , args = []
          , tipe = boxOfFn
          , body = callExpr (ctorExpr "Mk") [ intExpr 3, lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)) ]
          }
        , { name = "useBox"
          , args = [ pVar "b" ]
          , tipe = tLambda boxOfFn hInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ]
                      , binopsExpr [ ( varExpr "r", "+" ) ] (callExpr (varExpr "f") [ intExpr 2 ])
                      )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , { name = "rebox"
          , args = [ pVar "b" ]
          , tipe = tLambda boxOfFn boxOfFn
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ]
                      , callExpr (ctorExpr "Mk") [ varExpr "r", varExpr "f" ]
                      )
                    , ( pCtor "Nope" [], varExpr "b" )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr [ ( callExpr (varExpr "useBox") [ varExpr "mkBox" ], "+" ) ]
                    (callExpr (varExpr "useBox") [ callExpr (varExpr "rebox") [ varExpr "mkBox" ] ])
          }
        ]
        [ { name = "PS"
          , args = [ "x" ]
          , ctors =
                [ { name = "Mk", args = [ hInt, psFieldFn ] }
                , { name = "Nope", args = [] }
                ]
          }
        ]
        []



-- ====== HARNESS ======


{-| Monomorphizes `srcModule` with the solver engine under
`Config.defaultLimits` and the default lambda-set configuration, giving the
graph before global optimization, or an error message.
-}
runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    Pipeline.runSolverMonoWithLimits Config.defaultLimits Config.defaultLss srcModule



-- ====== READERS ======


{-| Returns the annotation on the `Int -> x` arrow of `Mk`'s second field from
every registry entry of a global named `Mk`, in descending SpecId order.
Entries removed by pruning, and any whose type is not a one-parameter arrow
returning a one-parameter arrow whose parameter is itself an arrow, contribute
nothing.
-}
unboxArgAnnos : Mono.MonoGraph -> List Mono.LambdaSetAnno
unboxArgAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "Mk" then
                        case monoType of
                            -- The field's arrow is the one parameter of the
                            -- arrow that Mk's first application returns.
                            Mono.MFunction _ _ [ _ ] (Mono.MFunction _ _ [ Mono.MFunction _ anno _ _ ] _) ->
                                anno :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Reports whether an annotation is ⊤, whatever its provenance code.
-}
isTop : Mono.LambdaSetAnno -> Bool
isTop =
    Mono.isTopAnno


{-| Reports whether an annotation is an `LSet` with at least one member.
-}
isSet : Mono.LambdaSetAnno -> Bool
isSet a =
    case a of
        Mono.LSet (_ :: _) ->
            True

        _ ->
            False


{-| Renders `annos` for a failure message: `LTop` with its provenance label,
`LVar` with its number, and `LSet` and `LPartial` with how many members they
have, not which.
-}
describe : List Mono.LambdaSetAnno -> String
describe annos =
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
                annos
            )
        ++ "]"
