module Compiler.MonoOpt.InlineSimplifyWhitelistTest exposing (suite)

{-| Tests that the post-mono inliner's whitelist and blacklist name functions
by package (plans/seqdict-hash-once-per-function.md, A1), through
`InlineSimplify.resolveInlineNames` and `InlineSimplify.isWhitelisted`, and
that `InlineSimplify.unmatchedBareNames` warns about a bare name that matches
only another package's definition.

The tests establish:

  - A qualified entry matches its package's definition and not a definition of
    the same `Module.name` in another package.
  - A bare entry matches the root package's definition only.
  - A record accessor never matches.
  - An entry that does not parse matches nothing.
  - `unmatchedBareNames` warns for a bare configured name that names no
    definition of the program but one of another package, with the qualified
    form, and not for a qualified name or a bare name of the program.

-}

import Array
import Compiler.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.InlineSimplify as InlineSimplify
import Data.BitSet as BitSet
import Dict
import Expect
import Set
import Test exposing (Test)


{-| The whitelist tests, as the module docstring lists them.
-}
suite : Test
suite =
    let
        names =
            InlineSimplify.resolveInlineNames "author/project"
                [ "eco/system:SeqDict.get", "Utils.Bytes.Encode.int", "not a name" ]

        global pkg moduleName name =
            Mono.Global (ModuleName.Canonical pkg moduleName) name
    in
    Test.describe "inliner whitelist names"
        [ Test.test "a qualified entry matches its own package" <|
            \_ -> Expect.equal True (InlineSimplify.isWhitelisted names (global ( "eco", "system" ) "SeqDict" "get"))
        , Test.test "a qualified entry does not match another package's module of that name" <|
            \_ -> Expect.equal False (InlineSimplify.isWhitelisted names (global ( "author", "project" ) "SeqDict" "get"))
        , Test.test "a bare entry matches the root package" <|
            \_ -> Expect.equal True (InlineSimplify.isWhitelisted names (global ( "author", "project" ) "Utils.Bytes.Encode" "int"))
        , Test.test "a bare entry does not match another package" <|
            \_ -> Expect.equal False (InlineSimplify.isWhitelisted names (global ( "some", "lib" ) "Utils.Bytes.Encode" "int"))
        , Test.test "an accessor never matches" <|
            \_ -> Expect.equal False (InlineSimplify.isWhitelisted names (Mono.Accessor "get"))
        , Test.test "an entry that does not parse matches nothing" <|
            \_ -> Expect.equal 2 (Set.size names)
        , Test.test "unmatchedBareNames warns about a bare name of another package only" <|
            \_ ->
                let
                    inline =
                        Config.default.inline

                    cfg =
                        { inline | whitelist = [ "SeqDict.get", "eco/system:SeqDict.member", "Main.main" ] }
                in
                Expect.equal
                    [ "inline: \"SeqDict.get\" names no definition of this program; did you mean \"eco/system:SeqDict.get\"?" ]
                    (InlineSimplify.unmatchedBareNames cfg testGraph)
        ]


{-| A graph whose `main` is `Main.main` of `author/project` and which also has
specializations of `SeqDict.get` and `SeqDict.member` of `eco/system`.
-}
testGraph : Mono.MonoGraph
testGraph =
    let
        ty =
            Mono.MInt

        mainHome =
            ModuleName.Canonical ( "author", "project" ) "Main"

        seqDict =
            ModuleName.Canonical ( "eco", "system" ) "SeqDict"
    in
    Mono.MonoGraph
        { nodes = Array.fromList [ Nothing, Nothing, Nothing ]
        , main = Mono.StaticMain 0
        , registry =
            { nextId = 3
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping =
                Array.fromList
                    [ Just ( Mono.Global mainHome "main", ty )
                    , Just ( Mono.Global seqDict "get", ty )
                    , Just ( Mono.Global seqDict "member", ty )
                    ]
            , countByGlobal = Dict.empty
            }
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 0
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = []
        , flagsDecoder = Nothing
        , flagsSchema = ""
        , lssMemberOrigins = Dict.empty
        , lssMemberKinds = Dict.empty
        , lssBlockedMembers = Dict.empty
        , repr = Mono.emptyReprInfo
        }
