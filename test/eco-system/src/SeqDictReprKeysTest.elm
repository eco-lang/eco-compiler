module SeqDictReprKeysTest exposing (main)

{-| SeqDict with keys and values of every heap representation the compiler may choose: an erased
one-constructor wrapper, a Maybe-shaped user type, a tagged union, records, tuples, `Maybe` of a
tuple, Strings in each form (literal, concatenation, slice, rope, from a list), Floats including
±0 and the infinities. For each key type, `exercise` builds a dict, reads every key, removes every
other key, updates the rest, and compares with a freshly built dict both in order (`==`) and
ignoring order (`unorderedEquals`); every result must be `True`. `crossForms` looks keys up with
equal keys built another way.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: wrapper: [True,True,True,True,True,True]
-- CHECK: maybeShaped: [True,True,True,True,True,True]
-- CHECK: tagged: [True,True,True,True,True,True]
-- CHECK: record: [True,True,True,True,True,True]
-- CHECK: tuple: [True,True,True,True,True,True]
-- CHECK: maybeTuple: [True,True,True,True,True,True]
-- CHECK: strings: [True,True,True,True,True,True]
-- CHECK: floats: [True,True,True,True,True,True]
-- CHECK: wrapperValues: [True,True,True,True,True,True]
-- CHECK: crossForms: [True,True,True,True,True]

import SeqDict exposing (SeqDict)
import System
import Task


type Id
    = Id Int


type Opt
    = None
    | Some ( Int, Int )


type Shape
    = Dot
    | Circle Float
    | Box { w : Int, h : Int }


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


{-| Distinct `keys`, each mapped to `value i` for its position `i`.
-}
exercise : (Int -> v) -> (v -> v) -> List k -> List Bool
exercise value bump keys =
    let
        pairs =
            List.indexedMap (\i k -> ( k, value i )) keys

        d =
            SeqDict.fromList pairs

        ( evens, odds ) =
            List.partition (\( i, _ ) -> modBy 2 i == 0) (List.indexedMap Tuple.pair pairs)
                |> Tuple.mapBoth (List.map Tuple.second) (List.map Tuple.second)

        removed =
            List.foldl (\( k, _ ) acc -> SeqDict.remove k acc) d evens

        updated =
            List.foldl (\k acc -> SeqDict.update k (Maybe.map bump) acc) removed keys
    in
    [ List.all (\( k, v ) -> SeqDict.get k d == Just v) pairs
    , SeqDict.toList removed == odds
    , SeqDict.toList updated == List.map (Tuple.mapSecond bump) odds
    , removed == SeqDict.fromList odds
    , SeqDict.unorderedEquals removed (SeqDict.fromList (List.reverse odds))
    , SeqDict.foldr (\k v acc -> ( k, v ) :: acc) [] updated == SeqDict.toList updated
    ]


intKeys : (Int -> k) -> List k
intKeys f =
    List.map f (List.range 0 40)


report : () -> ()
report () =
    let
        _ =
            Debug.log "wrapper" (exercise identity ((+) 1) (intKeys Id))

        _ =
            Debug.log "maybeShaped"
                (exercise identity
                    ((+) 1)
                    (None
                        :: intKeys (\i -> Some ( i, i * 3 ))
                    )
                )

        _ =
            Debug.log "tagged"
                (exercise identity
                    ((+) 1)
                    (Dot
                        :: intKeys (\i -> Circle (toFloat i / 2))
                        ++ intKeys (\i -> Box { w = i, h = 40 - i })
                    )
                )

        _ =
            Debug.log "record" (exercise identity ((+) 1) (intKeys (\i -> { name = String.fromInt i, size = i })))

        _ =
            Debug.log "tuple" (exercise identity ((+) 1) (intKeys (\i -> ( i, String.fromInt i, i * 2 ))))

        _ =
            Debug.log "maybeTuple" (exercise identity ((+) 1) (Nothing :: intKeys (\i -> Just ( i, i ))))

        _ =
            Debug.log "strings"
                (exercise identity
                    ((+) 1)
                    ([ "literal", "con" ++ "catenated", String.slice 2 9 "xxsliced!yy", String.fromList [ 'l', 'i', 's', 't' ], "" ]
                        ++ intKeys (\i -> String.concat (List.repeat 30 (String.fromInt i)))
                    )
                )

        _ =
            Debug.log "floats" (exercise identity ((+) 1) [ 0.0, 1.5, -2.25, 1 / 0, -1 / 0, 1.0e300, 3.0e-300 ])

        _ =
            Debug.log "wrapperValues" (exercise Id (\(Id n) -> Id (n + 1)) (intKeys String.fromInt))

        byLiteral =
            SeqDict.fromList [ ( "hello world", 1 ), ( String.repeat 50 "ab", 2 ) ]

        _ =
            Debug.log "crossForms"
                [ SeqDict.get ("hello " ++ "world") byLiteral == Just 1
                , SeqDict.get (String.slice 1 12 "_hello world_") byLiteral == Just 1
                , SeqDict.get (String.concat (List.repeat 25 "abab")) byLiteral == Just 2
                , SeqDict.get (String.fromList (String.toList "hello world")) byLiteral == Just 1
                , SeqDict.get -0.0 (SeqDict.fromList [ ( 0.0, 1 ) ]) == Just 1
                ]
    in
    ()
