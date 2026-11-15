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

{-| An Elm program that has graphs run by a separate host program shares no code with it, only
messages of bytes: requests go out of Elm and replies come back in. The layout of every message
therefore has to be fixed exactly, on each side, and this module is that layout on the Elm side, in
both directions.

Every message starts with a 16-byte _header_ of four little-endian unsigned 32-bit _words_: an
_id_, a _code_ saying which request the message is or answers, a _status_, and 0. A request's
status is 0. A reply carries back the id and code of the request it answers, and status 0 for
success or 1 for failure; the payload of a failure is a message in UTF-8 text. The requests that
are not answered (`put`, `save`, `loadInto`, `loadRangeInto`, `drop` and `finish`), and the header
of a _sequence_, a message whose payload is a list of requests (code 6 below), have id 0. For the
other requests, this module writes the id it is given, modulo 2³²; it does not choose one.

Only the tensors of a run are _padded_: each fed input of a run (an input whose role is
`Graph.Fed`), and each fed output in its reply, is followed by zeros up to a multiple of 16 bytes.
Every other payload, including the bytes of a `put` and of a `get`, `load` or `loadRange` reply,
is sent as it is. The offset and length of a file range (`loadRange`, `loadRangeInto`) are two
words; for one from 0 to 2⁵³ these are its low 32 bits then its high 32 bits. Names and paths are
written as they are, with nothing escaped, so a zero byte inside a buffer name ends the name early
in the requests where a zero byte follows the name.

The requests, by code, with what follows the header:

  - 1 `run`: the graph's fed inputs in the order of its inputs, each padded; the id is the
    graph's. Its reply holds the fed outputs in the order of the graph's outputs, each padded.
  - 2 `put`: `NAME`, a zero byte, the buffer's bytes.
  - 3 `get`: `NAME`. Its reply holds the buffer's bytes, none if there is no such buffer.
  - 4 `save` and 5 `loadInto`: `NAME`, a zero byte, `PATH`.
  - 6 a sequence: each request as its length (one word) and its bytes. The requests are handled
    in order, but a compile among them is answered when it finishes, which need not be in the
    sequence's order.
  - 7 `loadRangeInto`: `NAME`, a zero byte, offset, length, `PATH`.
  - 8 `drop`: `NAME`.
  - 9 `loadRange`: offset, length, `PATH`. Its reply, when it succeeds, holds those bytes of the
    file.
  - 10 `compile`: the two _spec lines_ that `specText` writes, then the MLIR; the id is the
    graph's. Its reply has no payload when it succeeds.
  - 11 `load`: `PATH`. Its reply, when it succeeds, holds the whole file.
  - 12 `finish`: the exit code, one word.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as E
import Graph


{-| One request before `encode` lays it out, with any id it carries already chosen. Each constructor
is the request of the same name in the module docstring's list; what follows is what its arguments
are, in order.

`Run` carries the graph's id and the bytes of its fed inputs in the order of its inputs, unpadded:
`encode` pads them.

`Put` carries the buffer's name and the bytes to store in it.

`Get` carries the request's id and the buffer's name.

`Save` and `LoadInto` carry the buffer's name, then the path.

`LoadRangeInto` carries the buffer's name, the path, the offset and the length.

`Drop` carries the buffer's name.

`LoadRange` carries the request's id, the path, the offset and the length.

`Compile` carries the graph's id, the specs of its inputs and of its outputs, and the MLIR, which
is sent after the spec lines as it is.

`Load` carries the request's id and the path.

`Finish` carries the exit code.

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


{-| Produces the encoder for a request's header with `id` and `code`: status 0 and a last word of 0.
-}
header : Int -> Int -> E.Encoder
header id code =
    E.sequence [ word id, word code, word 0, word 0 ]


{-| Produces the encoder for `n` as one little-endian unsigned 32-bit word, `n` taken modulo 2³².
-}
word : Int -> E.Encoder
word n =
    E.unsignedInt32 LE (modBy 4294967296 n)


{-| Produces the encoder for an offset or length `n` as two words, `modBy 2³² n` then `n // 2³²`,
each written as `word` writes it.

For `n` from 0 to 2⁵³ these are its low and high 32 bits. A negative `n` that is not a multiple of
2³² is not written as its two's-complement pattern, because `//` rounds toward zero: −1 gives the
words 2³² − 1 and 0. Nothing refuses a negative `n`.

-}
u64 : Int -> E.Encoder
u64 n =
    E.sequence [ word (modBy 4294967296 n), word (n // 4294967296) ]


{-| Produces the encoder for `name` followed by a zero byte.
-}
named : String -> E.Encoder
named name =
    E.sequence [ E.string name, E.unsignedInt8 0 ]


{-| Returns `n` rounded up to a multiple of 16, for an `n` from 0 to 2³⁵ − 16.
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
then each output, separated by spaces, each line ending in a newline.

A spec is written `name:dtype:AxB`, its sizes joined by `x` (an empty size part for a scalar),
followed by `:r=NAME` when its role is `Graph.Resident NAME`. Nothing is escaped, so a name, dtype
or resident name holding a space, a tab, a newline or a colon does not read back as the spec that
was written; the host fails such a compile in all but one case (see `Max.Session.host`).

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


{-| Returns the bytes of one request, header included, laid out as the module docstring lists for
its code.
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
one, and otherwise a sequence (code 6) holding them all. An empty list gives a sequence with
nothing after its header.
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


{-| A reply as it comes over the wire: the id, code and status from its header, and as `payload`
every byte after the header.
-}
type alias Reply =
    { id : Int, code : Int, status : Int, payload : Bytes }


{-| Reads a reply, or returns `Nothing` for a message shorter than a header. Any id, code and
status are accepted, and the header's fourth word is not kept.
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
to a multiple of 16 bytes, or `Nothing` unless `payload` is exactly as long as those padded tensors.
This holds for widths that are not negative. The padding is skipped, not checked.
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


{-| Returns `b` read as UTF-8 text by `Bytes.Decode.string`, or an empty string when that fails.

Whether malformed text fails depends on the platform. Compiled by eco to native code, the decoder
refuses any malformed UTF-8. Under JavaScript, elm/bytes reads malformed bytes as some other text,
and fails only when a byte it reads as the start of a character promises more bytes than are left.

-}
text : Bytes -> String
text b =
    Decode.decode (Decode.string (Bytes.width b)) b |> Maybe.withDefault ""
