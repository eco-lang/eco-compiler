module HttpResponseHeadersDictTest exposing (main)

{-| Updates `Metadata.headers`, the `Dict String String` the Http kernel builds, with `Dict.insert`
and `Dict.remove`, and compares each result with the same updates on a `Dict` rebuilt by Elm code
from the same pairs. The kernel used to build a right-leaning chain with `()` as every node's
colour, which `insert` and `remove` pattern-match on (plans/kg-reported-bugs.md step 1, kernel
audit). The headers themselves depend on the server, so only agreement is printed.
-}

-- CHECK: same after inserts: True
-- CHECK: same after removes: True
-- CHECK: same after removing every key: True
-- CHECK: empty after removing every key: True
-- CHECK: same after mixed updates: True

import Dict exposing (Dict)
import Http
import Platform
import Task
import TestServerConfig


type Msg
    = Got (Result String (Dict String String))
    | GotServer TestServerConfig.Server


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


get : TestServerConfig.Server -> Cmd Msg
get server =
    Http.request
        { method = "GET"
        , headers = []
        , url = server.baseUrl ++ "/echo-headers"
        , body = Http.emptyBody
        , expect = Http.expectStringResponse Got toResult
        , timeout = Nothing
        , tracker = Nothing
        }


toResult : Http.Response String -> Result String (Dict String String)
toResult response =
    case response of
        Http.GoodStatus_ metadata _ ->
            Ok metadata.headers

        _ ->
            Err "bad"


inserts : Dict String String -> Dict String String
inserts d =
    List.foldl (\k acc -> Dict.insert k "v" acc) d [ "a-first", "x-mid", "zz-last", "content-type", "m", "b", "y" ]


removeKeys : List String -> Dict String String -> Dict String String
removeKeys keys d =
    List.foldl Dict.remove d keys


mixed : Dict String String -> Dict String String
mixed d =
    d
        |> Dict.insert "x-a" "1"
        |> Dict.remove "content-type"
        |> Dict.insert "a" "2"
        |> Dict.remove "x-a"
        |> Dict.remove "x-test-server"
        |> Dict.insert "zzz" "3"


report : Dict String String -> List ( String, Bool )
report kernel =
    let
        rebuilt =
            Dict.fromList (Dict.toList kernel)

        same f =
            Dict.toList (f kernel) == Dict.toList (f rebuilt)

        keys =
            Dict.keys kernel
    in
    [ ( "same after inserts", same inserts )
    , ( "same after removes", same (removeKeys (List.take 3 keys ++ [ "missing" ])) )
    , ( "same after removing every key", same (removeKeys (List.reverse keys)) )
    , ( "empty after removing every key", Dict.isEmpty (removeKeys keys kernel) )
    , ( "same after mixed updates", same mixed )
    ]


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, get server )

        Got (Ok headers) ->
            let
                _ =
                    List.foldl (\( label, ok ) () -> always () (Debug.log label ok)) () (report headers)
            in
            ( model, Cmd.none )

        Got (Err e) ->
            let
                _ =
                    Debug.log "error" e
            in
            ( model, Cmd.none )
