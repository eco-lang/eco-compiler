module TestLogic.Monomorphize.LssVarCtorRowsTest exposing (suite)

{-| Checks, on two small fixtures, that the solver engine leaves no unresolved
lambda set, `LVar`, on the payload of the constructor `Mk`, and that
`Mono.enrichAnnotationsTopOnly` keeps an `LVar` base unchanged on a one-arrow
function type.

A _lambda set_ is the set of functions that may reach an arrow, and
`Mono.LambdaSetAnno` records it on every `MFunction`. `LSet` names the
members, `LPartial` names some members and admits more, `LTop` means the
members are unknown, and `LVar` is a set variable: a slot that nothing
wrote. As `Mono.LambdaSetAnno` describes, consumers other than the
analysis treat `LVar` as they treat `LTop`: it names no members, so no call
through it can be devirtualized. A constructor's
_registry row_ is one of its `( Global, MonoType )` entries in the graph's
`reverseMapping`, one per specialization.

Once specialization finishes, `Compiler.MonoSolver.Monomorphize` settles
constructor rows from their sibling rows. Its pass that fills a variable
slot on a constructor row from the sets of the sibling rows does so under a
completeness rule of its own, and it heals rows that carry `LTop` with
`Mono.enrichAnnotationsTopOnly`. That merge drops `LTop` contributors
from the union it writes, so used on a never-written slot it could write a
set that leaves out a function that reaches the slot; it therefore keeps an
`LVar` base as it is.

The fixtures declare `type PS x = Mk Int (Int -> x) | Nope`, and the payload
tests 1 and 2 read is `Mk`'s second argument, the arrow `Int -> x`.
`fixtureClean` builds one `PS Int` with `Mk` and a literal lambda and
consumes it, and also builds a `PS String` with `Nope` alone, so `Mk` is
never constructed at `PS String`. `fixtureFlex` keeps `fixtureClean`'s
`mkBox` and `useBox`, drops the `PS String` definitions, and adds a `Mk`
construction whose payload is a function parameter rather than a literal
lambda. Both are run by `runWith`.

  - Test 1 requires `fixtureClean` to give at least one readable `Mk` payload
    annotation, and none of them to be `LVar`.
  - Test 2 requires none of `fixtureFlex`'s `Mk` payload annotations to be
    `LVar`. It does not require any to be found.
  - Test 3 calls `Mono.enrichAnnotationsTopOnly` on one-arrow `Int -> Int`
    types: an `LVar 3` base stays `LVar 3` against an `LSet [ 7 ]` source,
    an `LTop` base becomes `LSet [ 7 ]`, and an `LSet [ 7 ]` base stays as it
    is against an `LVar` source.

Among what is not tested: whether a payload was never a variable or was
filled by settling, so the completeness rule's refusals are not exercised;
`Mk` rows whose type does not have the shape `mkPayloadAnnos` reads; payloads
that are `LTop` or `LPartial`; and `Mono.enrichAnnotationsTopOnly` on nested
arrows or on types other than functions.

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


{-| The three tests described in the module docstring.
-}
suite : Test
suite =
    Test.describe "completeness-gated ctor-row var writes"
        [ Test.test "1. the clean fixture's ctor payload rows carry no var" <|
            \() ->
                case runWith fixtureClean of
                    Ok g ->
                        case mkPayloadAnnos g of
                            [] ->
                                Expect.fail "no Mk /a1 payload positions — fixture broken"

                            a ->
                                if List.any isVar a then
                                    Expect.fail
                                        ("fixture manufactured a var row after all — UPGRADE this pin to a real differential: "
                                            ++ describe a
                                        )

                                else
                                    Expect.pass

                    Err e ->
                        Expect.fail e
        , Test.test "2. the flex fixture's ctor payload rows carry no var either" <|
            \() ->
                case runWith fixtureFlex of
                    Ok g ->
                        if List.any isVar (mkPayloadAnnos g) then
                            Expect.fail ("expected no var row, got " ++ describe (mkPayloadAnnos g))

                        else
                            Expect.pass

                    Err e ->
                        Expect.fail e
        , Test.test "3. enrichAnnotationsTopOnly: LVar base never flips, LTop base heals (AR-V1 pin)" <|
            \() ->
                let
                    varSide =
                        Mono.mFunction (Mono.LVar 3) [ Mono.MInt ] Mono.MInt

                    topSide =
                        Mono.mFunction Mono.topPoison [ Mono.MInt ] Mono.MInt

                    setSide =
                        Mono.mFunction (Mono.LSet [ 7 ]) [ Mono.MInt ] Mono.MInt
                in
                Expect.equal
                    [ Mono.headAnno (Mono.enrichAnnotationsTopOnly varSide setSide)
                    , Mono.headAnno (Mono.enrichAnnotationsTopOnly topSide setSide)
                    , Mono.headAnno (Mono.enrichAnnotationsTopOnly setSide varSide)
                    ]
                    [ Mono.LVar 3
                    , Mono.LSet [ 7 ]
                    , Mono.LSet [ 7 ]
                    ]
        ]



-- ====== FIXTURES ======


{-| The source type `Int`.
-}
hInt : Src.Type
hInt =
    tType "Int" []


{-| The source type `PS Int`.
-}
psOfInt : Src.Type
psOfInt =
    tType "PS" [ hInt ]


{-| The source type `Int -> x`, the field type of `Mk`'s function payload.
-}
psField : Src.Type
psField =
    tLambda hInt (tVar "x")


{-| The declaration `type PS x = Mk Int (Int -> x) | Nope`, in the form the
module builder takes.
-}
psUnion : { name : String, args : List String, ctors : List { name : String, args : List Src.Type } }
psUnion =
    { name = "PS"
    , args = [ "x" ]
    , ctors =
        [ { name = "Mk", args = [ hInt, psField ] }
        , { name = "Nope", args = [] }
        ]
    }


{-| A module in which `Mk` is constructed in one place, by `mkBox`, with
the literal lambda `\x -> x + 1` as its payload, and that payload is called
by `useBox`.

`nopeStr` is a `PS String` built with `Nope`, and `peekStr` matches on it with
a `Mk` branch, so `PS String` is used without `Mk` ever being constructed at
that type. `testValue` calls `useBox` and `peekStr` so that both are
specialized.

-}
fixtureClean : Src.Module
fixtureClean =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkBox"
          , args = []
          , tipe = psOfInt
          , body =
                callExpr (ctorExpr "Mk")
                    [ intExpr 3
                    , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    ]
          }
        , { name = "useBox"
          , args = [ pVar "b" ]
          , tipe = tLambda psOfInt hInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ]
                      , binopsExpr [ ( varExpr "r", "+" ) ] (callExpr (varExpr "f") [ intExpr 2 ])
                      )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , { name = "nopeStr"
          , args = []
          , tipe = tType "PS" [ tType "String" [] ]
          , body = ctorExpr "Nope"
          }
        , { name = "peekStr"
          , args = [ pVar "b" ]
          , tipe = tLambda (tType "PS" [ tType "String" [] ]) hInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ], varExpr "r" )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr [ ( callExpr (varExpr "useBox") [ varExpr "mkBox" ], "+" ) ]
                    (callExpr (varExpr "peekStr") [ varExpr "nopeStr" ])
          }
        ]
        [ psUnion ]
        []


{-| A module with `fixtureClean`'s `mkBox` and `useBox`, plus a second `Mk`
construction whose payload is a function parameter.

`wrap f = Mk 1 f` is polymorphic in the payload's result, and is called only
through `wrap2`, which passes on its own parameter. `testValue` calls `wrap2`
with the lambda `\z -> z + 9` and hands the result to `useBox`, so two
functions reach `Mk`'s payload: `mkBox`'s lambda and that one.

-}
fixtureFlex : Src.Module
fixtureFlex =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkBox"
          , args = []
          , tipe = psOfInt
          , body =
                callExpr (ctorExpr "Mk")
                    [ intExpr 3
                    , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                    ]
          }
        , { name = "wrap"
          , args = [ pVar "f" ]
          , tipe = tLambda (tLambda hInt (tVar "x")) (tType "PS" [ tVar "x" ])
          , body = callExpr (ctorExpr "Mk") [ intExpr 1, varExpr "f" ]
          }
        , { name = "wrap2"
          , args = [ pVar "h" ]
          , tipe = tLambda (tLambda hInt (tVar "y")) (tType "PS" [ tVar "y" ])
          , body = callExpr (varExpr "wrap") [ varExpr "h" ]
          }
        , { name = "useBox"
          , args = [ pVar "b" ]
          , tipe = tLambda psOfInt hInt
          , body =
                caseExpr (varExpr "b")
                    [ ( pCtor "Mk" [ pVar "r", pVar "f" ]
                      , binopsExpr [ ( varExpr "r", "+" ) ] (callExpr (varExpr "f") [ intExpr 2 ])
                      )
                    , ( pCtor "Nope" [], intExpr 0 )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "useBox") [ varExpr "mkBox" ], "+" ) ]
                    (callExpr (varExpr "useBox")
                        [ callExpr (varExpr "wrap2")
                            [ lambdaExpr [ pVar "z" ] (binopsExpr [ ( varExpr "z", "+" ) ] (intExpr 9)) ]
                        ]
                    )
          }
        ]
        [ psUnion ]
        []



-- ====== HARNESS ======


{-| Monomorphizes `srcModule` with the solver engine, under the default limits
and the default lambda-set configuration with `enabled` set, which that
default already has.
-}
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


{-| Returns the lambda-set annotation of `Mk`'s function payload from every
registry row named `Mk`.

A row is read only when its type is two curried one-parameter arrows whose
second parameter is a function; any other row named `Mk` is skipped.
Removed specializations are skipped too.

-}
mkPayloadAnnos : Mono.MonoGraph -> List Mono.LambdaSetAnno
mkPayloadAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "Mk" then
                        case monoType of
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


{-| Tells whether an annotation is a set variable, `LVar`.
-}
isVar : Mono.LambdaSetAnno -> Bool
isVar a =
    case a of
        Mono.LVar _ ->
            True

        _ ->
            False


{-| Renders annotations for a failure message, giving each set's member count
rather than its members.
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
