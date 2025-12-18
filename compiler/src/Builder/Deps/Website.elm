module Builder.Deps.Website exposing (route, metadata)

{-| Constructs URLs for the Elm package registry website.

This module provides utilities for building URLs to access package metadata, documentation,
and registry endpoints. It respects the GUIDA\_REGISTRY environment variable to support
custom package registries, defaulting to package.elm-lang.org.


# URL Construction

@docs route, metadata

-}

import Builder.Http as Http
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Task exposing (Task)
import Utils.Main as Utils


domain : Task Never String
domain =
    Utils.envLookupEnv "GUIDA_REGISTRY"
        |> Task.map (Maybe.withDefault "https://package.elm-lang.org")


{-| Construct a URL for a registry API endpoint with optional query parameters.
Respects the GUIDA\_REGISTRY environment variable for custom registries.
-}
route : String -> List ( String, String ) -> Task Never String
route path params =
    domain
        |> Task.map (\d -> Http.toUrl (d ++ path) params)


{-| Construct a URL for accessing package metadata files (like docs.json or endpoint.json).
Respects the GUIDA\_REGISTRY environment variable for custom registries.
-}
metadata : Pkg.Name -> V.Version -> String -> Task Never String
metadata name version file =
    domain
        |> Task.map (\d -> d ++ "/packages/" ++ Pkg.toUrl name ++ "/" ++ V.toChars version ++ "/" ++ file)
