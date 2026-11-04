module HttpInvalidMethodTest exposing (main)

{-| HTTPS-NEW-2, non-stream twin (plans/kernel-lib-bug-fixes.md, "Findings
beyond the triage"): a request whose method is not an HTTP token is refused
before it is sent, and fails with `Http.BadUrl` carrying the request's URL.

That is what stock elm/http gives in a browser: `xhr.open` throws a
SyntaxError for a method that is not a token, and Http.js turns that into
`BadUrl_(request.url)`. Three methods are tried, one after the other so the
output order is fixed:

  - injected: a method holding a request line and a header
    (`GET /anything HTTP/1.1\r\nX-Injected: 1\r\n\r\nGET`);
  - space: `PRO PFIND`;
  - empty: `""` (not a token either; D23 rejects it for Http.Stream too).

HttpService used to pass the method to libcurl as it was, so the injected one
went out as its own request line and header (`GoodStatus`, with the server
echoing `x-injected`), and the empty one went out as a GET. A valid custom
token such as PROPFIND is unaffected (HttpPutTest, HttpDeleteTest).

-}

-- CHECK: injected: "BadUrl (request url)"
-- CHECK: space: "BadUrl (request url)"
-- CHECK: empty: "BadUrl (request url)"

import Http
import Platform
import Task
import TestServerConfig


type Msg
    = GotServer TestServerConfig.Server
    | Got Int (Result Http.Error String)


methods : List ( String, String )
methods =
    [ ( "injected", "GET /anything HTTP/1.1\r\nX-Injected: 1\r\n\r\nGET" )
    , ( "space", "PRO PFIND" )
    , ( "empty", "" )
    ]


main : Program () (Maybe String) Msg
main =
    Platform.worker
        { init = \_ -> ( Nothing, Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


send : String -> Int -> Cmd Msg
send url i =
    case List.drop i methods of
        ( _, method ) :: _ ->
            Http.request
                { method = method
                , headers = []
                , url = url
                , body = Http.emptyBody
                , expect = Http.expectString (Got i)
                , timeout = Nothing
                , tracker = Nothing
                }

        [] ->
            Cmd.none


label : String -> Result Http.Error String -> String
label url result =
    case result of
        Ok body ->
            if String.contains "x-injected" (String.toLower body) then
                "GoodStatus x-injected"

            else
                "GoodStatus"

        Err (Http.BadUrl u) ->
            if u == url then
                "BadUrl (request url)"

            else
                "BadUrl " ++ u

        Err Http.Timeout ->
            "Timeout"

        Err Http.NetworkError ->
            "NetworkError"

        Err (Http.BadStatus code) ->
            "BadStatus " ++ String.fromInt code

        Err (Http.BadBody _) ->
            "BadBody"


update : Msg -> Maybe String -> ( Maybe String, Cmd Msg )
update msg model =
    case ( msg, model ) of
        ( GotServer server, _ ) ->
            let
                url =
                    server.baseUrl ++ "/anything"
            in
            ( Just url, send url 0 )

        ( Got i result, Just url ) ->
            let
                name =
                    List.drop i methods |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault "?"

                _ =
                    Debug.log name (label url result)
            in
            ( model, send url (i + 1) )

        ( Got _ _, Nothing ) ->
            ( model, Cmd.none )
