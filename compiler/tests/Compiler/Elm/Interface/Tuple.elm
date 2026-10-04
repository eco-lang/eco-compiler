module Compiler.Elm.Interface.Tuple exposing (tupleInterface)

{-| A hand-built stand-in for the interface of elm/core's `Tuple` module, so
that test programs calling tuple functions can be canonicalized and type
checked without elm/core's `Tuple` module being compiled.

An interface is what a compiled module offers to the modules that import it, as
`Compiler.Elm.Interface` describes. This one is homed in elm/core and declares
six values, `pair`, `first`, `second`, `mapFirst`, `mapSecond` and `mapBoth`,
all on two-element tuples. It declares no union types, aliases or operators.

Each value's annotation quantifies over every type variable that occurs in its
type, which is how a polymorphic function's annotation is written in the
canonical AST. None of the variables used here is super-constrained, that is,
none starts with `number`, `comparable`, `appendable` or `compappend`. The
arrows are built with `Can.tLambda`, so each is built with a `NoArrow` slot.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)



-- ============================================================================
-- TUPLE INTERFACE
-- ============================================================================


{-| The interface of the `Tuple` stand-in: the six tuple functions, homed in
elm/core, with no unions, aliases or binary operators.
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


{-| Returns the names of the type variables that occur in `tipe`, including
the extension variable of an extensible record.

For an alias it collects from both the alias's arguments and its body, so the
body of a `Holey` alias contributes the alias's own parameter names as well.

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


{-| Builds the annotation of a value of type `tipe`, quantified over every type
variable that `collectFreeVars` finds in it.
-}
mkAnnotation : Can.Type Name -> Can.Annotation Name
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe



-- ============================================================================
-- TYPES
-- ============================================================================


{-| The type variable `a`, the type of a tuple's first element before any
mapping.
-}
aVar : Can.Type Name
aVar =
    Can.TVar "a"


{-| The type variable `b`, the type of a tuple's second element before any
mapping.
-}
bVar : Can.Type Name
bVar =
    Can.TVar "b"


{-| The type variable `x`, the type the first element is mapped to.
-}
xVar : Can.Type Name
xVar =
    Can.TVar "x"


{-| The type variable `y`, the type the second element is mapped to.
-}
yVar : Can.Type Name
yVar =
    Can.TVar "y"


{-| The tuple type `( a, b )`: the result of `pair`, and the tuple taken by
the other five functions.
-}
tupleAB : Can.Type Name
tupleAB =
    Can.TTuple aVar bVar []


{-| The tuple type `( x, b )`, the result of `mapFirst`.
-}
tupleXB : Can.Type Name
tupleXB =
    Can.TTuple xVar bVar []


{-| The tuple type `( a, y )`, the result of `mapSecond`.
-}
tupleAY : Can.Type Name
tupleAY =
    Can.TTuple aVar yVar []


{-| The tuple type `( x, y )`, the result of `mapBoth`.
-}
tupleXY : Can.Type Name
tupleXY =
    Can.TTuple xVar yVar []



-- ============================================================================
-- VALUES (Functions)
-- ============================================================================


{-| The annotations of the six tuple functions, keyed by function name. The
comment above each entry gives its type in Elm syntax.
-}
tupleValues : Dict Name (Can.Annotation Name)
tupleValues =
    Dict.fromList
        [ -- pair : a -> b -> ( a, b )
          ( "pair"
          , mkAnnotation (Can.tLambda aVar (Can.tLambda bVar tupleAB))
          )

        -- first : ( a, b ) -> a
        , ( "first"
          , mkAnnotation (Can.tLambda tupleAB aVar)
          )

        -- second : ( a, b ) -> b
        , ( "second"
          , mkAnnotation (Can.tLambda tupleAB bVar)
          )

        -- mapFirst : (a -> x) -> ( a, b ) -> ( x, b )
        , ( "mapFirst"
          , mkAnnotation
                (Can.tLambda
                    (Can.tLambda aVar xVar)
                    (Can.tLambda tupleAB tupleXB)
                )
          )

        -- mapSecond : (b -> y) -> ( a, b ) -> ( a, y )
        , ( "mapSecond"
          , mkAnnotation
                (Can.tLambda
                    (Can.tLambda bVar yVar)
                    (Can.tLambda tupleAB tupleAY)
                )
          )

        -- mapBoth : (a -> x) -> (b -> y) -> ( a, b ) -> ( x, y )
        , ( "mapBoth"
          , mkAnnotation
                (Can.tLambda
                    (Can.tLambda aVar xVar)
                    (Can.tLambda
                        (Can.tLambda bVar yVar)
                        (Can.tLambda tupleAB tupleXY)
                    )
                )
          )
        ]
