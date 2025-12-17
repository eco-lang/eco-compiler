module Compiler.Type.Instantiate exposing
    ( FreeVars
    , fromSrcType
    )

{-| Instantiation of source-level type annotations into internal type representations.

This module converts type annotations from the canonical AST (source types) into the
internal type representation used during type inference. The conversion involves creating
fresh type variables and properly handling type aliases and polymorphism.

When a type annotation contains free type variables (like `a` in `List a`), those
variables are tracked in the FreeVars dictionary to ensure consistent mapping throughout
the type structure.


# Types

@docs FreeVars


# Conversion

@docs fromSrcType

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Type.Type exposing (Type(..))
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Crash
import Utils.Main as Utils



-- FREE VARS


{-| A mapping from type variable names to their instantiated type representations.

When converting source types to internal types, free type variables (like `a` in `List a`)
need to be tracked to ensure all occurrences of the same variable name map to the same
internal type variable. This dictionary maintains that consistent mapping throughout the
conversion process.
-}
type alias FreeVars =
    Dict String Name Type



-- FROM SOURCE TYPE


{-| Convert a source-level type annotation into an internal type representation.

Takes a mapping of free type variables and a canonical source type, and produces
an internal type used during type inference. This handles:
- Function types (lambdas)
- Type variables (using the FreeVars mapping)
- Named types with arguments (applications)
- Type aliases (both filled and holey)
- Tuples (pairs and triples)
- Unit type
- Record types with optional extension

The conversion may perform IO operations such as creating fresh type variables
for unbound names.
-}
fromSrcType : FreeVars -> Can.Type -> IO Type
fromSrcType freeVars sourceType =
    case sourceType of
        Can.TLambda arg result ->
            IO.pure FunN
                |> IO.apply (fromSrcType freeVars arg)
                |> IO.apply (fromSrcType freeVars result)

        Can.TVar name ->
            IO.pure (Utils.find identity name freeVars)

        Can.TType home name args ->
            IO.map (AppN home name)
                (IO.traverseList (fromSrcType freeVars) args)

        Can.TAlias home name args aliasedType ->
            IO.traverseList (IO.traverseTuple (fromSrcType freeVars)) args
                |> IO.andThen
                    (\targs ->
                        IO.map (AliasN home name targs)
                            (case aliasedType of
                                Can.Filled realType ->
                                    fromSrcType freeVars realType

                                Can.Holey realType ->
                                    fromSrcType (Dict.fromList identity targs) realType
                            )
                    )

        Can.TTuple a b maybeC ->
            IO.pure TupleN
                |> IO.apply (fromSrcType freeVars a)
                |> IO.apply (fromSrcType freeVars b)
                |> IO.apply (IO.traverseList (fromSrcType freeVars) maybeC)

        Can.TUnit ->
            IO.pure UnitN

        Can.TRecord fields maybeExt ->
            IO.pure RecordN
                |> IO.apply (IO.traverseMap identity compare (fromSrcFieldType freeVars) fields)
                |> IO.apply
                    (case maybeExt of
                        Nothing ->
                            IO.pure EmptyRecordN

                        Just ext ->
                            IO.pure (Utils.find identity ext freeVars)
                    )


fromSrcFieldType : Dict String Name Type -> Can.FieldType -> IO Type
fromSrcFieldType freeVars (Can.FieldType _ tipe) =
    fromSrcType freeVars tipe
