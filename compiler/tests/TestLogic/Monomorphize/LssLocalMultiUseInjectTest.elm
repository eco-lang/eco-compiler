module TestLogic.Monomorphize.LssLocalMultiUseInjectTest exposing (suite)

{-| F2 — local-multi USE-SITE MEMBER INJECTION
(`plans/lss-container-payload-transport.md` §12.9.4, `lss.stamp.useInject`).

A let-bound function passed as an ARGUMENT takes the `StashLocalMulti` path:
its type is fresh-instantiated into the callee's param slot and the instance
is recorded, but no member was ever written (GAP-9b: "no member, no stamp"),
so every HOF fed a let-function saw an unwritten var at the callback — 866
argument positions on the self-compile, 99 % of them flex, the largest single
class after the `papSuccWrite` fix.

The fix mints, at the use site, the id the instance's RHS re-translation will
mint for its lambda (same source lambda, same instance tag, same spec — a
deterministic get-or-create), and writes it into the stashed var before the
callee is zonked. THE PIN is the join: every callee spec's callback annotation
is a singleton EQUAL to the `lssMember` of the instance closure it names.
Flag-off pins the defect, so the differential is not vacuous.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , makeModuleWithTypedDefs
        , pVar
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "F2 local-multi use-site member injection"
        [ Test.test "1. FLAG-OFF: the callee's callback annotation is NOT a set (the defect)" <|
            \() ->
                case runWith False twoInstances of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads [ "applyI", "applyS" ] g
                        in
                        if List.isEmpty heads then
                            Expect.fail "fixture broken: no applyI/applyS spec"

                        else if List.any isSet (List.map Tuple.second heads) then
                            Expect.fail ("expected no set at the callback flag-off, got " ++ describeHeads heads)

                        else
                            Expect.pass
        , Test.test "2. FLAG-ON: both instances — each callee's callback is the SINGLETON of ITS instance closure" <|
            \() ->
                case runWith True twoInstances of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads [ "applyI", "applyS" ] g

                            instances =
                                instanceMembers "ident" g
                        in
                        if List.length instances /= 2 then
                            Expect.fail ("fixture broken: expected 2 instances of `ident`, got " ++ describeInstances instances)

                        else
                            expectJoin heads instances
        , Test.test "3. FLAG-ON: the two instances carry DISTINCT ids (ordinal 1 is tagged)" <|
            \() ->
                case runWith True twoInstances of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            ids =
                                List.map Tuple.second (instanceMembers "ident" g)
                        in
                        if List.length (distinct ids) == 2 then
                            Expect.pass

                        else
                            Expect.fail ("expected 2 distinct instance ids, got " ++ describeInts ids)
        , Test.test "4. F2.b FLAG-ON: a self-reference inside the instance RHS names the instance too" <|
            \() ->
                -- `go` passes ITSELF to `applyI` from inside its own body; that
                -- reference is translated during the instance re-translation,
                -- where the stack entry is popped and `varEnv` unbound. Every
                -- `applyI` spec (outer use AND inner use) must read the same
                -- singleton — otherwise the inner demand carries a var and the
                -- keyed callee splits or joins to a partial.
                case runWith True selfReference of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads [ "applyI" ] g

                            instances =
                                instanceMembers "go" g
                        in
                        if List.isEmpty instances then
                            Expect.fail "fixture broken: no instance of `go`"

                        else
                            expectJoin heads instances
        , Test.test "7. F2.c FLAG-ON: a local whose RHS is a PARTIAL APPLICATION names the PAP member at its use" <|
            \() ->
                -- `let h = apply2 inc in useF h`: `h` is function-typed (a
                -- local-multi) with no lambda id — F2's `noLam` residual and
                -- the compileExpr chain root on the self-compile. The use site
                -- mints `p|apply2|1`, the same key the RHS re-translation's
                -- `injectPapMember` mints, and writes it head-only.
                case runWithPap True papRhs of
                    Err e ->
                        Expect.fail e

                    Ok ((Mono.MonoGraph g) as graph) ->
                        case calleeHeads [ "useF" ] graph of
                            [ ( _, Mono.LSet [ m ] ) ] ->
                                case Dict.get m g.lssMemberOrigins of
                                    Just (Mono.OriginPap (Mono.Global _ gname) 1) ->
                                        if gname == "apply2" then
                                            Expect.pass

                                        else
                                            Expect.fail ("PAP member names the wrong global: " ++ gname)

                                    other ->
                                        Expect.fail ("expected a p|apply2|1 origin for member " ++ String.fromInt m ++ ", got " ++ Debug.toString other)

                            heads ->
                                Expect.fail ("expected one useF spec with a singleton callback, got " ++ describeHeads heads)
        , Test.test "8. F2.c FLAG-OFF: the PAP-RHS local is unwritten at its use (the defect)" <|
            \() ->
                case runWithPap False papRhs of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads [ "useF" ] g
                        in
                        if List.isEmpty heads then
                            Expect.fail "fixture broken: no useF spec"

                        else if List.any isSet (List.map Tuple.second heads) then
                            Expect.fail ("expected no set at useF's callback flag-off, got " ++ describeHeads heads)

                        else
                            Expect.pass
        , Test.test "5. F2.b FLAG-OFF: the self-reference is unwritten (the defect)" <|
            \() ->
                case runWith False selfReference of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads [ "applyI" ] g
                        in
                        if List.isEmpty heads then
                            Expect.fail "fixture broken: no applyI spec"

                        else if List.any isSet (List.map Tuple.second heads) then
                            Expect.fail ("expected no set at the callback flag-off, got " ++ describeHeads heads)

                        else
                            Expect.pass
        ]


{-| Every callee spec's callback head is `LSet [m]` with `m` the member of one
of the given instance closures, and every instance is named by some callee.
-}
expectJoin : List ( String, Mono.LambdaSetAnno ) -> List ( String, Int ) -> Expect.Expectation
expectJoin heads instances =
    let
        ids =
            List.map Tuple.second instances

        bad =
            List.filter
                (\( _, anno ) ->
                    case anno of
                        Mono.LSet [ m ] ->
                            not (List.member m ids)

                        _ ->
                            True
                )
                heads

        named =
            List.filterMap
                (\( _, anno ) ->
                    case anno of
                        Mono.LSet [ m ] ->
                            Just m

                        _ ->
                            Nothing
                )
                heads
    in
    if List.isEmpty heads then
        Expect.fail "fixture broken: no callee spec"

    else if not (List.isEmpty bad) then
        Expect.fail ("callee callback annotations not the instance singleton: " ++ describeHeads bad ++ "; instances " ++ describeInstances instances)

    else if List.any (\m -> not (List.member m named)) ids then
        Expect.fail ("an instance is named by no callee: instances " ++ describeInstances instances ++ ", callees " ++ describeHeads heads)

    else
        Expect.pass



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


hStr : Src.Type
hStr =
    tLambda (tType "String" []) (tType "String" [])


{-| One let-bound polymorphic function, passed to two HOFs at two types: two
instances (`ident`, `ident$1`), two callee specs, one join each.
-}
twoInstances : Src.Module
twoInstances =
    makeModuleWithTypedDefs "Test"
        [ { name = "applyI"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "applyS"
          , args = [ pVar "f", pVar "s" ]
          , tipe = tLambda hStr hStr
          , body = callExpr (varExpr "f") [ varExpr "s" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tTuple (tType "Int" []) (tType "String" [])
          , body =
                letExpr
                    [ define "ident" [ pVar "x" ] (varExpr "x") ]
                    (tupleExpr
                        (callExpr (varExpr "applyI") [ varExpr "ident", intExpr 3 ])
                        (callExpr (varExpr "applyS") [ varExpr "ident", strExpr "a" ])
                    )
          }
        ]


{-| `go` hands ITSELF to the HOF from inside its own body.
-}
selfReference : Src.Module
selfReference =
    makeModuleWithTypedDefs "Test"
        [ { name = "applyI"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                letExpr
                    [ define "go"
                        [ pVar "n" ]
                        (ifExpr (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
                            (callExpr (varExpr "applyI") [ varExpr "go", binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ])
                            (varExpr "n")
                        )
                    ]
                    (callExpr (varExpr "applyI") [ varExpr "go", intExpr 3 ])
          }
        ]


{-| F2.c: `h = apply2 inc` is a partial application of a 2-ary global.
-}
papRhs : Src.Module
papRhs =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) }
        , { name = "apply2", args = [ pVar "f", pVar "n" ], tipe = tLambda hInt hInt, body = callExpr (varExpr "f") [ varExpr "n" ] }
        , { name = "applyI", args = [ pVar "f", pVar "n" ], tipe = tLambda hInt hInt, body = callExpr (varExpr "f") [ varExpr "n" ] }
        , { name = "useF", args = [ pVar "g" ], tipe = tLambda hInt (tType "Int" []), body = callExpr (varExpr "applyI") [ varExpr "g", intExpr 3 ] }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                letExpr
                    [ define "h" [] (callExpr (varExpr "apply2") [ varExpr "inc" ]) ]
                    (callExpr (varExpr "useF") [ varExpr "h" ])
          }
        ]



-- ====== HARNESS ======


runWithPap : Bool -> Src.Module -> Result String Mono.MonoGraph
runWithPap on srcModule =
    let
        defaults =
            Config.defaultLss

        stampDefaults =
            Config.defaultLss.stamp
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults
            | enabled = True
            , keyed = True
            , stamp = { stampDefaults | enabled = True, useInject = True, useInjectPap = on }
        }
        srcModule


runWith : Bool -> Src.Module -> Result String Mono.MonoGraph
runWith on srcModule =
    let
        defaults =
            Config.defaultLss

        stampDefaults =
            Config.defaultLss.stamp
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults
            | enabled = True
            , keyed = True
            , stamp = { stampDefaults | enabled = True, useInject = on }
        }
        srcModule



-- ====== READERS ======


{-| (callee name, head annotation of its FIRST parameter) for every registry
spec of the named globals.
-}
calleeHeads : List String -> Mono.MonoGraph -> List ( String, Mono.LambdaSetAnno )
calleeHeads targets (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, Mono.MFunction _ _ (p0 :: _) _ ) ->
                    if List.member name targets then
                        ( name, Mono.headAnno p0 ) :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| (binding name, `lssMember`) of every `MonoDef`-bound closure whose name is
the def or one of its `$N` instances.
-}
instanceMembers : String -> Mono.MonoGraph -> List ( String, Int )
instanceMembers defName (Mono.MonoGraph g) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    List.foldl (collectInstances defName) acc (nodeExprsOf node)

                Nothing ->
                    acc
        )
        []
        g.nodes


collectInstances : String -> Mono.MonoExpr -> List ( String, Int ) -> List ( String, Int )
collectInstances defName expr acc =
    MonoTraverse.foldExpr
        (\e a ->
            case e of
                Mono.MonoLet (Mono.MonoDef n (Mono.MonoClosure info _ _)) _ _ ->
                    if n == defName || String.startsWith (defName ++ "$") n then
                        case info.lssMember of
                            Just m ->
                                ( n, m ) :: a

                            Nothing ->
                                a

                    else
                        a

                _ ->
                    a
        )
        acc
        expr


nodeExprsOf : Mono.MonoNode -> List Mono.MonoExpr
nodeExprsOf node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        _ ->
            []


isSet : Mono.LambdaSetAnno -> Bool
isSet anno =
    case anno of
        Mono.LSet _ ->
            True

        _ ->
            False


distinct : List Int -> List Int
distinct =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []


describeInts : List Int -> String
describeInts xs =
    "[" ++ String.join "," (List.map String.fromInt xs) ++ "]"


describeInstances : List ( String, Int ) -> String
describeInstances xs =
    "[" ++ String.join ", " (List.map (\( n, m ) -> n ++ "=" ++ String.fromInt m) xs) ++ "]"


describeHeads : List ( String, Mono.LambdaSetAnno ) -> String
describeHeads xs =
    "[" ++ String.join ", " (List.map (\( n, a ) -> n ++ ":" ++ describeAnno a) xs) ++ "]"


describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LSet ms ->
            "LSet" ++ describeInts ms

        Mono.LVar v ->
            "LVar" ++ String.fromInt v

        Mono.LTop k ->
            "LTop" ++ String.fromInt k

        Mono.LPartial ms ->
            "LPartial" ++ describeInts ms
