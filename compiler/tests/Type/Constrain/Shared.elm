module Type.Constrain.Shared exposing (expectEquivalentTypeChecking)

{-| Shared test infrastructure for constraint equivalence testing.

This module provides test runners that compare `constrain` and `constrainWithIds` paths.

For Canonical AST builders, use Compiler.AST.CanonicalBuilder.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name
import Compiler.Data.NonEmptyList as NE
import Compiler.Reporting.Annotation as A
import Compiler.Type.Constrain.Erased.Module as ConstrainErased
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Solve as Solve
import Data.Map as Dict exposing (Dict)
import Expect
import Set exposing (Set)
import System.TypeCheck.IO as IO



-- ============================================================================
-- TEST INFRASTRUCTURE
-- ============================================================================


{-| Run both constraint paths and verify they produce equivalent results.

Both paths should either:

  - Both succeed (annotations may differ in internal details but should be equivalent)
  - Both fail with errors

Additionally, when WithIds path succeeds, we verify that ALL expression IDs
from the original module are present in the nodeTypes map.

-}
expectEquivalentTypeChecking : Can.Module -> Expect.Expectation
expectEquivalentTypeChecking modul =
    let
        standardResult =
            IO.unsafePerformIO (runStandardPath modul)

        withIdsResult =
            IO.unsafePerformIO (runWithIdsPath modul)

        -- Extract all expression IDs from the module
        allExprIds =
            extractModuleExprIds modul
    in
    case ( standardResult, withIdsResult ) of
        ( Ok _, Ok { nodeTypes } ) ->
            -- Both succeeded - now check that all IDs are in nodeTypes
            let
                nodeTypeIds =
                    Dict.keys compare nodeTypes |> Set.fromList

                missingIds =
                    Set.diff allExprIds nodeTypeIds
            in
            if Set.isEmpty missingIds then
                Expect.pass

            else
                Expect.fail
                    ("WithIds path succeeded but missing types for expression IDs: "
                        ++ (Set.toList missingIds |> List.map String.fromInt |> String.join ", ")
                        ++ "\nExpected IDs: "
                        ++ (Set.toList allExprIds |> List.map String.fromInt |> String.join ", ")
                        ++ "\nGot IDs: "
                        ++ (Set.toList nodeTypeIds |> List.map String.fromInt |> String.join ", ")
                    )

        ( Err _, Err _ ) ->
            -- Both failed - this is acceptable (they agree)
            Expect.pass

        ( Ok _, Err errorCount ) ->
            Expect.fail
                ("Standard path succeeded but WithIds path failed with: "
                    ++ String.fromInt errorCount
                    ++ " error(s)"
                )

        ( Err errorCount, Ok _ ) ->
            Expect.fail
                ("WithIds path succeeded but standard path failed with: "
                    ++ String.fromInt errorCount
                    ++ " error(s)"
                )


{-| Run the standard constraint generation and solving path.
-}
runStandardPath : Can.Module -> IO.IO (Result Int (Dict String Name.Name Can.Annotation))
runStandardPath modul =
    ConstrainErased.constrain modul
        |> IO.andThen Solve.run
        |> IO.map
            (\result ->
                case result of
                    Ok annotations ->
                        Ok annotations

                    Err (NE.Nonempty _ rest) ->
                        Err (1 + List.length rest)
            )


{-| Run the WithIds constraint generation and solving path.
Returns both annotations and the nodeTypes map.
-}
runWithIdsPath : Can.Module -> IO.IO (Result Int { annotations : Dict String Name.Name Can.Annotation, nodeTypes : Dict Int Int Can.Type })
runWithIdsPath modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars ) ->
                Solve.runWithIds constraint nodeVars
            )
        |> IO.map
            (\result ->
                case result of
                    Ok data ->
                        Ok data

                    Err (NE.Nonempty _ rest) ->
                        Err (1 + List.length rest)
            )


{-| Extract all expression IDs from a module.
-}
extractModuleExprIds : Can.Module -> Set Int
extractModuleExprIds (Can.Module { decls }) =
    extractDeclsExprIds decls


{-| Extract expression IDs from declarations.
-}
extractDeclsExprIds : Can.Decls -> Set Int
extractDeclsExprIds decls =
    case decls of
        Can.Declare def rest ->
            Set.union (extractDefExprIds def) (extractDeclsExprIds rest)

        Can.DeclareRec def defs rest ->
            List.foldl
                (\d acc -> Set.union (extractDefExprIds d) acc)
                (Set.union (extractDefExprIds def) (extractDeclsExprIds rest))
                defs

        Can.SaveTheEnvironment ->
            Set.empty


{-| Extract expression IDs from a definition.
-}
extractDefExprIds : Can.Def -> Set Int
extractDefExprIds def =
    case def of
        Can.Def _ patterns expr ->
            Set.union
                (List.foldl (\p acc -> Set.union (extractPatternExprIds p) acc) Set.empty patterns)
                (extractAllExprIds expr)

        Can.TypedDef _ _ patternsWithTypes expr _ ->
            Set.union
                (List.foldl (\( p, _ ) acc -> Set.union (extractPatternExprIds p) acc) Set.empty patternsWithTypes)
                (extractAllExprIds expr)


{-| Extract all expression IDs from an expression (recursively).
-}
extractAllExprIds : Can.Expr -> Set Int
extractAllExprIds (A.At _ { id, node }) =
    Set.insert id (extractExprNodeIds node)


{-| Extract expression IDs from an expression node.
-}
extractExprNodeIds : Can.Expr_ -> Set Int
extractExprNodeIds node =
    case node of
        Can.VarLocal _ ->
            Set.empty

        Can.VarTopLevel _ _ ->
            Set.empty

        Can.VarKernel _ _ ->
            Set.empty

        Can.VarForeign _ _ _ ->
            Set.empty

        Can.VarCtor _ _ _ _ _ ->
            Set.empty

        Can.VarDebug _ _ _ ->
            Set.empty

        Can.VarOperator _ _ _ _ ->
            Set.empty

        Can.Chr _ ->
            Set.empty

        Can.Str _ ->
            Set.empty

        Can.Int _ ->
            Set.empty

        Can.Float _ ->
            Set.empty

        Can.List exprs ->
            List.foldl (\e acc -> Set.union (extractAllExprIds e) acc) Set.empty exprs

        Can.Negate expr ->
            extractAllExprIds expr

        Can.Binop _ _ _ _ left right ->
            Set.union (extractAllExprIds left) (extractAllExprIds right)

        Can.Lambda patterns body ->
            Set.union
                (List.foldl (\p acc -> Set.union (extractPatternExprIds p) acc) Set.empty patterns)
                (extractAllExprIds body)

        Can.Call func args ->
            List.foldl
                (\e acc -> Set.union (extractAllExprIds e) acc)
                (extractAllExprIds func)
                args

        Can.If branches final ->
            List.foldl
                (\( cond, then_ ) acc ->
                    Set.union (extractAllExprIds cond) (Set.union (extractAllExprIds then_) acc)
                )
                (extractAllExprIds final)
                branches

        Can.Let def body ->
            Set.union (extractDefExprIds def) (extractAllExprIds body)

        Can.LetRec defs body ->
            List.foldl
                (\d acc -> Set.union (extractDefExprIds d) acc)
                (extractAllExprIds body)
                defs

        Can.LetDestruct pattern expr body ->
            Set.union
                (extractPatternExprIds pattern)
                (Set.union (extractAllExprIds expr) (extractAllExprIds body))

        Can.Case subject branches ->
            List.foldl
                (\(Can.CaseBranch pattern body) acc ->
                    Set.union (extractPatternExprIds pattern) (Set.union (extractAllExprIds body) acc)
                )
                (extractAllExprIds subject)
                branches

        Can.Accessor _ ->
            Set.empty

        Can.Access record _ ->
            extractAllExprIds record

        Can.Update record fields ->
            Dict.foldl A.compareLocated
                (\_ (Can.FieldUpdate _ expr) acc -> Set.union (extractAllExprIds expr) acc)
                (extractAllExprIds record)
                fields

        Can.Record fields ->
            Dict.foldl A.compareLocated (\_ expr acc -> Set.union (extractAllExprIds expr) acc) Set.empty fields

        Can.Unit ->
            Set.empty

        Can.Tuple a b rest ->
            List.foldl
                (\e acc -> Set.union (extractAllExprIds e) acc)
                (Set.union (extractAllExprIds a) (extractAllExprIds b))
                rest

        Can.Shader _ _ ->
            Set.empty


{-| Extract expression IDs from a pattern (patterns don't have expression IDs,
but they may contain nested patterns that we need to traverse).
-}
extractPatternExprIds : Can.Pattern -> Set Int
extractPatternExprIds (A.At _ { node }) =
    case node of
        Can.PAnything ->
            Set.empty

        Can.PVar _ ->
            Set.empty

        Can.PRecord _ ->
            Set.empty

        Can.PAlias pattern _ ->
            extractPatternExprIds pattern

        Can.PUnit ->
            Set.empty

        Can.PTuple a b rest ->
            List.foldl
                (\p acc -> Set.union (extractPatternExprIds p) acc)
                (Set.union (extractPatternExprIds a) (extractPatternExprIds b))
                rest

        Can.PList patterns ->
            List.foldl (\p acc -> Set.union (extractPatternExprIds p) acc) Set.empty patterns

        Can.PCons head tail ->
            Set.union (extractPatternExprIds head) (extractPatternExprIds tail)

        Can.PBool _ _ ->
            Set.empty

        Can.PChr _ ->
            Set.empty

        Can.PStr _ _ ->
            Set.empty

        Can.PInt _ ->
            Set.empty

        Can.PCtor { args } ->
            List.foldl (\(Can.PatternCtorArg _ _ p) acc -> Set.union (extractPatternExprIds p) acc) Set.empty args
