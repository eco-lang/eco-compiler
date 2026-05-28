module HttpBadUrlTest exposing (main)

-- CHECK: err: "BadUrl"

import Http
import Platform


type Msg
    = Got (Result Http.Error String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), get )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


get : Cmd Msg
get =
    Http.get
        { url = "not a url"
        , expect = Http.expectString Got
        }


errLabel : Http.Error -> String
errLabel err =
    case err of
        Http.BadUrl _ ->
            "BadUrl"

        Http.Timeout ->
            "Timeout"

        Http.NetworkError ->
            "NetworkError"

        Http.BadStatus code ->
            "BadStatus " ++ String.fromInt code

        Http.BadBody _ ->
            "BadBody"


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got (Ok _) ->
            let
                _ =
                    Debug.log "err" "Ok"
            in
            ( model, Cmd.none )

        Got (Err e) ->
            let
                _ =
                    Debug.log "err" (errLabel e)
            in
            ( model, Cmd.none )
