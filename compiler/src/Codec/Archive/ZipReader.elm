module Codec.Archive.ZipReader exposing (Entry, entries)

{-| Reads the entries of a ZIP archive, as the package manager needs them for
the package archives it downloads.

It reads the central directory at the end of the archive and takes each entry's
data from where its local header says it starts, so it lists the entries in the
central directory's order, as adm-zip's `getEntries`, which the compiler used
before, did. Entries stored as they are (method 0) and deflated ones (method 8,
inflated with `folkertdev/elm-flate`) are read; any other method, a Zip64
archive, a split archive, or bytes that are not a well-formed archive make the
whole read fail. Directory entries, whose names end in `/`, are listed too,
with no data. Every field is read with `Bytes.Decode`, never with `Bitwise`, so
the result is the same on eco's native backend, whose `Bitwise` is 64-bit, as
on JavaScript.

@docs Entry, entries

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode exposing (Decoder, Step(..))
import Codec.Utf8 as Utf8
import Flate


{-| One entry of an archive: its name, the path within the archive, and its
contents, inflated.
-}
type alias Entry =
    { name : String
    , data : Bytes
    }


{-| The entries of the archive, in the order of its central directory, or
`Nothing` if it cannot be read.
-}
entries : Bytes -> Maybe (List Entry)
entries archive =
    findEndOfCentralDirectory archive
        |> Maybe.andThen
            (\( count, offset ) ->
                decodeAt offset (Decode.loop ( count, [] ) centralEntryStep) archive
            )
        |> Maybe.andThen (traverse (readEntry archive))



-- ====== END OF CENTRAL DIRECTORY ======


{-| The number of entries and the offset of the central directory, read from the
end-of-central-directory record. The record is the last 22 bytes of an archive
without a comment; an archive comment, at most 65535 bytes, comes after it, so
the record is looked for from the end back over that many bytes.
-}
findEndOfCentralDirectory : Bytes -> Maybe ( Int, Int )
findEndOfCentralDirectory archive =
    let
        last : Int
        last =
            Bytes.width archive - 22

        search : Int -> Maybe ( Int, Int )
        search offset =
            if offset < 0 || offset < last - 65535 then
                Nothing

            else
                case decodeAt offset endOfCentralDirectory archive of
                    Just (Just found) ->
                        Just found

                    _ ->
                        search (offset - 1)
    in
    search last


{-| Reads an end-of-central-directory record: `Just` the entry count and the
central directory's offset, or `Nothing` if the signature does not match or the
archive is split over several disks or uses Zip64.
-}
endOfCentralDirectory : Decoder (Maybe ( Int, Int ))
endOfCentralDirectory =
    Decode.unsignedInt32 LE
        |> Decode.andThen
            (\signature ->
                if signature /= 0x06054B50 then
                    Decode.succeed Nothing

                else
                    Decode.map5
                        (\disk cdDisk onDisk total ( _, offset ) ->
                            if disk /= 0 || cdDisk /= 0 || onDisk /= total || total == 0xFFFF || offset == 0xFFFFFFFF then
                                Nothing

                            else
                                Just ( total, offset )
                        )
                        (Decode.unsignedInt16 LE)
                        (Decode.unsignedInt16 LE)
                        (Decode.unsignedInt16 LE)
                        (Decode.unsignedInt16 LE)
                        (Decode.map2 Tuple.pair (Decode.unsignedInt32 LE) (Decode.unsignedInt32 LE))
            )



-- ====== CENTRAL DIRECTORY ======


{-| What a central directory header says about one entry.
-}
type alias CentralEntry =
    { method : Int
    , compressedSize : Int
    , localOffset : Int
    , name : String
    }


{-| Reads the remaining `n` central directory headers onto `acc`, most recent
first, failing on a header without its signature.
-}
centralEntryStep : ( Int, List CentralEntry ) -> Decoder (Step ( Int, List CentralEntry ) (List CentralEntry))
centralEntryStep ( n, acc ) =
    if n <= 0 then
        Decode.succeed (Done (List.reverse acc))

    else
        centralEntry |> Decode.map (\entry -> Loop ( n - 1, entry :: acc ))


{-| Reads one central directory header (46 bytes, then the name, extra field and
comment).
-}
centralEntry : Decoder CentralEntry
centralEntry =
    Decode.unsignedInt32 LE
        |> Decode.andThen
            (\signature ->
                if signature /= 0x02014B50 then
                    Decode.fail

                else
                    -- version made by, version needed, flags
                    skip 6
                        |> Decode.andThen (\_ -> Decode.unsignedInt16 LE)
                        |> Decode.andThen
                            (\method ->
                                -- time, date, crc-32
                                skip 8
                                    |> Decode.andThen (\_ -> Decode.map2 Tuple.pair (Decode.unsignedInt32 LE) (Decode.unsignedInt32 LE))
                                    |> Decode.andThen
                                        (\( compressedSize, size ) ->
                                            Decode.map3 (\a b c -> ( a, b, c ))
                                                (Decode.unsignedInt16 LE)
                                                (Decode.unsignedInt16 LE)
                                                (Decode.unsignedInt16 LE)
                                                |> Decode.andThen
                                                    (\( nameLength, extraLength, commentLength ) ->
                                                        -- disk number start, internal and external attributes
                                                        skip 8
                                                            |> Decode.andThen (\_ -> Decode.unsignedInt32 LE)
                                                            |> Decode.andThen
                                                                (\localOffset ->
                                                                    Decode.bytes nameLength
                                                                        |> Decode.andThen
                                                                            (\nameBytes ->
                                                                                skip (extraLength + commentLength)
                                                                                    |> Decode.andThen
                                                                                        (\_ ->
                                                                                            if compressedSize == 0xFFFFFFFF || size == 0xFFFFFFFF || localOffset == 0xFFFFFFFF then
                                                                                                Decode.fail

                                                                                            else
                                                                                                Decode.succeed
                                                                                                    { method = method
                                                                                                    , compressedSize = compressedSize
                                                                                                    , localOffset = localOffset
                                                                                                    , name = Utf8.decode nameBytes
                                                                                                    }
                                                                                        )
                                                                            )
                                                                )
                                                    )
                                        )
                            )
            )



-- ====== ENTRY DATA ======


{-| Reads an entry's data from the archive: past its local header (30 bytes,
then its own name and extra field, whose lengths may differ from the central
directory's), and inflated if it is deflated.
-}
readEntry : Bytes -> CentralEntry -> Maybe Entry
readEntry archive entry =
    decodeAt entry.localOffset localHeader archive
        |> Maybe.andThen
            (\headerLength ->
                decodeAt (entry.localOffset + headerLength) (Decode.bytes entry.compressedSize) archive
            )
        |> Maybe.andThen
            (\raw ->
                case entry.method of
                    0 ->
                        Just raw

                    8 ->
                        Flate.inflate raw

                    _ ->
                        Nothing
            )
        |> Maybe.map (\data -> { name = entry.name, data = data })


{-| Reads a local file header and gives its length, failing on a header without
its signature.
-}
localHeader : Decoder Int
localHeader =
    Decode.unsignedInt32 LE
        |> Decode.andThen
            (\signature ->
                if signature /= 0x04034B50 then
                    Decode.fail

                else
                    skip 22
                        |> Decode.andThen (\_ -> Decode.map2 (\n e -> 30 + n + e) (Decode.unsignedInt16 LE) (Decode.unsignedInt16 LE))
            )



-- ====== HELPERS ======


{-| Runs `decoder` on the bytes from `offset` on.
-}
decodeAt : Int -> Decoder a -> Bytes -> Maybe a
decodeAt offset decoder bytes =
    if offset < 0 || offset > Bytes.width bytes then
        Nothing

    else
        Decode.decode (skip offset |> Decode.andThen (\_ -> decoder)) bytes


{-| Skips `n` bytes.
-}
skip : Int -> Decoder ()
skip n =
    Decode.bytes n |> Decode.map (\_ -> ())


{-| Applies `f` to each element, giving `Nothing` if any result is `Nothing`.
-}
traverse : (a -> Maybe b) -> List a -> Maybe (List b)
traverse f list =
    List.foldr (\x acc -> Maybe.map2 (::) (f x) acc) (Just []) list
