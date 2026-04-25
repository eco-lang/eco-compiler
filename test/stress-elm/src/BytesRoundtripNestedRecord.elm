module BytesRoundtripNestedRecord exposing (main)

{-| Multi-level nested structure approximating an `.ecoi` module-interface
    shape: an outer record whose `modules` field is a `BD.list` of inner
    records, each carrying a String plus a nested `BD.list` of `(String, Int)`
    pairs. Exercises two `BD.list` decoders stacked inside an outer record,
    matching the compiler's own interface-cache decoders.
-}

-- CHECK: roundtrip: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Gen exposing (Seed)
import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


defsPerModule : Int
defsPerModule =
    10


loopCount : Int
loopCount =
    n // 100


initialSeed : Seed
initialSeed =
    0xBADC0DE5


type alias Def =
    ( String, Int )


type alias Module =
    { name : String, defs : List Def }


type alias Interface =
    { version : Int, modules : List Module }


genString : Int -> Seed -> ( String, Seed )
genString maxLen seed =
    let
        ( len, s1 ) =
            Gen.intIn 1 maxLen seed
    in
    Gen.asciiString len s1


genDef : Seed -> ( Def, Seed )
genDef seed =
    let
        ( name, s1 ) =
            genString 8 seed

        ( v, s2 ) =
            Gen.int32 s1
    in
    ( ( name, v ), s2 )


genModule : Seed -> ( Module, Seed )
genModule seed =
    let
        ( name, s1 ) =
            genString 12 seed

        ( defs, s2 ) =
            Gen.listOf defsPerModule genDef s1
    in
    ( { name = name, defs = defs }, s2 )


gen : Seed -> ( Interface, Seed )
gen seed =
    let
        ( ver, s1 ) =
            Gen.int32 seed

        ( mods, s2 ) =
            Gen.listOf m genModule s1
    in
    ( { version = ver, modules = mods }, s2 )


encodeString : String -> E.Encoder
encodeString s =
    let
        w =
            E.getStringWidth s
    in
    E.sequence [ E.unsignedInt16 BE w, E.string s ]


encodeDef : Def -> E.Encoder
encodeDef ( name, v ) =
    E.sequence [ encodeString name, E.signedInt32 BE v ]


encodeModule : Module -> E.Encoder
encodeModule mod =
    E.sequence
        [ encodeString mod.name
        , E.unsignedInt16 BE (List.length mod.defs)
        , E.sequence (List.map encodeDef mod.defs)
        ]


encoder : Interface -> E.Encoder
encoder iface =
    E.sequence
        [ E.signedInt32 BE iface.version
        , E.unsignedInt16 BE (List.length iface.modules)
        , E.sequence (List.map encodeModule iface.modules)
        ]


decodeString : D.Decoder String
decodeString =
    D.unsignedInt16 BE |> D.andThen D.string


decodeDef : D.Decoder Def
decodeDef =
    decodeString
        |> D.andThen
            (\name ->
                D.signedInt32 BE |> D.map (\v -> ( name, v ))
            )


decodeDefs : D.Decoder (List Def)
decodeDefs =
    D.unsignedInt16 BE
        |> D.andThen
            (\len ->
                D.loop ( len, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            decodeDef |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
                    )
            )


decodeModule : D.Decoder Module
decodeModule =
    decodeString
        |> D.andThen
            (\name ->
                decodeDefs
                    |> D.map (\defs -> { name = name, defs = defs })
            )


decoder : D.Decoder Interface
decoder =
    D.signedInt32 BE
        |> D.andThen
            (\ver ->
                D.unsignedInt16 BE
                    |> D.andThen
                        (\len ->
                            D.loop ( len, [] )
                                (\( remaining, acc ) ->
                                    if remaining <= 0 then
                                        D.succeed (D.Done (List.reverse acc))

                                    else
                                        decodeModule
                                            |> D.map (\v -> D.Loop ( remaining - 1, v :: acc ))
                                )
                                |> D.map (\mods -> { version = ver, modules = mods })
                        )
            )


loop : Seed -> Int -> Bool -> Bool
loop seed count ok =
    if count <= 0 then
        ok

    else
        let
            ( original, seed1 ) =
                gen seed

            encoded =
                E.encode (encoder original)

            decoded =
                D.decode decoder encoded

            ok2 =
                case decoded of
                    Just v ->
                        v == original

                    Nothing ->
                        False
        in
        loop seed1 (count - 1) (ok && ok2)


main =
    let
        result =
            loop initialSeed loopCount True

        _ =
            Debug.log "roundtrip" result
    in
    text "done"
