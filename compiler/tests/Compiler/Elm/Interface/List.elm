module Compiler.Elm.Interface.List exposing (listInterface)

{-| `TestLogic.TestPipeline` canonicalizes test programs against the hand-built
module interfaces in `Compiler.Elm.Interface.Basic.testIfaces` rather than
against a compiled elm/core, and this module supplies the one for `List`, which
`testIfaces` holds under the module name `List`.

An interface is what a module offers its importers: the type of each exported
value, its union types and aliases, and its infix operators. This one belongs to
the package elm/core. It declares one operator, `::`, which stands for the value
`cons`, associates to the right and has precedence 5. Its values are `cons`,
`map`, `map2`, `foldr`, `foldl`, `filter`, `any`, `all`, `reverse`, `range`,
`length`, `concat` and `drop`, each polymorphic in every type variable its type
mentions.

Among what this interface does not contain: any other `List` function, any
union type or alias, and so the `List` type itself, which the annotations refer
to by name in the module `List` of elm/core without declaring it.

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


{-| The interface of elm/core's `List` module as test programs see it: the
values of `listValues`, the `::` operator of `listBinops`, and no unions or
aliases.
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


{-| The operator table of the mock `List` interface, holding only `::`. It
stands for the value `cons`, has type `a -> List a -> List a` quantified over
`a`, associates to the right and has precedence 5.
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
            Can.tLambda aVar (Can.tLambda listA listA)

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


{-| Returns the set of every type variable named in `tipe`, including a
record's extension variable.

For an alias, only the alias's argument types are searched, as in
`Compiler.Canonicalize.Type`: a `Holey` body names the alias's own parameters,
which the alias binds.

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

        Can.TAlias _ _ args _ ->
            List.foldl (\( _, t ) acc -> Dict.union (collectFreeVars t) acc) Dict.empty args


{-| Returns an annotation for `tipe` that is polymorphic in every type
variable `tipe` names.
-}
mkAnnotation : Can.Type Name -> Can.Annotation Name
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe


{-| The values of the mock `List` interface, each mapped to its type
annotation.
-}
listValues : Dict Name (Can.Annotation Name)
listValues =
    let
        aVar =
            Can.TVar "a"

        bVar =
            Can.TVar "b"

        cVar =
            Can.TVar "c"

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
            Can.tLambda aVar (Can.tLambda listA listA)

        -- map : (a -> b) -> List a -> List b
        mapType =
            Can.tLambda (Can.tLambda aVar bVar) (Can.tLambda listA listB)

        listC =
            Can.TType ModuleName.list "List" [ cVar ]

        -- map2 : (a -> b -> c) -> List a -> List b -> List c
        map2Type =
            Can.tLambda
                (Can.tLambda aVar (Can.tLambda bVar cVar))
                (Can.tLambda listA (Can.tLambda listB listC))

        -- foldr : (a -> b -> b) -> b -> List a -> b
        foldrType =
            Can.tLambda
                (Can.tLambda aVar (Can.tLambda bVar bVar))
                (Can.tLambda bVar (Can.tLambda listA bVar))

        -- foldl : (a -> b -> b) -> b -> List a -> b
        foldlType =
            Can.tLambda
                (Can.tLambda aVar (Can.tLambda bVar bVar))
                (Can.tLambda bVar (Can.tLambda listA bVar))

        -- reverse : List a -> List a
        reverseType =
            Can.tLambda listA listA

        listInt =
            Can.TType ModuleName.list "List" [ intType ]

        -- range : Int -> Int -> List Int
        rangeType =
            Can.tLambda intType (Can.tLambda intType listInt)

        -- length : List a -> Int
        lengthType =
            Can.tLambda listA intType

        -- concat : List (List a) -> List a
        concatType =
            Can.tLambda listListA listA

        -- drop : Int -> List a -> List a
        dropType =
            Can.tLambda intType (Can.tLambda listA listA)

        boolType =
            Can.TType ModuleName.basics "Bool" []

        -- filter : (a -> Bool) -> List a -> List a
        filterType =
            Can.tLambda (Can.tLambda aVar boolType) (Can.tLambda listA listA)

        -- any : (a -> Bool) -> List a -> Bool
        anyType =
            Can.tLambda (Can.tLambda aVar boolType) (Can.tLambda listA boolType)

        -- all : (a -> Bool) -> List a -> Bool
        allType =
            Can.tLambda (Can.tLambda aVar boolType) (Can.tLambda listA boolType)
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
