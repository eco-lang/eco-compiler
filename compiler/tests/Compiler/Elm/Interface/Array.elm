module Compiler.Elm.Interface.Array exposing (arrayInterface)

{-| Interface for elm/core Array module types and functions used in tests.
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
-- ARRAY INTERFACE
-- ============================================================================


{-| The Array module interface containing Array types and functions.
-}
arrayInterface : I.Interface
arrayInterface =
    I.Interface
        { home = Pkg.core
        , values = arrayValues
        , unions = arrayUnions
        , aliases = arrayAliases
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


{-| Type variables used throughout.
-}
aVar : Can.Type
aVar =
    Can.TVar "a"


bVar : Can.Type
bVar =
    Can.TVar "b"


intType : Can.Type
intType =
    Can.TType ModuleName.basics "Int" []


boolType : Can.Type
boolType =
    Can.TType ModuleName.basics "Bool" []


{-| Array a
-}
arrayA : Can.Type
arrayA =
    Can.TType ModuleName.array "Array" [ aVar ]


{-| JsArray a
-}
jsArrayA : Can.Type
jsArrayA =
    Can.TType jsArrayModuleName "JsArray" [ aVar ]


{-| Node a
-}
nodeA : Can.Type
nodeA =
    Can.TType ModuleName.array "Node" [ aVar ]


{-| Tree a = JsArray (Node a)
-}
treeA : Can.Type
treeA =
    Can.TType jsArrayModuleName "JsArray" [ nodeA ]


{-| Builder a record type
-}
builderA : Can.Type
builderA =
    Can.TRecord
        (Dict.fromList identity
            [ ( "tail", Can.FieldType 0 jsArrayA )
            , ( "nodeList", Can.FieldType 0 (Can.TType ModuleName.list "List" [ nodeA ]) )
            , ( "nodeListSize", Can.FieldType 0 intType )
            ]
        )
        Nothing


listA : Can.Type
listA =
    Can.TType ModuleName.list "List" [ aVar ]


listNodeA : Can.Type
listNodeA =
    Can.TType ModuleName.list "List" [ nodeA ]



-- ============================================================================
-- UNIONS (Type definitions)
-- ============================================================================


{-| Array union type definitions.

type Array a = Array_elm_builtin Int Int (Tree a) (JsArray a)
type Node a = SubTree (Tree a) | Leaf (JsArray a)

-}
arrayUnions : Dict String Name I.Union
arrayUnions =
    let
        arrayElmBuiltinCtor =
            Can.Ctor
                { name = "Array_elm_builtin"
                , index = Index.first
                , numArgs = 4
                , args = [ intType, intType, treeA, jsArrayA ]
                }

        arrayUnion =
            Can.Union
                { vars = [ "a" ]
                , alts = [ arrayElmBuiltinCtor ]
                , numAlts = 1
                , opts = Can.Normal
                }

        subTreeCtor =
            Can.Ctor
                { name = "SubTree"
                , index = Index.first
                , numArgs = 1
                , args = [ treeA ]
                }

        leafCtor =
            Can.Ctor
                { name = "Leaf"
                , index = Index.second
                , numArgs = 1
                , args = [ jsArrayA ]
                }

        nodeUnion =
            Can.Union
                { vars = [ "a" ]
                , alts = [ subTreeCtor, leafCtor ]
                , numAlts = 2
                , opts = Can.Normal
                }
    in
    Dict.fromList identity
        [ ( "Array", I.OpenUnion arrayUnion )
        , ( "Node", I.OpenUnion nodeUnion )
        ]



-- ============================================================================
-- ALIASES
-- ============================================================================


{-| Array type aliases.
-}
arrayAliases : Dict String Name I.Alias
arrayAliases =
    Dict.fromList identity
        [ ( "Tree"
          , I.PublicAlias
                (Can.Alias [ "a" ] (Can.TType jsArrayModuleName "JsArray" [ nodeA ]))
          )
        , ( "Builder"
          , I.PublicAlias
                (Can.Alias [ "a" ] builderA)
          )
        ]



-- ============================================================================
-- VALUES (Functions)
-- ============================================================================


{-| Array function values.
-}
arrayValues : Dict String Name Can.Annotation
arrayValues =
    Dict.fromList identity
        [ -- initialize : Int -> (Int -> a) -> Array a
          ( "initialize"
          , mkAnnotation
                (Can.TLambda intType
                    (Can.TLambda (Can.TLambda intType aVar) arrayA)
                )
          )

        -- empty : Array a
        , ( "empty", mkAnnotation arrayA )

        -- repeat : Int -> a -> Array a
        , ( "repeat"
          , mkAnnotation
                (Can.TLambda intType (Can.TLambda aVar arrayA))
          )

        -- push : a -> Array a -> Array a
        , ( "push"
          , mkAnnotation
                (Can.TLambda aVar (Can.TLambda arrayA arrayA))
          )

        -- slice : Int -> Int -> Array a -> Array a
        , ( "slice"
          , mkAnnotation
                (Can.TLambda intType (Can.TLambda intType (Can.TLambda arrayA arrayA)))
          )

        -- append : Array a -> Array a -> Array a
        , ( "append"
          , mkAnnotation
                (Can.TLambda arrayA (Can.TLambda arrayA arrayA))
          )

        -- unsafeReplaceTail : JsArray a -> Array a -> Array a
        , ( "unsafeReplaceTail"
          , mkAnnotation
                (Can.TLambda jsArrayA (Can.TLambda arrayA arrayA))
          )

        -- translateIndex : Int -> Array a -> Int
        , ( "translateIndex"
          , mkAnnotation
                (Can.TLambda intType (Can.TLambda arrayA intType))
          )

        -- sliceRight : Int -> Array a -> Array a
        , ( "sliceRight"
          , mkAnnotation
                (Can.TLambda intType (Can.TLambda arrayA arrayA))
          )

        -- sliceLeft : Int -> Array a -> Array a
        , ( "sliceLeft"
          , mkAnnotation
                (Can.TLambda intType (Can.TLambda arrayA arrayA))
          )

        -- builderToArray : Bool -> Builder a -> Array a
        , ( "builderToArray"
          , mkAnnotation
                (Can.TLambda boolType (Can.TLambda builderA arrayA))
          )

        -- builderFromArray : Array a -> Builder a
        , ( "builderFromArray"
          , mkAnnotation
                (Can.TLambda arrayA builderA)
          )

        -- appendHelpTree : JsArray a -> Array a -> Array a
        , ( "appendHelpTree"
          , mkAnnotation
                (Can.TLambda jsArrayA (Can.TLambda arrayA arrayA))
          )

        -- appendHelpBuilder : JsArray a -> Builder a -> Builder a
        , ( "appendHelpBuilder"
          , mkAnnotation
                (Can.TLambda jsArrayA (Can.TLambda builderA builderA))
          )

        -- tailIndex : Int -> Int
        , ( "tailIndex"
          , mkAnnotation
                (Can.TLambda intType intType)
          )

        -- shiftStep : Int
        , ( "shiftStep", mkAnnotation intType )

        -- branchFactor : Int
        , ( "branchFactor", mkAnnotation intType )

        -- fromListHelp : List a -> List (Node a) -> Int -> Array a
        , ( "fromListHelp"
          , mkAnnotation
                (Can.TLambda listA
                    (Can.TLambda listNodeA
                        (Can.TLambda intType arrayA)
                    )
                )
          )
        ]
