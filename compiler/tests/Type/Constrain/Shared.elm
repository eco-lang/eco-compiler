module Type.Constrain.Shared exposing (expectEquivalentTypeChecking)

{-| A single expectation for constraint tests: the two type-checking paths agree
on a canonical module, and the typed path gives a type to each of its
expressions.

The compiler type-checks a module in one of two ways. The _erased path_
generates constraints with `Compiler.Type.Constrain.Erased.Module.constrain` and
solves them with `Compiler.Type.Solve.run`, which yields only the top-level
annotations. The _typed path_ generates them with
`Compiler.Type.Constrain.Typed.Module.constrainWithIds` and solves them with
`Compiler.Type.Solve.runWithIds`, which also yields a _node type_ for each
recorded node: an array indexed by the node's id, holding `Just` the solved type
where one was recorded. Every canonical expression carries such an id, its
_expression id_. Without this check, the two paths could disagree about whether
a module type-checks, or the typed path could leave an expression untyped,
without either path reporting anything.

`expectEquivalentTypeChecking` checks:

  - that the two paths agree on success or failure. When both fail it passes;
    the errors, and their number, are not compared. When exactly one fails it
    fails, reporting that path's error count.
  - that, when both succeed, each expression id found in the module's
    declarations has a `Just` node type. The ids are collected by walking every
    definition, including its argument patterns, and every nested expression.

Among what is not checked: the annotations of the two paths are not compared,
so agreement on success says nothing about the types inferred; pattern ids are
not collected, so a pattern without a node type is not caught; and no node type
is compared with any expected type.

Most of this module is the expression-id walk over the canonical AST.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Reporting.Annotation as A
import Compiler.Type.Constrain.Erased.Module as ConstrainErased
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Solve as Solve
import Compiler.Type.Vars as Vars
import Data.Map
import Dict exposing (Dict)
import Expect
import Set exposing (Set)
import System.TypeCheck.IO as IO



-- ============================================================================
-- TEST INFRASTRUCTURE
-- ============================================================================


{-| Returns an expectation that type-checks `modul` on both the erased and the
typed path and requires them to agree.

It passes when both paths fail, whatever their errors. It fails when exactly one
path fails, naming that path and its error count. When both succeed, it passes
only if each expression id in the module's declarations has a `Just` node type
on the typed path, and otherwise fails listing the missing ids, the expected
ids and the ids that have a type. The annotations of the two paths are not
compared.

-}
expectEquivalentTypeChecking : Can.Module -> Expect.Expectation
expectEquivalentTypeChecking modul =
    let
        standardResult =
            IO.unsafePerformIO (runStandardPath modul)

        withIdsResult =
            IO.unsafePerformIO (runWithIdsPath modul)

        allExprIds =
            extractModuleExprIds modul
    in
    case ( standardResult, withIdsResult ) of
        ( Ok _, Ok { nodeTypes } ) ->
            let
                -- An index of nodeTypes is a node id.
                nodeTypeIds =
                    Array.foldl
                        (\maybeType ( idx, acc ) ->
                            case maybeType of
                                Just _ ->
                                    ( idx + 1, Set.insert idx acc )

                                Nothing ->
                                    ( idx + 1, acc )
                        )
                        ( 0, Set.empty )
                        nodeTypes
                        |> Tuple.second

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


{-| Type-checks `modul` on the erased path, giving its top-level annotations or
the number of type errors.
-}
runStandardPath : Can.Module -> IO.IO (Result Int (Dict Name.Name (Can.Annotation Name)))
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


{-| Type-checks `modul` on the typed path, giving everything
`Compiler.Type.Solve.runWithIds` returns, including the node types, or the
number of type errors.
-}
runWithIdsPath :
    Can.Module
    ->
        IO.IO
            (Result
                Int
                { annotations : Dict Name.Name (Can.Annotation Name)
                , nodeTypes : Array.Array (Maybe (Can.Type Name))
                , nodeVars : Array.Array (Maybe Vars.Variable)
                , annotationVars : Dict Name.Name Vars.Variable
                , solverState :
                    { cells : Array.Array Vars.PointCell
                    }
                }
            )
runWithIdsPath modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars, _ ) ->
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


{-| Returns the expression ids of every expression in the module's
declarations.
-}
extractModuleExprIds : Can.Module -> Set Int
extractModuleExprIds (Can.Module { decls }) =
    extractDeclsExprIds decls


{-| Returns the expression ids in every definition of a chain of declarations,
recursive groups included.
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


{-| Returns the expression ids in a definition's body and argument patterns.
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


{-| Returns the id of an expression together with the ids of every expression
nested inside it.
-}
extractAllExprIds : Can.Expr -> Set Int
extractAllExprIds (A.At _ { id, node }) =
    Set.insert id (extractExprNodeIds node)


{-| Returns the ids of every expression nested inside an expression node, not
counting the node's own id, which `extractAllExprIds` adds. Patterns within the
node are walked too.
-}
extractExprNodeIds : Can.Expr_ -> Set Int
extractExprNodeIds node =
    case node of
        Can.VarLocal _ ->
            Set.empty

        Can.VarTopLevel _ _ ->
            Set.empty

        Can.VarKernel _ _ _ ->
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
            Data.Map.foldl A.compareLocated
                (\_ (Can.FieldUpdate _ expr) acc -> Set.union (extractAllExprIds expr) acc)
                (extractAllExprIds record)
                fields

        Can.Record fields ->
            Data.Map.foldl A.compareLocated (\_ expr acc -> Set.union (extractAllExprIds expr) acc) Set.empty fields

        Can.Unit ->
            Set.empty

        Can.Tuple a b rest ->
            List.foldl
                (\e acc -> Set.union (extractAllExprIds e) acc)
                (Set.union (extractAllExprIds a) (extractAllExprIds b))
                rest

        Can.Shader _ _ ->
            Set.empty


{-| Returns the expression ids inside a pattern, which is always the empty set:
a canonical pattern contains no expressions. The nested patterns are walked all
the same. The pattern's own id is not collected.
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
