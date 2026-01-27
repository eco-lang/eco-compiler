module Compiler.Generate.Monomorphize.WrapperCurriedCalls exposing
    ( expectWrapperCurriedCalls
    , checkWrapperCurriedCalls
    )

{-| Test logic for MONO\_016: Wrapper closures generate curried calls.

When creating uncurried wrapper closures for functions that return functions,
the wrapper must generate nested MonoCall expressions that respect the original
curried parameter structure. Each MonoCall must pass only the number of arguments
the callee accepts at that application level.

@docs expectWrapperCurriedCalls, checkWrapperCurriedCalls

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect exposing (Expectation)


{-| Violation record for reporting issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| MONO\_016: Verify wrapper closures generate curried calls.
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


{-| Check wrapper curried calls consistency in the MonoGraph.
-}
checkWrapperCurriedCalls : Mono.MonoGraph -> List Violation
checkWrapperCurriedCalls (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeCurriedCalls specId node ++ acc)
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
-- CURRIED CALL VERIFICATION
-- ============================================================================


{-| Check curried call structure for a single MonoNode.
-}
checkNodeCurriedCalls : Int -> Mono.MonoNode -> List Violation
checkNodeCurriedCalls specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprCurriedCallIssues context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprCurriedCallIssues context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprCurriedCallIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprCurriedCallIssues context expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectExprCurriedCallIssues context e) defs

        _ ->
            []


{-| Get the first-level arity from a function type.

This returns the number of arguments the function accepts at the FIRST
application level, NOT the flattened arity.

For example:

  - `MFunction [A] (MFunction [B, C] D)` returns 1 (just A)
  - `MFunction [A, B] C` returns 2 (A and B)
  - `MInt` returns 0 (not a function)

-}
getFirstLevelArity : Mono.MonoType -> Int
getFirstLevelArity monoType =
    case monoType of
        Mono.MFunction params _ ->
            List.length params

        _ ->
            0


{-| Check if a MonoCall violates curried call structure.

A violation occurs when a MonoCall passes more arguments than its callee
accepts at the first application level.

-}
checkMonoCallCurried : String -> Mono.MonoExpr -> List Mono.MonoExpr -> List Violation
checkMonoCallCurried context fnExpr argExprs =
    let
        fnType =
            Mono.typeOf fnExpr

        firstLevelArity =
            getFirstLevelArity fnType

        argCount =
            List.length argExprs
    in
    -- A function type with arity 0 means it's not a function (e.g., already evaluated)
    -- so we only check when firstLevelArity > 0
    if firstLevelArity > 0 && argCount > firstLevelArity then
        [ { context = context
          , message =
                "MonoCall passes "
                    ++ String.fromInt argCount
                    ++ " arguments but callee type "
                    ++ monoTypeToString fnType
                    ++ " accepts only "
                    ++ String.fromInt firstLevelArity
                    ++ " at first application level. "
                    ++ "Wrapper should generate nested calls for curried functions."
          }
        ]

    else
        []


{-| Collect curried call issues from expressions.
-}
collectExprCurriedCallIssues : String -> Mono.MonoExpr -> List Violation
collectExprCurriedCallIssues context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectExprCurriedCallIssues context e) closureInfo.captures
                ++ collectExprCurriedCallIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs _ ->
            -- Check this call for curried structure violations
            checkMonoCallCurried context fnExpr argExprs
                ++ collectExprCurriedCallIssues context fnExpr
                ++ List.concatMap (collectExprCurriedCallIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprCurriedCallIssues context e) args

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprCurriedCallIssues context) exprs

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprCurriedCallIssues context c ++ collectExprCurriedCallIssues context t) branches
                ++ collectExprCurriedCallIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefCurriedCallIssues context def
                ++ collectExprCurriedCallIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprCurriedCallIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, e ) -> collectExprCurriedCallIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (collectExprCurriedCallIssues context) fieldExprs

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprCurriedCallIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprCurriedCallIssues context e) updates

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectExprCurriedCallIssues context recordExpr

        Mono.MonoTupleCreate _ exprs _ ->
            List.concatMap (collectExprCurriedCallIssues context) exprs

        _ ->
            []


{-| Collect curried call issues from a definition.
-}
collectDefCurriedCallIssues : String -> Mono.MonoDef -> List Violation
collectDefCurriedCallIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprCurriedCallIssues context expr

        Mono.MonoTailDef _ _ body ->
            collectExprCurriedCallIssues context body



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
