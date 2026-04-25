module JsonRoundtripNestedTree exposing (main)

-- CHECK: roundtrip: True

import Gen exposing (Seed)
import Html exposing (text)
import Json.Decode as D
import Json.Encode as E


n : Int
n =
    1000


m : Int
m =
    1000


loopCount : Int
loopCount =
    n // 4


{-| Balanced binary tree of depth 9 ≈ 1023 internal nodes — stresses lazy recursion. -}
treeDepth : Int
treeDepth =
    9


initialSeed : Seed
initialSeed =
    0x12345678


type Tree
    = Leaf Int
    | Branch Tree Tree


genTree : Int -> Seed -> ( Tree, Seed )
genTree d seed =
    if d <= 0 then
        let
            ( v, s1 ) =
                Gen.int32 seed
        in
        ( Leaf v, s1 )

    else
        let
            ( l, s1 ) =
                genTree (d - 1) seed

            ( r, s2 ) =
                genTree (d - 1) s1
        in
        ( Branch l r, s2 )


encodeTree : Tree -> E.Value
encodeTree t =
    case t of
        Leaf v ->
            E.object [ ( "v", E.int v ) ]

        Branch l r ->
            E.object
                [ ( "l", encodeTree l )
                , ( "r", encodeTree r )
                ]


decodeTree : D.Decoder Tree
decodeTree =
    D.oneOf
        [ D.field "v" D.int |> D.map Leaf
        , D.map2 Branch
            (D.field "l" (D.lazy (\_ -> decodeTree)))
            (D.field "r" (D.lazy (\_ -> decodeTree)))
        ]


loop : Seed -> Int -> Bool -> Bool
loop seed count ok =
    if count <= 0 then
        ok

    else
        let
            ( original, seed1 ) =
                genTree treeDepth seed

            encoded =
                E.encode 0 (encodeTree original)

            decoded =
                D.decodeString decodeTree encoded

            ok2 =
                case decoded of
                    Ok v ->
                        v == original

                    Err _ ->
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
