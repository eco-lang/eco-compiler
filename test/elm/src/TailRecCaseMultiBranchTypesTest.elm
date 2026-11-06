module TailRecCaseMultiBranchTypesTest exposing (main)

{-| A self tail-recursive search whose outer `case` has one branch per constructor of a
custom type at the head of a list, with a nested `case` on a `String` inside one branch,
finds the right element.

`findEndianness` walks a list of `Expr`, counting positions from `idx`, and stops at the
first `Var "LE"` or `Var "BE"`; every other element is skipped by a tail call. In
`[ Lit 1, Call "foo" [], Var "LE", Var "other" ]` that is position 2.
-}

-- CHECK: result: "found LE at 2"

import Html exposing (text)


type Expr
    = Var String
    | Call String (List Expr)
    | Lit Int


findEndianness : List Expr -> Int -> String
findEndianness exprs idx =
    case exprs of
        [] ->
            "not found"

        (Var name) :: rest ->
            case name of
                "LE" ->
                    "found LE at " ++ String.fromInt idx

                "BE" ->
                    "found BE at " ++ String.fromInt idx

                _ ->
                    findEndianness rest (idx + 1)

        (Call _ _) :: rest ->
            findEndianness rest (idx + 1)

        (Lit _) :: rest ->
            findEndianness rest (idx + 1)


main =
    let
        exprs =
            [ Lit 1, Call "foo" [], Var "LE", Var "other" ]

        _ = Debug.log "result" (findEndianness exprs 0)
    in
    text "done"
