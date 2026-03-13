module Eco.Http exposing (fetch, getArchive)

{-| HTTP operations: fetch URLs and download archives.

All operations are atomic IO primitives backed by kernel implementations.


# Operations

@docs fetch, getArchive

-}

import Eco.Kernel.Http
import Task exposing (Task)


{-| Fetch a URL with the given HTTP method and headers.
Returns the response body on success, or an error record on failure.
-}
fetch :
    String
    -> String
    -> List ( String, String )
    -> Task Never (Result { statusCode : Int, statusText : String, url : String } String)
fetch method url headers =
    Eco.Kernel.Http.fetch method url headers
        |> Task.map
            (Result.mapError
                (\( statusCode, statusText ) ->
                    { statusCode = statusCode, statusText = statusText, url = url }
                )
            )


{-| Download and extract a ZIP archive from a URL.
Returns a record with sha and archive entries on success, or an error message on failure.
-}
getArchive :
    String
    -> Task Never (Result String { sha : String, archive : List { relativePath : String, data : String } })
getArchive url =
    Eco.Kernel.Http.getArchive url
        |> Task.map
            (Result.map
                (\( sha, entries ) ->
                    { sha = sha
                    , archive = List.map (\( relativePath, data ) -> { relativePath = relativePath, data = data }) entries
                    }
                )
            )
