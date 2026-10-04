module Eco.Http exposing (fetch, getArchive)

{-| Gives the stock-Elm build of the compiler its HTTP client. The requests are
made by the eco-io server, not by the Elm program.

This module is the stock-Elm twin of the kernel module `Eco.Http`, with the same
two functions and the same signatures. Each call is one eco-io request, as
`Eco.XHR` describes: `fetch` asks for an HTTP request to be made and returns the
body of the response, and `getArchive` asks for a ZIP archive to be downloaded
and returns its entries.

A failure that eco-io reports in its reply is given as an `Err` in the result.
Neither task can fail as a task: a failure of the eco-io request itself crashes
the program through `Eco.XHR.orCrash`, and so does a 2xx reply this module
cannot read, as `Eco.XHR.jsonTask` describes. This module assumes that eco-io
treats some failed HTTP requests as a failure of its own, such as a URL it
cannot parse or a compressed body it cannot decompress, so these crash too.

@docs fetch, getArchive

-}

import Eco.Http.Error as HttpErr exposing (HttpError)
import Eco.XHR
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| Asks eco-io to send an HTTP request with `method` to `url`, carrying
`headers` as name and value pairs, and returns the body of the response as text.

A reply that carries a status code instead of a body gives an `Err`, which
`Eco.Http.Error.decode` builds from `url`, the status code and the status text.
A status text that is present but not a string is read as `""`; a reply with no
`statusText` field cannot be read and crashes the program. This module
assumes that eco-io sends a body only for a 2xx response, and otherwise the
status, with code 0 when no response arrived.

-}
fetch : String -> String -> List ( String, String ) -> Task Never (Result HttpError String)
fetch method url headers =
    Eco.XHR.jsonTask "Http.fetch"
        (Encode.object
            [ ( "method", Encode.string method )
            , ( "url", Encode.string url )
            , ( "headers"
              , Encode.list
                    (\( k, v ) ->
                        Encode.list Encode.string [ k, v ]
                    )
                    headers
              )
            ]
        )
        (Decode.oneOf
            [ Decode.map Ok (Decode.field "body" Decode.string)
            , Decode.map Err
                (Decode.map2 (\sc st -> ( sc, st ))
                    (Decode.field "statusCode" Decode.int)
                    (Decode.field "statusText" (Decode.oneOf [ Decode.string, Decode.succeed "" ]))
                )
            ]
        )
        |> Eco.XHR.orCrash
        |> Task.map (Result.mapError (HttpErr.decode url))


{-| Asks eco-io to download the ZIP archive at `url`, and returns its hash and
its entries, each with its path inside the archive and its contents as text.

A reply that carries an `error` message instead gives `Err` with that message.
This module assumes that eco-io follows redirects, and that `sha` is the SHA-1
of the downloaded bytes in hexadecimal.

-}
getArchive : String -> Task Never (Result String { sha : String, archive : List { relativePath : String, data : String } })
getArchive url =
    Eco.XHR.jsonTask "Http.getArchive"
        (Encode.object
            [ ( "url", Encode.string url )
            ]
        )
        (Decode.oneOf
            [ Decode.map Ok
                (Decode.map2 (\sha archive -> { sha = sha, archive = archive })
                    (Decode.field "sha" Decode.string)
                    (Decode.field "archive"
                        (Decode.list
                            (Decode.map2 (\rp d -> { relativePath = rp, data = d })
                                (Decode.field "eRelativePath" Decode.string)
                                (Decode.field "eData" Decode.string)
                            )
                        )
                    )
                )
            , Decode.map Err (Decode.field "error" Decode.string)
            ]
        )
        |> Eco.XHR.orCrash
