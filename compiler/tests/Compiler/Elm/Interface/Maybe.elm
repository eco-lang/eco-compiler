module Compiler.Elm.Interface.Maybe exposing (maybeInterface)

{-| Interface for elm/core Maybe module used in tests.
-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.Package as Pkg
import Data.Map as Dict exposing (Dict)



-- ============================================================================
-- MAYBE INTERFACE
-- ============================================================================


{-| The Maybe module interface containing Maybe type with Just and Nothing.
-}
maybeInterface : I.Interface
maybeInterface =
    I.Interface
        { home = Pkg.core
        , values = Dict.empty
        , unions = maybeUnion
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| Maybe type with Nothing and Just constructors.

    type Maybe a
        = Nothing
        | Just a

-}
maybeUnion : Dict String Name I.Union
maybeUnion =
    let
        aVar =
            Can.TVar "a"

        nothingC =
            Can.Ctor { name = "Nothing", index = Index.first, numArgs = 0, args = [] }

        justC =
            Can.Ctor { name = "Just", index = Index.second, numArgs = 1, args = [ aVar ] }

        union =
            Can.Union
                { vars = [ "a" ]
                , alts = [ nothingC, justC ]
                , numAlts = 2
                , opts = Can.Normal
                }
    in
    Dict.singleton identity "Maybe" (I.OpenUnion union)
