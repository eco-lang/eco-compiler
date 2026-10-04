module Compiler.Elm.Interface.Maybe exposing (maybeInterface)

{-| A hand-built interface for elm/core's `Maybe` module, so that a test program
can use `Maybe`, `Just` and `Nothing` without elm/core being compiled.

An interface is what canonicalization and type checking know about a module
that is imported: its values, union types, aliases and operators, as
`Compiler.Elm.Interface` describes. This one declares the union `Maybe a`,
exported open so that its constructors are visible, and nothing else.

It differs from the real module in two ways a test can notice. It has no
values, so `Maybe.withDefault`, `Maybe.map` and the module's other functions
are absent. And it numbers the constructors `Nothing` 0 and `Just` 1, whereas
elm/core declares `Just` first and the canonicalizer numbers constructors in
declaration order, so a compiled elm/core `Maybe` has them the other way round.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)



-- ============================================================================
-- MAYBE INTERFACE
-- ============================================================================


{-| The mock interface of elm/core's `Maybe` module, holding the `Maybe` union
and no values, aliases or operators.
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


{-| The unions of the mock `Maybe` module: only `Maybe` itself, exported open.
It is the union a canonicalizer would build from this declaration, with
`Nothing` at index 0 and `Just` at index 1.

    type Maybe a
        = Nothing
        | Just a

-}
maybeUnion : Dict Name I.Union
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
    Dict.singleton "Maybe" (I.OpenUnion union)
