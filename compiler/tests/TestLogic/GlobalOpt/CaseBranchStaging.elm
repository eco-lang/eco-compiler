module TestLogic.GlobalOpt.CaseBranchStaging exposing (expectCaseBranchStaging, checkCaseBranchStaging)

{-| Test logic for GOPT\_003: Case/if branches have compatible staging.

For every MonoCase and MonoIf returning function types after GlobalOpt,
all branch result types must have identical staging signatures.
Non-conforming branches should have been wrapped via buildAbiWrapperGO.

This extends MONO\_018 (type equality) to include staging equality after GlobalOpt.

@docs expectCaseBranchStaging, checkCaseBranchStaging

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Data.Map as Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Violation record for reporting issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| GOPT\_003: Verify case/if branches have compatible staging after GlobalOpt.
-}
expectCaseBranchStaging : Src.Module -> Expectation
expectCaseBranchStaging srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { optimizedMonoGraph } ->
            let
                violations =
                    checkCaseBranchStaging optimizedMonoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check case branch staging for all expressions in the MonoGraph.
-}
checkCaseBranchStaging : Mono.MonoGraph -> List Violation
checkCaseBranchStaging (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc ->
            acc ++ checkNode specId node
        )
        []
        data.nodes


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"



-- ============================================================================
-- GOPT_003: CASE BRANCH STAGING VERIFICATION
-- ============================================================================


{-| Check a single MonoNode for case branch staging violations.
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

        Mono.MonoCycle defs _ ->
            List.concatMap (\( name, expr ) -> checkExpr (ctx ++ " cycle=" ++ name) expr) defs

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []


{-| Recursively check a MonoExpr for case branch staging violations.
-}
checkExpr : String -> Mono.MonoExpr -> List Violation
checkExpr ctx expr =
    case expr of
        Mono.MonoCase _ _ decider jumps resultType ->
            -- Check that all branch types match resultType (including staging)
            checkDecider ctx resultType decider
                ++ checkJumps ctx resultType jumps
                ++ List.concatMap (\( _, branchExpr ) -> checkExpr ctx branchExpr) jumps

        Mono.MonoIf branches final resultType ->
            -- Check MonoIf branches too
            let
                branchViolations =
                    List.concatMap
                        (\( condExpr, thenExpr ) ->
                            let
                                thenType =
                                    Mono.typeOf thenExpr
                            in
                            if thenType /= resultType then
                                [ { context = ctx ++ " if-branch"
                                  , message =
                                        "GOPT_003 violation: if branch type != resultType\n"
                                            ++ "  resultType: "
                                            ++ Debug.toString resultType
                                            ++ "\n"
                                            ++ "  branch type: "
                                            ++ Debug.toString thenType
                                  }
                                ]

                            else
                                []
                        )
                        branches

                finalType =
                    Mono.typeOf final

                finalViolation =
                    if finalType /= resultType then
                        [ { context = ctx ++ " if-else"
                          , message =
                                "GOPT_003 violation: if else type != resultType\n"
                                    ++ "  resultType: "
                                    ++ Debug.toString resultType
                                    ++ "\n"
                                    ++ "  else type: "
                                    ++ Debug.toString finalType
                          }
                        ]

                    else
                        []
            in
            branchViolations
                ++ finalViolation
                ++ List.concatMap (\( c, t ) -> checkExpr ctx c ++ checkExpr ctx t) branches
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

        -- Leaf expressions
        Mono.MonoLiteral _ _ ->
            []

        Mono.MonoVarLocal _ _ ->
            []

        Mono.MonoVarGlobal _ _ _ ->
            []

        Mono.MonoVarKernel _ _ _ _ ->
            []

        Mono.MonoUnit ->
            []


{-| Check all jump branches have types matching resultType.
-}
checkJumps : String -> Mono.MonoType -> List ( Int, Mono.MonoExpr ) -> List Violation
checkJumps ctx resultType jumps =
    List.concatMap
        (\( idx, branchExpr ) ->
            let
                branchTy =
                    Mono.typeOf branchExpr
            in
            if branchTy == resultType then
                []

            else
                [ { context = ctx ++ " jump=" ++ String.fromInt idx
                  , message =
                        "GOPT_003 violation: branch type != MonoCase resultType\n"
                            ++ "  resultType: "
                            ++ Debug.toString resultType
                            ++ "\n"
                            ++ "  branch type: "
                            ++ Debug.toString branchTy
                  }
                ]
        )
        jumps


{-| Check the decider tree for inline leaves that have types matching resultType.
-}
checkDecider : String -> Mono.MonoType -> Mono.Decider Mono.MonoChoice -> List Violation
checkDecider ctx resultType decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Jump _ ->
                    -- Jump references are checked via checkJumps
                    []

                Mono.Inline expr ->
                    let
                        ty =
                            Mono.typeOf expr
                    in
                    if ty == resultType then
                        -- Also check sub-expressions
                        checkExpr (ctx ++ " inline-leaf") expr

                    else
                        { context = ctx ++ " inline-leaf"
                        , message =
                            "GOPT_003 violation: inline leaf type != MonoCase resultType\n"
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
