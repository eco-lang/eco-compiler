module TestLogic.Monomorphize.LssSigFlowTest exposing (suite)

{-| Checks that the solver engine's signature set flow carries lambda-set
members through a definition's signature in the right direction, and widens to
`LTop` where it cannot see every member. Without these tests a caller could be
handed a set that is too small, which is a miscompile once a one-member set is
devirtualized to a direct call, or a set that mixes two parameters' members,
which loses precision without failing anything.

A _lambda set_ is the annotation on an arrow of a `MonoType`: the function
values, by member id, that can reach that arrow. `Compiler.AST.Monomorphized`
owns its meaning (`LambdaSetAnno`). What matters here is that an `LSet` lists
its members and is read as complete, an `LTop` has been widened, and an `LVar`
is an arrow nothing was written to. _Signature set flow_ is the part of the
solver's signature inference (`Compiler.MonoSolver.LssInfer`) that connects the
flow inside a definition's body to the arrows of its annotation, so that a
caller receives the members the body contributes. Three of that module's terms
are used below:

  - A _hub_ is the point where the branches of an `if` or `case` meet. Each
    branch flows into the hub in one direction, so a branch keeps its own set
    and the hub reads as the union of its branches.
  - A hub is _poisoned_, set to `LTop`, when any branch is not known to carry
    its complete set, such as a call result.
  - Flow between two tuple, record or custom types is _degraded_: the whole
    subtree is joined in both directions instead. The solver's report counts,
    as `degraded=`, each degrade whose types contain an arrow.

Each fixture is a module `Test` of annotated definitions and a `testValue : Int`
that calls the definition under test. It is monomorphized on the solver engine
through `TestLogic.TestPipeline`, with `Config.defaultLss` (lambda-set
specialization enabled) and `Config.defaultLimits` except where a test below
says otherwise, and the tests read the _demand types_ of that definition: the
`MonoType` of each of its specializations in the output registry's
`reverseMapping`. A demand type's _result arrow_ is the last function type on
its return spine, and its _parameter arrows_ are the arguments down that spine
that are functions.

The numbers in the test names are labels; there are no tests 2, 3 or 5.

  - 1a: `chooseHandler b f g = if b then f else g`, called with two different
    lambdas. Some result arrow is an `LSet` of exactly two members, and exactly
    two parameter arrows are one-member `LSet`s, with different members. A hub
    that joined its branches in both directions would give each parameter
    both lambdas and fail the second assertion.
  - 4: `pick c g = if c then inc else g 0`, where `testValue` passes `mkAdd`
    as `g`. One branch is the global `inc`, the other a call result. There is
    at least one result arrow and every one is `LTop`. A hub that published
    only the member it could see would claim `inc` as the only function
    reaching the result.
  - 6: `mk2 s` returns one of two lambdas written in its body, run with
    `maxSetSize = 1` and the report on. The report's `bySigSize=` count is
    exactly 1, and there is at least one result arrow of `mk2` and every one
    is `LTop`.
  - 7: `chain b c f g h = if b then f else (if c then g else h)`, called with
    three different lambdas. The inner hub is a branch of the outer one.
    Some result arrow is a three-member `LSet`, and the parameter arrows are
    exactly three one-member `LSet`s.
  - 8: `choosePair b p q = if b then p else q` over pairs of `Int -> Int`
    functions, called with two tuple literals of lambdas, with the report on.
    Both parameter tuples and the result tuple carry the same two two-member
    `LSet`s (the hub joined `p` and `q` in both directions), and the report's
    `degraded=` count is at least 1. The control `firstPairModule`, where
    `choosePair b p q = p` has no hub, degrades nothing and keeps a
    one-member `LSet` on every tuple element, so the degrade is the hub's.
  - 9: `useH b hof1 hof2 k = let h = if b then hof1 else hof2 in h k`, where
    `hof1` and `hof2` each take an `Int -> Int`. Flow into a parameter runs
    backwards: `k` flows into `h`'s parameter, and from there into the
    parameters of `hof1` and `hof2`. Across the demand types there are exactly
    two such inner arrows; each is an `LVar`, an `LTop`, or equal to the
    annotation on `k`'s arrow in some demand type; and neither carries, in an
    `LSet` or an `LPartial`, a member found on the arrows of `hof1` or `hof2`
    themselves. Flow in the wrong direction would put those members there.

Among what is not tested: a `case` as a hub; degrades of record and custom
types; which members a set holds, except in tests 8 and 9; `LPartial`
annotations, which the size checks of tests 1a and 7 do not count as a match.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefs
        , pTuple
        , pVar
        , tLambda
        , tTuple
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The signature set-flow tests listed in the module docstring.
-}
suite : Test
suite =
    Test.describe "LSS_020 signature set-flow"
        [ Test.test "1a. THE depollution pin: chooseHandler's result reads the honest 2-set AND the params keep DISTINCT singletons" <|
            \() ->
                case run chooseHandlerModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "chooseHandler" graph)

                            paramSingletons =
                                demandsOf "chooseHandler" graph
                                    |> List.concatMap paramArrowAnnos
                                    |> List.filterMap
                                        (\anno ->
                                            case anno of
                                                Mono.LSet [ m ] ->
                                                    Just m

                                                _ ->
                                                    Nothing
                                        )
                        in
                        Expect.all
                            [ \() ->
                                if List.any (annoHasSize 2) resultAnnos then
                                    Expect.pass

                                else
                                    Expect.fail ("result arrow should be an honest 2-set, got: " ++ describeAnnos resultAnnos)
                            , \() ->
                                case paramSingletons of
                                    [ m1, m2 ] ->
                                        if m1 /= m2 then
                                            Expect.pass

                                        else
                                            Expect.fail "param singletons must be DISTINCT members"

                                    _ ->
                                        Expect.fail
                                            ("expected exactly two SINGLETON param arrows (the depollution), got: "
                                                ++ describeAnnos (List.concatMap paramArrowAnnos (demandsOf "chooseHandler" graph))
                                            )
                            ]
                            ()
        , Test.test "4. HONESTY pin: a hub mixing an honest branch with a call result POISONS (no false singleton)" <|
            \() ->
                case run pickModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "pick" graph)
                        in
                        if List.isEmpty resultAnnos then
                            Expect.fail "no pick demands found"

                        else if List.all Mono.isTopAnno resultAnnos then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected LTop on every pick result arrow (honesty rule), got: "
                                    ++ describeAnnos resultAnnos
                                )
        , Test.test "6. B.4 rider: a >maxSetSize signature arrow widens and bumps widenedBySigSize" <|
            \() ->
                let
                    defaults =
                        Config.defaultLss
                in
                case
                    Pipeline.runSolverMonoWithReport Config.defaultLimits
                        { defaults | enabled = True, maxSetSize = 1 }
                        mk2Module
                of
                    Err msg ->
                        Expect.fail msg

                    Ok ( graph, maybeReport ) ->
                        let
                            report =
                                Maybe.withDefault "" maybeReport

                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "mk2" graph)
                        in
                        Expect.all
                            [ \() ->
                                if counterOf "bySigSize=" report == 1 then
                                    Expect.pass

                                else
                                    Expect.fail ("expected bySigSize=1 in the report, got: " ++ report)
                            , \() ->
                                if List.all Mono.isTopAnno resultAnnos && not (List.isEmpty resultAnnos) then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the widened result arrow to read LTop, got: "
                                            ++ describeAnnos resultAnnos
                                        )
                            ]
                            ()
        , Test.test "7. transitive chain: three lambdas through a nested hub — result 3-set, params all singletons" <|
            \() ->
                case run chainModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            resultAnnos =
                                List.filterMap deepestRetAnno (demandsOf "chain" graph)

                            paramAnnos =
                                List.concatMap paramArrowAnnos (demandsOf "chain" graph)
                        in
                        Expect.all
                            [ \() ->
                                if List.any (annoHasSize 3) resultAnnos then
                                    Expect.pass

                                else
                                    Expect.fail ("expected a 3-set result, got: " ++ describeAnnos resultAnnos)
                            , \() ->
                                if List.length paramAnnos == 3 && List.all (annoHasSize 1) paramAnnos then
                                    Expect.pass

                                else
                                    Expect.fail ("expected three singleton params, got: " ++ describeAnnos paramAnnos)
                            ]
                            ()
        , Test.test "8. container degrade: a Tuple hub goes symmetric and the report counts it" <|
            \() ->
                case ( runWithReport choosePairModule, runWithReport firstPairModule ) of
                    ( Err msg, _ ) ->
                        Expect.fail msg

                    ( _, Err msg ) ->
                        Expect.fail msg

                    ( Ok ( hubGraph, hubReport ), Ok ( ctlGraph, ctlReport ) ) ->
                        let
                            hubTuples =
                                List.concatMap tupleAnnosOnSpine (demandsOf "choosePair" hubGraph)

                            ctlTuples =
                                List.concatMap tupleAnnosOnSpine (demandsOf "choosePair" ctlGraph)
                        in
                        Expect.all
                            [ \() ->
                                -- The hub joins p and q both ways, so both
                                -- parameters and the result read the same two
                                -- 2-member sets.
                                case hubTuples of
                                    (first :: _) as tuples ->
                                        if
                                            List.length tuples
                                                == 3
                                                && List.all ((==) first) tuples
                                                && List.map (annoHasSize 2) first
                                                == [ True, True ]
                                        then
                                            Expect.pass

                                        else
                                            Expect.fail ("expected p, q and the result to read the same pair of 2-sets, got: " ++ String.join " / " (List.map describeAnnos tuples))

                                    [] ->
                                        Expect.fail "no choosePair tuple annos found"
                            , \() ->
                                if counterOf "degraded=" hubReport >= 1 then
                                    Expect.pass

                                else
                                    Expect.fail ("expected a nonzero degrade count, report says: " ++ hubReport)
                            , \() ->
                                -- Control: without the hub nothing degrades (the
                                -- tuple-literal arguments do not), and each
                                -- parameter keeps its own singletons.
                                if
                                    counterOf "degraded=" ctlReport
                                        == 0
                                        && List.length ctlTuples
                                        == 3
                                        && List.all (List.all (annoHasSize 1)) ctlTuples
                                then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("expected the hub-less control to keep singletons and degrade nothing, got: "
                                            ++ String.join " / " (List.map describeAnnos ctlTuples)
                                            ++ " with report "
                                            ++ ctlReport
                                        )
                            ]
                            ()
        , Test.test "9. contravariance pin: a HOF param's inner arrow is LTop or carries k — never a k-less non-⊤ set" <|
            \() ->
                case run useHModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            hofInnerAnnos =
                                demandsOf "useH" graph
                                    |> List.concatMap hofParamInnerAnnos
                        in
                        Expect.equal ( 2, True, True )
                            ( List.length hofInnerAnnos
                            , List.all
                                (\a ->
                                    isVarAnno a
                                        || Mono.isTopAnno a
                                        || List.member a (plainFnParamAnnosOf "useH" graph)
                                )
                                hofInnerAnnos
                            , List.all
                                (\a ->
                                    List.all
                                        (\m -> not (List.member m (backwardsMembers "useH" graph)))
                                        (membersOf a)
                                )
                                hofInnerAnnos
                            )
        ]



-- ====== HARNESS ======


{-| Monomorphizes `srcModule` on the solver engine with `Config.defaultLss` and
the default limits, giving the output graph or the pipeline's error message.
-}
run : Src.Module -> Result String Mono.MonoGraph
run srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        -- `enabled` is already True in `defaultLss`.
        { defaults | enabled = True }
        srcModule


{-| Monomorphizes `srcModule` like `run`, with the lambda-set report on, giving
the output graph and the report text, empty when the solver returned none.
-}
runWithReport : Src.Module -> Result String ( Mono.MonoGraph, String )
runWithReport srcModule =
    Pipeline.runSolverMonoWithReport Config.defaultLimits Config.defaultLss srcModule
        |> Result.map (Tuple.mapSecond (Maybe.withDefault ""))


{-| Returns the number written straight after the first occurrence of
`label` in `report`, where `label` includes the `=`, as in `"degraded="`.
Gives -1 when `label` does not occur or is not followed by a digit, so a
`bySigSize=1` check does not also accept 10 to 19.
-}
counterOf : String -> String -> Int
counterOf label report =
    case String.split label report |> List.drop 1 |> List.head of
        Just rest ->
            Maybe.withDefault -1 (String.toInt (String.fromList (takeDigits (String.toList rest))))

        Nothing ->
            -1


{-| Returns the leading decimal digits of `chars`.
-}
takeDigits : List Char -> List Char
takeDigits chars =
    case chars of
        c :: rest ->
            if Char.isDigit c then
                c :: takeDigits rest

            else
                []

        [] ->
            []


{-| Returns the demand type of every specialization in `graph` whose global is
named `target`, read from the registry's `reverseMapping`. Only the name is
compared, not the module.
-}
demandsOf : String -> Mono.MonoGraph -> List Mono.MonoType
demandsOf target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == target then
                        monoType :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns the annotations of the parameter arrows of `t`: the head annotation
of each argument that is itself a function, at every level of the return spine.
Arrows inside a parameter's own type are not included.
-}
paramArrowAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
paramArrowAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a ->
                    case a of
                        Mono.MFunction _ anno _ _ ->
                            Just anno

                        _ ->
                            Nothing
                )
                args
                ++ paramArrowAnnos ret

        _ ->
            []


{-| Returns the annotation of the result arrow of `t`: the head annotation of
the last function type on its return spine, or `Nothing` when `t` is not a
function.
-}
deepestRetAnno : Mono.MonoType -> Maybe Mono.LambdaSetAnno
deepestRetAnno t =
    case t of
        Mono.MFunction _ anno _ ret ->
            case deepestRetAnno ret of
                Just deeper ->
                    Just deeper

                Nothing ->
                    Just anno

        _ ->
            Nothing


{-| Returns, for every tuple argument down `t`'s return spine and the tuple
the spine ends in, the head annotations of its function elements, in that
order.
-}
tupleAnnosOnSpine : Mono.MonoType -> List (List Mono.LambdaSetAnno)
tupleAnnosOnSpine t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap tupleFnAnnos args ++ tupleAnnosOnSpine ret

        _ ->
            List.filterMap tupleFnAnnos [ t ]


{-| Returns the head annotations of the function elements of a tuple type, or
`Nothing` for any other type.
-}
tupleFnAnnos : Mono.MonoType -> Maybe (List Mono.LambdaSetAnno)
tupleFnAnnos t =
    case t of
        Mono.MTuple _ els ->
            Just
                (List.filterMap
                    (\el ->
                        case el of
                            Mono.MFunction _ anno _ _ ->
                                Just anno

                            _ ->
                                Nothing
                    )
                    els
                )

        _ ->
            Nothing


{-| Returns, for each higher-order parameter of `t`, the annotation of the
function it takes, at every level of the return spine. A higher-order parameter
here is a function whose only argument is itself a function, such as
`(Int -> Int) -> Int`.
-}
hofParamInnerAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
hofParamInnerAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a ->
                    case a of
                        Mono.MFunction _ _ [ Mono.MFunction _ innerAnno _ _ ] _ ->
                            Just innerAnno

                        _ ->
                            Nothing
                )
                args
                ++ hofParamInnerAnnos ret

        _ ->
            []


{-| Returns the head annotations of the function parameters of `target`'s
demand types that are not higher-order, as `hofParamInnerAnnos` uses the term.
In `useHModule` that is `k`'s arrow.
-}
plainFnParamAnnosOf : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
plainFnParamAnnosOf target graph =
    List.concatMap plainFnParamAnnos (demandsOf target graph)


{-| Returns the head annotations of the function parameters of `t` that are not
higher-order, at every level of the return spine.
-}
plainFnParamAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
plainFnParamAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a ->
                    case a of
                        Mono.MFunction _ _ [ Mono.MFunction _ _ _ _ ] _ ->
                            -- a HOF param, not a plain one
                            Nothing

                        Mono.MFunction _ anno _ _ ->
                            Just anno

                        _ ->
                            Nothing
                )
                args
                ++ plainFnParamAnnos ret

        _ ->
            []


{-| Returns the members on the head arrows of `target`'s higher-order
parameters, across its demand types: the members that a flow in the wrong
direction would put on the arrows those parameters take.
-}
backwardsMembers : String -> Mono.MonoGraph -> List Int
backwardsMembers target graph =
    List.concatMap membersOf
        (List.concatMap hofParamOuterAnnos (demandsOf target graph))


{-| Returns the head annotation of each higher-order parameter of `t`, at every
level of the return spine.
-}
hofParamOuterAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
hofParamOuterAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a ->
                    case a of
                        Mono.MFunction _ outerAnno [ Mono.MFunction _ _ _ _ ] _ ->
                            Just outerAnno

                        _ ->
                            Nothing
                )
                args
                ++ hofParamOuterAnnos ret

        _ ->
            []


{-| Returns the members an `LSet` or an `LPartial` lists, and nothing for
`LTop` or `LVar`.
-}
membersOf : Mono.LambdaSetAnno -> List Int
membersOf anno =
    case anno of
        Mono.LSet ms ->
            ms

        Mono.LPartial ms ->
            ms

        _ ->
            []


{-| Tells whether `anno` is an `LVar`, an arrow nothing was written to.
-}
isVarAnno : Mono.LambdaSetAnno -> Bool
isVarAnno anno =
    case anno of
        Mono.LVar _ ->
            True

        _ ->
            False


{-| Tells whether `anno` is an `LSet` of exactly `n` members. An `LPartial` of
`n` members does not count.
-}
annoHasSize : Int -> Mono.LambdaSetAnno -> Bool
annoHasSize n anno =
    case anno of
        Mono.LSet members ->
            List.length members == n

        Mono.LTop _ ->
            False

        Mono.LVar _ ->
            False

        Mono.LPartial _ ->
            False


{-| Renders annotations for a failure message, such as `LTop, LSet[4,5]`. An
`LTop`'s provenance code is not shown.
-}
describeAnnos : List Mono.LambdaSetAnno -> String
describeAnnos annos =
    String.join ", "
        (List.map
            (\anno ->
                case anno of
                    Mono.LTop _ ->
                        "LTop"

                    Mono.LVar n ->
                        "LVar" ++ String.fromInt n

                    Mono.LSet ms ->
                        "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"

                    Mono.LPartial ms ->
                        "LPartial[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
            )
            annos
        )



-- ====== FIXTURES ======


{-| The source type `Int -> Int`, the function type the fixtures pass around.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| The fixture of test 1a: `chooseHandler`, annotated with a concrete type,
returns `f` or `g`, and `testValue` calls it with `\x -> x + 1` and
`\y -> y + 2` and applies the result to 9.
-}
chooseHandlerModule : Src.Module
chooseHandlerModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "chooseHandler"
          , args = [ pVar "b", pVar "f", pVar "g" ]
          , tipe = tLambda (tType "Bool" []) (tLambda hInt (tLambda hInt hInt))
          , body = ifExpr (varExpr "b") (varExpr "f") (varExpr "g")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "chooseHandler")
                        [ boolExpr True
                        , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                        , lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2))
                        ]
                    )
                    [ intExpr 9 ]
          }
        ]


{-| The fixture of test 6: `mk2 : Bool -> (Int -> Int)` returns `\x -> x + 1`
or `\y -> y + 2`, both written in its own body, and `testValue` applies
`mk2 True` to 4.
-}
mk2Module : Src.Module
mk2Module =
    makeModuleWithTypedDefs "Test"
        [ { name = "mk2"
          , args = [ pVar "s" ]
          , tipe = tLambda (tType "Bool" []) hInt
          , body =
                ifExpr (varExpr "s")
                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)))
                    (lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2)))
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (callExpr (varExpr "mk2") [ boolExpr True ]) [ intExpr 4 ]
          }
        ]


{-| The fixture of test 4: `pick c g` returns the global `inc` or the call
`g 0`, where `g : Int -> Int -> Int`, and `testValue` applies
`pick True mkAdd` to 7.
-}
pickModule : Src.Module
pickModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "mkAdd"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "pick"
          , args = [ pVar "c", pVar "g" ]
          , tipe = tLambda (tType "Bool" []) (tLambda (tLambda (tType "Int" []) hInt) hInt)
          , body =
                ifExpr (varExpr "c")
                    (varExpr "inc")
                    (callExpr (varExpr "g") [ intExpr 0 ])
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "pick") [ boolExpr True, varExpr "mkAdd" ])
                    [ intExpr 7 ]
          }
        ]


{-| The fixture of test 7: `chain` returns `f`, `g` or `h` through two nested
`if`s, and `testValue` calls it with three different lambdas and applies the
result to 9.
-}
chainModule : Src.Module
chainModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "chain"
          , args = [ pVar "b", pVar "c", pVar "f", pVar "g", pVar "h" ]
          , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tType "Bool" [])
                        (tLambda hInt (tLambda hInt (tLambda hInt hInt)))
                    )
          , body =
                ifExpr (varExpr "b")
                    (varExpr "f")
                    (ifExpr (varExpr "c") (varExpr "g") (varExpr "h"))
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr
                    (callExpr (varExpr "chain")
                        [ boolExpr True
                        , boolExpr False
                        , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                        , lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2))
                        , lambdaExpr [ pVar "z" ] (binopsExpr [ ( varExpr "z", "+" ) ] (intExpr 3))
                        ]
                    )
                    [ intExpr 9 ]
          }
        ]


{-| The fixture of test 8: `choosePair` returns the pair `p` or the pair `q`,
each a pair of `Int -> Int` functions, and `testValue` calls it with two tuple
literals of lambdas and applies the first element of the result to 5.
-}
choosePairModule : Src.Module
choosePairModule =
    makeModuleWithTypedDefs "Test" choosePairDefs


{-| The definitions of `choosePairModule`.
-}
choosePairDefs : List TypedDef
choosePairDefs =
    [ { name = "choosePair"
      , args = [ pVar "b", pVar "p", pVar "q" ]
      , tipe =
            tLambda (tType "Bool" [])
                (tLambda (tTuple hInt hInt) (tLambda (tTuple hInt hInt) (tTuple hInt hInt)))
      , body = ifExpr (varExpr "b") (varExpr "p") (varExpr "q")
      }
    , { name = "testValue"
      , args = []
      , tipe = tType "Int" []
      , body =
            caseFirst
                (callExpr (varExpr "choosePair")
                    [ boolExpr True
                    , tupleExpr
                        (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)))
                        (lambdaExpr [ pVar "y" ] (binopsExpr [ ( varExpr "y", "+" ) ] (intExpr 2)))
                    , tupleExpr
                        (lambdaExpr [ pVar "u" ] (binopsExpr [ ( varExpr "u", "+" ) ] (intExpr 3)))
                        (lambdaExpr [ pVar "v" ] (binopsExpr [ ( varExpr "v", "+" ) ] (intExpr 4)))
                    ]
                )
      }
    ]


{-| The control of test 8: `choosePairModule` with `choosePair b p q = p`,
so no hub joins `p` and `q`.
-}
firstPairModule : Src.Module
firstPairModule =
    makeModuleWithTypedDefs "Test"
        (List.map
            (\def ->
                if def.name == "choosePair" then
                    { def | body = varExpr "p" }

                else
                    def
            )
            choosePairDefs
        )


{-| Builds a `case` that applies the first element of `pairExpr`, a pair of
functions, to 5. It takes the pair apart with a tuple pattern, so the program
does not need `Tuple.first`.
-}
caseFirst : Src.Expr -> Src.Expr
caseFirst pairExpr =
    caseExpr pairExpr
        [ ( pTuple (pVar "fst1") (pVar "snd1")
          , callExpr (varExpr "fst1") [ intExpr 5 ]
          )
        ]


{-| The fixture of test 9: `useH` binds `h` to `hof1` or `hof2` in a `let` and
returns `h k`, and `testValue` calls it with `\f -> f 1`, `\g -> g 2` and
`\x -> x * 2`.
-}
useHModule : Src.Module
useHModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "useH"
          , args = [ pVar "b", pVar "hof1", pVar "hof2", pVar "k" ]
          , tipe =
                tLambda (tType "Bool" [])
                    (tLambda (tLambda hInt (tType "Int" []))
                        (tLambda (tLambda hInt (tType "Int" []))
                            (tLambda hInt (tType "Int" []))
                        )
                    )
          , body =
                letExpr
                    [ define "h" [] (ifExpr (varExpr "b") (varExpr "hof1") (varExpr "hof2")) ]
                    (callExpr (varExpr "h") [ varExpr "k" ])
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "useH")
                    [ boolExpr True
                    , lambdaExpr [ pVar "f" ] (callExpr (varExpr "f") [ intExpr 1 ])
                    , lambdaExpr [ pVar "g" ] (callExpr (varExpr "g") [ intExpr 2 ])
                    , lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 2))
                    ]
          }
        ]
