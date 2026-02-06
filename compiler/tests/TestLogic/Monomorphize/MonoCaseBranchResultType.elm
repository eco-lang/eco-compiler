module TestLogic.Monomorphize.MonoCaseBranchResultType exposing (expectMonoCaseBranchResultTypes, checkMonoCaseBranchResultTypes)

{-| Test logic for MONO\_018: MonoCase branch result types match MonoCase resultType.

For every MonoCase in the MonoGraph, the types of all branch expressions (both
in the jumps list and inline leaves in the decider) must equal the MonoCase's
resultType.

This invariant catches the "different staging boundaries across branches" bug where:

  - Branch expressions have structurally different MonoTypes
  - MonoCase resultType stores one shape while branches have another
  - Mono.typeOf would return incorrect types for the case expression

@docs expectMonoCaseBranchResultTypes, checkMonoCaseBranchResultTypes

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


{-| MONO\_018: Verify MonoCase branch result types match MonoCase resultType.
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


{-| Check MonoCase branch result type consistency for all expressions in the MonoGraph.
-}
checkMonoCaseBranchResultTypes : Mono.MonoGraph -> List Violation
checkMonoCaseBranchResultTypes (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc ->
            acc ++ checkNode specId node
        )
        []
        data.nodes


{-| Check a single MonoNode for MonoCase violations.
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


{-| Recursively check a MonoExpr for MonoCase violations.
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

        -- Leaf expressions - no sub-expressions to check
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
                        "GOPT_018 violation: branch type != MonoCase resultType\n"
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
                        -- Also check sub-expressions in the inlined expression
                        checkExpr (ctx ++ " inline-leaf") expr

                    else
                        { context = ctx ++ " inline-leaf"
                        , message =
                            "GOPT_018 violation: inline leaf type != MonoCase resultType\n"
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


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n\n"
