module SeqDictKeyKindsTest exposing (main)

{-| SeqDict keys of every kind find their entries whatever form an equal key takes, because `FNV.hash`
(src/eco-system/FNV/FNVExports.cpp) hashes content, not representation, so it agrees with `==`.

  - Floats: 0 and -0 are one key; 1, 1.25 and 1.5 are three.
  - Strings built by `++`, `String.slice` and `String.fromList` find a literal's entry.
  - Records with their fields written in another order, custom types, tuples and lists.
  - Dicts built in another order, as keys.
  - Long Strings that differ only in their last unit, past 4,096 units (the String hash reads every
    unit), and keys that differ only beyond the hash's bounds (256 list items, 16 levels of nesting),
    which hash alike, so the trie must tell them apart with `==`.

A SeqDict used as a key is in SeqDictEqualityTest, with the other checks of `==` on SeqDicts.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: floats: [Just "b",Just "c",Just "zero"]
-- CHECK: floatSize: 4
-- CHECK: strings: [Just 1,Just 1,Just 1,Nothing]
-- CHECK: records: [Just "r",Nothing]
-- CHECK: customs: [Just 1,Just 2,Just 3,Just 4,Nothing]
-- CHECK: tuplesLists: [Just "t",Just "l",Nothing]
-- CHECK: dictKey: Just "d"
-- CHECK: longStrings: (Just 1,Just 2,2)
-- CHECK: longLists: (Just 1,Just 2,2)
-- CHECK: deepNesting: (Just 1,Just 2,2)
-- CHECK: chars: [Just "a",Just "e",Nothing]

import Dict
import SeqDict exposing (SeqDict)
import System
import Task


type Key
    = Num Int
    | Pair String Float
    | Wrapped (Maybe Key)
    | Empty


type Nest
    = Leaf Int
    | Node Nest


nest : Int -> Int -> Nest
nest depth leaf =
    if depth <= 0 then
        Leaf leaf

    else
        Node (nest (depth - 1) leaf)


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        floats =
            SeqDict.fromList [ ( 1.0, "a" ), ( 1.5, "b" ), ( 1.25, "c" ), ( -0.0, "minus zero" ) ]
                |> SeqDict.insert 0.0 "zero"

        _ =
            Debug.log "floats" [ SeqDict.get (3 / 2) floats, SeqDict.get (5 / 4) floats, SeqDict.get (0 * -1) floats ]

        _ =
            Debug.log "floatSize" (SeqDict.size floats)

        strings =
            SeqDict.singleton "hello world" 1

        _ =
            Debug.log "strings"
                [ SeqDict.get ("hello " ++ "world") strings
                , SeqDict.get (String.slice 2 13 "<<hello world>>") strings
                , SeqDict.get (String.fromList [ 'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd' ]) strings
                , SeqDict.get "hello World" strings
                ]

        records =
            SeqDict.singleton { name = "x", size = 2, ratio = 0.5 } "r"

        _ =
            Debug.log "records"
                [ SeqDict.get { ratio = 1 / 2, size = 1 + 1, name = "x" } records
                , SeqDict.get { name = "x", size = 2, ratio = 0.25 } records
                ]

        customs =
            SeqDict.fromList [ ( Num 1, 1 ), ( Pair "p" 2.5, 2 ), ( Wrapped (Just Empty), 3 ), ( Wrapped Nothing, 4 ) ]

        _ =
            Debug.log "customs"
                [ SeqDict.get (Num (2 - 1)) customs
                , SeqDict.get (Pair ("" ++ "p") 2.5) customs
                , SeqDict.get (Wrapped (Maybe.map identity (Just Empty))) customs
                , SeqDict.get (Wrapped Nothing) customs
                , SeqDict.get (Wrapped (Just (Num 1))) customs
                ]

        tuplesLists =
            SeqDict.fromList [ ( ( 1, 'x', 2.5 ), "t" ), ( ( 0, 'y', 0 ), "u" ) ]

        lists =
            SeqDict.singleton (List.range 1 10) "l"

        _ =
            Debug.log "tuplesLists"
                [ SeqDict.get ( 2 - 1, 'x', 5 / 2 ) tuplesLists
                , SeqDict.get (List.map (\i -> i + 1) (List.range 0 9)) lists
                , SeqDict.get (List.range 1 11) lists
                ]

        -- Equal Dicts built in different orders have different trees.
        _ =
            Debug.log "dictKey"
                (SeqDict.get (Dict.fromList [ ( 3, "z" ), ( 1, "x" ), ( 2, "y" ) ])
                    (SeqDict.singleton (Dict.fromList [ ( 1, "x" ), ( 2, "y" ), ( 3, "z" ) ]) "d")
                )

        -- Long Strings differing only at the end; past the hash's bounds lists and nesting collide,
        -- and `==` must separate them.
        longA =
            String.repeat 5000 "a" ++ "1"

        longB =
            String.repeat 5000 "a" ++ "2"

        byString =
            SeqDict.fromList [ ( longA, 1 ), ( longB, 2 ) ]

        _ =
            Debug.log "longStrings"
                ( SeqDict.get (String.repeat 2500 "aa" ++ "1") byString, SeqDict.get longB byString, SeqDict.size byString )

        listA =
            List.range 1 400 ++ [ 1 ]

        listB =
            List.range 1 400 ++ [ 2 ]

        byList =
            SeqDict.fromList [ ( listA, 1 ), ( listB, 2 ) ]

        _ =
            Debug.log "longLists"
                ( SeqDict.get (List.range 1 400 ++ [ 2 - 1 ]) byList, SeqDict.get listB byList, SeqDict.size byList )

        byNest =
            SeqDict.fromList [ ( nest 30 1, 1 ), ( nest 30 2, 2 ) ]

        _ =
            Debug.log "deepNesting" ( SeqDict.get (nest 30 1) byNest, SeqDict.get (Node (nest 29 2)) byNest, SeqDict.size byNest )

        chars =
            SeqDict.fromList [ ( 'a', "a" ), ( 'é', "e" ) ]

        _ =
            Debug.log "chars"
                [ SeqDict.get (String.uncons "abc" |> Maybe.map Tuple.first |> Maybe.withDefault '?') chars
                , SeqDict.get (Char.fromCode 233) chars
                , SeqDict.get 'A' chars
                ]
    in
    ()

