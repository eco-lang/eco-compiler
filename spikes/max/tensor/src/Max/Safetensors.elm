module Max.Safetensors exposing
    ( Entry
    , readLength, headerLength, readHeader, parse
    , dataStart, loadAll
    )

{-| A model's pretrained weights usually come as a `.safetensors` checkpoint, and this module reads
one into a session's resident buffers.

The file is an 8-byte little-endian header length, then a JSON header of that many bytes, then the
data. The header names each tensor and gives its dtype, its shape and the byte range of its data,
counted from where the data starts. Only the header passes through Elm: each tensor goes from the
file straight into a resident buffer (`Max.Session.loadRangeInto`).

Reading a checkpoint takes three round trips through a session, each answered by
`Max.Session.Loaded` with the checkpoint's path:

1.  `readLength path`; `headerLength` of the bytes gives the header's length `n`.
2.  `readHeader path n`; `parse` of the bytes gives the entries.
3.  `loadAll path (dataStart n) nameOf entries`, sent, fills a buffer for each entry.

The in-Elm session reads no files, so this works on the host backend only.


# Entries

@docs Entry


# Reading the header

@docs readLength, headerLength, readHeader, parse


# Loading the tensors

@docs dataStart, loadAll

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as BD
import Json.Decode as D
import Max.Session as Session exposing (Command)


{-| A tensor in the checkpoint, as its header describes it.

`dtype` is the checkpoint's name for it, such as `"F32"` or `"BF16"`, not the package's. `begin`
and `end` are the tensor's byte range, `end` excluded, counted from the start of the data, not of
the file.

-}
type alias Entry =
    { name : String, dtype : String, shape : List Int, begin : Int, end : Int }


{-| Creates the command that reads the first 8 bytes of the checkpoint at `path`, which hold the
header's length.
-}
readLength : String -> Command
readLength path =
    Session.loadRange path 0 8


{-| Returns the header's length, read from the checkpoint's first 8 bytes, or `Nothing` if fewer
than 8 bytes are given.
-}
headerLength : Bytes -> Maybe Int
headerLength =
    BD.decode (BD.map2 (\lo hi -> lo + hi * 4294967296) (BD.unsignedInt32 LE) (BD.unsignedInt32 LE))


{-| Creates the command that reads the header of the checkpoint at `path`, given the header's
length.
-}
readHeader : String -> Int -> Command
readHeader path length =
    Session.loadRange path 8 length


{-| Returns where a checkpoint's data starts in the file, given its header's length: after the
8-byte length and the header.
-}
dataStart : Int -> Int
dataStart length =
    8 + length


{-| Returns the header's entries in the order of their data in the file, or why the header cannot
be read: it is not UTF-8 text, not a JSON object, or an entry lacks a string `dtype`, a list of
integers `shape`, or a `data_offsets` of exactly two integers. The `__metadata__` entry is skipped.
-}
parse : Bytes -> Result String (List Entry)
parse header =
    case BD.decode (BD.string (Bytes.width header)) header of
        Nothing ->
            Err "the header is not text"

        Just text ->
            D.decodeString (D.keyValuePairs D.value) text
                |> Result.mapError D.errorToString
                |> Result.andThen
                    (\pairs ->
                        pairs
                            |> List.filter (\( n, _ ) -> n /= "__metadata__")
                            |> List.map (\( n, v ) -> entry n v)
                            |> List.foldr (Result.map2 (::)) (Ok [])
                            |> Result.map (List.sortBy .begin)
                    )


{-| Returns the entry the header holds under `name`, or why it cannot be read, in a message starting
with the name.
-}
entry : String -> D.Value -> Result String Entry
entry name v =
    D.decodeValue
        (D.map3 (\dt shape offsets -> ( dt, shape, offsets ))
            (D.field "dtype" D.string)
            (D.field "shape" (D.list D.int))
            (D.field "data_offsets" (D.list D.int))
        )
        v
        |> Result.mapError (\e -> name ++ ": " ++ D.errorToString e)
        |> Result.andThen
            (\( dt, shape, offsets ) ->
                case offsets of
                    [ b, e ] ->
                        Ok { name = name, dtype = dt, shape = shape, begin = b, end = e }

                    _ ->
                        Err (name ++ ": data_offsets is not [begin, end]")
            )


{-| Creates one `loadRangeInto` for each entry, in the order given: the tensor's bytes in the
checkpoint at `path`, whose data starts at byte `start`, into the resident buffer `nameOf entry`.
-}
loadAll : String -> Int -> (Entry -> String) -> List Entry -> List Command
loadAll path start nameOf entries =
    List.map (\e -> Session.loadRangeInto (nameOf e) path (start + e.begin) (e.end - e.begin)) entries
