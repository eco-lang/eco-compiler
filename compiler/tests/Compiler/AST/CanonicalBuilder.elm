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
    , makeModule
    , makeModuleWithDecls
    , makeTypedDef
    , pVar
    , stringType
    , tFunc
    , tupleExpr
    , tupleType
    , varForeignExpr
    , varKernelExpr
    , varLocalExpr
    , varType
    )

{-| Lets a test build Canonical AST values directly, so that a stage working on
the Canonical AST can be given exactly the tree a test wants without running the
parser and canonicalizer to produce it.

The Canonical AST is the tree `Compiler.AST.Canonical` defines: every reference
to a top-level, imported or kernel value names the module it comes from, and
every expression and pattern carries an integer id beside its node. This module
builds a subset of that tree: expressions (`Int` literals, lists, pairs,
lambdas, calls, single-definition `let`s and three kinds of variable reference),
one pattern (`pVar`), definitions with and without annotations, whole modules,
and the common `elm/core` types.

Four things hold for everything built here.

The caller chooses every id. Each expression and pattern builder takes the id of
the node it builds as its first argument, and nothing here allocates ids or
checks that two nodes do not share one.

Nothing has a real source position. Every expression, pattern and defined name
is placed at `A.zero`, the zero-width region at (0, 0) that no source text
occupies.

Every module built here is named `Test`, belongs to the `elm/core` package and
exports everything.

Function types are built with `Can.tLambda`, so their arrows carry no arrow
identity, as `Compiler.AST.Canonical` describes for `tLambda`.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)



-- ============================================================================
-- MODULE AND DEFINITION BUILDERS
-- ============================================================================


{-| Builds a module whose one declaration defines `name`, with no arguments and
no annotation, as `expr`. The module has no docs, unions, aliases, binary
operators or effects.
-}
makeModule : Name.Name -> Can.Expr -> Can.Module
makeModule name expr =
    let
        def =
            Can.Def (A.At A.zero name) [] expr

        decls =
            Can.Declare def Can.SaveTheEnvironment

        home =
            ModuleName.Canonical Pkg.core "Test"
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


{-| Builds a module declaring `decls`, otherwise the same as `makeModule`: no
docs, unions, aliases, binary operators or effects.
-}
makeModuleWithDecls : Can.Decls -> Can.Module
makeModuleWithDecls decls =
    let
        home =
            ModuleName.Canonical Pkg.core "Test"
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


{-| Builds a definition of `name` with no annotation, taking `args` and returning
`body`.
-}
makeDef : Name.Name -> List Can.Pattern -> Can.Expr -> Can.Def
makeDef name args body =
    Can.Def (A.At A.zero name) args body


{-| Builds an annotated definition of `name`, whose arguments are the patterns in
`args` each paired with its type, and which returns `body` of type `resultType`.

The definition's free type variables are not passed in. They are collected from
the argument types and `resultType`: every type variable and record extension
variable named in them. In an alias application both the alias's arguments and
its body are searched, so a `Holey` body contributes the alias's own parameter
names.

-}
makeTypedDef : Name.Name -> List ( Can.Pattern, Can.Type Name ) -> Can.Expr -> Can.Type Name -> Can.Def
makeTypedDef name args body resultType =
    let
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


{-| Returns the names of the type variables that occur in `tipe`, record
extension variables included. An alias application is searched in its
arguments only, as `Compiler.Canonicalize.Type` does: a `Holey` body is written
in the alias's own parameter names, which the alias binds, and a `Filled` body
holds nothing the arguments do not.
-}
extractFreeTypeVars : Can.Type Name -> Dict Name.Name ()
extractFreeTypeVars tipe =
    case tipe of
        Can.TVar name ->
            Dict.singleton name ()

        Can.TLambda _ arg result ->
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

        Can.TAlias _ _ args _ ->
            List.foldl
                (\( _, t ) acc -> Dict.union acc (extractFreeTypeVars t))
                Dict.empty
                args



-- ============================================================================
-- EXPRESSION AND ANNOTATION BUILDERS
-- ============================================================================


{-| Builds an expression with id `id` and contents `node`, placed at `A.zero`.
-}
makeExpr : Int -> Can.Expr_ -> Can.Expr
makeExpr id node =
    A.At A.zero { id = id, node = node }


{-| Builds an `Int` literal of value `n`, with id `id`.
-}
intExpr : Int -> Int -> Can.Expr
intExpr id n =
    makeExpr id (Can.Int n)


{-| Builds a list literal holding `elements`.
-}
listExpr : Int -> List Can.Expr -> Can.Expr
listExpr id elements =
    makeExpr id (Can.List elements)


{-| Builds the pair `( a, b )`.
-}
tupleExpr : Int -> Can.Expr -> Can.Expr -> Can.Expr
tupleExpr id a b =
    makeExpr id (Can.Tuple a b [])


{-| Builds an anonymous function taking `args` and returning `body`.
-}
lambdaExpr : Int -> List Can.Pattern -> Can.Expr -> Can.Expr
lambdaExpr id args body =
    makeExpr id (Can.Lambda args body)


{-| Builds the application of `func` to `args`.
-}
callExpr : Int -> Can.Expr -> List Can.Expr -> Can.Expr
callExpr id func args =
    makeExpr id (Can.Call func args)


{-| Builds a non-recursive `let` that defines `def` and evaluates to `body`.
-}
letExpr : Int -> Can.Def -> Can.Expr -> Can.Expr
letExpr id def body =
    makeExpr id (Can.Let def body)


{-| Builds a reference to the local variable `name`.
-}
varLocalExpr : Int -> Name.Name -> Can.Expr
varLocalExpr id name =
    makeExpr id (Can.VarLocal name)


{-| Builds a reference to the kernel value `name` in the kernel module `home`,
always under the `Elm` kernel prefix: `varKernelExpr id "Platform" "batch"`
refers to `Elm.Kernel.Platform.batch`. A reference under the `Eco` prefix cannot
be built with this.
-}
varKernelExpr : Int -> Name.Name -> Name.Name -> Can.Expr
varKernelExpr id home name =
    makeExpr id (Can.VarKernel "Elm" home name)


{-| Builds a reference to the value `name` defined in the module `home`, carrying
`annotation` as its type.
-}
varForeignExpr : Int -> ModuleName.Canonical -> Name.Name -> Can.Annotation Name -> Can.Expr
varForeignExpr id home name annotation =
    makeExpr id (Can.VarForeign home name annotation)


{-| Builds an annotation of `tipe` quantified over `freeVars`. The names are used
as given and are not checked against the variables in `tipe`.
-}
makeAnnotation : List Name.Name -> Can.Type Name -> Can.Annotation Name
makeAnnotation freeVars tipe =
    Can.Forall (Dict.fromList (List.map (\v -> ( v, () )) freeVars)) tipe



-- ============================================================================
-- PATTERN BUILDERS
-- ============================================================================


{-| Builds a pattern with id `id` and contents `node`, placed at `A.zero`.
-}
makePattern : Int -> Can.Pattern_ -> Can.Pattern
makePattern id node =
    A.At A.zero { id = id, node = node }


{-| Builds a pattern that binds whatever it matches to `name`.
-}
pVar : Int -> Name.Name -> Can.Pattern
pVar id name =
    makePattern id (Can.PVar name)



-- ============================================================================
-- TYPE BUILDERS
-- ============================================================================


{-| The type `Int`, from `Basics` in `elm/core`.
-}
intType : Can.Type Name
intType =
    Can.TType (ModuleName.Canonical Pkg.core "Basics") "Int" []


{-| Returns the type of lists of `elemType`.
-}
listType : Can.Type Name -> Can.Type Name
listType elemType =
    Can.TType (ModuleName.Canonical Pkg.core "List") "List" [ elemType ]


{-| Returns the tuple type whose element types are `a`, `b` and then those in
`rest`.
-}
tupleType : Can.Type Name -> Can.Type Name -> List (Can.Type Name) -> Can.Type Name
tupleType a b rest =
    Can.TTuple a b rest


{-| Returns the type of functions from `from` to `to`, with no arrow identity.
-}
funType : Can.Type Name -> Can.Type Name -> Can.Type Name
funType from to =
    Can.tLambda from to


{-| Returns the type variable named `name`.
-}
varType : Name.Name -> Can.Type Name
varType name =
    Can.TVar name


{-| The type `Float`, from `Basics` in `elm/core`.
-}
floatType : Can.Type Name
floatType =
    Can.TType (ModuleName.Canonical Pkg.core "Basics") "Float" []


{-| The type `Bool`, from `Basics` in `elm/core`.
-}
boolType : Can.Type Name
boolType =
    Can.TType (ModuleName.Canonical Pkg.core "Basics") "Bool" []


{-| The type `Char`, from the `Char` module of `elm/core`.
-}
charType : Can.Type Name
charType =
    Can.TType (ModuleName.Canonical Pkg.core "Char") "Char" []


{-| The type `String`, from the `String` module of `elm/core`.
-}
stringType : Can.Type Name
stringType =
    Can.TType (ModuleName.Canonical Pkg.core "String") "String" []


{-| Returns the curried function type taking `args` in order and returning
`result`, with no arrow identity on any arrow. With no `args` it is `result`.

    tFunc [ intType, intType ] intType
    -- equivalent to: Int -> Int -> Int

-}
tFunc : List (Can.Type Name) -> Can.Type Name -> Can.Type Name
tFunc args result =
    List.foldr Can.tLambda result args
