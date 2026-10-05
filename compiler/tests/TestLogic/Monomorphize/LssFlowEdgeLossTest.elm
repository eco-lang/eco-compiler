module TestLogic.Monomorphize.LssFlowEdgeLossTest exposing (suite)

{-| Checks that when a curried function is passed by bare reference to a
higher-order function, lambda-set specialization leaves known members on the
inner arrow of its type where it is consumed, and no set variable there where
it is defined.

Lambda-set specialization annotates each arrow of a monomorphized function
type with what is known about which functions a value on that arrow can be.
An `LSet` lists those functions, its members; an `LVar` is a set variable,
which names no members. A call through an arrow that names no members cannot
be turned into a direct call. The arrow this test is about is an inner one:
the type of what a two-stage function returns once it has its first argument.
Without this test, such an inner arrow could be left as a variable with
nothing failing.

The first fixture is the module `fixtureRef`:

    mkAdder =
        \a -> \b -> a + b

    useStep f seed =
        f seed 2

    testValue =
        useStep mkAdder 5

`mkAdder` is a value with no declared parameters whose body is two nested
lambdas, and it reaches `useStep` as a bare reference, not as the result of a
call. `useStep` applies its parameter `f` to one argument and the result to a
second, so both arrows of `f`'s type are used. The second fixture,
`fixtureCall`, hands `useStep` the result of a call instead:
`mkAdderC k = \a -> \b -> k + a + b` and `testValue = useStep (mkAdderC 1) 5`.
Each module is compiled with the solver engine at the default lambda-set
configuration and the default specialization limits, and the annotations are
read from the specialization registry, one row per specialization.

What the tests establish, for each fixture:

  - The producer (`mkAdder`, or `mkAdderC` after its one parameter) has
    exactly one row, and the two arrows of the function it hands over carry
    non-empty `LSet`s.
  - There is at least one `useStep` row, and every one carries exactly those
    two annotations on the arrow of its function parameter and on the arrow
    of that parameter's result, so the consumer and the producer were healed
    consistently.

Among what is not tested: which of the solver's passes fills the inner
arrows, and which members they hold.

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
        , varExpr
        )
import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The lambda-set tests for a curried function passed by bare reference and
as the result of a call, described in the module docstring.
-}
suite : Test
suite =
    Test.describe "flow edge loss — the §9 pinned examples"
        [ Test.test "BARE-REF arg at shipped defaults: settle heals both rows consistently" <|
            \() ->
                expectConsistentRows fixtureRef "mkAdder" 0
        , Test.test "CALL-RESULT arg at shipped defaults: settle heals both rows consistently" <|
            \() ->
                expectConsistentRows fixtureCall "mkAdderC" 1
        ]


{-| Compiles `fixture` and passes when the producer `producer` has exactly one
registry row and every `useStep` row (at least one) carries on its function
parameter's two arrows the same two annotations, both non-empty `LSet`s, as
the producer's row carries on the two arrows of the function it hands over:
its own type's arrows after dropping `skip` leading ones, the parameters
applied before the function is passed.
-}
expectConsistentRows : Src.Module -> String -> Int -> Expect.Expectation
expectConsistentRows fixture producer skip =
    case runDefaults fixture of
        Ok g ->
            let
                consumer =
                    useStepAnnos g

                produced =
                    List.map (curriedAnnos >> List.drop skip) (rowTypes producer g)
            in
            case produced of
                [ [ h, r ] ] ->
                    if isSet h && isSet r && not (List.isEmpty consumer) && List.all (\pair -> pair == ( h, r )) consumer then
                        Expect.pass

                    else
                        Expect.fail
                            ("expected every useStep row to carry the "
                                ++ producer
                                ++ " row's sets "
                                ++ describePairs [ ( h, r ) ]
                                ++ ", got useStep "
                                ++ describePairs consumer
                            )

                _ ->
                    Expect.fail
                        ("fixture broken: expected one "
                            ++ producer
                            ++ " row handing over a two-arrow function, got "
                            ++ String.join ", " (List.map describe produced)
                        )

        Err e ->
            Expect.fail e



-- ====== FIXTURES ======


{-| The source type `Int`, used in every fixture annotation.
-}
hInt : Src.Type
hInt =
    tType "Int" []


{-| The consumer shared by both fixtures, `useStep f seed = (f seed) 2`,
annotated `(Int -> Int -> Int) -> Int -> Int`.
-}
useStepDef : { name : String, args : List Src.Pattern, tipe : Src.Type, body : Src.Expr }
useStepDef =
    { name = "useStep"
    , args = [ pVar "f", pVar "seed" ]
    , tipe = tLambda (tLambda hInt (tLambda hInt hInt)) (tLambda hInt hInt)
    , body = callExpr (callExpr (varExpr "f") [ varExpr "seed" ]) [ intExpr 2 ]
    }


{-| The module the test compiles, in which `useStep` is given the value
`mkAdder = \a -> \b -> a + b` by bare reference: `testValue` is
`useStep mkAdder 5`.
-}
fixtureRef : Src.Module
fixtureRef =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkAdder"
          , args = []
          , tipe = tLambda hInt (tLambda hInt hInt)
          , body =
                lambdaExpr [ pVar "a" ]
                    (lambdaExpr [ pVar "b" ] (binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")))
          }
        , useStepDef
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body = callExpr (varExpr "useStep") [ varExpr "mkAdder", intExpr 5 ]
          }
        ]
        []
        []


{-| The module in which `useStep` is given the function a call returns:
`mkAdderC k = \a -> \b -> k + a + b`, annotated `Int -> Int -> Int -> Int`,
and `testValue` is `useStep (mkAdderC 1) 5`.
-}
fixtureCall : Src.Module
fixtureCall =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = "mkAdderC"
          , args = [ pVar "k" ]
          , tipe = tLambda hInt (tLambda hInt (tLambda hInt hInt))
          , body =
                lambdaExpr [ pVar "a" ]
                    (lambdaExpr [ pVar "b" ] (binopsExpr [ ( varExpr "k", "+" ), ( varExpr "a", "+" ) ] (varExpr "b")))
          }
        , useStepDef
        , { name = "testValue"
          , args = []
          , tipe = hInt
          , body = callExpr (varExpr "useStep") [ callExpr (varExpr "mkAdderC") [ intExpr 1 ], intExpr 5 ]
          }
        ]
        []
        []



-- ====== HARNESS ======


{-| Compiles `srcModule` and monomorphizes it with the solver engine, the
default lambda-set configuration and the default specialization limits,
returning the graph or the message of the first stage that failed.

Setting `enabled` changes nothing, since it is already `True` in
`Config.defaultLss`.

-}
runDefaults : Src.Module -> Result String Mono.MonoGraph
runDefaults srcModule =
    let
        d =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { d | enabled = True }
        srcModule



-- ====== READERS ======


{-| Returns, for each registry row of `useStep` whose first parameter is a
function returning a function, the annotations on that parameter's own arrow
and on the arrow of its result, in that order. Rows of any other shape are
skipped.
-}
useStepAnnos : Mono.MonoGraph -> List ( Mono.LambdaSetAnno, Mono.LambdaSetAnno )
useStepAnnos (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == "useStep" then
                        case monoType of
                            Mono.MFunction _ _ ((Mono.MFunction _ headA _ (Mono.MFunction _ resA _ _)) :: _) _ ->
                                ( headA, resA ) :: acc

                            _ ->
                                acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns the type of every registry row of the global named `name`.
-}
rowTypes : String -> Mono.MonoGraph -> List Mono.MonoType
rowTypes name (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ n, monoType ) ->
                    if n == name then
                        monoType :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns the annotations on the arrows of a curried function type, the
outermost first, following each arrow's result. A flattened arrow with more
than one parameter ends the walk, so it shows as a shorter list.
-}
curriedAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
curriedAnnos t =
    case t of
        Mono.MFunction _ anno [ _ ] result ->
            anno :: curriedAnnos result

        _ ->
            []


{-| Tells whether an annotation is an `LSet` with at least one member.
-}
isSet : Mono.LambdaSetAnno -> Bool
isSet a =
    case a of
        Mono.LSet (_ :: _) ->
            True

        _ ->
            False


{-| Renders the pairs `useStepAnnos` returns, for a failure message.
-}
describePairs : List ( Mono.LambdaSetAnno, Mono.LambdaSetAnno ) -> String
describePairs pairs =
    "[" ++ String.join ", " (List.map (\( h, r ) -> "(" ++ one h ++ " -> " ++ one r ++ ")") pairs) ++ "]"


{-| Renders a list of annotations, for a failure message.
-}
describe : List Mono.LambdaSetAnno -> String
describe xs =
    "[" ++ String.join ", " (List.map one xs) ++ "]"


{-| Renders one annotation as its constructor name followed by its top kind
label, its variable number or its member count.
-}
one : Mono.LambdaSetAnno -> String
one a =
    case a of
        Mono.LTop k ->
            "LTop " ++ Mono.topKindLabel k

        Mono.LVar n ->
            "LVar " ++ String.fromInt n

        Mono.LSet ms ->
            "LSet " ++ String.fromInt (List.length ms)

        Mono.LPartial ms ->
            "LPartial " ++ String.fromInt (List.length ms)
