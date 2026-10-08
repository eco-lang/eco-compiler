module WebSocket.Internal exposing
    ( WebSocket(..), Upgrade(..), Negotiated
    , UpgradeArg, OpenArg, toUpgrade, toWebSocket
    , handshakeError, handshakeErrorPrefix
    )

{-| Internal; not exposed.

The handle types of `WebSocket` are defined here so that `WebSocket` and `Http.Server` can both
build and unwrap them, while users only see the aliases exposed by `WebSocket`
(plans/eco-system-websockets.md §3.1, §3.6). The decoders turn the kernels' boundary tuples
(Appendix B) into these types.

`Message`, `StreamedMessage` and their `fromWire`/`toWire` closures live in `WebSocket` itself:
`Message(..)` is exposed with its constructors, which an alias cannot re-export.

-}

import Socket.Address exposing (Endpoint)
import Socket.Internal


{-| An open WebSocket: its WebSocket-table id, the ids of its readable and writable stream pairs,
what the handshake agreed on, and both endpoints (`WebSocket.readable` and friends rebuild the
`Stream` handles from the ids). `mode` is the phantom `WebSocket.Whole` or
`WebSocket.Streamed`.
-}
type WebSocket mode
    = WebSocket
        { id : Int
        , readable : Int
        , writable : Int
        , protocol : Maybe String
        , compression : Maybe Negotiated
        , local : Endpoint
        , remote : Endpoint
        }


{-| The parameters of a negotiated permessage-deflate (the same record as `WebSocket.Negotiated`).
-}
type alias Negotiated =
    { serverNoContextTakeover : Bool
    , clientNoContextTakeover : Bool
    , serverMaxWindowBits : Int
    , clientMaxWindowBits : Int
    }


{-| A received opening request, not yet answered: the id the kernel keeps it under, its request
line, its headers (lower-case names, duplicates kept, in order), the `Sec-WebSocket-Accept` value
its key calls for (`""` over HTTP/2), whether it came over HTTP/2 (extended CONNECT), and the
peer's endpoint.
-}
type Upgrade
    = Upgrade
        { id : Int
        , method : String
        , target : String
        , version : String
        , headers : List ( String, String )
        , expectedAccept : String
        , isH2 : Bool
        , remote : Endpoint
        }


{-| What `WebSocket.readUpgrade` and `HttpServer.takeUpgrade` return:
`( upId, ( method, target, version ), ( headers, isH2, remoteEpT ) )`.
-}
type alias UpgradeArg =
    ( Int, ( String, String, String ), ( List ( String, List String ), Bool, ( Int, String, Int ) ) )


{-| What `WebSocket.open` returns: `( wsId, ( readableId, writableId ), ( localEpT, remoteEpT ) )`.
-}
type alias OpenArg =
    ( Int, ( Int, Int ), ( ( Int, String, Int ), ( Int, String, Int ) ) )


{-| Build an `Upgrade`; `acceptFor` computes the `Sec-WebSocket-Accept` value of a key.
-}
toUpgrade : (String -> String) -> UpgradeArg -> Upgrade
toUpgrade acceptFor ( id, ( method, target, version ), ( headers, isH2, remote ) ) =
    let
        flat =
            List.concatMap (\( name, values ) -> List.map (\v -> ( String.toLower name, v )) values) headers

        key =
            flat
                |> List.filter (\( name, _ ) -> name == "sec-websocket-key")
                |> List.map (Tuple.second >> String.trim)
                |> List.head
    in
    Upgrade
        { id = id
        , method = method
        , target = target
        , version = version
        , headers = flat
        , expectedAccept =
            case ( isH2, key ) of
                ( False, Just k ) ->
                    acceptFor k

                _ ->
                    ""
        , isH2 = isH2
        , remote = Socket.Internal.toEndpoint remote
        }


{-| Build a `WebSocket` from `open`'s result and what the handshake agreed on.
-}
toWebSocket : Maybe String -> Maybe Negotiated -> OpenArg -> WebSocket mode
toWebSocket protocol compression ( id, ( readableId, writableId ), ( local, remote ) ) =
    WebSocket
        { id = id
        , readable = readableId
        , writable = writableId
        , protocol = protocol
        , compression = compression
        , local = Socket.Internal.toEndpoint local
        , remote = Socket.Internal.toEndpoint remote
        }


{-| The prefix of an `ERR_WS_HANDSHAKE` message that carries the HTTP status
(`WebSocket.handshakeStatus` reads it back).
-}
handshakeErrorPrefix : String
handshakeErrorPrefix =
    "status "


{-| An `ERR_WS_HANDSHAKE` error (Appendix D.9). With a status the message is
`"status <n>: <text>"`.
-}
handshakeError : Maybe Int -> String -> Socket.Internal.Error
handshakeError status text =
    Socket.Internal.Error
        { code = "ERR_WS_HANDSHAKE"
        , message =
            case status of
                Just s ->
                    handshakeErrorPrefix ++ String.fromInt s ++ ": " ++ text

                Nothing ->
                    text
        }
