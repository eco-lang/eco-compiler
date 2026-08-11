module AppendTypeSplitTest exposing (main)

{-| kernel-opt-05: `++` at mono sites that statically know the operand type
lowers to `eco.string.append` / `eco.list.append` instead of the polymorphic
`Elm_Kernel_Utils_append`, which re-derives the type at runtime from two tag
loads and silently returns its first argument for any pair it does not
recognise.

Behaviour must be IDENTICAL in both flavours, so this fixture pins behaviour.
Both typed exports reach the SAME backends the polymorphic kernel reaches, so
the cases below deliberately cover the full shape domain rather than just flat
leaves: an operand may be a rope, a slice/view, a chunk spine, or an embedded
constant (`""` and `[]` are both `Const_Empty`, for which `Export::toPtr`
yields null and the wrapper's own guard answers).

The `appendable`-polymorphic helper is here to exercise the residue path: if
mono settles it to concrete String and List specializations both become typed
ops, and if any site stays an `MVar` it falls through `utilsIntrinsic`'s final
wildcard and keeps the kernel call. Either way the answer must not change.

-}

-- CHECK: strs: "foobar"
-- CHECK: strEmptyR: "foo"
-- CHECK: strEmptyL: "foo"
-- CHECK: strBothEmpty: ""
-- CHECK: ropeLen: 40000
-- CHECK: sliceAppend: "llohel"
-- CHECK: ropeThenSlice: "ab"
-- CHECK: lists: [1, 2, 3, 4]
-- CHECK: listEmptyR: [1, 2]
-- CHECK: listEmptyL: [1, 2]
-- CHECK: listBothEmpty: []
-- CHECK: chunkAppend: [2, 4, 6, 1]
-- CHECK: nested: "abcdef"
-- CHECK: polyStr: "hihi"
-- CHECK: polyList: [7, 7]

import Html exposing (text)


{-| Both operands are flat leaves.
-}
strs : String
strs =
    "foo" ++ "bar"


{-| Above STRING\_FLATTEN\_LIMIT (32768 units): append builds a rope rather than
flattening, so the result is a Tag\_StringRope.
-}
ropeStr : String
ropeStr =
    String.repeat 20000 "a" ++ String.repeat 20000 "b"


{-| Both operands are interior views over the same source string.
-}
sliceAppend : String
sliceAppend =
    String.slice 2 5 "hello" ++ String.slice 0 3 "hello"


{-| A slice OF a rope: the operand is a view whose base is not a flat leaf.
-}
ropeThenSlice : String
ropeThenSlice =
    String.slice 19999 20001 ropeStr


{-| Cons spines from literals.
-}
lists : List Int
lists =
    [ 1, 2 ] ++ [ 3, 4 ]


{-| A combinator-produced spine (which the chunked-list representation may
build as Tag\_ConsChunk) appended to a literal.
-}
chunkAppend : List Int
chunkAppend =
    List.map (\x -> x * 2) [ 1, 2, 3 ] ++ [ 1 ]


{-| Nested appends: the result of one append is an operand of the next.
-}
nested : String
nested =
    ("ab" ++ "cd") ++ "ef"


{-| `appendable`-polymorphic, used at both String and List.
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
