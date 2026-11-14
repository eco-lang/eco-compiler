module Max.Internal.Protocol exposing
    ( Reply
    , Request(..)
    , decodeReply
    , encode
    , encodeAll
    , paddedSize
    , specText
    , splitPadded
    , text
    )

{-| An Elm program and the MAX host talk over two ports carrying bytes: one for every request the
program makes, in order, and one for every reply. This module is the byte layout of those
messages, version 2 of the protocol, in both directions.

Every message starts with a 16-byte _header_ of four little-endian unsigned 32-bit words: an `id`,
a `code` saying what the message is, a `status`, and 0. A request's status is 0. A reply carries
the `id` and `code` of the request it answers, and status 0 for success or 1 for failure, when its
payload is a UTF-8 message. A request that expects no reply has id 0. A tensor in a message is
padded with zeros to a multiple of 16 bytes. An offset or length in a payload is two words, its low
32 bits then its high 32 bits.

The requests, by code, with what follows the header:

  - 1 `run`: the graph's fed inputs in graph order, each padded; the id is the graph's. Its reply
    holds the fed outputs in graph order, each padded.
  - 2 `put`: `NAME`, a zero byte, the buffer's bytes.
  - 3 `get`: `NAME`. Its reply holds the buffer's bytes, none if it was never set.
  - 4 `save` and 5 `loadInto`: `NAME`, a zero byte, `PATH`.
  - 6 a sequence: each request as its length (one word) and its bytes, to be run in order.
  - 7 `loadRangeInto`: `NAME`, a zero byte, offset, length, `PATH`.
  - 8 `drop`: `NAME`.
  - 9 `loadRange`: offset, length, `PATH`. Its reply holds those bytes of the file.
  - 10 `compile`: two lines of specs, `in …` and `out …`, then the MLIR; the id is the graph's.
    Its reply has no payload when it succeeds.
  - 11 `load`: `PATH`. Its reply holds the whole file.
  - 12 `finish`: the exit code, one word.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as E
import Graph


{-| A request as it goes over the wire, with its id already chosen.

`Run` carries the graph id and the fed inputs' bytes in graph order, unpadded. `Get`, `LoadRange`
and `Load` carry the id the reply will quote first. `LoadRangeInto` carries the buffer's name, the
path, the offset and the length; `LoadRange` the id, the path, the offset and the length. `Compile`
carries the graph id, the graph's input and output specs, and the MLIR. `Save` and `LoadInto` carry
the buffer's name, then the path.

-}
type Request
    = Run Int (List Bytes)
    | Put String Bytes
    | Get Int String
    | Save String String
    | LoadInto String String
    | LoadRangeInto String String Int Int
    | Drop String
    | LoadRange Int String Int Int
    | Compile Int (List Graph.Spec) (List Graph.Spec) Bytes
    | Load Int String
    | Finish Int


{-| Produces the encoder for a header with `id` and `code` and status 0.
-}
header : Int -> Int -> E.Encoder
header id code =
    E.sequence [ word id, word code, word 0, word 0 ]


{-| Produces the encoder for `n` as one little-endian unsigned 32-bit word, `n` taken modulo 2³².
-}
word : Int -> E.Encoder
word n =
    E.unsignedInt32 LE (modBy 4294967296 n)


{-| Produces the encoder for an offset or length: two words, low then high. Values up to 2⁵³ are
exact.
-}
u64 : Int -> E.Encoder
u64 n =
    E.sequence [ word (modBy 4294967296 n), word (n // 4294967296) ]


{-| Produces the encoder for `name` followed by a zero byte.
-}
named : String -> E.Encoder
named name =
    E.sequence [ E.string name, E.unsignedInt8 0 ]


{-| Returns `n` rounded up to a multiple of 16.
-}
paddedSize : Int -> Int
paddedSize n =
    (n + 15) // 16 * 16


{-| Produces the encoder for `b` followed by zeros up to a multiple of 16 bytes.
-}
padded : Bytes -> E.Encoder
padded b =
    let
        w =
            Bytes.width b
    in
    E.sequence (E.bytes b :: List.repeat (paddedSize w - w) (E.unsignedInt8 0))


{-| Returns the two spec lines a compile request starts with: `in` and then each input, `out` and
then each output, each line ending in a newline. A spec is written `name:dtype:AxB`, its sizes
joined by `x` (nothing after the second colon for a scalar), followed by `:r=NAME` when its role is
`Resident NAME`.
-}
specText : List Graph.Spec -> List Graph.Spec -> String
specText inputs outputs =
    let
        one s =
            s.name
                ++ ":"
                ++ s.dtype
                ++ ":"
                ++ String.join "x" (List.map String.fromInt s.shape)
                ++ (case s.role of
                        Graph.Fed ->
                            ""

                        Graph.Resident n ->
                            ":r=" ++ n
                   )

        line tag specs =
            String.join " " (tag :: List.map one specs) ++ "\n"
    in
    line "in" inputs ++ line "out" outputs


{-| Returns the bytes of one request.
-}
encode : Request -> Bytes
encode request =
    E.encode <|
        case request of
            Run graph inputs ->
                E.sequence (header graph 1 :: List.map padded inputs)

            Put name bytes ->
                E.sequence [ header 0 2, named name, E.bytes bytes ]

            Get id name ->
                E.sequence [ header id 3, E.string name ]

            Save name path ->
                E.sequence [ header 0 4, named name, E.string path ]

            LoadInto name path ->
                E.sequence [ header 0 5, named name, E.string path ]

            LoadRangeInto name path offset length ->
                E.sequence [ header 0 7, named name, u64 offset, u64 length, E.string path ]

            Drop name ->
                E.sequence [ header 0 8, E.string name ]

            LoadRange id path offset length ->
                E.sequence [ header id 9, u64 offset, u64 length, E.string path ]

            Compile graph inputs outputs mlir ->
                E.sequence [ header graph 10, E.string (specText inputs outputs), E.bytes mlir ]

            Load id path ->
                E.sequence [ header id 11, E.string path ]

            Finish code ->
                E.sequence [ header 0 12, word code ]


{-| Returns the one message that carries `requests` in order: the request itself when there is
one, and otherwise a sequence (code 6) holding them all. No requests give an empty sequence.
-}
encodeAll : List Request -> Bytes
encodeAll requests =
    case requests of
        [ one ] ->
            encode one

        _ ->
            E.encode
                (E.sequence
                    (header 0 6
                        :: List.map (\r -> encode r |> (\b -> E.sequence [ word (Bytes.width b), E.bytes b ])) requests
                    )
                )


{-| A reply as it comes over the wire: its header's words and the bytes after it.
-}
type alias Reply =
    { id : Int, code : Int, status : Int, payload : Bytes }


{-| Reads a reply, or returns `Nothing` for a message shorter than a header.
-}
decodeReply : Bytes -> Maybe Reply
decodeReply b =
    let
        w =
            Decode.unsignedInt32 LE
    in
    Decode.decode
        (Decode.map4 (\id code status _ -> \payload -> { id = id, code = code, status = status, payload = payload }) w w w w
            |> Decode.andThen (\k -> Decode.map k (Decode.bytes (Bytes.width b - 16)))
        )
        b


{-| Returns the tensors of `widths` bytes each that `payload` holds one after another, each padded
to 16 bytes, or `Nothing` unless `payload` is exactly as long as those padded tensors.
-}
splitPadded : List Int -> Bytes -> Maybe (List Bytes)
splitPadded widths payload =
    if List.sum (List.map paddedSize widths) /= Bytes.width payload then
        Nothing

    else
        Decode.decode
            (Decode.loop ( widths, [] )
                (\( left, acc ) ->
                    case left of
                        [] ->
                            Decode.succeed (Decode.Done (List.reverse acc))

                        n :: rest ->
                            Decode.bytes n
                                |> Decode.andThen (\t -> Decode.bytes (paddedSize n - n) |> Decode.map (\_ -> Decode.Loop ( rest, t :: acc )))
                )
            )
            payload


{-| Returns `b` read as UTF-8 text, or an empty string if it is not.
-}
text : Bytes -> String
text b =
    Decode.decode (Decode.string (Bytes.width b)) b |> Maybe.withDefault ""
