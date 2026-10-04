module Compiler.Elm.Interface.JsArray exposing (jsArrayInterface)

{-| A test program that imports `Elm.JsArray` needs an interface for that module
to be canonicalized against, and this module supplies a hand-written one in
place of one compiled from elm/core.

An interface is what a compiled module offers to the modules that import it:
the type annotation of each exposed value, and its unions, aliases and
operators. `jsArrayInterface` is that record for `Elm.JsArray`, the elm/core
module that defines the `JsArray` type.

It is a mock, and it differs from the elm/core source that
`Compiler.Elm.Source.JsArray` carries in three ways.

  - It declares only eight functions: `empty`, `push`, `length`, `slice`,
    `foldl`, `foldr`, `initializeFromList` and `map`. Others in that source,
    such as `singleton`, `initialize` and `unsafeGet`, are not in it.
  - Its `JsArray a` has a single constructor, `JsArray_elm_builtin`, which
    takes no arguments, so the `a` appears in no constructor. The source
    declares `type JsArray a = JsArray a`.
  - The union is open, so a module importing this interface sees its
    constructor. The source exposes `JsArray` without its constructor.

Each function's annotation quantifies over every type variable in its type,
which `mkAnnotation` finds with `collectFreeVars`.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName exposing (Canonical(..))
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)


{-| The canonical name of the module `Elm.JsArray` in the `elm/core` package,
which is the home of the `JsArray` type.
-}
jsArrayModuleName : Canonical
jsArrayModuleName =
    Canonical Pkg.core "Elm.JsArray"



-- ============================================================================
-- JSARRAY INTERFACE
-- ============================================================================


{-| The mock interface of `Elm.JsArray`: the eight functions of `jsArrayValues`
and the `JsArray` union, with no aliases or operators, in the `elm/core`
package.
-}
jsArrayInterface : I.Interface
jsArrayInterface =
    I.Interface
        { home = Pkg.core
        , values = jsArrayValues
        , unions = jsArrayUnions
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| Returns the name of every type variable that occurs in `tipe`, including the
extension variable of an extensible record. For an alias, the variables of its
arguments and of its body are both collected.
-}
collectFreeVars : Can.Type Name -> Can.FreeVars
collectFreeVars tipe =
    case tipe of
        Can.TLambda _ a b ->
            Dict.union (collectFreeVars a) (collectFreeVars b)

        Can.TVar name ->
            Dict.singleton name ()

        Can.TType _ _ args ->
            List.foldl (\arg acc -> Dict.union (collectFreeVars arg) acc) Dict.empty args

        Can.TRecord fields maybeExt ->
            let
                fieldVars =
                    Dict.foldl (\_ (Can.FieldType _ t) acc -> Dict.union (collectFreeVars t) acc) Dict.empty fields

                extVar =
                    case maybeExt of
                        Just name ->
                            Dict.singleton name ()

                        Nothing ->
                            Dict.empty
            in
            Dict.union fieldVars extVar

        Can.TUnit ->
            Dict.empty

        Can.TTuple a b cs ->
            List.foldl (\t acc -> Dict.union (collectFreeVars t) acc)
                (Dict.union (collectFreeVars a) (collectFreeVars b))
                cs

        Can.TAlias _ _ args aliasType ->
            let
                argVars =
                    List.foldl (\( _, t ) acc -> Dict.union (collectFreeVars t) acc) Dict.empty args
            in
            case aliasType of
                Can.Holey t ->
                    Dict.union argVars (collectFreeVars t)

                Can.Filled t ->
                    Dict.union argVars (collectFreeVars t)


{-| Returns an annotation of `tipe` that quantifies over every type variable in
it.
-}
mkAnnotation : Can.Type Name -> Can.Annotation Name
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe



-- ============================================================================
-- TYPES
-- ============================================================================


{-| The type variable `a`, the element type of `JsArray a` and `List a` in these
signatures.
-}
aVar : Can.Type Name
aVar =
    Can.TVar "a"


{-| The type variable `b`, the accumulator of the folds and the element type of
the array `map` returns.
-}
bVar : Can.Type Name
bVar =
    Can.TVar "b"


{-| The type `Int` from `Basics`.
-}
intType : Can.Type Name
intType =
    Can.TType ModuleName.basics "Int" []


{-| The type `JsArray a`.
-}
jsArrayA : Can.Type Name
jsArrayA =
    Can.TType jsArrayModuleName "JsArray" [ aVar ]


{-| The type `JsArray b`, which `map` returns.
-}
jsArrayB : Can.Type Name
jsArrayB =
    Can.TType jsArrayModuleName "JsArray" [ bVar ]


{-| The type `List a`, which `initializeFromList` takes and returns.
-}
listA : Can.Type Name
listA =
    Can.TType ModuleName.list "List" [ aVar ]



-- ============================================================================
-- UNIONS
-- ============================================================================


{-| The unions of the mock module, of which there is one: `JsArray a`, open,
with a single constructor `JsArray_elm_builtin` that takes no arguments.
-}
jsArrayUnions : Dict Name I.Union
jsArrayUnions =
    let
        jsArrayCtor =
            Can.Ctor
                { name = "JsArray_elm_builtin"
                , index = Index.first
                , numArgs = 0
                , args = []
                }

        jsArrayUnion =
            Can.Union
                { vars = [ "a" ]
                , alts = [ jsArrayCtor ]
                , numAlts = 1
                , opts = Can.Normal
                }
    in
    Dict.fromList
        [ ( "JsArray", I.OpenUnion jsArrayUnion )
        ]



-- ============================================================================
-- VALUES (Functions)
-- ============================================================================


{-| The annotations of the eight functions the mock module exposes, keyed by
name.
-}
jsArrayValues : Dict Name (Can.Annotation Name)
jsArrayValues =
    Dict.fromList
        [ -- empty : JsArray a
          ( "empty", mkAnnotation jsArrayA )

        -- push : a -> JsArray a -> JsArray a
        , ( "push"
          , mkAnnotation
                (Can.tLambda aVar (Can.tLambda jsArrayA jsArrayA))
          )

        -- length : JsArray a -> Int
        , ( "length"
          , mkAnnotation
                (Can.tLambda jsArrayA intType)
          )

        -- slice : Int -> Int -> JsArray a -> JsArray a
        , ( "slice"
          , mkAnnotation
                (Can.tLambda intType (Can.tLambda intType (Can.tLambda jsArrayA jsArrayA)))
          )

        -- foldl : (a -> b -> b) -> b -> JsArray a -> b
        , ( "foldl"
          , mkAnnotation
                (Can.tLambda
                    (Can.tLambda aVar (Can.tLambda bVar bVar))
                    (Can.tLambda bVar (Can.tLambda jsArrayA bVar))
                )
          )

        -- foldr : (a -> b -> b) -> b -> JsArray a -> b
        , ( "foldr"
          , mkAnnotation
                (Can.tLambda
                    (Can.tLambda aVar (Can.tLambda bVar bVar))
                    (Can.tLambda bVar (Can.tLambda jsArrayA bVar))
                )
          )

        -- initializeFromList : Int -> List a -> ( JsArray a, List a )
        , ( "initializeFromList"
          , mkAnnotation
                (Can.tLambda intType
                    (Can.tLambda listA
                        (Can.TTuple jsArrayA listA [])
                    )
                )
          )

        -- map : (a -> b) -> JsArray a -> JsArray b
        , ( "map"
          , mkAnnotation
                (Can.tLambda
                    (Can.tLambda aVar bVar)
                    (Can.tLambda jsArrayA jsArrayB)
                )
          )
        ]
