module SeqDictCollisionTest exposing (main)

{-| SeqDict with keys whose hashes collide in full, on either backend: natively, Strings equal in
their first 4096 units, lists equal in their first 256 items, and values that differ only below
nesting depth 16 (the native hash's bounds); on JS, Floats with the same integer part and the same
deep nesting. Each group is mixed with 2,000 Int keys, so that collision nodes are pushed below
branches that other keys share and are hoisted again when those keys go. For each group the checks
are: every key found; replacing a value inside a collision; removing collision keys one by one down
to none; removing all the Int keys first; the order kept throughout; and equality with a freshly
built dict.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: strings: [True,True,True,True,True,True,True]
-- CHECK: lists: [True,True,True,True,True,True,True]
-- CHECK: deep: [True,True,True,True,True,True,True]
-- CHECK: floats: [True,True,True,True,True,True,True]

import SeqDict exposing (SeqDict)
import System
import Task


type Nest
    = Bottom Int
    | Wrap Nest


nest : Int -> Int -> Nest
nest depth leaf =
    if depth <= 0 then
        Bottom leaf

    else
        Wrap (nest (depth - 1) leaf)


type Key a
    = Colliding a
    | Plain Int


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


group : List a -> List Bool
group colliding =
    let
        plain =
            List.map Plain (List.range 0 1999)

        coll =
            List.map Colliding colliding

        -- the colliding keys go in between the plain ones
        keys =
            List.take 1000 plain ++ coll ++ List.drop 1000 plain

        d =
            SeqDict.fromList (List.indexedMap (\i k -> ( k, i )) keys)

        firstColl =
            List.head coll

        replaced =
            case firstColl of
                Just k ->
                    SeqDict.insert k -1 d

                Nothing ->
                    d

        removeAll ks dict =
            List.foldl SeqDict.remove dict ks

        noPlain =
            removeAll plain d

        oneByOne =
            List.foldl
                (\k ( dict, ok ) ->
                    let
                        next =
                            SeqDict.remove k dict
                    in
                    ( next, ok && SeqDict.get k next == Nothing && SeqDict.size next == SeqDict.size dict - 1 )
                )
                ( d, True )
                coll
    in
    [ List.all (\( i, k ) -> SeqDict.get k d == Just i) (List.indexedMap Tuple.pair keys)
    , Maybe.andThen (\k -> SeqDict.get k replaced) firstColl == Just -1
    , SeqDict.keys replaced == keys
    , Tuple.second oneByOne
    , SeqDict.keys (Tuple.first oneByOne) == plain
    , SeqDict.keys noPlain == coll && List.all (\k -> SeqDict.member k noPlain) coll
    , noPlain == SeqDict.fromList (List.filter (\( k, _ ) -> List.member k coll) (List.indexedMap (\i k -> ( k, i )) keys))
    ]


report : () -> ()
report () =
    let
        prefix =
            String.repeat 4096 "x"

        _ =
            Debug.log "strings" (group [ prefix ++ "a", prefix ++ "b", prefix ++ "c" ])

        _ =
            Debug.log "lists" (group [ List.repeat 256 7 ++ [ 1 ], List.repeat 256 7 ++ [ 2 ], List.repeat 256 7 ++ [ 3 ] ])

        _ =
            Debug.log "deep" (group [ nest 20 1, nest 20 2, nest 20 3 ])

        _ =
            Debug.log "floats" (group [ 1.25, 1.5, 1.75 ])
    in
    ()
