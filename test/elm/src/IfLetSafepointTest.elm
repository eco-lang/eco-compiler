module IfLetSafepointTest exposing (main)

{-| Tests that safepoints after sequential if-then-else let bindings
do not reference values from inside if-branch regions.

Each let binding uses an if-then-else (compiled as eco.case on Bool).
The else branches create local bindings (via nested case, function calls).
After all bindings, an allocation (list cons) triggers a safepoint.
If varMappings leak from inside if-branches, the safepoint will reference
SSA values from inside eco.case regions, causing an MLIR parse error.
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


{-| Sequential let bindings where each uses if-then-else.
The else branches create local varMappings that must not leak.
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
    -- This cons allocation triggers a safepoint.
    -- The safepoint must NOT reference SSA values from inside
    -- the if-branch regions above.
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
