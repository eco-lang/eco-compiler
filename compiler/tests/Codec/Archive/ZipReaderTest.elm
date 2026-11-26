module Codec.Archive.ZipReaderTest exposing (suite)

{-| `Codec.Archive.ZipReader.entries` on an archive written by Python's `zipfile`: a directory
entry, a stored file and a deflated one, in that order, followed by an archive comment (so the
end-of-central-directory record is not at the very end). The archive's SHA-1, as `sha1sum` gives
it, checks `Codec.Sha1` on the same bytes.
-}

import Bytes exposing (Bytes)
import Bytes.Encode as Encode
import Codec.Archive.ZipReader as ZipReader
import Codec.Sha1 as Sha1
import Codec.Utf8 as Utf8
import Expect
import Test exposing (Test)


fixture : Bytes
fixture =
    fromHex
        (String.concat
                [ "504b0304140000000000000021000000000000000000000000000a000000706b672d312e302e302f504b030414000000"
                , "000000002100ab13eed1140000001400000012000000706b672d312e302e302f656c6d2e6a736f6e7b2274797065223a"
                , "20227061636b616765227d0a504b0304140000000800000021000f299fc52c0000008601000016000000706b672d312e"
                , "302e302f7372632f4d61696e2e656c6dcbcd4f29cd4955f04dcccc5348ad28c82fcecc4b57d0c8057235b9b874751592"
                , "13d30eaf541865d094c10500504b01021403140000000000000021000000000000000000000000000a00000000000000"
                , "00000000800100000000706b672d312e302e302f504b0102140314000000000000002100ab13eed11400000014000000"
                , "120000000000000000000000800128000000706b672d312e302e302f656c6d2e6a736f6e504b01021403140000000800"
                , "000021000f299fc52c0000008601000016000000000000000000000080016c000000706b672d312e302e302f7372632f"
                , "4d61696e2e656c6d504b05060000000003000300bc000000cc0000001200616e206172636869766520636f6d6d656e74"
                ]
        )


fromHex : String -> Bytes
fromHex text =
    let
        digit c =
            if Char.isDigit c then
                Char.toCode c - 48

            else
                Char.toCode c - 87

        pairs chars =
            case chars of
                hi :: lo :: rest ->
                    Encode.unsignedInt8 (digit hi * 16 + digit lo) :: pairs rest

                _ ->
                    []
    in
    Encode.encode (Encode.sequence (pairs (String.toList text)))


suite : Test
suite =
    Test.describe "Codec.Archive.ZipReader"
        [ Test.test "entries in central directory order, with their contents" <|
            \_ ->
                ZipReader.entries fixture
                    |> Maybe.map (List.map (\e -> ( e.name, Utf8.decode e.data )))
                    |> Expect.equal
                        (Just
                            [ ( "pkg-1.0.0/", "" )
                            , ( "pkg-1.0.0/elm.json", "{\"type\": \"package\"}\n" )
                            , ( "pkg-1.0.0/src/Main.elm", "module Main exposing (main)\n\n" ++ String.repeat 40 "-- café " ++ "\n" )
                            ]
                        )
        , Test.test "not an archive" <|
            \_ -> ZipReader.entries (Utf8.encode "not a zip archive at all, but long enough") |> Expect.equal Nothing
        , Test.test "SHA-1 of the archive" <|
            \_ -> Sha1.hex fixture |> Expect.equal "c26cfad7cd026fd751dfd3418d72e8492027d9b0"
        ]
