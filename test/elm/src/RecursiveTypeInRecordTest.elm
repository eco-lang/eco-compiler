module RecursiveTypeInRecordTest exposing (main)

{-| Test recursive type nested in record field. -}

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
