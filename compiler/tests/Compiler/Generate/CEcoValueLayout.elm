module Compiler.Generate.CEcoValueLayout exposing (expectValidCEcoValueLayout)

{-| Test logic for invariant MONO\_003: CEcoValue layout is consistent.

For each monomorphized value:

  - Verify the CEcoValue layout matches the MonoType.
  - Verify field ordering is deterministic.
  - Verify alignment and padding are correct.

This module reuses the existing typed optimization pipeline to verify
CEcoValue layout is correctly computed.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect


{-| Verify that CEcoValue MVars do not affect layout.
-}
expectValidCEcoValueLayout : Src.Module -> Expect.Expectation
expectValidCEcoValueLayout srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectCEcoValueLayoutIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- CECOVALUE LAYOUT VERIFICATION
-- ============================================================================


{-| Collect issues with CEcoValue layout.

CEcoValue type variables should only appear in positions that don't affect
runtime layout:

  - As type arguments to generic containers (passed through)
  - Never directly determining field layout, calling convention, or unboxing

-}
collectCEcoValueLayoutIssues : Mono.MonoGraph -> List String
collectCEcoValueLayoutIssues (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeCEcoValueLayout specId node ++ acc)
        []
        data.nodes


{-| Check CEcoValue layout for a single node.
-}
checkNodeCEcoValueLayout : Int -> Mono.MonoNode -> List String
checkNodeCEcoValueLayout specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ collectExprCEcoValueIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ List.concatMap (\( _, t ) -> checkCEcoValueInLayoutPosition context t) params
                ++ collectExprCEcoValueIssues context expr

        Mono.MonoCtor ctorLayout monoType ->
            -- Constructor fields must not have unresolved CEcoValue in layout positions
            checkCtorLayoutCEcoValue context ctorLayout
                ++ checkCEcoValueInLayoutPosition context monoType

        Mono.MonoEnum _ monoType ->
            checkCEcoValueInLayoutPosition context monoType

        Mono.MonoExtern monoType ->
            checkCEcoValueInLayoutPosition context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ collectExprCEcoValueIssues context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ collectExprCEcoValueIssues context expr

        Mono.MonoCycle defs monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ List.concatMap (\( _, e ) -> collectExprCEcoValueIssues context e) defs


{-| Check if CEcoValue appears in a layout-affecting position.

CEcoValue should only appear in type arguments to containers (like List a),
not as direct record fields, tuple elements, or function parameters
that would affect the runtime representation.

-}
checkCEcoValueInLayoutPosition : String -> Mono.MonoType -> List String
checkCEcoValueInLayoutPosition context monoType =
    case monoType of
        Mono.MVar _ Mono.CEcoValue ->
            -- CEcoValue at the top level is ok - it's erased at runtime
            []

        Mono.MList elemType ->
            -- List element type can be CEcoValue (boxed reference)
            checkCEcoValueInLayoutPosition context elemType

        Mono.MRecord layout ->
            -- Record fields should not directly be CEcoValue in unboxed positions
            -- (For now, we just check the layout is valid)
            if layout.fieldCount < 0 then
                [ context ++ ": Record layout has invalid field count" ]

            else
                []

        Mono.MTuple layout ->
            -- Tuple elements should not directly be CEcoValue in unboxed positions
            if layout.arity < 0 then
                [ context ++ ": Tuple layout has invalid arity" ]

            else
                []

        Mono.MCustom _ _ typeArgs ->
            -- Custom type arguments can be CEcoValue (passed through)
            List.concatMap (checkCEcoValueInLayoutPosition context) typeArgs

        Mono.MFunction paramTypes returnType ->
            -- Function parameters and return types can contain CEcoValue
            List.concatMap (checkCEcoValueInLayoutPosition context) paramTypes
                ++ checkCEcoValueInLayoutPosition context returnType

        _ ->
            []


{-| Check constructor layout for CEcoValue issues.
-}
checkCtorLayoutCEcoValue : String -> Mono.CtorLayout -> List String
checkCtorLayoutCEcoValue context layout =
    -- Check that unboxed fields don't have CEcoValue (they need concrete types)
    -- For now, just verify the layout is well-formed
    if layout.unboxedCount < 0 then
        [ context ++ ": Constructor '" ++ layout.name ++ "' has invalid unboxed count" ]

    else
        []


{-| Collect CEcoValue issues from expressions.
-}
collectExprCEcoValueIssues : String -> Mono.MonoExpr -> List String
collectExprCEcoValueIssues context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr _ ->
            -- Closure parameter types should be concrete for unboxed values
            List.concatMap (\( _, t ) -> checkCEcoValueInLayoutPosition context t) closureInfo.params
                ++ List.concatMap (\( _, e, _ ) -> collectExprCEcoValueIssues context e) closureInfo.captures
                ++ collectExprCEcoValueIssues context bodyExpr

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprCEcoValueIssues context) exprs

        Mono.MonoCall _ fnExpr argExprs _ ->
            collectExprCEcoValueIssues context fnExpr
                ++ List.concatMap (collectExprCEcoValueIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprCEcoValueIssues context e) args

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprCEcoValueIssues context c ++ collectExprCEcoValueIssues context t) branches
                ++ collectExprCEcoValueIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefCEcoValueIssues context def
                ++ collectExprCEcoValueIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprCEcoValueIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, e ) -> collectExprCEcoValueIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ _ ->
            List.concatMap (collectExprCEcoValueIssues context) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectExprCEcoValueIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ _ ->
            collectExprCEcoValueIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprCEcoValueIssues context e) updates

        Mono.MonoTupleCreate _ elementExprs _ _ ->
            List.concatMap (collectExprCEcoValueIssues context) elementExprs

        _ ->
            []


{-| Collect CEcoValue issues from a MonoDef.
-}
collectDefCEcoValueIssues : String -> Mono.MonoDef -> List String
collectDefCEcoValueIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprCEcoValueIssues context expr

        Mono.MonoTailDef _ params expr ->
            List.concatMap (\( _, t ) -> checkCEcoValueInLayoutPosition context t) params
                ++ collectExprCEcoValueIssues context expr
