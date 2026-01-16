module Compiler.Type.PostSolve.Determinism exposing
    ( expectDeterministicTypes
    )

{-| Test logic for invariant POST_004: Type inference is deterministic.

Verify that running type inference multiple times on the same input
produces identical results. This is important for:

  - Reproducible builds
  - Consistent error messages
  - Caching correctness

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Expect


{-| Verify that PostSolve is deterministic for Group B and kernels.
-}
expectDeterministicTypes : Src.Module -> Expect.Expectation
expectDeterministicTypes srcModule =
    -- Run PostSolve twice and compare results
    case ( TOMono.runToPostSolve srcModule, TOMono.runToPostSolve srcModule ) of
        ( Err msg1, _ ) ->
            Expect.fail ("First run failed: " ++ msg1)

        ( _, Err msg2 ) ->
            Expect.fail ("Second run failed: " ++ msg2)

        ( Ok result1, Ok result2 ) ->
            let
                nodeTypesMatch =
                    compareNodeTypes result1.nodeTypes result2.nodeTypes
            in
            if List.isEmpty nodeTypesMatch then
                Expect.pass

            else
                Expect.fail ("Non-deterministic types:\n" ++ String.join "\n" nodeTypesMatch)



-- ============================================================================
-- DETERMINISM VERIFICATION
-- ============================================================================


{-| Compare two NodeTypes dictionaries for equality.
-}
compareNodeTypes : Dict.Dict Int Int Can.Type -> Dict.Dict Int Int Can.Type -> List String
compareNodeTypes types1 types2 =
    let
        keys1 =
            Dict.keys compare types1

        keys2 =
            Dict.keys compare types2

        -- Check for missing keys
        keyIssues =
            if List.length keys1 /= List.length keys2 then
                [ "Different number of nodes: " ++ String.fromInt (List.length keys1) ++ " vs " ++ String.fromInt (List.length keys2) ]

            else
                []

        -- Compare types for each key
        typeIssues =
            Dict.foldl compare
                (\nodeId type1 acc ->
                    case Dict.get identity nodeId types2 of
                        Nothing ->
                            ("NodeId " ++ String.fromInt nodeId ++ " missing in second run") :: acc

                        Just type2 ->
                            if not (typesStructurallyEqual type1 type2) then
                                ("NodeId " ++ String.fromInt nodeId ++ " has different type") :: acc

                            else
                                acc
                )
                []
                types1
    in
    keyIssues ++ typeIssues


{-| Check if two types are structurally equal.

This is a deep equality check that compares the structure of types.

-}
typesStructurallyEqual : Can.Type -> Can.Type -> Bool
typesStructurallyEqual type1 type2 =
    case ( type1, type2 ) of
        ( Can.TVar name1, Can.TVar name2 ) ->
            name1 == name2

        ( Can.TLambda arg1 result1, Can.TLambda arg2 result2 ) ->
            typesStructurallyEqual arg1 arg2 && typesStructurallyEqual result1 result2

        ( Can.TType mod1 name1 args1, Can.TType mod2 name2 args2 ) ->
            mod1 == mod2 && name1 == name2 && List.length args1 == List.length args2 && List.all identity (List.map2 typesStructurallyEqual args1 args2)

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            ext1 == ext2 && recordFieldsEqual fields1 fields2

        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            typesStructurallyEqual a1 a2
                && typesStructurallyEqual b1 b2
                && (List.length cs1 == List.length cs2)
                && List.all identity (List.map2 typesStructurallyEqual cs1 cs2)

        ( Can.TAlias mod1 name1 args1 aliased1, Can.TAlias mod2 name2 args2 aliased2 ) ->
            mod1
                == mod2
                && name1
                == name2
                && List.length args1
                == List.length args2
                && List.all identity (List.map2 (\( n1, t1 ) ( n2, t2 ) -> n1 == n2 && typesStructurallyEqual t1 t2) args1 args2)
                && aliasedTypesEqual aliased1 aliased2

        _ ->
            False


{-| Check if two record field dictionaries are equal.
-}
recordFieldsEqual : Dict.Dict String String Can.FieldType -> Dict.Dict String String Can.FieldType -> Bool
recordFieldsEqual fields1 fields2 =
    let
        keys1 =
            Dict.keys compare fields1

        keys2 =
            Dict.keys compare fields2
    in
    keys1
        == keys2
        && List.all
            (\key ->
                case ( Dict.get identity key fields1, Dict.get identity key fields2 ) of
                    ( Just (Can.FieldType idx1 t1), Just (Can.FieldType idx2 t2) ) ->
                        idx1 == idx2 && typesStructurallyEqual t1 t2

                    _ ->
                        False
            )
            keys1


{-| Check if two aliased types are equal.
-}
aliasedTypesEqual : Can.AliasType -> Can.AliasType -> Bool
aliasedTypesEqual alias1 alias2 =
    case ( alias1, alias2 ) of
        ( Can.Holey t1, Can.Holey t2 ) ->
            typesStructurallyEqual t1 t2

        ( Can.Filled t1, Can.Filled t2 ) ->
            typesStructurallyEqual t1 t2

        _ ->
            False
