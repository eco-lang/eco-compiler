module TestLogic.Monomorphize.MonoCaseBranchResultType exposing (expectMonoCaseBranchResultTypes, expectHonestJoinStaging, Violation)

{-| Checks that every branch of every `case` in a monomorphized program has
exactly the type the case records for itself, so that `Mono.typeOf` of a case
expression is true of each of its branches.

A `MonoCase` stores its result type in its last field, and `Mono.typeOf` of the
case returns that stored type without looking at the branches. Anything that
asks a case for its type therefore relies on every branch having that type. A
branch whose type differs, for example a function whose `MFunction` type groups
its parameters into stages differently from the stored type, makes the case's
type wrong for that branch.

A case's branch bodies are held in two places, and both are checked. The jump
list holds the bodies the decision tree reaches by `Jump n`; a body can instead
sit in a leaf of the decision tree itself, as `Inline expr`. Each body's
`Mono.typeOf` is compared with the stored type by `Mono.eqLayout`: the layout,
including how each function type groups its parameters into stages, must
agree. Lambda-set annotations are not compared. Under the solver engine they
are per occurrence (LSS\_006), so a branch may carry a smaller set than the
join it flows into, and a ⊤ carries a provenance code that differs between
occurrences; neither is a staging or layout difference.

`expectMonoCaseBranchResultTypes` checks the graph that
`TestLogic.TestPipeline.runToMono` produces: the production monomorphizer's
output, before inlining or any GlobalOpt pass has run (invariant MONO\_018).
Every expression in every node that has a body is walked, so cases nested
anywhere are checked too.

After global optimization the equality no longer holds by design: a join's
branches keep their own staging. `expectHonestJoinStaging` checks what GOPT\_003
now requires instead, that no call claims a staging a join does not have.

Among what is not checked: the branches of an `if`, and the types on the
decision tree's paths.

@docs expectMonoCaseBranchResultTypes, expectHonestJoinStaging, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One branch whose type differs from its case's stored result type.

`context` names the node by its index in the graph's node array and ends with
`jump=<n>` for a jump-list body or `inline-leaf` for an inline one. `message`
gives both types as `Debug.toString` prints them.

-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Builds `srcModule` with `TestLogic.TestPipeline.runToMono` and passes when
every case branch in the resulting graph, jump-list or inline, has a type `eqLayout`
to its case's stored result type.

It fails with the pipeline's message if the build fails, and otherwise with
every mismatch found, one paragraph each.

-}
expectMonoCaseBranchResultTypes : Src.Module -> Expectation
expectMonoCaseBranchResultTypes srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkMonoCaseBranchResultTypes monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| GOPT\_003 (plans/staging-honesty-and-production-test-pipeline.md P2.3):
builds `srcModule` with `TestLogic.TestPipeline.runToGlobalOpt` and fails if a
call claims a staging that the join its callee returns through does not have.

After global optimization the branches of a function-valued `case` or `if`
may be staged differently from one another and from the join's stored type:
nothing re-stages them to agree. What must hold is that no call relies on it.
For every staged-curried call with `CallDirectKnownSegmentation` and a
non-empty `remainingStageArities` (it claims to know the stages after the
first) whose callee is a global, the global's body is followed to the join it
returns through (the body itself, or the body of its closure); if that join's
branches do not all have one natural staging, the call is a violation.

-}
expectHonestJoinStaging : Src.Module -> Expectation
expectHonestJoinStaging srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { optimizedMonoGraph } ->
            case checkHonestJoinStaging optimizedMonoGraph of
                [] ->
                    Expect.pass

                violations ->
                    Expect.fail (formatViolations violations)


checkHonestJoinStaging : Mono.MonoGraph -> List Violation
checkHonestJoinStaging (Mono.MonoGraph data) =
    let
        nodeExpr specId =
            case Array.get specId data.nodes |> Maybe.andThen identity of
                Just (Mono.MonoDefine e _) ->
                    Just e

                Just (Mono.MonoTailFunc _ e _) ->
                    Just e

                _ ->
                    Nothing

        -- The branches of the join a global's value returns through, if any.
        joinBranches e =
            case e of
                Mono.MonoClosure _ body _ ->
                    joinBranchesOf body

                _ ->
                    joinBranchesOf e

        joinBranchesOf e =
            case e of
                Mono.MonoCase _ _ decider jumps _ ->
                    Just (List.map Tuple.second jumps ++ inlineLeaves decider [])

                Mono.MonoIf branches final _ ->
                    Just (List.map Tuple.second branches ++ [ final ])

                _ ->
                    Nothing

        inlineLeaves d acc =
            case d of
                Mono.Leaf (Mono.Inline x) ->
                    x :: acc

                Mono.Leaf (Mono.Jump _) ->
                    acc

                Mono.Chain _ yes no ->
                    inlineLeaves no (inlineLeaves yes acc)

                Mono.FanOut _ edges fallback ->
                    inlineLeaves fallback (List.foldl (\( _, dd ) a -> inlineLeaves dd a) acc edges)

        naturalStaging x =
            case x of
                Mono.MonoClosure info body _ ->
                    Just (List.length info.params :: naturalStagingOfType (Mono.typeOf body))

                _ ->
                    Nothing

        naturalStagingOfType t =
            case t of
                Mono.MFunction _ _ args ret ->
                    List.length args :: naturalStagingOfType ret

                _ ->
                    []

        agree branches =
            case List.map naturalStaging branches of
                first :: rest ->
                    first /= Nothing && List.all ((==) first) rest

                [] ->
                    True

        check ctx acc e =
            case e of
                Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) _ _ info ->
                    if
                        info.callModel
                            == Mono.StageCurried
                            && info.callKind
                            == Mono.CallDirectKnownSegmentation
                            && not (List.isEmpty info.remainingStageArities)
                    then
                        case nodeExpr specId |> Maybe.andThen joinBranches of
                            Just branches ->
                                if agree branches then
                                    acc

                                else
                                    { context = ctx ++ " call of SpecId " ++ String.fromInt specId
                                    , message =
                                        "GOPT_003 violation: the call claims remainingStageArities "
                                            ++ Debug.toString info.remainingStageArities
                                            ++ " through a join whose branches are staged "
                                            ++ Debug.toString (List.map naturalStaging branches)
                                    }
                                        :: acc

                            Nothing ->
                                acc

                    else
                        acc

                _ ->
                    acc
    in
    Array.toIndexedList data.nodes
        |> List.concatMap
            (\( specId, maybeNode ) ->
                case Maybe.andThen (\_ -> nodeExpr specId) maybeNode of
                    Just e ->
                        MonoTraverse.foldExprAccFirst (check ("SpecId " ++ String.fromInt specId)) [] e

                    Nothing ->
                        []
            )


{-| Returns the violations in every node of the graph, in node order, each
labelled with the node's index in the node array. Empty slots are skipped.
-}
checkMonoCaseBranchResultTypes : Mono.MonoGraph -> List Violation
checkMonoCaseBranchResultTypes (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, acc ++ checkNode specId node )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the violations in `node`'s body, labelled `SpecId <specId>`.
Constructor, enum, extern and effect-manager-leaf nodes have no body and give
none.
-}
checkNode : Int -> Mono.MonoNode -> List Violation
checkNode specId node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            checkExpr ctx expr

        Mono.MonoTailFunc _ expr _ ->
            checkExpr ctx expr

        Mono.MonoPortIncoming expr _ ->
            checkExpr ctx expr

        Mono.MonoPortOutgoing expr _ ->
            checkExpr ctx expr

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


{-| Returns the violations in `expr` and every expression inside it, labelled
with `ctx`. Only a `MonoCase` is compared with anything; every other expression
is walked through to its children.
-}
checkExpr : String -> Mono.MonoExpr -> List Violation
checkExpr ctx expr =
    case expr of
        Mono.MonoCase _ _ decider jumps resultType ->
            checkDecider ctx resultType decider
                ++ checkJumps ctx resultType jumps
                ++ List.concatMap (\( _, branchExpr ) -> checkExpr ctx branchExpr) jumps

        Mono.MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> checkExpr ctx c ++ checkExpr ctx t) branches
                ++ checkExpr ctx final

        Mono.MonoLet def body _ ->
            let
                defViolations =
                    case def of
                        Mono.MonoDef _ bound ->
                            checkExpr ctx bound

                        Mono.MonoTailDef _ _ bound ->
                            checkExpr ctx bound
            in
            defViolations ++ checkExpr ctx body

        Mono.MonoClosure info body _ ->
            let
                captureViolations =
                    List.concatMap (\( _, e, _ ) -> checkExpr ctx e) info.captures
            in
            captureViolations ++ checkExpr ctx body

        Mono.MonoCall _ fn args _ _ ->
            checkExpr ctx fn ++ List.concatMap (checkExpr ctx) args

        Mono.MonoTailCall _ namedArgs _ ->
            List.concatMap (\( _, a ) -> checkExpr ctx a) namedArgs

        Mono.MonoDestruct _ inner _ ->
            checkExpr ctx inner

        Mono.MonoList _ items _ ->
            List.concatMap (checkExpr ctx) items

        Mono.MonoRecordCreate fields _ ->
            List.concatMap (\( _, e ) -> checkExpr ctx e) fields

        Mono.MonoRecordAccess inner _ _ ->
            checkExpr ctx inner

        Mono.MonoRecordUpdate inner updates _ ->
            checkExpr ctx inner ++ List.concatMap (\( _, e ) -> checkExpr ctx e) updates

        Mono.MonoTupleCreate _ items _ ->
            List.concatMap (checkExpr ctx) items

        Mono.MonoLiteral _ _ ->
            []

        Mono.MonoVarLocal _ _ ->
            []

        Mono.MonoVarGlobal _ _ _ ->
            []

        Mono.MonoVarKernel _ _ _ _ _ ->
            []

        Mono.MonoUnit ->
            []

        Mono.MonoAccessorValue _ _ _ ->
            []


{-| Returns a violation for each body in `jumps` whose type is not `eqLayout` to
`resultType`. It does not look inside the bodies.
-}
checkJumps : String -> Mono.MonoType -> List ( Int, Mono.MonoExpr ) -> List Violation
checkJumps ctx resultType jumps =
    List.concatMap
        (\( idx, branchExpr ) ->
            let
                branchTy =
                    Mono.typeOf branchExpr
            in
            if Mono.eqLayout branchTy resultType then
                []

            else
                [ { context = ctx ++ " jump=" ++ String.fromInt idx
                  , message =
                        "MONO_018 violation: branch type != MonoCase resultType\n"
                            ++ "  resultType: "
                            ++ Debug.toString resultType
                            ++ "\n"
                            ++ "  branch type: "
                            ++ Debug.toString branchTy
                  }
                ]
        )
        jumps


{-| Returns the violations of every `Inline` leaf of `decider`: one if the
leaf's body has a type not `eqLayout` to `resultType`, then those inside the body,
all labelled with `inline-leaf` added to `ctx`.

A `Jump` leaf gives nothing here: the body it names is in the jump list, which
`checkJumps` compares.

-}
checkDecider : String -> Mono.MonoType -> Mono.Decider Mono.MonoChoice -> List Violation
checkDecider ctx resultType decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Jump _ ->
                    []

                Mono.Inline expr ->
                    let
                        ty =
                            Mono.typeOf expr
                    in
                    if Mono.eqLayout ty resultType then
                        checkExpr (ctx ++ " inline-leaf") expr

                    else
                        { context = ctx ++ " inline-leaf"
                        , message =
                            "MONO_018 violation: inline leaf type != MonoCase resultType\n"
                                ++ "  resultType: "
                                ++ Debug.toString resultType
                                ++ "\n"
                                ++ "  inline type: "
                                ++ Debug.toString ty
                        }
                            :: checkExpr (ctx ++ " inline-leaf") expr

        Mono.Chain _ yes no ->
            checkDecider ctx resultType yes
                ++ checkDecider ctx resultType no

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> checkDecider ctx resultType d) edges
                ++ checkDecider ctx resultType fallback


{-| Joins `violations` into one failure message, each written as
`context: message`, with a blank line between them.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"
