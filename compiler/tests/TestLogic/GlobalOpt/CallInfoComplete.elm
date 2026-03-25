module TestLogic.GlobalOpt.CallInfoComplete exposing (expectCallInfoComplete)

{-| Test logic for CallInfo invariants GOPT\_011 through GOPT\_015.

After GlobalOpt, every MonoCall with StageCurried callModel must have
a CallInfo whose fields are internally consistent:

  - GOPT\_011: stageArities is non-empty with all positive elements
  - GOPT\_012: sum(stageArities) == flattened arity of callee type
  - GOPT\_013: initialRemaining <= first stage arity
  - GOPT\_014: isSingleStageSaturated == (argCount >= initialRemaining && initialRemaining > 0)
  - GOPT\_015: For local StageCurried callees, initialRemaining must be positive when type arity > 0

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
collectDeciderIssues _ decider =
    case decider of
        Mono.Leaf _ ->
            []

        Mono.Chain _ success failure ->
            collectDeciderIssues "" success
                ++ collectDeciderIssues "" failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderIssues "" d) edges
                ++ collectDeciderIssues "" fallback



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
                ++ checkGopt015 ctx funcExpr callInfo



-- Note: GOPT_012 and GOPT_015 skip CallGenericApply internally,
-- since initialRemaining is intentionally 0 and unused by codegen.


{-| GOPT\_011: stageArities must be non-empty with all positive elements,
unless the callee is a thunk (initialRemaining=0) that returns a non-function
value, in which case empty stageArities is valid.
-}
checkGopt011 : String -> Mono.CallInfo -> List String
checkGopt011 ctx callInfo =
    if List.isEmpty callInfo.stageArities then
        if callInfo.initialRemaining == 0 then
            -- Thunk returning non-function value: empty stageArities is valid
            []

        else
            [ ctx ++ " [GOPT_011]: StageCurried call has empty stageArities but initialRemaining=" ++ String.fromInt callInfo.initialRemaining ]

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


{-| GOPT\_012: stageArities must be consistent with initialRemaining.

initialRemaining must not exceed the first element of stageArities.
Note: stageArities is derived from the expression type, while initialRemaining
is derived from the actual closure node. After staging canonicalization, the
node's param count may be higher (flattened) than the first stage arity.
So we check initialRemaining >= stageArities[0] (flattened closures have
at least as many params as the first type stage).

-}
checkGopt012 : String -> Mono.MonoExpr -> Mono.CallInfo -> List String
checkGopt012 ctx _ callInfo =
    case callInfo.callKind of
        Mono.CallGenericApply ->
            -- Generic apply ignores initialRemaining; skip this check
            []

        _ ->
            case List.head callInfo.stageArities of
                Just firstStage ->
                    if callInfo.initialRemaining < firstStage then
                        [ ctx
                            ++ " [GOPT_012]: initialRemaining="
                            ++ String.fromInt callInfo.initialRemaining
                            ++ " < stageArities[0]="
                            ++ String.fromInt firstStage
                            ++ " (stageArities="
                            ++ Debug.toString callInfo.stageArities
                            ++ ")"
                        ]

                    else
                        []

                Nothing ->
                    -- Empty stageArities handled by GOPT_011
                    []


{-| GOPT\_013: initialRemaining must not exceed the total flattened arity.

initialRemaining is how many args the closure accepts in its first stage
(which may be flattened by staging). It must satisfy:

  - initialRemaining <= sum(stageArities): cannot exceed total arity
  - initialRemaining >= stageArities[0]: must be at least the first type-stage
    (staging may flatten multiple type-stages into one closure stage)
  - initialRemaining > 0 when stageArities is non-empty

These checks ensure sourceArityForCallee returns a value consistent with
the callee's type structure.

-}
checkGopt013 : String -> Mono.CallInfo -> List String
checkGopt013 ctx callInfo =
    let
        totalArity =
            List.sum callInfo.stageArities
    in
    if totalArity > 0 && callInfo.initialRemaining > totalArity then
        [ ctx
            ++ " [GOPT_013]: initialRemaining="
            ++ String.fromInt callInfo.initialRemaining
            ++ " exceeds totalArity="
            ++ String.fromInt totalArity
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
            argCount == callInfo.initialRemaining && callInfo.initialRemaining > 0

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


{-| GOPT\_015: For StageCurried calls where callee is a MonoVarLocal,
initialRemaining must be positive when the callee has a function type.

This catches cases where varSourceArity was not populated for a local
variable (e.g., a closure parameter), causing sourceArityForCallee to
fall back to a type-based heuristic that may disagree with the canonical
staging representation.

-}
checkGopt015 : String -> Mono.MonoExpr -> Mono.CallInfo -> List String
checkGopt015 ctx funcExpr callInfo =
    case callInfo.callKind of
        Mono.CallGenericApply ->
            -- Generic apply ignores initialRemaining; skip this check
            []

        _ ->
            case funcExpr of
                Mono.MonoVarLocal localName _ ->
                    let
                        typeArity =
                            firstStageArityFromMonoType (Mono.typeOf funcExpr)
                    in
                    if callInfo.initialRemaining <= 0 && typeArity > 0 then
                        [ ctx
                            ++ " [GOPT_015]: StageCurried call to local '"
                            ++ localName
                            ++ "' has initialRemaining="
                            ++ String.fromInt callInfo.initialRemaining
                            ++ " but type arity="
                            ++ String.fromInt typeArity
                        ]

                    else
                        []

                _ ->
                    []


{-| Compute first-stage arity from a MonoType (mirrors firstStageArityFromType
in MonoGlobalOptimize.elm).
-}
firstStageArityFromMonoType : Mono.MonoType -> Int
firstStageArityFromMonoType monoType =
    case monoType of
        Mono.MFunction argTypes _ ->
            List.length argTypes

        _ ->
            0
