module Eco.Http exposing (fetch, getArchive)

{-| HTTP operations via eco-io.

@docs fetch, getArchive

-}

import Eco.XHR
import Json.Decode as Decode
import Json.Encode as Encode
import Task exposing (Task)


{-| Perform an HTTP request server-side. Returns Ok body on 2xx,
Err { statusCode, statusText, url } on non-2xx.
-}
fetch : String -> String -> List ( String, String ) -> Task Never (Result { statusCode : Int, statusText : String, url : String } String)
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
                (Decode.map3 (\sc st u -> { statusCode = sc, statusText = st, url = u })
                    (Decode.field "statusCode" Decode.int)
                    (Decode.field "statusText" (Decode.oneOf [ Decode.string, Decode.succeed "" ]))
                    (Decode.field "url" Decode.string)
                )
            ]
        )


{-| Download a ZIP archive from a URL (follows redirects), compute its SHA1,
and extract all entries. Returns Ok (sha, archive) or Err errorMessage.
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
