module UrlIssue54PercentEncodeLoneSurrogateTest exposing (main)

{-| `Url.percentEncode` throws on a lone surrogate.

<https://github.com/elm/url/issues/54>

Elm 0.19.1 (elm/url 1.0.0) calls `encodeURIComponent` unguarded, which throws `URIError: URI
malformed` for "\u{d800}" (a valid Elm String). `percentEncode : String -> String` must return a
string (`percentDecode` already catches the same exception).

-}

-- CHECK: encoded:

import Html exposing (text)
import Url


main =
    let
        _ =
            Debug.log "encoded" (String.length (Url.percentEncode "a\u{d800}b") > 0)
    in
    text "done"
