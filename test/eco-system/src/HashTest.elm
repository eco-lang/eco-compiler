module HashTest exposing (main)

{-| `Hash.hash` gives equal values equal hashes, whatever their representation: Strings built in
different ways (and, for lengths across the String hash's 32-unit rounds, flat copies, slices and
ropes of many short UTF-8 and UTF-16 leaves), `0` and `-0`, records, tuples, custom types (an erased wrapper, a Maybe-shaped type,
a tagged union), lists built by `::` and by `List.range`, Dicts and SeqDicts built in different
orders. No hash number is pinned: they differ between backends and programs.

-}

-- CHECK: strings: [True,True,True,True]
-- CHECK: forms: [True,True]
-- CHECK: numbers: [True,True,True]
-- CHECK: structures: [True,True,True,True,True,True]
-- CHECK: containers: [True,True,True]
-- CHECK: inRange: True

import Dict
import Hash
import SeqDict
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


same : a -> a -> Bool
same a b =
    a == b && Hash.hash a == Hash.hash b


report : () -> ()
report () =
    let
        _ =
            Debug.log "strings"
                [ same "hello world" ("hello " ++ "world")
                , same "hello world" (String.slice 1 12 "_hello world_")
                , same (String.repeat 3000 "ab") (String.concat (List.repeat 1500 "abab"))
                , same "" (String.left 0 "abc")
                ]

        -- k two-unit pieces, every 13th non-ASCII when `wide` (UTF-16 leaves among UTF-8 ones)
        pieces wide k =
            List.map
                (\i ->
                    String.fromInt (modBy 10 i)
                        ++ (if wide && modBy 13 i == 0 then
                                "\u{00E9}"

                            else
                                "x"
                           )
                )
                (List.range 1 k)

        -- `s`, a copy of it built from its Chars, and a slice of it out of a UTF-16 String
        formsOf s =
            let
                flat =
                    String.fromList (String.toList s)

                sliced =
                    String.slice 3 (3 + String.length s) ("ab\u{00E9}" ++ s ++ "xyz")
            in
            same s flat && same flat sliced

        -- every length: the joined pieces, and the same without their last unit
        allForms wide k =
            let
                joined =
                    String.concat (pieces wide k)
            in
            formsOf joined && formsOf (String.dropRight 1 joined)

        sizes =
            List.range 1 40 ++ [ 100, 70000 ]

        _ =
            Debug.log "forms" [ List.all (allForms False) sizes, List.all (allForms True) sizes ]

        _ =
            Debug.log "numbers" [ same 0.0 -0.0, same 42 (40 + 2), same 'x' (Char.fromCode 120) ]

        _ =
            Debug.log "structures"
                [ same ( 1, "a", 2.5 ) ( 0 + 1, "a", 5 / 2 )
                , same { a = 1, b = "x" } { b = "x", a = 1 }
                , same (Id 7) (Id (3 + 4))
                , same (Some ( 1, 2 )) (Some ( 1, 1 + 1 ))
                , same [ Dot, Circle 1.5, Box { w = 1, h = 2 } ] [ Dot, Circle (3 / 2), Box { h = 2, w = 1 } ]
                , same (List.range 1 300) (List.map identity (List.range 1 300))
                ]

        _ =
            Debug.log "containers"
                [ same (Dict.fromList [ ( 1, "a" ), ( 2, "b" ) ]) (Dict.fromList [ ( 2, "b" ), ( 1, "a" ) ])
                , same (SeqDict.fromList [ ( "k", 1 ) ]) (SeqDict.insert "k" 1 SeqDict.empty)
                , same (SeqDict.remove 2 (SeqDict.fromList [ ( 1, 1 ), ( 2, 2 ), ( 3, 3 ) ])) (SeqDict.fromList [ ( 1, 1 ), ( 3, 3 ) ])
                ]

        _ =
            Debug.log "inRange" (List.all (\h -> h >= 0 && h < 4294967296) (List.map Hash.hash [ "a", "b", "" ]))
    in
    ()
