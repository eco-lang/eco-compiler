module Compiler.Elm.EcoEnvironment exposing
    ( isEnvironmentFlags
    , systemHome, environmentDecoderName
    )

{-| Recognises programs whose flags are `eco/system`'s `System.Environment`
(plans/eco-system-api-refactor.md D13, §10.1).

An eco/system program is a plain `Platform.Program System.Environment model msg`.
`Environment` holds streams, so it cannot be decoded from JSON like ordinary
flags. Instead, the flags decoder of such a program is the unexposed
`System.environmentDecoder` of eco/system, which ignores the host JSON and
builds the environment through a kernel call. The three places that build a
program's flags decoder (the typed and erased local optimizers, and the
monomorphizer's entry preparation) ask `isEnvironmentFlags` first, and skip the
JSON payload check for these programs.

@docs isEnvironmentFlags
@docs systemHome, environmentDecoderName

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg


{-| The canonical name of eco/system's `System` module.
-}
systemHome : ModuleName.Canonical
systemHome =
    ModuleName.Canonical Pkg.ecoSystem "System"


{-| The name of the unexposed decoder in `System` that builds the
`Environment`.
-}
environmentDecoderName : Name
environmentDecoderName =
    "environmentDecoder"


{-| `True` if `tipe` (the annotation of `main`, before deep dealiasing) is a
`Platform.Program` whose flags are `System.Environment`, directly or through
type aliases. Aliases around the whole `Program` type are looked through too.
-}
isEnvironmentFlags : Can.Type Name -> Bool
isEnvironmentFlags tipe =
    case tipe of
        Can.TAlias _ _ args aliasType ->
            isEnvironmentFlags (Type.dealias args aliasType)

        Can.TType home name [ flags, _, _ ] ->
            home == ModuleName.platform && name == Name.program && isEnvironment flags

        _ ->
            False


isEnvironment : Can.Type Name -> Bool
isEnvironment tipe =
    case tipe of
        Can.TAlias home name args aliasType ->
            (home == systemHome && name == "Environment")
                || isEnvironment (Type.dealias args aliasType)

        _ ->
            False
