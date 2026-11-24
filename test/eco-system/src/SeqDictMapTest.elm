module SeqDictMapTest exposing (main)

{-| `SeqDict.map` on tries of every shape: 20,000 Int keys with every seventh removed (a deep trie
over an order array with holes), colliding keys mixed with plain ones (collision nodes below shared
branches; natively Strings equal in their first 4096 units, on JS Floats with the same integer part),
the empty dict, one entry, and a map of a map. Values change type (Int to String, to Float, to a
record) and keep it (Int to Int). For each: the entries are those of `List.map` over `toList`, in
order; every key is found with its new value; the result equals a freshly built dict; and an insert
and a remove on the result give what they give on the fresh dict. The validator
(`ECO_SEQDICT_VALIDATE=1`) checks after each operation that the trie and the order array share each
entry (O2), which is what the kernel copy (`SeqDictTrie.remap`) must keep.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: deep: [True,True,True,True,True]
-- CHECK: deepUnboxed: [True,True,True,True,True]
-- CHECK: deepFloat: [True,True,True,True,True]
-- CHECK: deepRecord: [True,True,True,True,True]
-- CHECK: strings: [True,True,True,True,True]
-- CHECK: floats: [True,True,True,True,True]
-- CHECK: empty: [True,True,True,True,True]
-- CHECK: one: [True,True,True,True,True]
-- CHECK: twice: [True,True,True,True,True]

import SeqDict exposing (SeqDict)
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


{-| The checks for `mapped`, `SeqDict.map f d`, given `expected` (`List.map` of `f` over `toList d`),
`fresh` (`SeqDict.fromList expected`), `extraKey`/`extraValue` for the insert check and the first key
of `d`. The call sites build these, so that no let-bound value of this polymorphic function is
specialized at two types (test/elm/src/LetValueSpecializedAtTwoTypesTest.elm).
-}
check : SeqDict k b -> List ( k, b ) -> SeqDict k b -> k -> b -> Maybe k -> List Bool
check mapped expected fresh extraKey extraValue firstKey =
    let
        removeFirst dict =
            case firstKey of
                Just k ->
                    SeqDict.remove k dict

                Nothing ->
                    dict
    in
    [ SeqDict.toList mapped == expected
    , List.all (\( k, v ) -> SeqDict.get k mapped == Just v) expected && SeqDict.size mapped == List.length expected
    , mapped == fresh
    , SeqDict.toList (SeqDict.insert extraKey extraValue mapped) == SeqDict.toList (SeqDict.insert extraKey extraValue fresh)
    , SeqDict.toList (removeFirst mapped) == SeqDict.toList (removeFirst fresh)
    ]


emptyInts : SeqDict Int Int
emptyInts =
    SeqDict.empty


withHoles : SeqDict Int Int
withHoles =
    List.foldl
        (\k d ->
            if modBy 7 k == 0 then
                SeqDict.remove k d

            else
                d
        )
        (SeqDict.fromList (List.map (\k -> ( k, 3 * k )) (List.range 0 19999)))
        (List.range 0 19999)


colliding : List comparable -> SeqDict (Result comparable Int) Int
colliding coll =
    let
        plain =
            List.map Ok (List.range 0 1999)

        keys =
            List.take 1000 plain ++ List.map Err coll ++ List.drop 1000 plain
    in
    SeqDict.fromList (List.indexedMap (\i k -> ( k, i )) keys)


report : () -> ()
report () =
    let
        prefix =
            String.repeat 4096 "x"

        _ =
            let
                d =
                    withHoles

                f =
                    (\k v -> String.fromInt (k + v))

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "deep" (check (SeqDict.map f d) expected (SeqDict.fromList expected) -1 "new" (List.head (SeqDict.keys d)))

        _ =
            let
                d =
                    withHoles

                f =
                    (\k v -> k * 1000 + v)

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "deepUnboxed" (check (SeqDict.map f d) expected (SeqDict.fromList expected) -1 5 (List.head (SeqDict.keys d)))

        _ =
            let
                d =
                    withHoles

                f =
                    (\_ v -> toFloat v / 2)

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "deepFloat" (check (SeqDict.map f d) expected (SeqDict.fromList expected) -1 0.5 (List.head (SeqDict.keys d)))

        _ =
            let
                d =
                    withHoles

                f =
                    (\k v -> { key = k, twice = 2 * v })

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "deepRecord" (check (SeqDict.map f d) expected (SeqDict.fromList expected) -1 { key = 0, twice = 0 } (List.head (SeqDict.keys d)))

        _ =
            let
                d =
                    (colliding [ prefix ++ "a", prefix ++ "b", prefix ++ "c" ])

                f =
                    (\_ v -> v + 1)

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "strings" (check (SeqDict.map f d) expected (SeqDict.fromList expected) (Ok -5) 0 (List.head (SeqDict.keys d)))

        _ =
            let
                d =
                    (colliding [ 1.25, 1.5, 1.75 ])

                f =
                    (\_ v -> v + 1)

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "floats" (check (SeqDict.map f d) expected (SeqDict.fromList expected) (Ok -5) 0 (List.head (SeqDict.keys d)))

        _ =
            let
                d =
                    emptyInts

                f =
                    (\_ v -> v + 1)

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "empty" (check (SeqDict.map f d) expected (SeqDict.fromList expected) 1 1 (List.head (SeqDict.keys d)))

        _ =
            let
                d =
                    (SeqDict.singleton 1 1)

                f =
                    (\_ v -> v + 1)

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "one" (check (SeqDict.map f d) expected (SeqDict.fromList expected) 2 2 (List.head (SeqDict.keys d)))

        _ =
            let
                d =
                    (SeqDict.map (\_ v -> String.fromInt v) withHoles)

                f =
                    (\_ v -> v ++ "!")

                expected =
                    List.map (\( key, value ) -> ( key, f key value )) (SeqDict.toList d)
            in
            Debug.log "twice" (check (SeqDict.map f d) expected (SeqDict.fromList expected) -1 "x" (List.head (SeqDict.keys d)))
    in
    ()
