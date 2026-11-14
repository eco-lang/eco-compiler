module Max.Safetensors exposing
    ( Entry
    , readLength, headerLength, readHeader, parse
    , dataStart, loadAll
    )

{-| This module loads the tensors of a `.safetensors` checkpoint, such as a model's weights, into a
host session's resident buffers, each tensor going from the file straight into its buffer.

A _checkpoint_, as this module reads it, is an 8-byte little-endian number giving the header's
length, then a JSON header of that many bytes, then the data. The header is a JSON object. Its
member `__metadata__` is skipped, and every other member is read as one tensor, an _entry_: the
member's key is the tensor's name, and its value gives the tensor's `dtype`, `shape` and
`data_offsets`. `data_offsets` is the tensor's byte range, which this module counts from the
_data start_, the first byte after the header, not from the start of the file.

Only the length and the header pass through Elm. Reading a checkpoint takes three steps, each a
`Max.Session.send` of the commands this module makes:

1.  `readLength path`. When the read succeeds, `Max.Session.Loaded` answers it, and
    `headerLength` of its bytes gives the header's length `n`.
2.  `readHeader path n`. When the read succeeds, `Loaded` answers it, and `parse` of its bytes
    gives the entries.
3.  `loadAll path (dataStart n) nameOf entries`. Each of these commands sets one resident buffer,
    and nothing answers them when they succeed. On the host, one that fails ends the program.

The answers to successful steps 1 and 2 are both `Loaded` with the checkpoint's path, and nothing
in the event says which of the two it answers. What the host does when step 1 or 2 cannot be read
is as `Max.Session.loadRange` describes.

A tensor's bytes go into its buffer as they are. Its `dtype` is neither checked nor converted, and
its byte count is not compared with its dtype and shape. A run reads a resident buffer by the
graph input's dtype and shape and checks only its byte count, as `Max.Session` describes. So a
tensor stored in another dtype than the input's is read as the input's dtype when the byte counts
agree, and otherwise stops the run, which on the host ends the program.

The in-Elm backend reads no files, and answers each of these commands that it runs with `Failed`,
so a checkpoint can be read only on the host backend.


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


{-| One tensor that a checkpoint's header describes: what the header says it holds, and where its
bytes lie in the file.

`name` is the tensor's key in the header. `dtype` is the header's own string for the element type,
used as it is, not converted to one of the package's dtype names. `begin` and `end` are the
tensor's byte range, `end` excluded, counted from the data start, not from the start of the file.
`parse` does not require `begin` and `end` to be non-negative or `begin` to be at most `end`, and
does not compare the range with `dtype` and `shape`, with the file's size, or with the other
entries' ranges.

-}
type alias Entry =
    { name : String, dtype : String, shape : List Int, begin : Int, end : Int }


{-| Creates the command that reads the first 8 bytes of the checkpoint at `path`, which hold the
header's length. On the host, `Max.Session.Loaded` answers a successful read with `path` and those
bytes; how a failed read is answered is as `Max.Session.loadRange` says.
-}
readLength : String -> Command
readLength path =
    Session.loadRange path 0 8


{-| Returns the header's length, read from the first 8 bytes given as an unsigned little-endian
number, or `Nothing` when fewer than 8 bytes are given. Any bytes after the eighth are ignored. A
length below 2⁵³ is read exactly.
-}
headerLength : Bytes -> Maybe Int
headerLength =
    BD.decode (BD.map2 (\lo hi -> lo + hi * 4294967296) (BD.unsignedInt32 LE) (BD.unsignedInt32 LE))


{-| Creates the command that reads the header of the checkpoint at `path`, given the header's
length: `length` bytes, starting at byte 8. On the host, `Max.Session.Loaded` answers a successful
read with `path` and those bytes. What the host does with a read that fails, such as one of a file
holding fewer than `8 + length` bytes, is as `Max.Session.loadRange` describes.
-}
readHeader : String -> Int -> Command
readHeader path length =
    Session.loadRange path 8 length


{-| Returns the position in the file of a checkpoint's data start, given its header's length: the
first byte after the 8-byte length and the header.
-}
dataStart : Int -> Int
dataStart length =
    8 + length


{-| Returns the entries a checkpoint's header describes, sorted by `begin`, or why the header cannot
be read. The member `__metadata__` is skipped, and every other member is an entry.

The header cannot be read when `Bytes.Decode.string` cannot decode its bytes, when the text is not
a JSON object, or when a member lacks any of a string `dtype`, a list of integers `shape` and a
`data_offsets` of exactly two integers. A message about a member starts with the member's name.
Under eco native code, `Bytes.Decode.string` fails on any malformed UTF-8. Under JavaScript,
elm/bytes fails only when a multi-byte sequence runs past the end of the bytes, and otherwise
reads malformed bytes as some text.

The entries are not checked against each other or against the file: their ranges may overlap,
leave gaps, run past the file's end, or have `end` before `begin`.

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


{-| Returns the entry for the header member with key `name` and value `v`, or why it cannot be
read, in a message starting with `name`.
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


{-| Creates one `Max.Session.loadRangeInto` for each entry, in the order given. Each sets the
resident buffer `nameOf entry` to the entry's bytes in the checkpoint at `path`, whose data starts
at byte `start` of the file, as `dataStart` gives it.

Nothing answers these commands when they succeed. On the host, a file that cannot be opened or
read, or an entry whose range runs past the file's end, ends the program. On the in-Elm backend the
first of them that runs gives `Failed`, and the rest of that `send` is skipped.

The entries are used as they are. An entry whose `end` is before its `begin` gives a negative
length, which nothing refuses, and which the host reads as another number. A negative `begin`,
which nothing refuses either, gives an offset before `start`: from −`start` to −1 the buffer's bytes
start in the 8-byte length or the header, and below −`start` the offset is negative, which the host
also reads as another number.

-}
loadAll : String -> Int -> (Entry -> String) -> List Entry -> List Command
loadAll path start nameOf entries =
    List.map (\e -> Session.loadRangeInto (nameOf e) path (start + e.begin) (e.end - e.begin)) entries
