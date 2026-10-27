module Compiler.Elm.EcoEnvironment exposing
    ( isEnvironmentFlags
    , systemHome, environmentDecoderName
    )

{-| Recognises a program whose flags are the `Environment` of eco/system's
`System` module, so that its flags decoder can be built without JSON.

An eco/system program is a plain `Platform.Program System.Environment model msg`.
`Environment` holds streams, so it cannot be decoded from JSON like ordinary
flags. Instead the flags decoder of such a program is `System.environmentDecoder`,
a value eco/system does not expose, which does not decode the host's JSON but builds the
environment through a kernel call. `isEnvironmentFlags` is the test, and
`systemHome` and `environmentDecoderName` name the decoder to use in its place.

The test works on the canonical type before deep dealiasing, because it finds
`System.Environment` by the alias's own name: once aliases are expanded the
flags are only a record, indistinguishable from any other.

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


{-| Returns `True` when `tipe`, the annotation of `main` before deep
dealiasing, is a `Platform.Program` whose flags are `System.Environment`.

Aliases wrapping the whole `Program` type are looked through, and so are
aliases standing for the flags, as long as one of them expands to
`System.Environment`.

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


{-| Returns `True` when `tipe` is the alias `System.Environment`, or an alias
whose expansion, followed through further aliases, reaches it.
-}
isEnvironment : Can.Type Name -> Bool
isEnvironment tipe =
    case tipe of
        Can.TAlias home name args aliasType ->
            (home == systemHome && name == "Environment")
                || isEnvironment (Type.dealias args aliasType)

        _ ->
            False
