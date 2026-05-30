module Eco.Http.Error exposing
    ( HttpError(..)
    , decode
    , toString
    )

{-| Structured HTTP error type for Eco.Http.

The kernel reports HTTP failures as the existing Result-in-success carrying a
`( statusCode, statusText )` tuple (statusCode 0 signals a transport-level
failure with no HTTP response). `decode` refines that into the typed `HttpError`.
This is the v1 "minimal split": network vs. status. Richer kinds (timeout, TLS,
body-decode, bad-url) are modelled in the ADT and produced by higher layers.

@docs HttpError
@docs decode
@docs toString

-}


{-| A structured HTTP error.
-}
type HttpError
    = BadUrl String String
    | Network { url : String, detail : String }
    | Timeout { url : String, detail : String }
    | Tls { url : String, detail : String }
    | BadStatus { url : String, statusCode : Int, statusText : String }
    | BodyDecode { url : String, detail : String }
    | OtherHttp { url : String, message : String }


{-| Refine the kernel's `( statusCode, statusText )` failure tuple into an
`HttpError`, given the request URL.
-}
decode : String -> ( Int, String ) -> HttpError
decode url ( statusCode, statusText ) =
    if statusCode == 0 then
        Network { url = url, detail = statusText }

    else
        BadStatus { url = url, statusCode = statusCode, statusText = statusText }


{-| A short human-readable description, for embedding in larger messages.
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
