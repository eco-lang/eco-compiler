module TaggedUnionDerefExtTest exposing (main)

{-| `TaggedUnionTest` with compiled code reading heap words through the
out-of-line entry points (`ECO_INLINE_DEREF_EXT=0`), which never receive a tagged
word (HEAP_086; validate builds abort if one does). Custom types with several constructors, one of which has a single boxed
field: `Shape` (nullary, a String field, an Int field, two fields), `Result
String Rec`, and a recursive `Expr`. Values are matched with `case`, compared
with `==` (two constructors over one String are different), printed with
`Debug.toString`, and held in records, lists, arrays, `Dict` values, closures
and a top-level constant; constructors are used as functions. No `Maybe` of
`Shape` appears, since a nullable `Maybe`'s payload is never tagged.

## eco

Each constructor whose one field is boxed (`Named`, `Ok`, `Err`, `Var`)
is represented without allocation, as its field's word tagged with the
constructor's index (plans/constructor-representation-followups.md F1,
HEAP_086); the others are null-cons words and heap objects as before.

-}

-- ENV: ECO_INLINE_DEREF_EXT=0
-- CHECK: shapes: [Empty,Named "a",Sized 3,Pair "p" 4,Named ""]
-- CHECK: describe: ["empty","named a","sized 3","pair p 4","named "]
-- CHECK: eqs: [True,False,False,True,False]
-- CHECK: results: [Ok { n = 1 },Err "bad"]
-- CHECK: resultN: [1,0]
-- CHECK: eval: -9
-- CHECK: exprs: Add (Lit 3) (Neg (Add (Lit 10) (Var "ab")))
-- CHECK: inRecord: { s = Named "r" }
-- CHECK: inArray: [Named "x",Named "y"]
-- CHECK: dict: [(1,Named "d"),(2,Empty)]
-- CHECK: closure: "named c"
-- CHECK: topLevel: Named "top"
-- CHECK: mapped: [Named "m1",Named "m2"]
-- CHECK: churn: 3000000
-- CHECK: after: [Empty,Named "a",Sized 3,Pair "p" 4,Named ""]
-- CHECK: afterExpr: -9

import Array
import Dict
import Html exposing (text)


type Shape
    = Empty
    | Named String
    | Sized Int
    | Pair String Int


type alias Rec =
    { n : Int }


type Expr
    = Lit Int
    | Var String
    | Neg Expr
    | Add Expr Expr


topLevel : Shape
topLevel =
    Named "top"


describe : Shape -> String
describe s =
    case s of
        Empty ->
            "empty"

        Named name ->
            "named " ++ name

        Sized k ->
            "sized " ++ String.fromInt k

        Pair a b ->
            "pair " ++ a ++ " " ++ String.fromInt b


eval : Expr -> Int
eval e =
    case e of
        Lit k ->
            k

        Var name ->
            String.length name

        Neg x ->
            negate (eval x)

        Add a b ->
            eval a + eval b


resultN : Result String Rec -> Int
resultN r =
    case r of
        Ok rec ->
            rec.n

        Err _ ->
            0


main =
    let
        shapes =
            [ Empty, Named "a", Sized 3, Pair "p" 4, Named "" ]

        _ =
            Debug.log "shapes" shapes

        _ =
            Debug.log "describe" (List.map describe shapes)

        _ =
            Debug.log "eqs"
                [ Named "a" == Named "a"
                , Named "a" == Named "b"
                , Named "" == Empty
                , Pair "p" 4 == Pair "p" 4
                , Named "p" == Sized 4
                ]

        results : List (Result String Rec)
        results =
            [ Ok { n = 1 }, Err "bad" ]

        _ =
            Debug.log "results" results

        _ =
            Debug.log "resultN" (List.map resultN results)

        expr =
            Add (Lit 3) (Neg (Add (Lit 10) (Var "ab")))

        _ =
            Debug.log "eval" (eval expr)

        _ =
            Debug.log "exprs" expr

        _ =
            Debug.log "inRecord" { s = Named "r" }

        _ =
            Debug.log "inArray" (Array.toList (Array.fromList [ Named "x", Named "y" ]))

        _ =
            Debug.log "dict" (Dict.toList (Dict.fromList [ ( 1, Named "d" ), ( 2, Empty ) ]))

        f =
            \() -> describe (Named "c")

        _ =
            Debug.log "closure" (f ())

        _ =
            Debug.log "topLevel" topLevel

        _ =
            Debug.log "mapped" (List.map Named [ "m1", "m2" ])

        churn =
            List.range 1 3000000
                |> List.map (\i -> Named (String.fromInt i))
                |> List.filter (\s -> s /= Empty)
                |> List.length

        _ =
            Debug.log "churn" churn

        -- The values built before the churn, which ran minor collections, read again.
        _ =
            Debug.log "after" shapes

        _ =
            Debug.log "afterExpr" (eval expr)
    in
    text "done"
