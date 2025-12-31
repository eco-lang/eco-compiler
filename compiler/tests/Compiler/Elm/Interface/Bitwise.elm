module Compiler.Elm.Interface.Bitwise exposing (bitwiseInterface)

{-| Interface for elm/core Bitwise module functions used in tests.
-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Data.Map as Dict exposing (Dict)



-- ============================================================================
-- BITWISE INTERFACE
-- ============================================================================


{-| The Bitwise module interface containing bitwise operation functions.
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


{-| Helper to create a value annotation with no free vars.
-}
mkAnnotation : Can.Type -> Can.Annotation
mkAnnotation tipe =
    Can.Forall Dict.empty tipe



-- ============================================================================
-- TYPES
-- ============================================================================


intType : Can.Type
intType =
    Can.TType ModuleName.basics "Int" []


{-| Int -> Int -> Int
-}
intBinopType : Can.Type
intBinopType =
    Can.TLambda intType (Can.TLambda intType intType)


{-| Int -> Int
-}
intUnaryType : Can.Type
intUnaryType =
    Can.TLambda intType intType



-- ============================================================================
-- VALUES (Functions)
-- ============================================================================


{-| Bitwise function values.
-}
bitwiseValues : Dict String Name Can.Annotation
bitwiseValues =
    Dict.fromList identity
        [ -- and : Int -> Int -> Int
          ( "and", mkAnnotation intBinopType )

        -- or : Int -> Int -> Int
        , ( "or", mkAnnotation intBinopType )

        -- xor : Int -> Int -> Int
        , ( "xor", mkAnnotation intBinopType )

        -- complement : Int -> Int
        , ( "complement", mkAnnotation intUnaryType )

        -- shiftLeftBy : Int -> Int -> Int
        , ( "shiftLeftBy", mkAnnotation intBinopType )

        -- shiftRightBy : Int -> Int -> Int
        , ( "shiftRightBy", mkAnnotation intBinopType )

        -- shiftRightZfBy : Int -> Int -> Int
        , ( "shiftRightZfBy", mkAnnotation intBinopType )
        ]
