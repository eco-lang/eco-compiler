module DictDiffFoldlStringKeysTest exposing (main)

{-| Test: Dict.diff followed by Dict.foldl over a Dict with String keys.

Targets the Stage 7 bootstrap crash signature (2026-04-24): a specialized
`Dict_foldl_$_22024` called from `Dict_diff_$_21988` in the native compiler's
`Builder.Build.crawlNewDeps` crashed with unbounded recursion because a Dict
node 3 levels deep had a null `left` field (hptr=0) instead of
`RBEmpty_elm_builtin`. The runtime's `eco_get_tag(0)` doesn't return the Empty
tag, so folding never terminated.

This small test exercises the same code path (Dict.diff on two String-keyed
Dicts, then Dict.foldl over the result) but does not exert heavy GC pressure,
so it may not reproduce the intermittent bug. See `DictDiffFoldlStress.elm`
for the stress version.
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

        -- Dict.diff removes keys present in `half` from `all`.
        -- Reproduces the Dict.diff + Dict.foldl pattern from crawlNewDeps.
        remaining =
            Dict.diff all half

        -- Fold the result to force traversal of every node (the crash path).
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
