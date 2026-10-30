module DebugToStringTest exposing (main)

{-| Debug.toString of every kind of value, recorded from Elm on node (run-js-e2e.js --record),
so eco's printer can be compared with Elm's exactly: lists and tuples (no space after the
comma), records (spaces), constructor arguments (parenthesised when they contain a space),
Floats (JS number formatting), Strings and Chars with escapes, and the Dict, Set and Array
forms.
-}

-- CHECK: list int: "[1,2,3]"
-- CHECK: list empty: "[]"
-- CHECK: list nested: "[[1],[],[2,3]]"
-- CHECK: tuple2: "(1,\"a\")"
-- CHECK: tuple3: "(1,2.5,'c')"
-- CHECK: unit: "()"
-- CHECK: record: "{ age = 3, name = \"x\" }"
-- CHECK: record nested: "{ a = { b = [1,2] }, c = (1,2) }"
-- CHECK: record empty: "{}"
-- CHECK: just int: "Just 1"
-- CHECK: just neg: "Just -1"
-- CHECK: just just: "Just (Just 1)"
-- CHECK: just list: "Just [1,2]"
-- CHECK: just string: "Just \"a b\""
-- CHECK: nothing: "Nothing"
-- CHECK: ok: "Ok 1"
-- CHECK: err: "Err \"bad\""
-- CHECK: ctor float: "Circle 1.5"
-- CHECK: ctor two: "Rect 2 3"
-- CHECK: ctor nested: "Named \"n\" (Just 4)"
-- CHECK: ctor nullary: "Empty"
-- CHECK: list ctor: "[Circle 1,Empty]"
-- CHECK: float 1.0: "1"
-- CHECK: float 0.1: "0.1"
-- CHECK: float 1/3: "0.3333333333333333"
-- CHECK: float 1e21: "1e+21"
-- CHECK: float 1e20: "100000000000000000000"
-- CHECK: float 1e-7: "1e-7"
-- CHECK: float 1e-6: "0.000001"
-- CHECK: float neg zero: "0"
-- CHECK: float -2.5: "-2.5"
-- CHECK: float max: "1.7976931348623157e+308"
-- CHECK: float min: "5e-324"
-- CHECK: int big: "9007199254740991"
-- CHECK: int neg: "-42"
-- CHECK: string plain: "\"hello\""
-- CHECK: string escapes: "\"a\\\"b\\\\c\\nd\\te\""
-- CHECK: string unicode: "22 E9 1F600 22"
-- CHECK: char: "'x'"
-- CHECK: char quote: "'\\''"
-- CHECK: char newline: "'\\n'"
-- CHECK: bool: "True"
-- CHECK: dict: "Dict.fromList [(1,\"a\"),(2,\"b\")]"
-- CHECK: set: "Set.fromList [1,2,3]"
-- CHECK: array: "Array.fromList [1,2]"
-- CHECK: dict empty: "Dict.fromList []"
-- CHECK: list float: "[1,2.5]"
-- CHECK: list string: "[\"a\",\"b\"]"
-- CHECK: tuple nested: "((1,2),[3])"

import Array
import ConformanceHelp exposing (cps, logAll, worker)
import Dict
import Set


type Shape
    = Circle Float
    | Rect Int Int
    | Named String (Maybe Int)
    | Empty


emptyInts : List Int
emptyInts =
    []


nothingInt : Maybe Int
nothingInt =
    Nothing


okInt : Result String Int
okInt =
    Ok 1


errInt : Result String Int
errInt =
    Err "bad"


emptyDict : Dict.Dict Int Int
emptyDict =
    Dict.empty


show : a -> String
show =
    Debug.toString


report : ()
report =
    logAll
        [ ( "list int", show [ 1, 2, 3 ] )
        , ( "list empty", show emptyInts )
        , ( "list nested", show [ [ 1 ], [], [ 2, 3 ] ] )
        , ( "tuple2", show ( 1, "a" ) )
        , ( "tuple3", show ( 1, 2.5, 'c' ) )
        , ( "unit", show () )
        , ( "record", show { name = "x", age = 3 } )
        , ( "record nested", show { a = { b = [ 1, 2 ] }, c = ( 1, 2 ) } )
        , ( "record empty", show {} )
        , ( "just int", show (Just 1) )
        , ( "just neg", show (Just -1) )
        , ( "just just", show (Just (Just 1)) )
        , ( "just list", show (Just [ 1, 2 ]) )
        , ( "just string", show (Just "a b") )
        , ( "nothing", show nothingInt )
        , ( "ok", show okInt )
        , ( "err", show errInt )
        , ( "ctor float", show (Circle 1.5) )
        , ( "ctor two", show (Rect 2 3) )
        , ( "ctor nested", show (Named "n" (Just 4)) )
        , ( "ctor nullary", show Empty )
        , ( "list ctor", show [ Circle 1, Empty ] )
        , ( "float 1.0", show 1.0 )
        , ( "float 0.1", show 0.1 )
        , ( "float 1/3", show (1 / 3) )
        , ( "float 1e21", show 1.0e21 )
        , ( "float 1e20", show 1.0e20 )
        , ( "float 1e-7", show 1.0e-7 )
        , ( "float 1e-6", show 1.0e-6 )
        , ( "float neg zero", show -0.0 )
        , ( "float -2.5", show -2.5 )
        , ( "float max", show 1.7976931348623157e308 )
        , ( "float min", show 5.0e-324 )
        , ( "int big", show 9007199254740991 )
        , ( "int neg", show -42 )
        , ( "string plain", show "hello" )
        , ( "string escapes", show "a\"b\\c\nd\te" )
        , ( "string unicode", cps (show "é😀") )
        , ( "char", show 'x' )
        , ( "char quote", show '\'' )
        , ( "char newline", show '\n' )
        , ( "bool", show True )
        , ( "dict", show (Dict.fromList [ ( 1, "a" ), ( 2, "b" ) ]) )
        , ( "set", show (Set.fromList [ 3, 1, 2 ]) )
        , ( "array", show (Array.fromList [ 1, 2 ]) )
        , ( "dict empty", show emptyDict )
        , ( "list float", show [ 1.0, 2.5 ] )
        , ( "list string", show [ "a", "b" ] )
        , ( "tuple nested", show ( ( 1, 2 ), [ 3 ] ) )
        ]


main : Program () () ()
main =
    worker report
