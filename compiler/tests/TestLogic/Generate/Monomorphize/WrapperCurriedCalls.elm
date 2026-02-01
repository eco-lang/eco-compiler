module TestLogic.Generate.Monomorphize.WrapperCurriedCalls exposing
    ( expectWrapperCurriedCalls
    , checkWrapperCurriedCalls
    )

{-| Test logic for MONO\_016: Stage arity invariant for closures.

For every MonoClosure whose MonoType is an MFunction, the length of
closureInfo.params must equal the length of the outermost MFunction
argument list (i.e., stage arity).

Simple directly-nested lambda chains are uncurried into a single flat
MFunction stage, while lambdas separated by let or case preserve nested
MFunction structure with each stage closure matching its outermost arg count.

@docs expectWrapperCurriedCalls, checkWrapperCurriedCalls

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import TestLogic.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect exposing (Expectation)


{-| Violation record for reporting issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| MONO\_016: Verify stage arity invariant for closures.
-}
expectWrapperCurriedCalls : Src.Module -> Expectation
expectWrapperCurriedCalls srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok monoGraph ->
            let
                violations =
                    checkWrapperCurriedCalls monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Check stage arity invariant for all closures in the MonoGraph.
-}
checkWrapperCurriedCalls : Mono.MonoGraph -> List Violation
checkWrapperCurriedCalls (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeStageArity specId node ++ acc)
        []
        data.nodes


{-| Format violations as a readable string.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map (\v -> v.context ++ ": " ++ v.message)
        |> String.join "\n"



-- ============================================================================
-- STAGE ARITY VERIFICATION
-- ============================================================================


{-| Check stage arity for closures in a single MonoNode.
-}
checkNodeStageArity : Int -> Mono.MonoNode -> List Violation
checkNodeStageArity specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprStageArityIssues context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprStageArityIssues context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprStageArityIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprStageArityIssues context expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectExprStageArityIssues context e) defs

        _ ->
            []


{-| Get the stage arity from a function type (outermost MFunction arg count).
-}
stageArity : Mono.MonoType -> Int
stageArity monoType =
    case monoType of
        Mono.MFunction params _ ->
            List.length params

        _ ->
            0


{-| Check if a MonoClosure violates the stage arity invariant.

MONO\_016: For every MonoClosure whose MonoType is an MFunction,
closureInfo.params length must equal the outermost MFunction argument count.

-}
checkClosureStageArity : String -> Mono.ClosureInfo -> Mono.MonoType -> List Violation
checkClosureStageArity context closureInfo monoType =
    let
        paramCount =
            List.length closureInfo.params

        expectedArity =
            stageArity monoType
    in
    case monoType of
        Mono.MFunction _ _ ->
            if paramCount /= expectedArity then
                [ { context = context
                  , message =
                        "MonoClosure has "
                            ++ String.fromInt paramCount
                            ++ " params but type "
                            ++ monoTypeToString monoType
                            ++ " has stage arity "
                            ++ String.fromInt expectedArity
                            ++ ". Params and stage arity must match."
                  }
                ]

            else
                []

        _ ->
            -- Non-function closures are fine (e.g., thunks returning values)
            []


{-| Collect stage arity issues from expressions.
-}
collectExprStageArityIssues : String -> Mono.MonoExpr -> List Violation
collectExprStageArityIssues context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr closureType ->
            -- Check this closure for stage arity violation
            checkClosureStageArity context closureInfo closureType
                ++ List.concatMap (\( _, e, _ ) -> collectExprStageArityIssues context e) closureInfo.captures
                ++ collectExprStageArityIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs _ ->
            collectExprStageArityIssues context fnExpr
                ++ List.concatMap (collectExprStageArityIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprStageArityIssues context e) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprStageArityIssues context) exprs

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprStageArityIssues context c ++ collectExprStageArityIssues context t) branches
                ++ collectExprStageArityIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefStageArityIssues context def
                ++ collectExprStageArityIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprStageArityIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, e ) -> collectExprStageArityIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (collectExprStageArityIssues context) fieldExprs

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprStageArityIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprStageArityIssues context e) updates

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectExprStageArityIssues context recordExpr

        Mono.MonoTupleCreate _ exprs _ ->
            List.concatMap (collectExprStageArityIssues context) exprs

        _ ->
            []


{-| Collect stage arity issues from a definition.
-}
collectDefStageArityIssues : String -> Mono.MonoDef -> List Violation
collectDefStageArityIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprStageArityIssues context expr

        Mono.MonoTailDef _ _ body ->
            collectExprStageArityIssues context body



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


{-| Convert a MonoType to a string for error messages.
-}
monoTypeToString : Mono.MonoType -> String
monoTypeToString monoType =
    case monoType of
        Mono.MInt ->
            "Int"

        Mono.MFloat ->
            "Float"

        Mono.MBool ->
            "Bool"

        Mono.MChar ->
            "Char"

        Mono.MString ->
            "String"

        Mono.MUnit ->
            "()"

        Mono.MList elementType ->
            "List " ++ monoTypeToString elementType

        Mono.MTuple elements ->
            "(" ++ String.join ", " (List.map monoTypeToString elements) ++ ")"

        Mono.MRecord fields ->
            let
                fieldStrs =
                    Dict.foldl compare
                        (\name ty acc -> (name ++ " : " ++ monoTypeToString ty) :: acc)
                        []
                        fields
            in
            "{ " ++ String.join ", " fieldStrs ++ " }"

        Mono.MCustom _ name _ ->
            name

        Mono.MFunction params result ->
            let
                paramStr =
                    case params of
                        [ single ] ->
                            monoTypeToString single

                        multiple ->
                            "(" ++ String.join ", " (List.map monoTypeToString multiple) ++ ")"
            in
            paramStr ++ " -> " ++ monoTypeToString result

        Mono.MVar name _ ->
            name
