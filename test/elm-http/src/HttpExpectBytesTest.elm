module HttpExpectBytesTest exposing (main)

-- CHECK: bytes: 66051

import Bytes exposing (Endianness(..))
import Bytes.Decode as BD
import Http
import Platform
import TestServerConfig
import Task


type Msg
    = Got (Result Http.Error Int)
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
    -- /bytes/4 returns the bytes 0x00 0x01 0x02 0x03; decoded BE as a u32
    -- that is 0x00010203 = 66051.
    Http.get
        { url = server.baseUrl ++ "/bytes/4"
        , expect = Http.expectBytes Got (BD.unsignedInt32 BE)
        }


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model, get server )

        Got (Ok n) ->
            let
                _ =
                    Debug.log "bytes" n
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "bytes" -1
            in
            ( model, Cmd.none )
