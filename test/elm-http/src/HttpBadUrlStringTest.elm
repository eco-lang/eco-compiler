module HttpBadUrlStringTest exposing (main)

{-| HTTP-06 (plans/kernel-lib-bug-fixes.md): the `Http.BadUrl` payload is the
request's URL, as elm/http's `__Http_BadUrl_(request.url)` gives it.

HttpBadUrlTest drops the payload, so it passes with an empty string. This test
prints it, for two URLs that both are bad URLs in a browser and under the Node
XHR shim: a malformed one ("not a url") and one with an unknown scheme. The
second request is sent only after the first result is back, so the output order
is fixed.

Native used to give `BadUrl ""` for the malformed URL (HttpService did not
fill in the URL for CURLE_URL_MALFORMAT) and `NetworkError` for the unknown
scheme (CURLE_UNSUPPORTED_PROTOCOL was not mapped to BadUrl).

-}

-- CHECK: first: "BadUrl not a url"
-- CHECK: second: "BadUrl foo://example.invalid/x"

import Http
import Platform


type Msg
    = First (Result Http.Error String)
    | Second (Result Http.Error String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), get "not a url" First )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


get : String -> (Result Http.Error String -> Msg) -> Cmd Msg
get url toMsg =
    Http.get
        { url = url
        , expect = Http.expectString toMsg
        }


label : Result Http.Error String -> String
label result =
    case result of
        Ok _ ->
            "Ok"

        Err (Http.BadUrl u) ->
            "BadUrl " ++ u

        Err Http.Timeout ->
            "Timeout"

        Err Http.NetworkError ->
            "NetworkError"

        Err (Http.BadStatus code) ->
            "BadStatus " ++ String.fromInt code

        Err (Http.BadBody _) ->
            "BadBody"


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        First result ->
            let
                _ =
                    Debug.log "first" (label result)
            in
            ( model, get "foo://example.invalid/x" Second )

        Second result ->
            let
                _ =
                    Debug.log "second" (label result)
            in
            ( model, Cmd.none )
