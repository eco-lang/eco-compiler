module TailRecCaseMultiBranchTypesTest exposing (main)

{-| Tail-recursive search with 4+ branches and nested string case.
Outer case on constructor list pattern, inner string dispatch for endianness.
Mimics Compiler.Generate.MLIR.BytesFusion.Reify.reifyEndianness.
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
