module Compiler.Elm.Interface.JsArray exposing (jsArrayInterface, jsArrayModuleName)

{-| Interface for Elm.JsArray module types and functions used in tests.
-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO exposing (Canonical(..))


{-| Canonical module name for Elm.JsArray (kernel module).
-}
jsArrayModuleName : Canonical
jsArrayModuleName =
    Canonical Pkg.core "Elm.JsArray"



-- ============================================================================
-- JSARRAY INTERFACE
-- ============================================================================


{-| The JsArray module interface containing JsArray types and functions.
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


{-| Collect all free type variables from a canonical type.
-}
collectFreeVars : Can.Type -> Can.FreeVars
collectFreeVars tipe =
    case tipe of
        Can.TLambda a b ->
            Dict.union (collectFreeVars a) (collectFreeVars b)

        Can.TVar name ->
            Dict.singleton identity name ()

        Can.TType _ _ args ->
            List.foldl (\arg acc -> Dict.union (collectFreeVars arg) acc) Dict.empty args

        Can.TRecord fields maybeExt ->
            let
                fieldVars =
                    Dict.foldl compare (\_ (Can.FieldType _ t) acc -> Dict.union (collectFreeVars t) acc) Dict.empty fields

                extVar =
                    case maybeExt of
                        Just name ->
                            Dict.singleton identity name ()

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


{-| Helper to create a value annotation.
-}
mkAnnotation : Can.Type -> Can.Annotation
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe



-- ============================================================================
-- TYPES
-- ============================================================================


aVar : Can.Type
aVar =
    Can.TVar "a"


bVar : Can.Type
bVar =
    Can.TVar "b"


intType : Can.Type
intType =
    Can.TType ModuleName.basics "Int" []


{-| JsArray a
-}
jsArrayA : Can.Type
jsArrayA =
    Can.TType jsArrayModuleName "JsArray" [ aVar ]


jsArrayB : Can.Type
jsArrayB =
    Can.TType jsArrayModuleName "JsArray" [ bVar ]


listA : Can.Type
listA =
    Can.TType ModuleName.list "List" [ aVar ]



-- ============================================================================
-- UNIONS
-- ============================================================================


{-| JsArray union type definition.

type JsArray a = JsArray_elm_builtin

-}
jsArrayUnions : Dict String Name I.Union
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
    Dict.fromList identity
        [ ( "JsArray", I.OpenUnion jsArrayUnion )
        ]



-- ============================================================================
-- VALUES (Functions)
-- ============================================================================


{-| JsArray function values.
-}
jsArrayValues : Dict String Name Can.Annotation
jsArrayValues =
    Dict.fromList identity
        [ -- empty : JsArray a
          ( "empty", mkAnnotation jsArrayA )

        -- push : a -> JsArray a -> JsArray a
        , ( "push"
          , mkAnnotation
                (Can.TLambda aVar (Can.TLambda jsArrayA jsArrayA))
          )

        -- length : JsArray a -> Int
        , ( "length"
          , mkAnnotation
                (Can.TLambda jsArrayA intType)
          )

        -- slice : Int -> Int -> JsArray a -> JsArray a
        , ( "slice"
          , mkAnnotation
                (Can.TLambda intType (Can.TLambda intType (Can.TLambda jsArrayA jsArrayA)))
          )

        -- foldl : (a -> b -> b) -> b -> JsArray a -> b
        , ( "foldl"
          , mkAnnotation
                (Can.TLambda
                    (Can.TLambda aVar (Can.TLambda bVar bVar))
                    (Can.TLambda bVar (Can.TLambda jsArrayA bVar))
                )
          )

        -- foldr : (a -> b -> b) -> b -> JsArray a -> b
        , ( "foldr"
          , mkAnnotation
                (Can.TLambda
                    (Can.TLambda aVar (Can.TLambda bVar bVar))
                    (Can.TLambda bVar (Can.TLambda jsArrayA bVar))
                )
          )

        -- initializeFromList : Int -> List a -> ( JsArray a, List a )
        , ( "initializeFromList"
          , mkAnnotation
                (Can.TLambda intType
                    (Can.TLambda listA
                        (Can.TTuple jsArrayA listA [])
                    )
                )
          )

        -- map : (a -> b) -> JsArray a -> JsArray b
        , ( "map"
          , mkAnnotation
                (Can.TLambda
                    (Can.TLambda aVar bVar)
                    (Can.TLambda jsArrayA jsArrayB)
                )
          )
        ]
