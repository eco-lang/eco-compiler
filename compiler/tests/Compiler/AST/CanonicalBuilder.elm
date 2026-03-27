module Compiler.AST.CanonicalBuilder exposing
    ( boolType
    , callExpr
    , charType
    , floatType
    , funType
    , intExpr
    , intType
    , lambdaExpr
    , letExpr
    , listExpr
    , listType
    , makeAnnotation
    , makeDef
    , -- ID Counter
      makeModule
    , makeModuleWithDecls
    , makeTypedDef
    , pVar
      -- Type builders for typed definitions
    , stringType
    , tFunc
    , tupleExpr
    , tupleType
    , varForeignExpr
    , varKernelExpr
    , varLocalExpr
    , varType
    )

{-| Builders for constructing Canonical AST values in tests.

This module provides:

1.  Canonical AST expression builders
2.  Canonical AST pattern builders
3.  Module builders for creating complete Canonical modules
4.  Type builders for typed definitions
5.  Fuzzers for generating random test inputs

For Source AST builders, use Compiler.AST.SourceBuilder.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- ID COUNTER
-- ============================================================================
-- ============================================================================
-- MODULE BUILDERS
-- ============================================================================


{-| Create a simple module with a single definition.
-}
makeModule : Name.Name -> Can.Expr -> Can.Module
makeModule name expr =
    let
        def =
            Can.Def (A.At A.zero name) [] expr

        decls =
            Can.Declare def Can.SaveTheEnvironment

        home =
            IO.Canonical Pkg.core "Test"
    in
    Can.Module
        { name = home
        , exports = Can.ExportEverything A.zero
        , docs = Src.NoDocs A.zero []
        , decls = decls
        , unions = Dict.empty
        , aliases = Dict.empty
        , binops = Dict.empty
        , effects = Can.NoEffects
        }


{-| Create a module with custom declarations.
-}
makeModuleWithDecls : Can.Decls -> Can.Module
makeModuleWithDecls decls =
    let
        home =
            IO.Canonical Pkg.core "Test"
    in
    Can.Module
        { name = home
        , exports = Can.ExportEverything A.zero
        , docs = Src.NoDocs A.zero []
        , decls = decls
        , unions = Dict.empty
        , aliases = Dict.empty
        , binops = Dict.empty
        , effects = Can.NoEffects
        }


{-| Create an untyped definition.
-}
makeDef : Name.Name -> List Can.Pattern -> Can.Expr -> Can.Def
makeDef name args body =
    Can.Def (A.At A.zero name) args body


{-| Create a typed definition.
Automatically extracts free type variables from the argument and result types.
-}
makeTypedDef : Name.Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> Can.Def
makeTypedDef name args body resultType =
    let
        -- Extract all free type variables from arg types and result type
        argTypes =
            List.map Tuple.second args

        allTypes =
            resultType :: argTypes

        freeVars =
            List.foldl
                (\t acc -> Dict.union acc (extractFreeTypeVars t))
                Dict.empty
                allTypes
    in
    Can.TypedDef (A.At A.zero name) freeVars args body resultType


{-| Extract free type variables from a Can.Type.
Returns a Dict mapping variable names to ().
-}
extractFreeTypeVars : Can.Type -> Dict Name.Name ()
extractFreeTypeVars tipe =
    case tipe of
        Can.TVar name ->
            Dict.singleton name ()

        Can.TLambda arg result ->
            Dict.union (extractFreeTypeVars arg) (extractFreeTypeVars result)

        Can.TType _ _ args ->
            List.foldl
                (\t acc -> Dict.union acc (extractFreeTypeVars t))
                Dict.empty
                args

        Can.TTuple a b rest ->
            List.foldl
                (\t acc -> Dict.union acc (extractFreeTypeVars t))
                (Dict.union (extractFreeTypeVars a) (extractFreeTypeVars b))
                rest

        Can.TRecord fields maybeExt ->
            let
                fieldVars =
                    Dict.foldl
                        (\_ (Can.FieldType _ fieldType) acc ->
                            Dict.union acc (extractFreeTypeVars fieldType)
                        )
                        Dict.empty
                        fields

                extVars =
                    case maybeExt of
                        Just extName ->
                            Dict.singleton extName ()

                        Nothing ->
                            Dict.empty
            in
            Dict.union fieldVars extVars

        Can.TUnit ->
            Dict.empty

        Can.TAlias _ _ args aliasedType ->
            let
                argVars =
                    List.foldl
                        (\( _, t ) acc -> Dict.union acc (extractFreeTypeVars t))
                        Dict.empty
                        args

                aliasVars =
                    case aliasedType of
                        Can.Holey t ->
                            extractFreeTypeVars t

                        Can.Filled t ->
                            extractFreeTypeVars t
            in
            Dict.union argVars aliasVars



-- ============================================================================
-- EXPRESSION BUILDERS
-- ============================================================================


{-| Create an expression with the given ID and node.
-}
makeExpr : Int -> Can.Expr_ -> Can.Expr
makeExpr id node =
    A.At A.zero { id = id, node = node }


{-| Create an Int literal expression.
-}
intExpr : Int -> Int -> Can.Expr
intExpr id n =
    makeExpr id (Can.Int n)


{-| Create a List expression.
-}
listExpr : Int -> List Can.Expr -> Can.Expr
listExpr id elements =
    makeExpr id (Can.List elements)


{-| Create a 2-tuple expression.
-}
tupleExpr : Int -> Can.Expr -> Can.Expr -> Can.Expr
tupleExpr id a b =
    makeExpr id (Can.Tuple a b [])


{-| Create a Lambda expression.
-}
lambdaExpr : Int -> List Can.Pattern -> Can.Expr -> Can.Expr
lambdaExpr id args body =
    makeExpr id (Can.Lambda args body)


{-| Create a function Call expression.
-}
callExpr : Int -> Can.Expr -> List Can.Expr -> Can.Expr
callExpr id func args =
    makeExpr id (Can.Call func args)


{-| Create a Let expression.
-}
letExpr : Int -> Can.Def -> Can.Expr -> Can.Expr
letExpr id def body =
    makeExpr id (Can.Let def body)


{-| Create a local variable reference.
-}
varLocalExpr : Int -> Name.Name -> Can.Expr
varLocalExpr id name =
    makeExpr id (Can.VarLocal name)


{-| Create a kernel function reference (VarKernel).
Used for kernel functions like Elm.Kernel.Platform.batch.
-}
varKernelExpr : Int -> Name.Name -> Name.Name -> Can.Expr
varKernelExpr id home name =
    makeExpr id (Can.VarKernel "Elm" home name)


{-| Create a foreign variable reference (VarForeign).
Used for references to functions from other modules with type annotations.
-}
varForeignExpr : Int -> IO.Canonical -> Name.Name -> Can.Annotation -> Can.Expr
varForeignExpr id home name annotation =
    makeExpr id (Can.VarForeign home name annotation)


{-| Create an annotation from free variables and a type.
-}
makeAnnotation : List Name.Name -> Can.Type -> Can.Annotation
makeAnnotation freeVars tipe =
    Can.Forall (Dict.fromList (List.map (\v -> ( v, () )) freeVars)) tipe



-- ============================================================================
-- PATTERN BUILDERS
-- ============================================================================


{-| Create a pattern with the given ID and node.
-}
makePattern : Int -> Can.Pattern_ -> Can.Pattern
makePattern id node =
    A.At A.zero { id = id, node = node }


{-| Variable pattern.
-}
pVar : Int -> Name.Name -> Can.Pattern
pVar id name =
    makePattern id (Can.PVar name)



-- ============================================================================
-- UNION AND CUSTOM TYPE BUILDERS
-- ============================================================================
-- ============================================================================
-- FUZZERS
-- ============================================================================
-- ============================================================================
-- TYPE BUILDERS
-- ============================================================================


{-| Int type.
-}
intType : Can.Type
intType =
    Can.TType (IO.Canonical Pkg.core "Basics") "Int" []


{-| List type.
-}
listType : Can.Type -> Can.Type
listType elemType =
    Can.TType (IO.Canonical Pkg.core "List") "List" [ elemType ]


{-| Tuple type.
-}
tupleType : Can.Type -> Can.Type -> List Can.Type -> Can.Type
tupleType a b rest =
    Can.TTuple a b rest


{-| Function type.
-}
funType : Can.Type -> Can.Type -> Can.Type
funType from to =
    Can.TLambda from to


{-| Type variable.
-}
varType : Name.Name -> Can.Type
varType name =
    Can.TVar name


{-| Float type.
-}
floatType : Can.Type
floatType =
    Can.TType (IO.Canonical Pkg.core "Basics") "Float" []


{-| Bool type.
-}
boolType : Can.Type
boolType =
    Can.TType (IO.Canonical Pkg.core "Basics") "Bool" []


{-| Char type.
-}
charType : Can.Type
charType =
    Can.TType (IO.Canonical Pkg.core "Char") "Char" []


{-| String type.
-}
stringType : Can.Type
stringType =
    Can.TType (IO.Canonical Pkg.core "String") "String" []


{-| Create a multi-argument function type (curried).

    tFunc [ intType, intType ] intType
    -- equivalent to: Int -> Int -> Int

-}
tFunc : List Can.Type -> Can.Type -> Can.Type
tFunc args result =
    List.foldr Can.TLambda result args
