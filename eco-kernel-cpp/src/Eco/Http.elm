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


{-| Download and extract a ZIP archive from a URL.
Returns the SHA1 hash and extracted file entries on success, or an error message on failure.
-}
getArchive :
    String
    -> Task Never (Result String { sha : String, archive : List { relativePath : String, data : String } })
getArchive url =
    Eco.Kernel.Http.getArchive url
