module Http.Response exposing
    ( Response, Status
    , addHeader, setBody, updateBody, setStatus
    , init, encode
    , err500, err500json, ok200, ok200json, notFound400json
    )

{-| DSL for building HTTP responses.


# Build a response

@docs Response, Status
@docs addHeader, setBody, updateBody, setStatus
@docs init, encode


# Helpers

@docs err500, err500json, ok200, ok200json, notFound400json

-}

import Json.Decode exposing (Value)
import Json.Encode as Encode
import Http.Body as Body exposing (Body, text)
import Http.Charset as Charset exposing (Charset)
import Http.KeyValueList as KeyValueList


{-| An HTTP response.
-}
type Response
    = Response Model


type alias Model =
    { body : Body
    , charset : Charset
    , headers : List ( String, String )
    , status : Status
    }


{-| An HTTP status code.
-}
type alias Status =
    Int



-- UPDATING


{-| Set a response header.

If you set the same response header more than once, the second value will
override the first.

-}
addHeader : ( String, String ) -> Response -> Response
addHeader ( key, value ) (Response res) =
    Response
        { res
            | headers =
                ( key |> String.toLower, value )
                    :: res.headers
        }


{-| Set the response body.
-}
setBody : Body -> Response -> Response
setBody body (Response res) =
    Response { res | body = body }


{-| Updates the response body.
-}
updateBody : (Body -> Body) -> Response -> Response
updateBody updater (Response res) =
    Response { res | body = updater res.body }


setCharset : Charset -> Response -> Response
setCharset value (Response res) =
    Response { res | charset = value }


{-| Set the response HTTP status code.
-}
setStatus : Status -> Response -> Response
setStatus value (Response res) =
    Response { res | status = value }



-- MISC


{-| A response with an empty body and invalid status.
-}
init : Response
init =
    Response
        (Model
            Body.empty
            Charset.utf8
            [ ( "cache-control", "max-age=0, private, must-revalidate" ) ]
            200
        )


{-| JSON encode an HTTP response.
-}
encode : Response -> Encode.Value
encode (Response res) =
    Encode.object
        [ ( "body", Body.encode res.body )
        , ( "headers"
          , res.headers
                ++ [ ( "content-type", contentType res ) ]
                |> KeyValueList.encode
          )
        , ( "statusCode", Encode.int res.status )
        , ( "isBase64Encoded", res.body |> Body.isBase64Encoded |> Encode.bool )
        ]


contentType : Model -> String
contentType { body, charset } =
    Body.contentType body
        ++ "; charset="
        ++ Charset.toString charset


{-| An HTTP 200 ok message as a string.
-}
ok200 : String -> Response
ok200 msg =
    init
        |> setBody (Body.text msg)


{-| An HTTP 500 error message as a string.
-}
err500 : String -> Response
err500 err =
    init
        |> setBody (Body.text err)
        |> setStatus 500


{-| An HTTP 200 ok message as a JSON.
-}
ok200json : Value -> Response
ok200json msg =
    init
        |> setBody (Body.json msg)


{-| An HTTP 500 error message as a JSON.
-}
err500json : Value -> Response
err500json err =
    init
        |> setBody (Body.json err)
        |> setStatus 500


{-| An HTTP 400 not found message as a JSON.
-}
notFound400json : Value -> Response
notFound400json err =
    init
        |> setBody (Body.json err)
        |> setStatus 400
