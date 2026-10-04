module Eco.Http.Error exposing
    ( HttpError(..)
    , decode
    , toString
    )

{-| Code that reports a failed HTTP request needs to know how it failed, and
this module gives that failure a type, `HttpError`, together with the step that
builds one from what the host reports.

The host's HTTP operation reports a request that did not succeed only as a pair
`( statusCode, statusText )`. This module reads a status code of 0 as meaning
that no HTTP response arrived at all, so that the text describes the transport
failure, and any other code as the status of a response that did arrive.
`decode` turns that pair into an `HttpError`, and `toString` describes one in
words.

`HttpError` names seven kinds of failure, but `decode` produces only two of them,
`Network` and `BadStatus`. Nothing in this module produces the other five.

@docs HttpError
@docs decode
@docs toString

-}


{-| Why an HTTP request failed. Every kind carries the URL of the request.

`BadUrl` carries the URL and then the reason it was rejected.

`Network` is a failure in which no HTTP response arrived. Its `detail` is the
transport's own description of what went wrong.

`BadStatus` is a response that arrived and was reported as a failure, with its
status code and status text.

`Timeout`, `Tls` and `BodyDecode` are a request that timed out, a TLS failure
and a response body that could not be decoded; `decode` never builds them.

`OtherHttp` is any other failure. Its `message` is the whole description.

-}
type HttpError
    = BadUrl String String
    | Network { url : String, detail : String }
    | Timeout { url : String, detail : String }
    | Tls { url : String, detail : String }
    | BadStatus { url : String, statusCode : Int, statusText : String }
    | BodyDecode { url : String, detail : String }
    | OtherHttp { url : String, message : String }


{-| Builds the `HttpError` for a failed request to `url` from the host's
`( statusCode, statusText )` pair. A status code of 0 gives `Network`, with
`statusText` as its detail; any other code gives `BadStatus`.
-}
decode : String -> ( Int, String ) -> HttpError
decode url ( statusCode, statusText ) =
    if statusCode == 0 then
        Network { url = url, detail = statusText }

    else
        BadStatus { url = url, statusCode = statusCode, statusText = statusText }


{-| Returns a short readable description of the error that includes its URL and
its own text: the detail, the status text or the message.
-}
toString : HttpError -> String
toString err =
    case err of
        BadUrl url detail ->
            "bad URL " ++ url ++ ": " ++ detail

        Network r ->
            "network error for " ++ r.url ++ ": " ++ r.detail

        Timeout r ->
            "timeout for " ++ r.url ++ ": " ++ r.detail

        Tls r ->
            "TLS error for " ++ r.url ++ ": " ++ r.detail

        BadStatus r ->
            "bad status " ++ String.fromInt r.statusCode ++ " for " ++ r.url ++ " (" ++ r.statusText ++ ")"

        BodyDecode r ->
            "body decode error for " ++ r.url ++ ": " ++ r.detail

        OtherHttp r ->
            r.message ++ " (" ++ r.url ++ ")"
