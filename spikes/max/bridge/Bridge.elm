port module Bridge exposing
    ( Format(..), compile, Command, send, run, load, put, get, save, loadInto, log, done
    , headerId, payload, packed, slice
    , compiledIn, runIn, loadIn, getIn
    )

{-| The ports between an Elm program and `max_bridge`, the generic MAX host, and the byte layout
they share.

Every message on a bytes port starts with a 16-byte header whose first u32 (little-endian) is an
id the reply carries back. Tensors in a message are each padded to 16 bytes.

A graph's resident tensors (`Graph.Resident`: parameters, optimizer state) live in host buffers
named by their resident name: `put` fills one, a run reads them and replaces those its outputs
name, `get` and `save` read one back. Only fed tensors travel with `run` and its reply.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Graph exposing (Graph)
import Json.Decode as D


port compileOut : Bytes -> Cmd msg


port compiledIn : (D.Value -> msg) -> Sub msg


{-| Run, put, get, save and loadInto: one port, so the host sees them in the order they were sent.
-}
port hostOut : Bytes -> Cmd msg


port runIn : (Bytes -> msg) -> Sub msg


port loadOut : Bytes -> Cmd msg


port loadIn : (Bytes -> msg) -> Sub msg


port getIn : (Bytes -> msg) -> Sub msg


port logOut : String -> Cmd msg


port doneOut : Int -> Cmd msg


header : Int -> Encode.Encoder
header id =
    command id 0


command : Int -> Int -> Encode.Encoder
command id code =
    Encode.sequence [ Encode.unsignedInt32 LE id, Encode.unsignedInt32 LE code, Encode.unsignedInt32 LE 0, Encode.unsignedInt32 LE 0 ]


headerId : Bytes -> Int
headerId b =
    Maybe.withDefault -1 (Decode.decode (Decode.unsignedInt32 LE) b)


{-| A message without its header.
-}
payload : Bytes -> Bytes
payload b =
    slice 16 (Bytes.width b - 16) b


paddedSize : Int -> Int
paddedSize n =
    n + modBy 16 (16 - modBy 16 n)


{-| `b` followed by zeros up to a multiple of 16.
-}
packed : Bytes -> Encode.Encoder
packed b =
    let
        w =
            Bytes.width b
    in
    Encode.sequence (Encode.bytes b :: List.repeat (paddedSize w - w) (Encode.unsignedInt8 0))


{-| `len` bytes of `b` from `offset`.
-}
slice : Int -> Int -> Bytes -> Bytes
slice offset len b =
    Decode.decode (Decode.bytes offset |> Decode.andThen (\_ -> Decode.bytes len)) b
        |> Maybe.withDefault (Encode.encode (Encode.sequence []))


type Format
    = Bytecode
    | GenericText


specText : String -> List Graph.Spec -> String
specText tag specs =
    let
        role r =
            case r of
                Graph.Fed ->
                    ""

                Graph.Resident n ->
                    ":r=" ++ n

        one s =
            s.name ++ ":" ++ s.dtype ++ ":" ++ String.join "x" (List.map String.fromInt s.shape) ++ role s.role
    in
    String.join " " (tag :: List.map one specs)


{-| Ask the host to compile `graph` as graph `id`; it answers on `compiledIn` with
`{"id": id, "ok": bool}`. Returns the MLIR's size too.
-}
compile : Format -> Int -> Graph -> ( Cmd msg, Int )
compile format id graph =
    let
        mlir =
            case format of
                Bytecode ->
                    Graph.toBytecode graph

                GenericText ->
                    Encode.encode (Encode.string (Graph.toGenericText graph))
    in
    ( compileOut
        (Encode.encode
            (Encode.sequence
                [ header id
                , Encode.string (specText "in" (Graph.inputs graph) ++ "\n" ++ specText "out" (Graph.outputs graph) ++ "\n")
                , Encode.bytes mlir
                ]
            )
        )
    , Bytes.width mlir
    )


{-| A command for the host: they run in the order `send` lists them (separate sends to one port
can arrive in either order).
-}
type Command
    = Command Bytes


{-| Commands in one message, run in order.
-}
send : List Command -> Cmd msg
send commands =
    case commands of
        [ Command one ] ->
            hostOut one

        _ ->
            hostOut
                (Encode.encode
                    (Encode.sequence
                        (command 0 6
                            :: List.map (\(Command b) -> Encode.sequence [ Encode.unsignedInt32 LE (Bytes.width b), Encode.bytes b ]) commands
                        )
                    )
                )


{-| Run graph `id` on its fed inputs (each packed by `packed`); the fed outputs come back on
`runIn`.
-}
run : Int -> List Encode.Encoder -> Command
run id tensors =
    Command (Encode.encode (Encode.sequence (command id 1 :: tensors)))


{-| Ask the host for the bytes of the file at `path`; they come back on `loadIn` under `id`.
-}
load : Int -> String -> Cmd msg
load id path =
    loadOut (Encode.encode (Encode.sequence [ header id, Encode.string path ]))


named : String -> Encode.Encoder
named name =
    Encode.sequence [ Encode.string name, Encode.unsignedInt8 0 ]


{-| Set the resident buffer `name`.
-}
put : String -> Bytes -> Command
put name bytes =
    Command (Encode.encode (Encode.sequence [ command 0 2, named name, Encode.bytes bytes ]))


{-| Ask for the resident buffer `name`; it comes back on `getIn` under `id`.
-}
get : Int -> String -> Command
get id name =
    Command (Encode.encode (Encode.sequence [ command id 3, Encode.string name ]))


save : String -> String -> Command
save name path =
    Command (Encode.encode (Encode.sequence [ command 0 4, named name, Encode.string path ]))


loadInto : String -> String -> Command
loadInto name path =
    Command (Encode.encode (Encode.sequence [ command 0 5, named name, Encode.string path ]))


log : String -> Cmd msg
log =
    logOut


done : Int -> Cmd msg
done =
    doneOut
