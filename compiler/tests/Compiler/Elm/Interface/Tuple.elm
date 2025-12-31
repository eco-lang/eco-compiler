module Compiler.Elm.Interface.Tuple exposing (tupleInterface)

{-| Interface for elm/core Tuple module functions used in tests.
-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.Package as Pkg
import Data.Map as Dict exposing (Dict)



-- ============================================================================
-- TUPLE INTERFACE
-- ============================================================================


{-| The Tuple module interface containing tuple manipulation functions.
-}
tupleInterface : I.Interface
tupleInterface =
    I.Interface
        { home = Pkg.core
        , values = tupleValues
        , unions = Dict.empty
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


xVar : Can.Type
xVar =
    Can.TVar "x"


yVar : Can.Type
yVar =
    Can.TVar "y"


{-| ( a, b )
-}
tupleAB : Can.Type
tupleAB =
    Can.TTuple aVar bVar []


{-| ( x, b )
-}
tupleXB : Can.Type
tupleXB =
    Can.TTuple xVar bVar []


{-| ( a, y )
-}
tupleAY : Can.Type
tupleAY =
    Can.TTuple aVar yVar []


{-| ( x, y )
-}
tupleXY : Can.Type
tupleXY =
    Can.TTuple xVar yVar []



-- ============================================================================
-- VALUES (Functions)
-- ============================================================================


{-| Tuple function values.
-}
tupleValues : Dict String Name Can.Annotation
tupleValues =
    Dict.fromList identity
        [ -- pair : a -> b -> ( a, b )
          ( "pair"
          , mkAnnotation (Can.TLambda aVar (Can.TLambda bVar tupleAB))
          )

        -- first : ( a, b ) -> a
        , ( "first"
          , mkAnnotation (Can.TLambda tupleAB aVar)
          )

        -- second : ( a, b ) -> b
        , ( "second"
          , mkAnnotation (Can.TLambda tupleAB bVar)
          )

        -- mapFirst : (a -> x) -> ( a, b ) -> ( x, b )
        , ( "mapFirst"
          , mkAnnotation
                (Can.TLambda
                    (Can.TLambda aVar xVar)
                    (Can.TLambda tupleAB tupleXB)
                )
          )

        -- mapSecond : (b -> y) -> ( a, b ) -> ( a, y )
        , ( "mapSecond"
          , mkAnnotation
                (Can.TLambda
                    (Can.TLambda bVar yVar)
                    (Can.TLambda tupleAB tupleAY)
                )
          )

        -- mapBoth : (a -> x) -> (b -> y) -> ( a, b ) -> ( x, y )
        , ( "mapBoth"
          , mkAnnotation
                (Can.TLambda
                    (Can.TLambda aVar xVar)
                    (Can.TLambda
                        (Can.TLambda bVar yVar)
                        (Can.TLambda tupleAB tupleXY)
                    )
                )
          )
        ]
