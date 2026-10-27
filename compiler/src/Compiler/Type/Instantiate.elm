module Compiler.Type.Instantiate exposing
    ( FreeVars
    , fromSrcType
    )

{-| Type inference needs written types, such as a type annotation, a port's type
or a constructor's argument types, in the solver's own type representation, and
this module does that conversion.

A written type is a `Can.Type`; the result is a `Compiler.Type.Type.Type`. The
conversion follows the structure of the written type one constructor at a time.
It creates no type variables. Every type variable the written type names,
including a record's extension variable, must already have a solver type in the
`FreeVars` the caller passes, and a name that is missing crashes the compiler.

An alias use keeps both its arguments and its expansion. The arguments are
converted with the caller's `FreeVars`. A `Filled` expansion already has the
arguments substituted in, so it is converted with the caller's `FreeVars` too. A
`Holey` expansion is written in terms of the alias's own parameter names, so it
is converted with a map from those names to the converted arguments instead.


# Types

@docs FreeVars


# Conversion

@docs fromSrcType

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Type.Type exposing (Type(..))
import Dict
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Main as Utils



-- ====== FREE VARS ======


{-| The solver type to use for each type variable name a written type may
mention. Every occurrence of a name becomes the one type stored for it.
-}
type alias FreeVars =
    Dict.Dict Name Type



-- ====== FROM SOURCE TYPE ======


{-| Converts the written type `sourceType` into a solver type, replacing each type
variable by its entry in `freeVars`.

A function arrow's slot annotation is dropped, a tuple of any arity becomes a
`TupleN`, and a closed record gets `EmptyRecordN` as its extension. A type
variable or record extension name that is not in `freeVars` crashes. Aliases
are handled as the module docstring describes. The `IO` result creates nothing;
it only threads the solver state.

-}
fromSrcType : FreeVars -> Can.Type Name -> IO Type
fromSrcType freeVars sourceType =
    case sourceType of
        Can.TLambda _ arg result ->
            IO.pure FunN
                |> IO.apply (fromSrcType freeVars arg)
                |> IO.apply (fromSrcType freeVars result)

        Can.TVar name ->
            IO.pure (Utils.dictFind name freeVars)

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
                                    fromSrcType (Dict.fromList targs) realType
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
                |> IO.apply
                    (Dict.toList fields
                        |> IO.traverseList (\( k, ft ) -> fromSrcFieldType freeVars ft |> IO.map (\t -> ( k, t )))
                        |> IO.map Dict.fromList
                    )
                |> IO.apply
                    (case maybeExt of
                        Nothing ->
                            IO.pure EmptyRecordN

                        Just ext ->
                            IO.pure (Utils.dictFind ext freeVars)
                    )


{-| Converts the type of one record field, ignoring the field's position.
-}
fromSrcFieldType : Dict.Dict Name Type -> Can.FieldType Name -> IO Type
fromSrcFieldType freeVars (Can.FieldType _ tipe) =
    fromSrcType freeVars tipe
