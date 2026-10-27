module Compiler.LocalOpt.Erased.DecisionTree exposing
    ( DecisionTree(..), Test, Path
    , compile
    )

{-| A `case` expression has to be turned into a sequence of runtime checks, and
this module decides which checks to make and in what order, for the erased
(JavaScript) path.

The value a `case` examines is the _scrutinee_. A _path_ names one part of it,
such as the second field of a tuple or the argument of a constructor, as
`Compiler.AST.DecisionTree.Path` describes. A _test_ is a question about the
value at a path, such as whether it was built with a particular constructor or
equals a particular literal, as `Compiler.AST.DecisionTree.Test` describes.
`compile` takes the patterns of one `case`, each paired with the index of its
branch, and returns a `DecisionTree`: a tree of tests whose leaves name the
branch to take.

The algorithm follows "When Do Match-Compilation Heuristics Matter?" by Kevin
Scott and Norman Ramsey. Each branch is kept as a list of the patterns still to
be checked, one per path. While the first remaining branch still has a pattern
that needs a test, the compiler picks a path, asks every branch what it needs
there, and splits the branches by the answer. Branch order is what gives a
`case` its first-match meaning: a leaf goes to the first branch whose remaining
patterns need no test.

Two heuristics choose the path. The first prefers the path that the fewest
branches do not care about, since those branches have to be copied into every
subtree. Among the paths that tie, the second prefers the one that splits the
branches into the fewest subtrees.

Before each step, patterns that need no test are flattened away: a constructor
of a type with only one constructor, a tuple and unit are replaced by their
parts, and an alias pattern `p as x` by `p` and the variable `x`.

@docs DecisionTree, Test, Path
@docs compile

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Path as Path
import Compiler.AST.DecisionTree.Test as Test
import Compiler.Data.Index as Index
import Compiler.Reporting.Annotation as A
import Data.Set as EverySet
import Prelude
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== COMPILE CASES ======


{-| Builds the decision tree for one `case`, given each branch's pattern
paired with the index of that branch, in source order.

Each `Match` in the result carries one of the given indices. A branch can be
reached by more than one leaf, and a branch that an earlier one shadows is
reached by none.

-}
compile : List ( Can.Pattern, Int ) -> DecisionTree
compile rawBranches =
    let
        format : ( Can.Pattern, Int ) -> Branch
        format ( pattern, index ) =
            Branch index [ ( Path.Empty, pattern ) ]
    in
    toDecisionTree (List.map format rawBranches)



-- ====== DECISION TREES ======


{-| A tree of runtime tests that chooses the branch of a `case` to take.

`Match` is a leaf, and carries the index of the branch to take, as given to
`compile`.

`Decision` examines the value at its path. Each edge pairs a test with the
subtree to follow when the value passes it, and the last part is the
_fallback_, the subtree for a value that passes none of the tests. The fallback
is `Nothing` exactly when the tests cover every possible value: every
constructor of the type, both `Bool` values, both empty and non-empty lists, or
a tuple. Tests on an `Int`, a `Char` or a `String` never cover every value, so
a decision on one always has a fallback.

-}
type DecisionTree
    = Match Int
    | Decision Path (List ( Test, DecisionTree )) (Maybe DecisionTree)


{-| A question about the value at one path, as `Compiler.AST.DecisionTree.Test`
describes. This is another name for that type, not a new one.
-}
type alias Test =
    Test.Test


{-| How to reach one part of the scrutinee, as `Compiler.AST.DecisionTree.Path`
describes. This is another name for that type, not a new one.
-}
type alias Path =
    Path.Path



-- ====== ACTUALLY BUILD DECISION TREES ======


{-| One branch of the `case` part-way through compilation: its index, and the
patterns it still needs to match, each paired with the path of the value it
applies to.
-}
type Branch
    = Branch Int (List ( Path, Can.Pattern ))


{-| Builds the decision tree for `rawBranches`, which are in source order.

A decision with one edge and no fallback is replaced by that edge's subtree,
since its test cannot fail.

-}
toDecisionTree : List Branch -> DecisionTree
toDecisionTree rawBranches =
    let
        branches : List Branch
        branches =
            List.map flattenPatterns rawBranches
    in
    case checkForMatch branches of
        Just goal ->
            Match goal

        Nothing ->
            let
                path : Path
                path =
                    pickPath branches

                ( edges, fallback ) =
                    gatherEdges branches path

                decisionEdges : List ( Test, DecisionTree )
                decisionEdges =
                    List.map (Tuple.mapSecond toDecisionTree) edges
            in
            case ( decisionEdges, fallback ) of
                ( [ ( _, decisionTree ) ], [] ) ->
                    decisionTree

                ( _, [] ) ->
                    Decision path decisionEdges Nothing

                ( [], _ :: _ ) ->
                    toDecisionTree fallback

                _ ->
                    Decision path decisionEdges (Just (toDecisionTree fallback))


{-| Tells whether `tests`, the distinct tests found at one path, cover every
value that can be there, judging by the kind of the first test: all of a type's
constructors, both `Bool` values, cons and nil, or a tuple. Tests on an `Int`,
a `Char` or a `String` are never complete. Crashes on an empty list.
-}
isComplete : List Test -> Bool
isComplete tests =
    case Prelude.head tests of
        Test.IsCtor _ _ _ numAlts _ ->
            numAlts == List.length tests

        Test.IsCons ->
            List.length tests == 2

        Test.IsNil ->
            List.length tests == 2

        Test.IsTuple ->
            True

        Test.IsInt _ ->
            False

        Test.IsChr _ ->
            False

        Test.IsStr _ ->
            False

        Test.IsBool _ ->
            List.length tests == 2



-- ====== FLATTEN PATTERNS ======


{-| Replaces each of a branch's patterns that needs no test by its parts, as
`flatten` does.
-}
flattenPatterns : Branch -> Branch
flattenPatterns (Branch goal pathPatterns) =
    Branch goal (List.foldr flatten [] pathPatterns)


{-| Adds a path and its pattern to the front of `otherPathPatterns`, first
taking apart any pattern that needs no test of its own.

A constructor of a type whose `numAlts` is 1 is replaced by its argument at
`Path.Unbox`, by its arguments at `Path.Index` positions when it has several,
and dropped when it has none. A tuple is replaced by its fields at `Path.Index`
positions, unit is dropped, and an alias `p as x` becomes `p` and the variable
`x` at the same path. The parts are flattened in turn. Any other pattern is kept as it is.

-}
flatten : ( Path, Can.Pattern ) -> List ( Path, Can.Pattern ) -> List ( Path, Can.Pattern )
flatten (( path, A.At region patternInfo ) as pathPattern) otherPathPatterns =
    case patternInfo.node of
        Can.PVar _ ->
            pathPattern :: otherPathPatterns

        Can.PAnything ->
            pathPattern :: otherPathPatterns

        Can.PCtor { union, args } ->
            let
                (Can.Union unionData) =
                    union
            in
            if unionData.numAlts == 1 then
                case List.map dearg args of
                    [ arg ] ->
                        flatten ( Path.Unbox path, arg ) otherPathPatterns

                    args_ ->
                        List.foldr flatten otherPathPatterns (subPositions path args_)

            else
                pathPattern :: otherPathPatterns

        Can.PTuple a b cs ->
            (a :: b :: cs)
                |> List.foldl
                    (\x ( index, acc ) ->
                        ( Index.next index
                        , ( Path.Index index path, x ) :: acc
                        )
                    )
                    ( Index.first, [] )
                |> Tuple.second
                |> List.foldl flatten otherPathPatterns

        Can.PUnit ->
            otherPathPatterns

        Can.PAlias realPattern alias ->
            flatten ( path, realPattern ) <|
                -- Use placeholder ID (-1) for synthesized patterns
                ( path, A.At region { id = -1, node = Can.PVar alias } )
                    :: otherPathPatterns

        Can.PRecord _ ->
            pathPattern :: otherPathPatterns

        Can.PList _ ->
            pathPattern :: otherPathPatterns

        Can.PCons _ _ ->
            pathPattern :: otherPathPatterns

        Can.PChr _ ->
            pathPattern :: otherPathPatterns

        Can.PStr _ _ ->
            pathPattern :: otherPathPatterns

        Can.PInt _ ->
            pathPattern :: otherPathPatterns

        Can.PBool _ _ ->
            pathPattern :: otherPathPatterns


{-| Pairs each pattern with the path to the field at its position below `path`.
-}
subPositions : Path -> List Can.Pattern -> List ( Path, Can.Pattern )
subPositions path patterns =
    Index.indexedMap (\index pattern -> ( Path.Index index path, pattern )) patterns


{-| Returns the pattern of a constructor argument.
-}
dearg : Can.PatternCtorArg -> Can.Pattern
dearg (Can.PatternCtorArg _ _ pattern) =
    pattern



-- ====== SUCCESSFULLY MATCH ======


{-| Returns the index of the first branch if none of its remaining patterns
needs a test, and `Nothing` otherwise or when there are no branches.
-}
checkForMatch : List Branch -> Maybe Int
checkForMatch branches =
    case branches of
        (Branch goal patterns) :: _ ->
            if List.all (Tuple.second >> needsTests >> not) patterns then
                Just goal

            else
                Nothing

        _ ->
            Nothing



-- ====== GATHER OUTGOING EDGES ======


{-| Splits `branches` by the tests found at `path`.

Each edge pairs one of the distinct tests at `path` with the branches that can
still match a value passing it. The second part is the fallback branches, those
that do not test `path`, and is empty when the tests are complete, as
`isComplete` decides.

-}
gatherEdges : List Branch -> Path -> ( List ( Test, List Branch ), List Branch )
gatherEdges branches path =
    let
        relevantTests : List Test
        relevantTests =
            testsAtPath path branches

        allEdges : List ( Test, List Branch )
        allEdges =
            List.map (edgesFor path branches) relevantTests

        fallbacks : List Branch
        fallbacks =
            if isComplete relevantTests then
                []

            else
                List.filter (isIrrelevantTo path) branches
    in
    ( allEdges, fallbacks )



-- ====== FIND RELEVANT TESTS ======


{-| Returns the distinct tests that `branches` make at `selectedPath`.
-}
testsAtPath : Path -> List Branch -> List Test
testsAtPath selectedPath branches =
    let
        allTests : List Test
        allTests =
            List.filterMap (testAtPath selectedPath) branches

        skipVisited : Test -> ( List Test, EverySet.EverySet String Test ) -> ( List Test, EverySet.EverySet String Test )
        skipVisited test (( uniqueTests, visitedTests ) as curr) =
            if EverySet.member Test.testToComparable test visitedTests then
                curr

            else
                ( test :: uniqueTests
                , EverySet.insert Test.testToComparable test visitedTests
                )
    in
    Tuple.first (List.foldr skipVisited ( [], EverySet.empty ) allTests)


{-| Returns the test a branch makes at `selectedPath`, or `Nothing` when it has
no pattern there or its pattern there needs no test. Crashes on an alias
pattern, which flattening has removed.
-}
testAtPath : Path -> Branch -> Maybe Test
testAtPath selectedPath (Branch _ pathPatterns) =
    Utils.listLookup selectedPath pathPatterns
        |> Maybe.andThen
            (\(A.At _ patternInfo) ->
                case patternInfo.node of
                    Can.PCtor { home, union, name, index } ->
                        let
                            (Can.Union unionData) =
                                union
                        in
                        Just (Test.IsCtor home name index unionData.numAlts unionData.opts)

                    Can.PList ps ->
                        Just
                            (case ps of
                                [] ->
                                    Test.IsNil

                                _ ->
                                    Test.IsCons
                            )

                    Can.PCons _ _ ->
                        Just Test.IsCons

                    Can.PTuple _ _ _ ->
                        Just Test.IsTuple

                    Can.PUnit ->
                        Just Test.IsTuple

                    Can.PVar _ ->
                        Nothing

                    Can.PAnything ->
                        Nothing

                    Can.PInt int ->
                        Just (Test.IsInt int)

                    Can.PStr str _ ->
                        Just (Test.IsStr str)

                    Can.PChr chr ->
                        Just (Test.IsChr chr)

                    Can.PBool _ bool ->
                        Just (Test.IsBool bool)

                    Can.PRecord _ ->
                        Nothing

                    Can.PAlias _ _ ->
                        crash "aliases should never reach 'testAtPath' function"
            )



-- ====== BUILD EDGES ======


{-| Pairs `test` with the branches that can still match a value at `path` that
passes it.
-}
edgesFor : Path -> List Branch -> Test -> ( Test, List Branch )
edgesFor path branches test =
    ( test
    , List.filterMap (toRelevantBranch test path) branches
    )


{-| Returns what remains of a branch once the value at `path` has passed `test`,
or `Nothing` when the branch's pattern there cannot match such a value.

A pattern that passes is replaced by the patterns for its parts, at the paths
below `path`. A branch with no pattern at `path`, or one that needs no test,
is returned unchanged.

-}
toRelevantBranch : Test -> Path -> Branch -> Maybe Branch
toRelevantBranch test path ((Branch goal pathPatterns) as branch) =
    case extract path pathPatterns of
        Found start (A.At region patternInfo) end ->
            case patternInfo.node of
                Can.PCtor { union, name, args } ->
                    case test of
                        Test.IsCtor _ testName _ _ _ ->
                            if name == testName then
                                Just
                                    (Branch goal <|
                                        case List.map dearg args of
                                            (arg :: []) as args_ ->
                                                let
                                                    (Can.Union unionData) =
                                                        union
                                                in
                                                if unionData.numAlts == 1 then
                                                    start ++ (( Path.Unbox path, arg ) :: end)

                                                else
                                                    start ++ subPositions path args_ ++ end

                                            args_ ->
                                                start ++ subPositions path args_ ++ end
                                    )

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PList [] ->
                    case test of
                        Test.IsNil ->
                            Just (Branch goal (start ++ end))

                        _ ->
                            Nothing

                Can.PList (hd :: tl) ->
                    case test of
                        Test.IsCons ->
                            let
                                -- Use placeholder ID (-1) for synthesized patterns
                                tl_ : Can.Pattern
                                tl_ =
                                    A.At region { id = -1, node = Can.PList tl }
                            in
                            Just (Branch goal (start ++ subPositions path [ hd, tl_ ] ++ end))

                        _ ->
                            Nothing

                Can.PCons hd tl ->
                    case test of
                        Test.IsCons ->
                            Just (Branch goal (start ++ subPositions path [ hd, tl ] ++ end))

                        _ ->
                            Nothing

                Can.PChr chr ->
                    case test of
                        Test.IsChr testChr ->
                            if chr == testChr then
                                Just (Branch goal (start ++ end))

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PStr str _ ->
                    case test of
                        Test.IsStr testStr ->
                            if str == testStr then
                                Just (Branch goal (start ++ end))

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PInt int ->
                    case test of
                        Test.IsInt testInt ->
                            if int == testInt then
                                Just (Branch goal (start ++ end))

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PBool _ bool ->
                    case test of
                        Test.IsBool testBool ->
                            if bool == testBool then
                                Just (Branch goal (start ++ end))

                            else
                                Nothing

                        _ ->
                            Nothing

                Can.PUnit ->
                    Just (Branch goal (start ++ end))

                Can.PTuple a b cs ->
                    Just
                        (Branch goal
                            (start
                                ++ subPositions path (a :: b :: cs)
                                ++ end
                            )
                        )

                Can.PVar _ ->
                    Just branch

                Can.PAnything ->
                    Just branch

                Can.PRecord _ ->
                    Just branch

                Can.PAlias _ _ ->
                    Just branch

        NotFound ->
            Just branch


{-| The result of looking for one path among a branch's patterns: `Found`
carries the patterns before it, its pattern, and the patterns after it.
-}
type Extract
    = NotFound
    | Found (List ( Path, Can.Pattern )) Can.Pattern (List ( Path, Can.Pattern ))


{-| Finds the first pattern at `selectedPath`, keeping the patterns either side
of it.
-}
extract : Path -> List ( Path, Can.Pattern ) -> Extract
extract selectedPath pathPatterns =
    case pathPatterns of
        [] ->
            NotFound

        (( path, pattern ) as first) :: rest ->
            if path == selectedPath then
                Found [] pattern rest

            else
                case extract selectedPath rest of
                    NotFound ->
                        NotFound

                    Found start foundPattern end ->
                        Found (first :: start) foundPattern end



-- ====== FIND IRRELEVANT BRANCHES ======


{-| Tells whether a branch does not care about the value at `selectedPath`: it
has no pattern there, or its pattern there needs no test.
-}
isIrrelevantTo : Path -> Branch -> Bool
isIrrelevantTo selectedPath (Branch _ pathPatterns) =
    case Utils.listLookup selectedPath pathPatterns of
        Nothing ->
            True

        Just pattern ->
            not (needsTests pattern)


{-| Tells whether matching a pattern requires a runtime test. Variables,
wildcards and record patterns need none. Crashes on an alias pattern, which
flattening has removed.
-}
needsTests : Can.Pattern -> Bool
needsTests (A.At _ patternInfo) =
    case patternInfo.node of
        Can.PVar _ ->
            False

        Can.PAnything ->
            False

        Can.PRecord _ ->
            False

        Can.PCtor _ ->
            True

        Can.PList _ ->
            True

        Can.PCons _ _ ->
            True

        Can.PUnit ->
            True

        Can.PTuple _ _ _ ->
            True

        Can.PChr _ ->
            True

        Can.PStr _ _ ->
            True

        Can.PInt _ ->
            True

        Can.PBool _ _ ->
            True

        Can.PAlias _ _ ->
            crash "aliases should never reach 'isIrrelevantTo' function"



-- ====== PICK A PATH ======


{-| Chooses the path to test next among those where some branch needs a test.

It keeps the paths that the fewest branches do not care about, and among those
the paths that give the fewest subtrees, counting the fallback as one. A tie
that remains is broken by position in the branches' pattern lists.

-}
pickPath : List Branch -> Path
pickPath branches =
    let
        allPaths : List Path
        allPaths =
            List.filterMap isChoicePath (List.concatMap (\(Branch _ patterns) -> patterns) branches)
    in
    case bests (addWeights (smallDefaults branches) allPaths) of
        [ path ] ->
            path

        tiedPaths ->
            Prelude.head (bests (addWeights (smallBranchingFactor branches) tiedPaths))


{-| Returns the path of a pattern that needs a test.
-}
isChoicePath : ( Path, Can.Pattern ) -> Maybe Path
isChoicePath ( path, pattern ) =
    if needsTests pattern then
        Just path

    else
        Nothing


{-| Pairs each path with its weight.
-}
addWeights : (Path -> Int) -> List Path -> List ( Path, Int )
addWeights toWeight paths =
    List.map (\path -> ( path, toWeight path )) paths


{-| Returns the paths of least weight. Crashes on an empty list.
-}
bests : List ( Path, Int ) -> List Path
bests allPaths =
    case allPaths of
        [] ->
            crash "Cannot choose the best of zero paths. This should never happen."

        ( headPath, headWeight ) :: weightedPaths ->
            let
                gatherMinimum : ( a, comparable ) -> ( comparable, List a ) -> ( comparable, List a )
                gatherMinimum ( path, weight ) (( minWeight, paths ) as acc) =
                    if weight == minWeight then
                        ( minWeight, path :: paths )

                    else if weight < minWeight then
                        ( weight, [ path ] )

                    else
                        acc
            in
            Tuple.second (List.foldl gatherMinimum ( headWeight, [ headPath ] ) weightedPaths)



-- ====== PATH PICKING HEURISTICS ======


{-| Counts the branches that do not care about the value at `path`.
-}
smallDefaults : List Branch -> Path -> Int
smallDefaults branches path =
    List.length (List.filter (isIrrelevantTo path) branches)


{-| Counts the subtrees a decision at `path` would have: one per edge, plus one
for a fallback.
-}
smallBranchingFactor : List Branch -> Path -> Int
smallBranchingFactor branches path =
    let
        ( edges, fallback ) =
            gatherEdges branches path
    in
    List.length edges
        + (if List.isEmpty fallback then
            0

           else
            1
          )
