module Checkpoint.Safetensors exposing (Entry, headerLength, parse, dataStart, loadAll)

{-| Reading `.safetensors` checkpoints: an 8-byte little-endian header length, a JSON header naming
each tensor's dtype, shape and byte range, then the data. Only the header passes through Elm; each
tensor goes from the file into a resident buffer on the host (`Bridge.loadRangeInto`).
-}

import Bridge
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as BD
import Json.Decode as D


{-| A tensor in the file: `begin` and `end` are relative to the data, which starts at `dataStart`.
-}
type alias Entry =
    { name : String, dtype : String, shape : List Int, begin : Int, end : Int }


{-| The header's length, from the file's first 8 bytes.
-}
headerLength : Bytes -> Maybe Int
headerLength =
    BD.decode (BD.map2 (\lo hi -> lo + hi * 4294967296) (BD.unsignedInt32 LE) (BD.unsignedInt32 LE))


{-| Where the data starts: after the length and the header.
-}
dataStart : Int -> Int
dataStart length =
    8 + length


{-| The header's entries, in file order (`__metadata__` skipped).
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
                            |> List.map
                                (\( n, v ) ->
                                    D.decodeValue
                                        (D.map3 (\dt shape offsets -> ( dt, shape, offsets ))
                                            (D.field "dtype" D.string)
                                            (D.field "shape" (D.list D.int))
                                            (D.field "data_offsets" (D.list D.int))
                                        )
                                        v
                                        |> Result.mapError (\e -> n ++ ": " ++ D.errorToString e)
                                        |> Result.andThen
                                            (\( dt, shape, offsets ) ->
                                                case offsets of
                                                    [ b, e ] ->
                                                        Ok { name = n, dtype = dt, shape = shape, begin = b, end = e }

                                                    _ ->
                                                        Err (n ++ ": data_offsets is not [begin, end]")
                                            )
                                )
                            |> List.foldr (Result.map2 (::)) (Ok [])
                            |> Result.map (List.sortBy .begin)
                    )


{-| One `loadRangeInto` per entry: the tensor's bytes into the resident buffer `nameOf entry`.
-}
loadAll : String -> Int -> (Entry -> String) -> List Entry -> List Bridge.Command
loadAll path start nameOf entries =
    List.map (\e -> Bridge.loadRangeInto (nameOf e) path (start + e.begin) (e.end - e.begin)) entries
