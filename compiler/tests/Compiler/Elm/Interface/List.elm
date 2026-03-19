module Compiler.Elm.Interface.List exposing (listInterface)

{-| Interface for elm/core List module functions used in tests.
-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)



-- ============================================================================
-- LIST INTERFACE
-- ============================================================================


{-| The List module interface containing list functions.
-}
listInterface : I.Interface
listInterface =
    I.Interface
        { home = Pkg.core
        , values = listValues
        , unions = Dict.empty
        , aliases = Dict.empty
        , binops = listBinops
        }


{-| List binary operators - specifically the :: (cons) operator.
-}
listBinops : Dict Name I.Binop
listBinops =
    let
        aVar =
            Can.TVar "a"

        listA =
            Can.TType ModuleName.list "List" [ aVar ]

        -- a -> List a -> List a
        consType =
            Can.TLambda aVar (Can.TLambda listA listA)

        consBinop =
            I.Binop
                { name = "cons"
                , annotation = Can.Forall (Dict.singleton "a" ()) consType
                , associativity = Binop.Right
                , precedence = 5
                }
    in
    Dict.fromList
        [ ( "::", consBinop )
        ]


{-| Collect all free type variables from a canonical type.
-}
collectFreeVars : Can.Type -> Can.FreeVars
collectFreeVars tipe =
    case tipe of
        Can.TLambda a b ->
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


{-| Helper to create a value annotation.
-}
mkAnnotation : Can.Type -> Can.Annotation
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe


{-| List function values.
-}
listValues : Dict Name Can.Annotation
listValues =
    let
        -- Type variables
        aVar =
            Can.TVar "a"

        bVar =
            Can.TVar "b"

        cVar =
            Can.TVar "c"

        -- Common types
        intType =
            Can.TType ModuleName.basics "Int" []

        listA =
            Can.TType ModuleName.list "List" [ aVar ]

        listB =
            Can.TType ModuleName.list "List" [ bVar ]

        listListA =
            Can.TType ModuleName.list "List" [ listA ]

        -- cons : a -> List a -> List a
        consType =
            Can.TLambda aVar (Can.TLambda listA listA)

        -- map : (a -> b) -> List a -> List b
        mapType =
            Can.TLambda (Can.TLambda aVar bVar) (Can.TLambda listA listB)

        -- map2 : (a -> b -> c) -> List a -> List b -> List c
        listC =
            Can.TType ModuleName.list "List" [ cVar ]

        map2Type =
            Can.TLambda
                (Can.TLambda aVar (Can.TLambda bVar cVar))
                (Can.TLambda listA (Can.TLambda listB listC))

        -- foldr : (a -> b -> b) -> b -> List a -> b
        foldrType =
            Can.TLambda
                (Can.TLambda aVar (Can.TLambda bVar bVar))
                (Can.TLambda bVar (Can.TLambda listA bVar))

        -- foldl : (a -> b -> b) -> b -> List a -> b
        foldlType =
            Can.TLambda
                (Can.TLambda aVar (Can.TLambda bVar bVar))
                (Can.TLambda bVar (Can.TLambda listA bVar))

        -- reverse : List a -> List a
        reverseType =
            Can.TLambda listA listA

        -- range : Int -> Int -> List Int
        listInt =
            Can.TType ModuleName.list "List" [ intType ]

        rangeType =
            Can.TLambda intType (Can.TLambda intType listInt)

        -- length : List a -> Int
        lengthType =
            Can.TLambda listA intType

        -- concat : List (List a) -> List a
        concatType =
            Can.TLambda listListA listA

        -- drop : Int -> List a -> List a
        dropType =
            Can.TLambda intType (Can.TLambda listA listA)

        -- filter : (a -> Bool) -> List a -> List a
        boolType =
            Can.TType ModuleName.basics "Bool" []

        filterType =
            Can.TLambda (Can.TLambda aVar boolType) (Can.TLambda listA listA)

        -- any : (a -> Bool) -> List a -> Bool
        anyType =
            Can.TLambda (Can.TLambda aVar boolType) (Can.TLambda listA boolType)

        -- all : (a -> Bool) -> List a -> Bool
        allType =
            Can.TLambda (Can.TLambda aVar boolType) (Can.TLambda listA boolType)
    in
    Dict.fromList
        [ ( "cons", mkAnnotation consType )
        , ( "map", mkAnnotation mapType )
        , ( "map2", mkAnnotation map2Type )
        , ( "foldr", mkAnnotation foldrType )
        , ( "foldl", mkAnnotation foldlType )
        , ( "filter", mkAnnotation filterType )
        , ( "any", mkAnnotation anyType )
        , ( "all", mkAnnotation allType )
        , ( "reverse", mkAnnotation reverseType )
        , ( "range", mkAnnotation rangeType )
        , ( "length", mkAnnotation lengthType )
        , ( "concat", mkAnnotation concatType )
        , ( "drop", mkAnnotation dropType )
        ]
