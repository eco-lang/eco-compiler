module Eco.Http.Error exposing
    ( HttpError(..)
    , decode
    , toString
    )

{-| Structured HTTP error type for Eco.Http.

The kernel reports HTTP failures as the existing Result-in-success carrying a
`( statusCode, statusText )` tuple (statusCode 0 signals a transport-level
failure with no HTTP response). `decode` refines that into the typed `HttpError`.
The split is network vs. status: the kernel reports nothing finer.

@docs HttpError
@docs decode
@docs toString

-}


{-| A structured HTTP error.
-}
type HttpError
    = Network { url : String, detail : String }
    | BadStatus { url : String, statusCode : Int, statusText : String }


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
        Network r ->
            "network error for " ++ r.url ++ ": " ++ r.detail

        BadStatus r ->
            "bad status " ++ String.fromInt r.statusCode ++ " for " ++ r.url ++ " (" ++ r.statusText ++ ")"
