module AppendTypeSplitTest exposing (main)

{-| `++` gives the right result on `String`s and `List`s, including empty operands, a long string, slices, nested appends, and a function whose type is `appendable`.

Each of `String` and `List` is appended with an empty operand on the left, on
the right, and on both sides. The string cases also append a 140,000-character
string built by `++`, slices of a string, and a slice taken across the join of
the long string. The list cases also append a list produced by `List.map`.

-}

-- CHECK: strs: "foobar"
-- CHECK: strEmptyR: "foo"
-- CHECK: strEmptyL: "foo"
-- CHECK: strBothEmpty: ""
-- CHECK: ropeLen: 140000
-- CHECK: sliceAppend: "llohel"
-- CHECK: ropeThenSlice: "ab"
-- CHECK: lists: [1,2,3,4]
-- CHECK: listEmptyR: [1,2]
-- CHECK: listEmptyL: [1,2]
-- CHECK: listBothEmpty: []
-- CHECK: chunkAppend: [2,4,6,1]
-- CHECK: nested: "abcdef"
-- CHECK: polyStr: "hihi"
-- CHECK: polyList: [7,7]

import Html exposing (text)


{-| Two string literals appended.
-}
strs : String
strs =
    "foo" ++ "bar"


{-| A 140,000-character string: 70,000 `a`s appended to 70,000 `b`s.
-}
ropeStr : String
ropeStr =
    String.repeat 70000 "a" ++ String.repeat 70000 "b"


{-| Two slices of the same string appended.
-}
sliceAppend : String
sliceAppend =
    String.slice 2 5 "hello" ++ String.slice 0 3 "hello"


{-| The two characters on either side of the join in `ropeStr`.
-}
ropeThenSlice : String
ropeThenSlice =
    String.slice 69999 70001 ropeStr


{-| Two list literals appended.
-}
lists : List Int
lists =
    [ 1, 2 ] ++ [ 3, 4 ]


{-| A list produced by `List.map` appended to a list literal.
-}
chunkAppend : List Int
chunkAppend =
    List.map (\x -> x * 2) [ 1, 2, 3 ] ++ [ 1 ]


{-| Three strings appended, where the left operand is itself an append.
-}
nested : String
nested =
    ("ab" ++ "cd") ++ "ef"


{-| Returns `x` appended to itself. Its type is `appendable`, and the test uses it
at `String` and at `List`.
-}
twice : appendable -> appendable
twice x =
    x ++ x


main : Html.Html msg
main =
    let
        _ =
            Debug.log "strs" strs

        _ =
            Debug.log "strEmptyR" ("foo" ++ "")

        _ =
            Debug.log "strEmptyL" ("" ++ "foo")

        _ =
            Debug.log "strBothEmpty" ("" ++ "")

        _ =
            Debug.log "ropeLen" (String.length ropeStr)

        _ =
            Debug.log "sliceAppend" sliceAppend

        _ =
            Debug.log "ropeThenSlice" ropeThenSlice

        _ =
            Debug.log "lists" lists

        _ =
            Debug.log "listEmptyR" ([ 1, 2 ] ++ [])

        _ =
            Debug.log "listEmptyL" ([] ++ [ 1, 2 ])

        _ =
            Debug.log "listBothEmpty" ([] ++ [])

        _ =
            Debug.log "chunkAppend" chunkAppend

        _ =
            Debug.log "nested" nested

        _ =
            Debug.log "polyStr" (twice "hi")

        _ =
            Debug.log "polyList" (twice [ 7 ])
    in
    text "done"
