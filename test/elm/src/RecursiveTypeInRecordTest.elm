module RecursiveTypeInRecordTest exposing (main)

{-| Checks that a custom type can recurse through a record carried by one of its constructors.

`Expr` has a constructor `Add` whose payload is a record with two `Expr` fields. The test
evaluates `Add { left = Lit 1, right = Add { left = Lit 2, right = Lit 3 } }` by pattern
matching and field access, and expects `6`.
-}

-- CHECK: eval: 6

import Html exposing (text)


type Expr
    = Lit Int
    | Add { left : Expr, right : Expr }


eval : Expr -> Int
eval expr =
    case expr of
        Lit n ->
            n

        Add r ->
            eval r.left + eval r.right


main =
    let
        e =
            Add { left = Lit 1, right = Add { left = Lit 2, right = Lit 3 } }

        _ =
            Debug.log "eval" (eval e)
    in
    text "done"
