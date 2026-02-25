module TestLogic.Monomorphize.LambdaIdUniqueness exposing
    ( expectLambdaIdUniqueness, checkLambdaIdUniqueness
    , Violation
    )

{-| Test logic for MONO\_019: Lambda IDs are unique within graph.

Within a single MonoGraph, each lambdaId identifies a unique logical lambda.
No two MonoClosure or MonoTailFunc nodes should share the same lambdaId.

@docs expectLambdaIdUniqueness, checkLambdaIdUniqueness, Violation

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


{-| MONO\_019: Verify lambdaId uniqueness within the MonoGraph.
-}
expectLambdaIdUniqueness : Src.Module -> Expectation
expectLambdaIdUniqueness srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkLambdaIdUniqueness monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check lambdaId uniqueness for all closures in the MonoGraph.
-}
checkLambdaIdUniqueness : Mono.MonoGraph -> List Violation
checkLambdaIdUniqueness (Mono.MonoGraph data) =
    let
        allLambdaIds =
            Dict.foldl compare
                (\specId node acc -> collectNodeLambdaIds specId node ++ acc)
                []
                data.nodes

        duplicates =
            findDuplicates allLambdaIds
    in
    List.map
        (\( lambdaId, locations ) ->
            { context = "LambdaId " ++ lambdaIdToString lambdaId
            , message =
                "MONO_019 violation: Duplicate lambdaId found at: "
                    ++ String.join ", " locations
            }
        )
        duplicates


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n"



-- ============================================================================
-- LAMBDA ID COLLECTION
-- ============================================================================


{-| A collected lambdaId with its location context.
-}
type alias LambdaIdWithContext =
    { lambdaId : Mono.LambdaId
    , location : String
    }


{-| Collect all lambdaIds from a MonoNode.
-}
collectNodeLambdaIds : Int -> Mono.MonoNode -> List LambdaIdWithContext
collectNodeLambdaIds specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprLambdaIds context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprLambdaIds context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprLambdaIds context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprLambdaIds context expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( name, e ) -> collectExprLambdaIds (context ++ "/" ++ name) e) defs

        _ ->
            []


{-| Collect lambdaIds from expressions.
-}
collectExprLambdaIds : String -> Mono.MonoExpr -> List LambdaIdWithContext
collectExprLambdaIds context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr _ ->
            -- This closure has a lambdaId
            { lambdaId = closureInfo.lambdaId, location = context }
                :: List.concatMap (\( _, e, _ ) -> collectExprLambdaIds context e) closureInfo.captures
                ++ collectExprLambdaIds context bodyExpr

        Mono.MonoCall _ fnExpr argExprs _ _ ->
            collectExprLambdaIds context fnExpr
                ++ List.concatMap (collectExprLambdaIds context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprLambdaIds context e) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprLambdaIds context) exprs

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprLambdaIds context c ++ collectExprLambdaIds context t) branches
                ++ collectExprLambdaIds context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefLambdaIds context def
                ++ collectExprLambdaIds context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprLambdaIds context valueExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectDeciderLambdaIds context decider
                ++ List.concatMap (\( _, e ) -> collectExprLambdaIds context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprLambdaIds context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprLambdaIds context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprLambdaIds context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprLambdaIds context e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprLambdaIds context) elementExprs

        _ ->
            []


{-| Collect lambdaIds from a MonoDef.
-}
collectDefLambdaIds : String -> Mono.MonoDef -> List LambdaIdWithContext
collectDefLambdaIds context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprLambdaIds context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprLambdaIds context expr


{-| Collect lambdaIds from a Decider tree.
-}
collectDeciderLambdaIds : String -> Mono.Decider Mono.MonoChoice -> List LambdaIdWithContext
collectDeciderLambdaIds context decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectExprLambdaIds (context ++ " inline-leaf") expr

                Mono.Jump _ ->
                    []

        Mono.Chain _ success failure ->
            collectDeciderLambdaIds context success
                ++ collectDeciderLambdaIds context failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderLambdaIds context d) edges
                ++ collectDeciderLambdaIds context fallback



-- ============================================================================
-- DUPLICATE DETECTION
-- ============================================================================


{-| Find duplicates in a list of lambdaIds with contexts.
Returns list of (lambdaId, list of locations where it appears).
-}
findDuplicates : List LambdaIdWithContext -> List ( Mono.LambdaId, List String )
findDuplicates items =
    let
        -- Group by lambdaId
        grouped =
            List.foldl
                (\item acc ->
                    let
                        key =
                            lambdaIdToString item.lambdaId

                        existing =
                            Dict.get identity key acc
                                |> Maybe.withDefault { lambdaId = item.lambdaId, locations = [] }
                    in
                    Dict.insert identity key { lambdaId = item.lambdaId, locations = item.location :: existing.locations } acc
                )
                Dict.empty
                items
    in
    -- Filter to only those with more than one occurrence
    Dict.values compare grouped
        |> List.filterMap
            (\{ lambdaId, locations } ->
                if List.length locations > 1 then
                    Just ( lambdaId, locations )

                else
                    Nothing
            )


{-| Convert a LambdaId to a string for comparison and display.
-}
lambdaIdToString : Mono.LambdaId -> String
lambdaIdToString lambdaId =
    Mono.toComparableLambdaId lambdaId |> String.join "/"
