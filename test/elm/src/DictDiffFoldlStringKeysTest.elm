module DictDiffFoldlStringKeysTest exposing (main)

{-| `Dict.diff` between two `String`-keyed dicts, followed by `Dict.foldl` over
the result, keeps exactly the keys missing from the second dict.

The first dict maps sixteen module-name strings to their positions 0 to 15; the
second holds the first eight of them. The test logs `True` when the difference
has size 8, its values sum to 8 + 9 + ... + 15 when folded with `Dict.foldl`, and
its keys are the last eight names in sorted order.

-}

-- CHECK: ok: True

import Dict exposing (Dict)
import Html exposing (text)


keys : List String
keys =
    [ "Compiler.Reporting.Annotation"
    , "Compiler.Reporting.Error.Syntax"
    , "Compiler.AST.Canonical"
    , "Compiler.AST.Optimized"
    , "Compiler.AST.Source"
    , "Compiler.Data.Name"
    , "Compiler.Data.OneOrMore"
    , "Compiler.Elm.Package"
    , "Compiler.Elm.Version"
    , "Compiler.Parse.Primitives"
    , "Compiler.Parse.Symbol"
    , "Compiler.Type.Type"
    , "Builder.Build"
    , "Builder.Reporting"
    , "Builder.File"
    , "Builder.Stuff"
    ]


buildDict : List String -> Dict String Int
buildDict =
    List.indexedMap (\i k -> ( k, i )) >> Dict.fromList


main =
    let
        all =
            buildDict keys

        half =
            buildDict (List.take 8 keys)

        remaining =
            Dict.diff all half

        sumIndexes =
            Dict.foldl (\_ v acc -> acc + v) 0 remaining

        expectedKeys =
            List.drop 8 keys

        expectedSum =
            List.sum (List.indexedMap (\i _ -> i + 8) expectedKeys)

        ok =
            Dict.size remaining
                == 8
                && sumIndexes
                == expectedSum
                && Dict.keys remaining
                == List.sort expectedKeys

        _ =
            Debug.log "ok" ok
    in
    text "done"
