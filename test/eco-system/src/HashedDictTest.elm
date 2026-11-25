module HashedDictTest exposing (main)

{-| `HashedDict` (plans/hashed-values-and-hash-consing.md H6) behaves as a `SeqDict` of the unwrapped
keys: every operation is checked against `SeqDict` on the same keys, in order. `SeqDict.lookup` and
`HashedDict.lookup` return the stored key and its value on a hit and `Nothing` on a miss.

-}

-- CHECK: lookup: [True,True,True,True]
-- CHECK: build: [True,True,True,True,True]
-- CHECK: query: [True,True,True,True,True]
-- CHECK: combine: [True,True,True,True]
-- CHECK: transform: [True,True,True,True,True,True]

import Hash exposing (Hashed, hashed, value)
import HashedDict exposing (HashedDict)
import SeqDict exposing (SeqDict)
import System
import Task


type alias Key =
    { path : List Int, name : String }


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


key : Int -> Key
key i =
    { path = List.range i (i + 20), name = "key-" ++ String.fromInt (modBy 7 i) }


pairs : Int -> Int -> List ( Key, Int )
pairs from to =
    List.map (\i -> ( key i, i * 10 )) (List.range from to)


hdict : List ( Key, v ) -> HashedDict Key v
hdict ps =
    HashedDict.fromList (List.map (\( k, v ) -> ( hashed k, v )) ps)


unwrap : HashedDict Key v -> List ( Key, v )
unwrap d =
    List.map (\( k, v ) -> ( value k, v )) (HashedDict.toList d)


same : HashedDict Key v -> SeqDict Key v -> Bool
same h s =
    unwrap h == SeqDict.toList s


report : () -> ()
report () =
    let
        ps =
            pairs 1 40

        h =
            hdict ps

        s =
            SeqDict.fromList ps

        h2 =
            hdict (pairs 30 60)

        s2 =
            SeqDict.fromList (pairs 30 60)

        probe =
            hashed (key 5)

        _ =
            Debug.log "lookup"
                [ SeqDict.lookup (key 5) s == Just ( key 5, 50 )
                , SeqDict.lookup (key 99) s == Nothing
                , Maybe.map (\( k, v ) -> ( value k, v )) (HashedDict.lookup probe h) == Just ( key 5, 50 )
                , HashedDict.lookup (hashed (key 99)) h == Nothing
                ]

        _ =
            Debug.log "build"
                [ same (HashedDict.insert (hashed (key 100)) 1 h) (SeqDict.insert (key 100) 1 s)
                , same (HashedDict.insert probe 7 h) (SeqDict.insert (key 5) 7 s)
                , same (HashedDict.remove probe h) (SeqDict.remove (key 5) s)
                , same (HashedDict.update probe (Maybe.map ((+) 1)) h) (SeqDict.update (key 5) (Maybe.map ((+) 1)) s)
                , same (HashedDict.updateIfExists probe ((*) 2) h) (SeqDict.updateIfExists (key 5) ((*) 2) s)
                ]

        _ =
            Debug.log "query"
                [ HashedDict.get probe h == SeqDict.get (key 5) s
                , HashedDict.member probe h && not (HashedDict.member (hashed (key 0)) h)
                , HashedDict.size h == SeqDict.size s
                , not (HashedDict.isEmpty h) && HashedDict.isEmpty HashedDict.empty
                , HashedDict.unorderedEquals h (hdict (List.reverse ps))
                ]

        _ =
            Debug.log "combine"
                [ same (HashedDict.union h h2) (SeqDict.union s s2)
                , same (HashedDict.intersect h h2) (SeqDict.intersect s s2)
                , same (HashedDict.diff h h2) (SeqDict.diff s s2)
                , HashedDict.merge (\k _ acc -> value k :: acc) (\k _ _ acc -> value k :: acc) (\k _ acc -> value k :: acc) h h2 []
                    == SeqDict.merge (\k _ acc -> k :: acc) (\k _ _ acc -> k :: acc) (\k _ acc -> k :: acc) s s2 []
                ]

        _ =
            Debug.log "transform"
                [ List.map value (HashedDict.keys h) == SeqDict.keys s && HashedDict.values h == SeqDict.values s
                , HashedDict.foldl (\_ v acc -> v :: acc) [] h == SeqDict.foldl (\_ v acc -> v :: acc) [] s
                , HashedDict.foldr (\_ v acc -> v :: acc) [] h == SeqDict.foldr (\_ v acc -> v :: acc) [] s
                , same (HashedDict.map (\_ v -> v + 1) h) (SeqDict.map (\_ v -> v + 1) s)
                , same (HashedDict.filter (\_ v -> v > 200) h) (SeqDict.filter (\_ v -> v > 200) s)
                    && same (HashedDict.filterMap (\_ v -> if v > 200 then Just v else Nothing) h) (SeqDict.filterMap (\_ v -> if v > 200 then Just v else Nothing) s)
                , Tuple.mapBoth unwrap unwrap (HashedDict.partition (\_ v -> v > 200) h)
                    == Tuple.mapBoth SeqDict.toList SeqDict.toList (SeqDict.partition (\_ v -> v > 200) s)
                ]
    in
    ()
