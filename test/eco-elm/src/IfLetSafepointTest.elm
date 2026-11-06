module IfLetSafepointTest exposing (main)

{-| A function whose let bindings are each an `if`-`then`-`else`, followed by building a list from them, returns the right string.

`process` binds `prefix`, `child` and `suffix` in turn, each with an `if` whose
`else` branch calls a helper that does a `case` on a `Tree`, and then conses
`prefix ++ "-" ++ suffix` onto a list. For `Node "hello" (Node "world" Leaf Leaf) Leaf`
the first element is `"hello-world"`.

## eco

Exercises safepoint placement in MLIR generation. Each let binding is an
if-then-else, compiled as an `eco.case` on Bool, whose else branch creates
local bindings. The final cons allocates and so gets a safepoint. If variable
mappings created inside the if-branch regions leaked out, the safepoint would
reference SSA values defined inside those `eco.case` regions and the MLIR
would fail to parse.

-}

-- CHECK: result: "hello-world"

import Html exposing (text)


type Tree
    = Leaf
    | Node String Tree Tree


getLabel : Tree -> String
getLabel tree =
    case tree of
        Node s _ _ ->
            s

        Leaf ->
            ""


getLeft : Tree -> Tree
getLeft tree =
    case tree of
        Node _ left _ ->
            left

        Leaf ->
            Leaf


{-| Conses `prefix ++ "-" ++ suffix` onto `acc`, where `prefix` is the label of
`tree` (or `fallback` for a `Leaf`) and `suffix` is the label of its left child
(or `""` when that is a `Leaf`).
-}
process : Tree -> String -> List String -> List String
process tree fallback acc =
    let
        prefix =
            if tree == Leaf then
                fallback
            else
                getLabel tree

        child =
            if tree == Leaf then
                Leaf
            else
                getLeft tree

        suffix =
            if child == Leaf then
                ""
            else
                getLabel child
    in
    (prefix ++ "-" ++ suffix) :: acc


main =
    let
        tree =
            Node "hello" (Node "world" Leaf Leaf) Leaf

        result =
            process tree "empty" []

        _ =
            Debug.log "result"
                (case result of
                    x :: _ ->
                        x

                    [] ->
                        "empty"
                )
    in
    text "done"
