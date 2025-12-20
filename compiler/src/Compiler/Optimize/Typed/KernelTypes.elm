module Compiler.Optimize.Typed.KernelTypes exposing
    ( KernelTypeEnv
    , fromDecls
    , lookup
    , inferFromUsage
    )

{-| Kernel function type environment for typed optimization.

This module builds a mapping from kernel function references to their canonical types.
Kernel functions (like `Elm.Kernel.List.cons`) are typically aliased through normal
Elm declarations like:

    cons : a -> List a -> List a
    cons =
        Elm.Kernel.List.cons

By finding these zero-argument definitions that just reference kernel functions,
we can extract the type annotation and use it when we encounter the kernel reference
during optimization.


# Type

@docs KernelTypeEnv


# Construction

@docs fromDecls


# Lookup

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes)
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)



-- ====== TYPE ======


{-| Environment mapping kernel function (home, name) pairs to their types.
-}
type alias KernelTypeEnv =
    Dict ( String, String ) ( Name, Name ) Can.Type



-- ====== CONSTRUCTION ======


{-| Build a kernel type environment from annotations and typed declarations.

Scans through declarations looking for zero-argument definitions whose bodies
are exactly `VarKernel` references. For each such definition, records the
type from the annotations dictionary.

-}
fromDecls : Dict String Name Can.Annotation -> TCan.Decls -> KernelTypeEnv
fromDecls annotations decls =
    fromDeclsHelp annotations decls Dict.empty


fromDeclsHelp : Dict String Name Can.Annotation -> TCan.Decls -> KernelTypeEnv -> KernelTypeEnv
fromDeclsHelp annotations decls env =
    case decls of
        TCan.Declare def rest ->
            fromDeclsHelp annotations rest (checkDef annotations def env)

        TCan.DeclareRec def defs rest ->
            let
                env1 =
                    checkDef annotations def env

                env2 =
                    List.foldl (\d e -> checkDef annotations d e) env1 defs
            in
            fromDeclsHelp annotations rest env2

        TCan.SaveTheEnvironment ->
            env


checkDef : Dict String Name Can.Annotation -> TCan.Def -> KernelTypeEnv -> KernelTypeEnv
checkDef annotations def env =
    case def of
        TCan.Def (A.At _ name) args body ->
            -- Only zero-arg defs that alias kernel functions
            case args of
                [] ->
                    checkKernelAlias annotations name body env

                _ ->
                    env

        TCan.TypedDef (A.At _ name) _ typedArgs body _ ->
            -- Only zero-arg defs that alias kernel functions
            case typedArgs of
                [] ->
                    checkKernelAlias annotations name body env

                _ ->
                    env


checkKernelAlias : Dict String Name Can.Annotation -> Name -> TCan.Expr -> KernelTypeEnv -> KernelTypeEnv
checkKernelAlias annotations defName (A.At _ texpr) env =
    case texpr of
        TCan.TypedExpr { expr } ->
            case expr of
                Can.VarKernel home name ->
                    -- This def is an alias for a kernel function
                    case Dict.get Basics.identity defName annotations of
                        Just (Can.Forall _ tipe) ->
                            Dict.insert toComparable ( home, name ) tipe env

                        Nothing ->
                            -- No annotation found, skip
                            env

                _ ->
                    env


toComparable : ( Name, Name ) -> ( String, String )
toComparable ( a, b ) =
    ( a, b )



-- ====== LOOKUP ======


{-| Look up a kernel type by (home, name).
-}
lookup : Name -> Name -> KernelTypeEnv -> Maybe Can.Type
lookup home name env =
    Dict.get toComparable ( home, name ) env


{-| Check if an entry exists for a kernel.
-}
hasEntry : Name -> Name -> KernelTypeEnv -> Bool
hasEntry home name env =
    case Dict.get toComparable ( home, name ) env of
        Just _ ->
            True

        Nothing ->
            False


{-| Insert a kernel type only if no entry exists (first-usage-wins).
-}
insertFirstUsage : Name -> Name -> Can.Type -> KernelTypeEnv -> KernelTypeEnv
insertFirstUsage home name tipe env =
    if hasEntry home name env then
        env

    else
        Dict.insert toComparable ( home, name ) tipe env


{-| Build a function type from argument types and result type.
-}
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes



-- ====== USAGE-BASED INFERENCE ======


{-| Infer kernel types from usage in expressions.

This is phase 2 of the mini kernel solver. It walks all expressions and
for each direct call of a kernel function, infers the type from the call
site and inserts it into the environment (only if no alias entry exists).

-}
inferFromUsage : TCan.Decls -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv
inferFromUsage decls exprTypes initialEnv =
    let
        inferDef : TCan.Def -> KernelTypeEnv -> KernelTypeEnv
        inferDef def env =
            case def of
                TCan.Def _ _ body ->
                    inferExpr body exprTypes env

                TCan.TypedDef _ _ _ body _ ->
                    inferExpr body exprTypes env

        inferDecls : TCan.Decls -> KernelTypeEnv -> KernelTypeEnv
        inferDecls ds env =
            case ds of
                TCan.Declare def rest ->
                    inferDecls rest (inferDef def env)

                TCan.DeclareRec d defs rest ->
                    let
                        env1 =
                            inferDef d env

                        env2 =
                            List.foldl inferDef env1 defs
                    in
                    inferDecls rest env2

                TCan.SaveTheEnvironment ->
                    env
    in
    inferDecls decls initialEnv


{-| Traverse an expression looking for kernel calls.
-}
inferExpr : TCan.Expr -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv
inferExpr (A.At _ texpr) exprTypes env =
    case texpr of
        TCan.TypedExpr { expr, tipe } ->
            case expr of
                -- Direct kernel call: Call (VarKernel home name) args
                Can.Call func args ->
                    let
                        typedFunc =
                            TCan.toTypedExpr exprTypes func

                        envAfterFunc =
                            inferExpr typedFunc exprTypes env

                        envAfterArgs =
                            List.foldl
                                (\arg acc -> inferExpr (TCan.toTypedExpr exprTypes arg) exprTypes acc)
                                envAfterFunc
                                args
                    in
                    case typedFunc of
                        A.At _ (TCan.TypedExpr funcData) ->
                            case funcData.expr of
                                Can.VarKernel home name ->
                                    let
                                        argTypes =
                                            List.map
                                                (\arg ->
                                                    let
                                                        (A.At _ (TCan.TypedExpr argData)) =
                                                            TCan.toTypedExpr exprTypes arg
                                                    in
                                                    argData.tipe
                                                )
                                                args

                                        candidateType =
                                            buildFunctionType argTypes tipe
                                    in
                                    insertFirstUsage home name candidateType envAfterArgs

                                _ ->
                                    envAfterArgs

                -- Lambda: recurse into body
                Can.Lambda _ body ->
                    inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env

                -- If: recurse into all branches and final
                Can.If branches final ->
                    let
                        env1 =
                            List.foldl
                                (\( cond, thenExpr ) acc ->
                                    acc
                                        |> inferExpr (TCan.toTypedExpr exprTypes cond) exprTypes
                                        |> inferExpr (TCan.toTypedExpr exprTypes thenExpr) exprTypes
                                )
                                env
                                branches
                    in
                    inferExpr (TCan.toTypedExpr exprTypes final) exprTypes env1

                -- Case: recurse into scrutinee and each branch body
                Can.Case scrutinee branches ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes scrutinee) exprTypes env

                        stepBranch (Can.CaseBranch _ branchExpr) acc =
                            inferExpr (TCan.toTypedExpr exprTypes branchExpr) exprTypes acc
                    in
                    List.foldl stepBranch env1 branches

                -- Let: recurse into body first, then def
                Can.Let def body ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
                    in
                    inferDefExpr def exprTypes env1

                -- LetRec: recurse into body first, then each def
                Can.LetRec defs body ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
                    in
                    List.foldl (\d acc -> inferDefExpr d exprTypes acc) env1 defs

                -- LetDestruct: recurse into bound expr and body
                Can.LetDestruct _ bound body ->
                    inferExpr (TCan.toTypedExpr exprTypes bound) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes body) exprTypes

                -- List: recurse into elements
                Can.List entries ->
                    List.foldl
                        (\e acc -> inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc)
                        env
                        entries

                -- Negate: recurse into subexpr
                Can.Negate sub ->
                    inferExpr (TCan.toTypedExpr exprTypes sub) exprTypes env

                -- Binop: recurse into left and right
                Can.Binop _ _ _ _ left right ->
                    inferExpr (TCan.toTypedExpr exprTypes left) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes right) exprTypes

                -- Record: recurse into all field exprs
                Can.Record fields ->
                    Dict.values A.compareLocated fields
                        |> List.foldl
                            (\fieldExpr acc -> inferExpr (TCan.toTypedExpr exprTypes fieldExpr) exprTypes acc)
                            env

                -- Update: recurse into record and all field updates
                Can.Update record fields ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes record) exprTypes env
                    in
                    Dict.toList A.compareLocated fields
                        |> List.foldl
                            (\( _, Can.FieldUpdate _ e ) acc ->
                                inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc
                            )
                            env1

                -- Accessor: `.field` has no subexpr
                Can.Accessor _ ->
                    env

                -- Access: recurse into record expression
                Can.Access record _ ->
                    inferExpr (TCan.toTypedExpr exprTypes record) exprTypes env

                -- Tuple: recurse into all components
                Can.Tuple a b cs ->
                    inferExpr (TCan.toTypedExpr exprTypes a) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes b) exprTypes
                        |> (\acc -> List.foldl (\e acc_ -> inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc_) acc cs)

                -- Shader: ignore
                Can.Shader _ _ ->
                    env

                -- Leaves: vars, literals, kernels, ctors, etc. — no recursion
                Can.VarLocal _ ->
                    env

                Can.VarTopLevel _ _ ->
                    env

                Can.VarKernel _ _ ->
                    -- bare kernel usage; we cannot infer HO types reliably
                    env

                Can.VarForeign _ _ _ ->
                    env

                Can.VarCtor _ _ _ _ _ ->
                    env

                Can.VarDebug _ _ _ ->
                    env

                Can.VarOperator _ _ _ _ ->
                    env

                Can.Chr _ ->
                    env

                Can.Str _ ->
                    env

                Can.Int _ ->
                    env

                Can.Float _ ->
                    env

                Can.Unit ->
                    env


{-| Traverse a definition's body looking for kernel calls.
-}
inferDefExpr : Can.Def -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv
inferDefExpr def exprTypes env =
    case def of
        Can.Def _ _ body ->
            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env

        Can.TypedDef _ _ _ body _ ->
            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
