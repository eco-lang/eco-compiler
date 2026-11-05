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

@docs HttpError
@docs decode
@docs toString

-}


{-| Why an HTTP request failed. Both kinds carry the URL of the request.

`Network` is a failure in which no HTTP response arrived. Its `detail` is the
transport's own description of what went wrong.

`BadStatus` is a response that arrived and was reported as a failure, with its
status code and status text.

-}
type HttpError
    = Network { url : String, detail : String }
    | BadStatus { url : String, statusCode : Int, statusText : String }


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
its own text: the detail or the status text.
-}
toString : HttpError -> String
toString err =
    case err of
        Network r ->
            "network error for " ++ r.url ++ ": " ++ r.detail

        BadStatus r ->
            "bad status " ++ String.fromInt r.statusCode ++ " for " ++ r.url ++ " (" ++ r.statusText ++ ")"
