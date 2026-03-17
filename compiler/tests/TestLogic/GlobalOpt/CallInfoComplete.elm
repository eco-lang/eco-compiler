module TestLogic.GlobalOpt.CallInfoComplete exposing (expectCallInfoComplete)

{-| Test logic for CallInfo invariants GOPT\_011 through GOPT\_014.

After GlobalOpt, every MonoCall with StageCurried callModel must have
a CallInfo whose fields are internally consistent:

  - GOPT\_011: stageArities is non-empty with all positive elements
  - GOPT\_012: sum(stageArities) == flattened arity of callee type
  - GOPT\_013: initialRemaining <= first stage arity
  - GOPT\_014: isSingleStageSaturated == (argCount >= initialRemaining && initialRemaining > 0)

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Expect
import TestLogic.TestPipeline as Pipeline


expectCallInfoComplete : Src.Module -> Expect.Expectation
expectCallInfoComplete srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            let
                issues =
                    collectAllIssues optimizedMonoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- GRAPH WALKER
-- ============================================================================


collectAllIssues : Mono.MonoGraph -> List String
collectAllIssues (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNode specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


checkNode : Int -> Mono.MonoNode -> List String
checkNode specId node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprIssues ctx expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprIssues ctx expr

        Mono.MonoPortIncoming expr _ ->
            collectExprIssues ctx expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprIssues ctx expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectExprIssues ctx e) defs

        _ ->
            []


collectExprIssues : String -> Mono.MonoExpr -> List String
collectExprIssues ctx expr =
    case expr of
        Mono.MonoCall _ funcExpr args _ callInfo ->
            checkCallInfo ctx funcExpr args callInfo
                ++ collectExprIssues ctx funcExpr
                ++ List.concatMap (collectExprIssues ctx) args

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectExprIssues ctx e) closureInfo.captures
                ++ collectExprIssues ctx bodyExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefIssues ctx def
                ++ collectExprIssues ctx bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprIssues ctx c ++ collectExprIssues ctx t) branches
                ++ collectExprIssues ctx elseExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectDeciderIssues ctx decider
                ++ List.concatMap (\( _, e ) -> collectExprIssues ctx e) branches

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprIssues ctx valueExpr

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprIssues ctx) exprs

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprIssues ctx e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprIssues ctx recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprIssues ctx recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprIssues ctx e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprIssues ctx) elementExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprIssues ctx e) args

        _ ->
            []


collectDefIssues : String -> Mono.MonoDef -> List String
collectDefIssues ctx def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprIssues ctx expr

        Mono.MonoTailDef _ _ expr ->
            collectExprIssues ctx expr


collectDeciderIssues : String -> Mono.Decider Mono.MonoChoice -> List String
collectDeciderIssues ctx decider =
    case decider of
        Mono.Leaf _ ->
            []

        Mono.Chain _ success failure ->
            collectDeciderIssues ctx success
                ++ collectDeciderIssues ctx failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderIssues ctx d) edges
                ++ collectDeciderIssues ctx fallback



-- ============================================================================
-- CALLINFO CHECKS
-- ============================================================================


checkCallInfo : String -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.CallInfo -> List String
checkCallInfo ctx funcExpr args callInfo =
    case callInfo.callModel of
        Mono.FlattenedExternal ->
            -- FlattenedExternal calls don't use staged currying; skip
            []

        Mono.StageCurried ->
            let
                argCount =
                    List.length args
            in
            checkGopt011 ctx callInfo
                ++ checkGopt012 ctx funcExpr callInfo
                ++ checkGopt013 ctx callInfo
                ++ checkGopt014 ctx argCount callInfo


{-| GOPT\_011: stageArities must be non-empty with all positive elements.
-}
checkGopt011 : String -> Mono.CallInfo -> List String
checkGopt011 ctx callInfo =
    if List.isEmpty callInfo.stageArities then
        [ ctx ++ " [GOPT_011]: StageCurried call has empty stageArities" ]

    else
        let
            nonPositive =
                List.filter (\n -> n <= 0) callInfo.stageArities
        in
        if List.isEmpty nonPositive then
            []

        else
            [ ctx
                ++ " [GOPT_011]: stageArities contains non-positive value(s): "
                ++ Debug.toString callInfo.stageArities
            ]


{-| GOPT\_012: sum(stageArities) must equal the flattened arity of the callee's function type.
-}
checkGopt012 : String -> Mono.MonoExpr -> Mono.CallInfo -> List String
checkGopt012 ctx funcExpr callInfo =
    let
        stageSum =
            List.sum callInfo.stageArities

        ( flatParams, _ ) =
            Mono.decomposeFunctionType (Mono.typeOf funcExpr)

        flattenedArity =
            List.length flatParams
    in
    if flattenedArity == 0 then
        -- Non-function type callee (e.g., thunk or dynamic); skip
        []

    else if stageSum /= flattenedArity then
        [ ctx
            ++ " [GOPT_012]: sum(stageArities)="
            ++ String.fromInt stageSum
            ++ " != flattenedArity="
            ++ String.fromInt flattenedArity
            ++ " (stageArities="
            ++ Debug.toString callInfo.stageArities
            ++ ", type="
            ++ Debug.toString (Mono.typeOf funcExpr)
            ++ ")"
        ]

    else
        []


{-| GOPT\_013: initialRemaining must not exceed the first stage arity.

initialRemaining is the current stage's arity — how many args the closure
accepts before it's saturated for this stage. remainingStageArities are the
arities of subsequent stages (the returned closure's stages).

For a callee with stageArities=[1,1] (two stages of arity 1):

  - Fresh call: initialRemaining=1, remainingStageArities=[1]
  - After first stage saturated, the result is a new closure with arity 1

The key invariant: initialRemaining must never exceed the first stage arity.
This catches Bug 1 where countTotalArityFromType sums all stages (returning 2
instead of 1 for MFunction [Int] (MFunction [Int] Int)).

-}
checkGopt013 : String -> Mono.CallInfo -> List String
checkGopt013 ctx callInfo =
    let
        firstStageArity =
            List.head callInfo.stageArities |> Maybe.withDefault 0
    in
    if firstStageArity > 0 && callInfo.initialRemaining > firstStageArity then
        [ ctx
            ++ " [GOPT_013]: initialRemaining="
            ++ String.fromInt callInfo.initialRemaining
            ++ " exceeds firstStageArity="
            ++ String.fromInt firstStageArity
            ++ " (stageArities="
            ++ Debug.toString callInfo.stageArities
            ++ ")"
        ]

    else
        []


{-| GOPT\_014: isSingleStageSaturated must be true iff
argCount >= initialRemaining and initialRemaining > 0.
-}
checkGopt014 : String -> Int -> Mono.CallInfo -> List String
checkGopt014 ctx argCount callInfo =
    let
        expectedSaturated =
            argCount >= callInfo.initialRemaining && callInfo.initialRemaining > 0

        actual =
            callInfo.isSingleStageSaturated
    in
    if actual /= expectedSaturated then
        [ ctx
            ++ " [GOPT_014]: isSingleStageSaturated="
            ++ Debug.toString actual
            ++ " but expected="
            ++ Debug.toString expectedSaturated
            ++ " (argCount="
            ++ String.fromInt argCount
            ++ ", initialRemaining="
            ++ String.fromInt callInfo.initialRemaining
            ++ ")"
        ]

    else
        []
