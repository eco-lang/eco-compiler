module Compiler.LocalOpt.Erased.DecisionTree exposing
    ( DecisionTree(..), Test, Path
    , compile
    )

{-| A `case` expression has to be turned into a sequence of runtime checks, and
this module decides which checks to make and in what order, for the erased
(JavaScript) path.

The value a `case` examines is the _scrutinee_. A _path_ names one part of it,
such as the second field of a tuple or the argument of a constructor, as
`Compiler.IR.DecisionTree.Path` describes. A _test_ is a question about the
value at a path, such as whether it was built with a particular constructor or
equals a particular literal, as `Compiler.IR.DecisionTree.Test` describes.
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

Patterns that need no test are flattened away as they enter a branch: a
constructor of a type with only one constructor, a tuple and unit are replaced
by their parts, and an alias pattern `p as x` by `p` and the variable `x`.

@docs DecisionTree, Test, Path
@docs compile

-}

import Compiler.Core.Annotation as A
import Compiler.Core.Index as Index
import Compiler.Core.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.DecisionTree.Path as Path
import Compiler.IR.DecisionTree.Test as Test
import Compiler.IR.Source.StringLiteral as ES
import Data.NonEmptyList as NE
import Data.Set as EverySet
import Maybe.Extra as Maybe
import System.Crash exposing (crash)
import Utils.Main as Utils



-- ====== COMPILE CASES ======


{-| Builds the decision tree for one `case`, given each branch's pattern
paired with the index of that branch, in source order.

Each `Match` in the result carries one of the given indices. A branch can be
reached by more than one leaf, and a branch that an earlier one shadows is
reached by none. Crashes on an empty list, since a `case` has a branch.

-}
compile : List ( Can.Pattern, Int ) -> DecisionTree
compile rawBranches =
    let
        format : ( Can.Pattern, Int ) -> Branch
        format ( pattern, index ) =
            Branch index (flatten ( Path.Empty, pattern ) [])
    in
    case List.map format rawBranches of
        first :: rest ->
            toDecisionTree first rest

        [] ->
            crash "Erased.DecisionTree.compile: a case has at least one branch"



-- ====== DECISION TREES ======


{-| A tree of runtime tests that chooses the branch of a `case` to take.

`Match` is a leaf, and carries the index of the branch to take, as given to
`compile`.

`Decision` examines the value at its path. Each edge pairs a test with the
subtree to follow when the value passes it, and the last part is the
_fallback_, the subtree for a value that passes none of the tests. The fallback
is `Nothing` exactly when the tests cover every possible value: every
constructor of the type, both `Bool` values, or both empty and non-empty lists.
Tests on an `Int`, a `Char` or a `String` never cover every value, so a
decision on one always has a fallback. A decision has at least one edge.

-}
type DecisionTree
    = Match Int
    | Decision Path (NE.Nonempty ( Test, DecisionTree )) (Maybe DecisionTree)


{-| A question about the value at one path, as `Compiler.IR.DecisionTree.Test`
describes. This is another name for that type, not a new one.
-}
type alias Test =
    Test.Test


{-| How to reach one part of the scrutinee, as `Compiler.IR.DecisionTree.Path`
describes. This is another name for that type, not a new one.
-}
type alias Path =
    Path.Path



-- ====== ACTUALLY BUILD DECISION TREES ======


{-| One branch of the `case` part-way through compilation: its index, and the
flattened patterns it still needs to match, each paired with the path of the
value it applies to.
-}
type Branch
    = Branch Int (List ( Path, FlatPattern ))


{-| A pattern as `flatten` leaves it: one that needs a test of its own, or
`FAnything` for one that needs none.

`FAnything` stands for a variable, a wildcard or a record pattern. `FCtor`
is a constructor of a type with two or more constructors, with the fields of
`Test.IsCtor` and the constructor's argument patterns. `FNil` is the empty
list pattern, and `FCons` a non-empty list or `::` pattern with its head and
tail patterns. The literal and `Bool` patterns keep their values.

-}
type FlatPattern
    = FAnything
    | FCtor ModuleName.Canonical Name.Name Index.ZeroBased Int Can.CtorOpts (List Can.Pattern)
    | FNil
    | FCons Can.Pattern Can.Pattern
    | FInt Int
    | FChr String
    | FStr String
    | FBool Bool


{-| Builds the decision tree for the branches `first :: rest`, which are in
source order. It is a `Match` of `first` when none of `first`'s patterns needs
a test.
-}
toDecisionTree : Branch -> List Branch -> DecisionTree
toDecisionTree ((Branch goal firstPatterns) as first) rest =
    case List.filterMap isChoicePath firstPatterns of
        [] ->
            Match goal

        firstPath :: firstPaths ->
            let
                branches : List Branch
                branches =
                    first :: rest

                path : Path
                path =
                    pickPath branches
                        (NE.Nonempty firstPath
                            (firstPaths ++ List.filterMap isChoicePath (List.concatMap (\(Branch _ patterns) -> patterns) rest))
                        )

                ( edges, fallback ) =
                    gatherEdges branches path

                decisionEdges : NE.Nonempty ( Test, DecisionTree )
                decisionEdges =
                    NE.map (Tuple.mapSecond (\(NE.Nonempty b bs) -> toDecisionTree b bs)) edges
            in
            case fallback of
                [] ->
                    Decision path decisionEdges Nothing

                f :: fs ->
                    Decision path decisionEdges (Just (toDecisionTree f fs))


{-| Tells whether `tests`, the distinct tests found at one path, cover every
value that can be there, judging by the kind of the first test: all of a type's
constructors, both `Bool` values, or cons and nil. Tests on an `Int`,
a `Char` or a `String` are never complete.
-}
isComplete : NE.Nonempty Test -> Bool
isComplete (NE.Nonempty firstTest otherTests) =
    let
        count : Int
        count =
            1 + List.length otherTests
    in
    case firstTest of
        Test.IsCtor _ _ _ numAlts _ ->
            numAlts == count

        Test.IsCons ->
            count == 2

        Test.IsNil ->
            count == 2

        Test.IsInt _ ->
            False

        Test.IsChr _ ->
            False

        Test.IsStr _ ->
            False

        Test.IsBool _ ->
            count == 2



-- ====== FLATTEN PATTERNS ======


{-| Adds a path and its pattern, as `FlatPattern`s, to the front of
`otherPathPatterns`, first taking apart any pattern that needs no test of its
own.

A constructor of a type whose `numAlts` is 1 is replaced by its argument at
`Path.Unbox`, by its arguments at `Path.Index` positions when it has several,
and dropped when it has none. A tuple is replaced by its fields at `Path.Index`
positions, unit is dropped, and an alias `p as x` becomes `p` and the variable
`x` at the same path. The parts are flattened in turn. Any other pattern
becomes its `FlatPattern`.

-}
flatten : ( Path, Can.Pattern ) -> List ( Path, FlatPattern ) -> List ( Path, FlatPattern )
flatten ( path, A.At region patternInfo ) otherPathPatterns =
    case patternInfo.node of
        Can.PVar _ ->
            ( path, FAnything ) :: otherPathPatterns

        Can.PAnything ->
            ( path, FAnything ) :: otherPathPatterns

        Can.PCtor { home, union, name, index, args } ->
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
                ( path, FCtor home name index unionData.numAlts unionData.opts (List.map dearg args) ) :: otherPathPatterns

        Can.PTuple a b cs ->
            (a :: b :: Maybe.toList cs)
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

        Can.PAlias realPattern _ ->
            flatten ( path, realPattern ) (( path, FAnything ) :: otherPathPatterns)

        Can.PRecord _ ->
            ( path, FAnything ) :: otherPathPatterns

        Can.PList [] ->
            ( path, FNil ) :: otherPathPatterns

        Can.PList (hd :: tl) ->
            let
                -- Use placeholder ID (-1) for synthesized patterns
                tl_ : Can.Pattern
                tl_ =
                    A.At region { id = -1, node = Can.PList tl }
            in
            ( path, FCons hd tl_ ) :: otherPathPatterns

        Can.PCons hd tl ->
            ( path, FCons hd tl ) :: otherPathPatterns

        Can.PChr chr ->
            ( path, FChr chr ) :: otherPathPatterns

        Can.PStr str _ ->
            ( path, FStr str ) :: otherPathPatterns

        Can.PInt int ->
            ( path, FInt int ) :: otherPathPatterns

        Can.PBool _ bool ->
            ( path, FBool bool ) :: otherPathPatterns


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



-- ====== GATHER OUTGOING EDGES ======


{-| Splits `branches` by the tests found at `path`.

Each edge pairs one of the distinct tests at `path` with the branches that can
still match a value passing it. The second part is the fallback branches, those
that do not test `path`, and is empty when the tests are complete, as
`isComplete` decides.

-}
gatherEdges : List Branch -> Path -> ( NE.Nonempty ( Test, NE.Nonempty Branch ), List Branch )
gatherEdges branches path =
    let
        relevantTests : NE.Nonempty Test
        relevantTests =
            testsAtPath path branches

        allEdges : NE.Nonempty ( Test, NE.Nonempty Branch )
        allEdges =
            NE.map (edgesFor path branches) relevantTests

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
testsAtPath : Path -> List Branch -> NE.Nonempty Test
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
    case Tuple.first (List.foldr skipVisited ( [], EverySet.empty ) allTests) of
        test :: tests ->
            NE.Nonempty test tests

        [] ->
            crash "Erased.DecisionTree.testsAtPath: some branch tests the picked path"


{-| Returns the test a branch makes at `selectedPath`, or `Nothing` when it has
no pattern there or its pattern there needs no test.
-}
testAtPath : Path -> Branch -> Maybe Test
testAtPath selectedPath (Branch _ pathPatterns) =
    Utils.listLookup selectedPath pathPatterns
        |> Maybe.andThen
            (\pattern ->
                case pattern of
                    FAnything ->
                        Nothing

                    FCtor home name index numAlts opts _ ->
                        Just (Test.IsCtor home name index numAlts opts)

                    FNil ->
                        Just Test.IsNil

                    FCons _ _ ->
                        Just Test.IsCons

                    FInt int ->
                        Just (Test.IsInt int)

                    FChr chr ->
                        Just (Test.IsChr chr)

                    FStr str ->
                        Just (Test.IsStr str)

                    FBool bool ->
                        Just (Test.IsBool bool)
            )



-- ====== BUILD EDGES ======


{-| Pairs `test` with the branches that can still match a value at `path` that
passes it.
-}
edgesFor : Path -> List Branch -> Test -> ( Test, NE.Nonempty Branch )
edgesFor path branches test =
    case List.filterMap (toRelevantBranch test path) branches of
        b :: bs ->
            ( test, NE.Nonempty b bs )

        [] ->
            crash "Erased.DecisionTree.edgesFor: the branch that made the test passes it"


{-| Returns what remains of a branch once the value at `path` has passed `test`,
or `Nothing` when the branch's pattern there cannot match such a value.

A pattern that passes is replaced by the flattened patterns for its parts, at
the paths below `path`. A branch with no pattern at `path`, or one that needs
no test, is returned unchanged.

-}
toRelevantBranch : Test -> Path -> Branch -> Maybe Branch
toRelevantBranch test path ((Branch goal pathPatterns) as branch) =
    case extract path pathPatterns of
        Found start pattern end ->
            let
                passWith : List ( Path, Can.Pattern ) -> Maybe Branch
                passWith parts =
                    Just (Branch goal (start ++ List.foldr flatten end parts))
            in
            case ( test, pattern ) of
                ( _, FAnything ) ->
                    Just branch

                ( Test.IsCtor _ testName _ _ _, FCtor _ name _ _ _ args ) ->
                    if name == testName then
                        passWith (subPositions path args)

                    else
                        Nothing

                ( Test.IsNil, FNil ) ->
                    passWith []

                ( Test.IsCons, FCons hd tl ) ->
                    passWith (subPositions path [ hd, tl ])

                ( Test.IsChr testChr, FChr chr ) ->
                    if ES.valueKey chr == ES.valueKey testChr then
                        passWith []

                    else
                        Nothing

                ( Test.IsStr testStr, FStr str ) ->
                    if ES.valueKey str == ES.valueKey testStr then
                        passWith []

                    else
                        Nothing

                ( Test.IsInt testInt, FInt int ) ->
                    if int == testInt then
                        passWith []

                    else
                        Nothing

                ( Test.IsBool testBool, FBool bool ) ->
                    if bool == testBool then
                        passWith []

                    else
                        Nothing

                _ ->
                    Nothing

        NotFound ->
            Just branch


{-| The result of looking for one path among a branch's patterns: `Found`
carries the patterns before it, its pattern, and the patterns after it.
-}
type Extract
    = NotFound
    | Found (List ( Path, FlatPattern )) FlatPattern (List ( Path, FlatPattern ))


{-| Finds the first pattern at `selectedPath`, keeping the patterns either side
of it.
-}
extract : Path -> List ( Path, FlatPattern ) -> Extract
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


{-| Tells whether matching a pattern requires a runtime test: every
`FlatPattern` but `FAnything` does.
-}
needsTests : FlatPattern -> Bool
needsTests pattern =
    case pattern of
        FAnything ->
            False

        _ ->
            True



-- ====== PICK A PATH ======


{-| Chooses the path to test next among those where some branch needs a test.

It keeps the paths that the fewest branches do not care about, and among those
the paths that give the fewest subtrees, counting the fallback as one. A tie
that remains is broken by position in the branches' pattern lists.

-}
pickPath : List Branch -> NE.Nonempty Path -> Path
pickPath branches allPaths =
    case bests (addWeights (smallDefaults branches) allPaths) of
        NE.Nonempty path [] ->
            path

        tiedPaths ->
            let
                (NE.Nonempty path _) =
                    bests (addWeights (smallBranchingFactor branches) tiedPaths)
            in
            path


{-| Returns the path of a pattern that needs a test.
-}
isChoicePath : ( Path, FlatPattern ) -> Maybe Path
isChoicePath ( path, pattern ) =
    if needsTests pattern then
        Just path

    else
        Nothing


{-| Pairs each path with its weight.
-}
addWeights : (Path -> Int) -> NE.Nonempty Path -> NE.Nonempty ( Path, Int )
addWeights toWeight paths =
    NE.map (\path -> ( path, toWeight path )) paths


{-| Returns the paths of least weight.
-}
bests : NE.Nonempty ( Path, Int ) -> NE.Nonempty Path
bests (NE.Nonempty ( headPath, headWeight ) weightedPaths) =
    let
        gatherMinimum : ( a, comparable ) -> ( comparable, NE.Nonempty a ) -> ( comparable, NE.Nonempty a )
        gatherMinimum ( path, weight ) (( minWeight, NE.Nonempty p ps ) as acc) =
            if weight == minWeight then
                ( minWeight, NE.Nonempty path (p :: ps) )

            else if weight < minWeight then
                ( weight, NE.singleton path )

            else
                acc
    in
    Tuple.second (List.foldl gatherMinimum ( headWeight, NE.singleton headPath ) weightedPaths)



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
    List.length (NE.toList edges)
        + (if List.isEmpty fallback then
            0

           else
            1
          )
