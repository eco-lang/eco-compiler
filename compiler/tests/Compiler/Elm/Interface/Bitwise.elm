module Compiler.Elm.Interface.Bitwise exposing (bitwiseInterface)

{-| A hand-built interface for elm/core's `Bitwise` module, so that test
programs can import `Bitwise` without elm/core being compiled.

It declares seven functions on `Int`: `and`, `or`, `xor`, `shiftLeftBy`,
`shiftRightBy` and `shiftRightZfBy` take two, and `complement` takes one. It
declares no types, aliases or operators.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)



-- ============================================================================
-- BITWISE INTERFACE
-- ============================================================================


{-| The mock `Bitwise` interface, homed in the elm/core package, holding the
functions of `bitwiseValues` and nothing else.
-}
bitwiseInterface : I.Interface
bitwiseInterface =
    I.Interface
        { home = Pkg.core
        , values = bitwiseValues
        , unions = Dict.empty
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| Returns `tipe` as an annotation that quantifies no type variables, which is
correct here because no type in this module mentions one.
-}
mkAnnotation : Can.Type Name -> Can.Annotation Name
mkAnnotation tipe =
    Can.Forall Dict.empty tipe



-- ============================================================================
-- TYPES
-- ============================================================================


{-| The type `Int`, homed in elm/core's `Basics` module.
-}
intType : Can.Type Name
intType =
    Can.TType ModuleName.basics "Int" []


{-| The type `Int -> Int -> Int`, shared by every function here except
`complement`.
-}
intBinopType : Can.Type Name
intBinopType =
    Can.tLambda intType (Can.tLambda intType intType)


{-| The type `Int -> Int`, the type of `complement`.
-}
intUnaryType : Can.Type Name
intUnaryType =
    Can.tLambda intType intType



-- ============================================================================
-- VALUES (Functions)
-- ============================================================================


{-| The annotations of the seven functions, keyed by name.
-}
bitwiseValues : Dict Name (Can.Annotation Name)
bitwiseValues =
    Dict.fromList
        [ ( "and", mkAnnotation intBinopType )
        , ( "or", mkAnnotation intBinopType )
        , ( "xor", mkAnnotation intBinopType )
        , ( "complement", mkAnnotation intUnaryType )
        , ( "shiftLeftBy", mkAnnotation intBinopType )
        , ( "shiftRightBy", mkAnnotation intBinopType )
        , ( "shiftRightZfBy", mkAnnotation intBinopType )
        ]
