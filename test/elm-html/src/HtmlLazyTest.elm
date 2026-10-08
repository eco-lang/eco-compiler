module HtmlLazyTest exposing (main)

{-| `Html.Lazy.lazy`..`lazy8` evaluate eagerly at construction (D5), with
their arguments in order. (Eco evaluates list elements right to left, so
the log order is not checked.)
-}

-- CHECK-DAG: lazy1: [1]
-- CHECK-DAG: lazy2: [1, 2]
-- CHECK-DAG: lazy3: [1, 2, 3]
-- CHECK-DAG: lazy4: [1, 2, 3, 4]
-- CHECK-DAG: lazy5: [1, 2, 3, 4, 5]
-- CHECK-DAG: lazy6: [1, 2, 3, 4, 5, 6]
-- CHECK-DAG: lazy7: [1, 2, 3, 4, 5, 6, 7]
-- CHECK-DAG: lazy8: [1, 2, 3, 4, 5, 6, 7, 8]
-- CHECK: built: 8

import Html exposing (Html)
import Html.Lazy as Lazy


view : String -> List Int -> Html msg
view label args =
    let
        _ =
            Debug.log label args
    in
    Html.text label


main =
    let
        nodes =
            [ Lazy.lazy (\a -> view "lazy1" [ a ]) 1
            , Lazy.lazy2 (\a b -> view "lazy2" [ a, b ]) 1 2
            , Lazy.lazy3 (\a b c -> view "lazy3" [ a, b, c ]) 1 2 3
            , Lazy.lazy4 (\a b c d -> view "lazy4" [ a, b, c, d ]) 1 2 3 4
            , Lazy.lazy5 (\a b c d e -> view "lazy5" [ a, b, c, d, e ]) 1 2 3 4 5
            , Lazy.lazy6 (\a b c d e f -> view "lazy6" [ a, b, c, d, e, f ]) 1 2 3 4 5 6
            , Lazy.lazy7 (\a b c d e f g -> view "lazy7" [ a, b, c, d, e, f, g ]) 1 2 3 4 5 6 7
            , Lazy.lazy8 (\a b c d e f g h -> view "lazy8" [ a, b, c, d, e, f, g, h ]) 1 2 3 4 5 6 7 8
            ]

        _ =
            Debug.log "built" (List.length nodes)
    in
    Html.div [] nodes
