module TestLogic.GlobalOpt.CallInfoComplete exposing (expectCallInfoComplete)

{-| Every `MonoCall` in a monomorphized program carries a `CallInfo` saying how
the call is to be applied, which the global optimizer fills in, and nothing in
the types stops the fields of one `CallInfo` from contradicting each other. This
module holds a check that finds such a call in a program after the global
optimizer has run, without generating any code.

A _staged_ call (one whose `callModel` is `StageCurried`) applies a function
value that takes its arguments in stages, each stage a group of parameters.
Its `CallInfo`, as `Compiler.AST.Monomorphized` defines it, records the
callee's _stage arities_ (`stageArities`, the parameter count of each stage),
the arity the global optimizer records for the callee value at this call
(`initialRemaining`), which is 0 when it has found no producer for the callee,
and whether the call supplies exactly that many arguments
(`isSingleStageSaturated`).

`expectCallInfoComplete` takes a source module, runs it through
`TestLogic.TestPipeline.runToGlobalOpt`, and fails if that run fails. Otherwise
it checks every staged call it reaches against these rules, and fails with one
line per broken rule, naming the `SpecId` of the node the call is in:

  - When `stageArities` is empty, `initialRemaining` is 0; otherwise every
    stage arity is positive.
  - `initialRemaining` is at least the first stage arity. Calls whose
    `callKind` is `CallGenericApply` or `CallSegmentationUnknown` are exempt,
    as are calls with no stage arities.
  - `initialRemaining` is at most the sum of the stage arities, when that sum
    is positive.
  - `isSingleStageSaturated` holds exactly when the call has as many arguments
    as `initialRemaining` and `initialRemaining` is positive.
  - When the callee is a local variable whose type's first stage has
    parameters, `initialRemaining` is positive. The same two call kinds are
    exempt.

The calls reached are those in the bodies of `MonoDefine`, `MonoTailFunc` and
port nodes, at any depth, including calls inside a call's function or argument
expressions, closure captures, `let` definitions and the branch bodies a `case`
jumps to. Calls whose `callModel` is `FlattenedExternal` are not checked, though
the expressions inside them are walked.

Among what is not checked: calls in a branch that a `case` decision tree holds
inline (an `Inline` leaf) rather than jumps to, and the `CallInfo` fields not
named above.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Returns an expectation that runs `srcModule` through the global optimizer
and passes when every staged call it reaches satisfies the rules in the module
docstring. It fails with the pipeline's error if the run fails, and otherwise
with one line per broken rule.
-}
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


{-| Returns the problems found in every node of the graph, each prefixed with
`SpecId` and the index of its node in the graph's node array.
-}
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


{-| Returns the problems found in the expression of one node, given its
`SpecId`. Only `MonoDefine`, `MonoTailFunc` and port nodes hold an expression
to walk; every other node yields none.
-}
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

        _ ->
            []


{-| Returns the problems found in every call within `expr`, at any depth, each
prefixed with `ctx`.

Within a `case`, only the branch bodies the decision tree jumps to are walked,
because `collectDeciderIssues` returns nothing for a leaf.

-}
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


{-| Returns the problems found in the body of a `let` definition.
-}
collectDefIssues : String -> Mono.MonoDef -> List String
collectDefIssues ctx def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprIssues ctx expr

        Mono.MonoTailDef _ _ expr ->
            collectExprIssues ctx expr


{-| Returns no problems for any decision tree. It recurses through the tree's
subtrees and returns nothing at a leaf, so a call inside an `Inline` leaf is
never examined. The context argument is ignored.
-}
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


{-| Returns the broken rules for one call's `CallInfo`, given the callee
expression and the arguments. A `FlattenedExternal` call is not checked; a
`StageCurried` call is checked against all five rules.
-}
checkCallInfo : String -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.CallInfo -> List String
checkCallInfo ctx funcExpr args callInfo =
    case callInfo.callModel of
        Mono.FlattenedExternal ->
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


{-| Returns a problem when `stageArities` is empty but `initialRemaining` is
not 0, or when any stage arity is 0 or negative. An empty `stageArities` with
an `initialRemaining` of 0 is accepted.
-}
checkGopt011 : String -> Mono.CallInfo -> List String
checkGopt011 ctx callInfo =
    if List.isEmpty callInfo.stageArities then
        if callInfo.initialRemaining == 0 then
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


{-| Returns a problem when `initialRemaining` is less than the first stage
arity.

The upper bound is `checkGopt013`'s. Calls whose kind is `CallGenericApply` or
`CallSegmentationUnknown` are exempt: a call for which the global optimizer has
found no producer for the callee gets one of those two kinds and an
`initialRemaining` of 0. A call with no stage arities is also exempt.

-}
checkGopt012 : String -> Mono.MonoExpr -> Mono.CallInfo -> List String
checkGopt012 ctx _ callInfo =
    case callInfo.callKind of
        Mono.CallGenericApply ->
            []

        Mono.CallSegmentationUnknown ->
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
                    -- An empty list is checked by checkGopt011.
                    []


{-| Returns a problem when `initialRemaining` is greater than the sum of the
stage arities, the callee's parameter count over all its stages. Nothing is
checked when that sum is 0 or less.
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


{-| Returns a problem when `isSingleStageSaturated` differs from whether
`argCount`, the number of arguments at the call, equals `initialRemaining` with
`initialRemaining` positive.
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


{-| Returns a problem when the callee is a local variable, the first stage of
its type has parameters, and `initialRemaining` is 0 or less. Calls whose kind
is `CallGenericApply` or `CallSegmentationUnknown` are exempt, as are callees
that are not a `MonoVarLocal`.
-}
checkGopt015 : String -> Mono.MonoExpr -> Mono.CallInfo -> List String
checkGopt015 ctx funcExpr callInfo =
    case callInfo.callKind of
        Mono.CallGenericApply ->
            []

        Mono.CallSegmentationUnknown ->
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


{-| Returns the number of parameters in the first stage of `monoType`, or 0 when
it is not a function type.
-}
firstStageArityFromMonoType : Mono.MonoType -> Int
firstStageArityFromMonoType monoType =
    case monoType of
        Mono.MFunction _ _ argTypes _ ->
            List.length argTypes

        _ ->
            0
