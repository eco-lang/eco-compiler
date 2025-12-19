module Compiler.Optimize.Typed.KernelTypes exposing
    ( KernelTypeEnv
    , fromDecls
    , lookup
    )

{-| Kernel type environment for typed optimization.

This module builds a mapping from kernel function references to their types
by scanning canonical module declarations for patterns like:

    cons : a -> List a -> List a
    cons =
        Elm.Kernel.List.cons

which exposes the kernel function with the same type as the Elm alias.


# Types

@docs KernelTypeEnv


# Building

@docs fromDecls


# Lookup

@docs lookup

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)



-- TYPES


{-| Environment mapping (home, kernelName) to the canonical type.

`home` is the short kernel module name (e.g., "List", "Utils"),
and `kernelName` is the function name (e.g., "cons").

-}
type alias KernelTypeEnv =
    Dict ( String, String ) ( Name, Name ) Can.Type


{-| Compare function for (Name, Name) tuple keys.
-}
comparePair : ( Name, Name ) -> ( Name, Name ) -> Order
comparePair ( h1, n1 ) ( h2, n2 ) =
    case compare h1 h2 of
        EQ ->
            compare n1 n2

        other ->
            other


{-| Identity function for (Name, Name) tuples.
-}
pairIdentity : ( Name, Name ) -> ( Name, Name )
pairIdentity p =
    p



-- LOOKUP


{-| Look up the type of a kernel function by its home and name.
-}
lookup : Name -> Name -> KernelTypeEnv -> Maybe Can.Type
lookup home name env =
    Dict.get pairIdentity ( home, name ) env



-- BUILDING


{-| Type annotations for top-level definitions.
-}
type alias Annotations =
    Dict String Name Can.Annotation


{-| Build a kernel type environment from annotations and declarations.

Scans declarations for the pattern where a top-level definition with
zero arguments has a body that is exactly a VarKernel reference.
The type from the annotation is associated with that kernel function.

-}
fromDecls : Annotations -> Can.Decls -> KernelTypeEnv
fromDecls annotations decls =
    stepDecls annotations decls Dict.empty


stepDecls : Annotations -> Can.Decls -> KernelTypeEnv -> KernelTypeEnv
stepDecls annotations decls env =
    case decls of
        Can.Declare def rest ->
            stepDecls annotations rest (stepDef annotations def env)

        Can.DeclareRec d ds rest ->
            -- Recursive groups: still just scan individual defs
            let
                env1 : KernelTypeEnv
                env1 =
                    List.foldl (stepDef annotations) env (d :: ds)
            in
            stepDecls annotations rest env1

        Can.SaveTheEnvironment ->
            env


stepDef : Annotations -> Can.Def -> KernelTypeEnv -> KernelTypeEnv
stepDef annotations def env =
    case def of
        -- Untyped def, 0 args, body is exactly a VarKernel
        Can.Def (A.At _ name) [] (A.At _ (Can.VarKernel home kernelName)) ->
            let
                tipe : Can.Type
                tipe =
                    annotationToType name annotations
            in
            Dict.insert pairIdentity ( home, kernelName ) tipe env

        -- Typed def, 0 args, body is exactly a VarKernel
        Can.TypedDef (A.At _ name) _ [] (A.At _ (Can.VarKernel home kernelName)) resultType ->
            -- For typed defs, resultType is the canonical function type
            -- But we should use the full type from annotations for consistency
            let
                tipe : Can.Type
                tipe =
                    case Dict.get identity name annotations of
                        Just (Can.Forall _ t) ->
                            t

                        Nothing ->
                            -- Fall back to resultType if annotation not found
                            resultType
            in
            Dict.insert pairIdentity ( home, kernelName ) tipe env

        _ ->
            env


{-| Get the type from an annotation, unwrapping Forall.
-}
annotationToType : Name -> Annotations -> Can.Type
annotationToType defName annotations =
    case Dict.get identity defName annotations of
        Just (Can.Forall _ tipe) ->
            tipe

        Nothing ->
            -- This should not happen in well-typed code, but keep a
            -- placeholder rather than crash in the first version.
            Can.TVar ("missing_annot_" ++ defName)
