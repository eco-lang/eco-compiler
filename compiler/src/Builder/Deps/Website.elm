module Builder.Deps.Website exposing (route, metadata)

{-| Every request the compiler makes to the package server starts from a URL
built here, so this module is the one place that decides which server that is.

The server's address, called the domain here, is the value of the
`GUIDA_REGISTRY` environment variable when it is set, and
`https://package.elm-lang.org` otherwise. The variable is read again each time a
URL is built. Its value is used as a prefix exactly as given, with nothing
added or removed, so a value ending in `/` produces a doubled slash.

`route` builds a URL for an endpoint of the server, and `metadata` one for a
file the server keeps about one version of one package.


# URL Construction

@docs route, metadata

-}

import Builder.Http as Http
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Task exposing (Task)
import Utils.Main as Utils


{-| A task giving the package server's domain: the `GUIDA_REGISTRY` environment
variable when it is set, and `https://package.elm-lang.org` otherwise.
-}
domain : Task Never String
domain =
    Utils.envLookupEnv "GUIDA_REGISTRY"
        |> Task.map (Maybe.withDefault "https://package.elm-lang.org")


{-| Returns the URL of `path` on the package server, with `params` appended as
a percent-encoded query string when there are any.

`path` is appended to the domain as given, so it should begin with `/`.

-}
route : String -> List ( String, String ) -> Task Never String
route path params =
    domain
        |> Task.map (\d -> Http.toUrl (d ++ path) params)


{-| Returns the URL of the file named `file` that the package server keeps for
version `version` of package `name`, of the form
`<domain>/packages/<author>/<project>/<version>/<file>`.
-}
metadata : Pkg.Name -> V.Version -> String -> Task Never String
metadata name version file =
    domain
        |> Task.map (\d -> d ++ "/packages/" ++ Pkg.toUrl name ++ "/" ++ V.toChars version ++ "/" ++ file)
