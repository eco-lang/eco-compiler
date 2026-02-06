module Compiler.LocalOpt.Typed.DecisionTree exposing
    ( DecisionTree(..), Test, Path, ContainerHint
    , compile
    , pathEncoder, pathDecoder, testEncoder, testDecoder
    )

{-| Compiles pattern matching into efficient decision trees with container type hints.

This module is a typed variant of `Compiler.LocalOpt.Erased.DecisionTree` that
extends `Path` with `ContainerHint` information. This allows typed backends
(MLIR/native) to use type-specific projection operations instead of generic ones.

The algorithm is identical to the erased version, described in "When Do Match-Compilation
Heuristics Matter?" by Kevin Scott and Norman Ramsey.


# Core Types

@docs DecisionTree, Test, Path, ContainerHint


# Compilation

@docs compile


# Binary Encoding

@docs pathEncoder, pathDecoder, testEncoder, testDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Data.Set as EverySet
import Hex.Convert
import Prelude
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- ====== COMPILE CASES ======


{-| Users of this module will mainly interact with this function. It takes
some normal branches and gives out a decision tree that has "labels" at all
the leafs and a dictionary that maps these "labels" to the code that should
run.

If 2 or more leaves point to the same label, we need to do some tricks in JS to
make that work nicely. When is JS getting goto?! ;) That is outside the scope
of this module though.

-}
compile : List ( Can.Pattern, Int ) -> DecisionTree
compile rawBranches =
    let
        format : ( Can.Pattern, Int ) -> Branch
        format ( pattern, index ) =
            Branch index [ ( TypedPath.Empty, pattern ) ]
    in
    toDecisionTree (List.map format rawBranches)



-- ====== DECISION TREES ======


{-| A decision tree representation for efficient pattern matching.

  - `Match Int`: A leaf node indicating successful match with the branch index
  - `Decision Path (List (Test, DecisionTree)) (Maybe DecisionTree)`: A decision node that tests a value at the given path, with edges for each test outcome and an optional fallback for unmatched cases

-}
type DecisionTree
    = Match Int
    | Decision Path (List ( Test, DecisionTree )) (Maybe DecisionTree)


{-| A runtime test to determine which branch to take in a decision tree.
Re-exported from Compiler.AST.DecisionTree.Test for backward compatibility.
-}
type alias Test =
    Test.Test


{-| Indicates what kind of container an TypedPath.Index navigates into.
Re-exported from Compiler.AST.DecisionTree.TypedPath for backward compatibility.
-}
type alias ContainerHint =
    TypedPath.ContainerHint


{-| A path describing how to access a value within a matched pattern.
Re-exported from Compiler.AST.DecisionTree.TypedPath for backward compatibility.
-}
type alias Path =
    TypedPath.Path



-- ====== ACTUALLY BUILD DECISION TREES ======


type Branch
    = Branch Int (List ( Path, Can.Pattern ))


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


{-| Flatten type aliases and use the VariantDict to figure out when a tag is
the only variant so we can skip doing any tests on it.
-}
flattenPatterns : Branch -> Branch
flattenPatterns (Branch goal pathPatterns) =
    Branch goal (List.foldr flatten [] pathPatterns)


flatten : ( Path, Can.Pattern ) -> List ( Path, Can.Pattern ) -> List ( Path, Can.Pattern )
flatten (( path, A.At region patternInfo ) as pathPattern) otherPathPatterns =
    case patternInfo.node of
        Can.PVar _ ->
            pathPattern :: otherPathPatterns

        Can.PAnything ->
            pathPattern :: otherPathPatterns

        Can.PCtor { union, name, args } ->
            let
                (Can.Union unionData) =
                    union
            in
            if unionData.numAlts == 1 then
                case List.map dearg args of
                    [ arg ] ->
                        flatten ( TypedPath.Unbox path, arg ) otherPathPatterns

                    args_ ->
                        List.foldr flatten otherPathPatterns (subPositions (TypedPath.HintCustom name) path args_)

            else
                pathPattern :: otherPathPatterns

        Can.PTuple a b cs ->
            let
                all =
                    a :: b :: cs

                len =
                    List.length all

                hint =
                    case len of
                        2 ->
                            TypedPath.HintTuple2

                        3 ->
                            TypedPath.HintTuple3

                        _ ->
                            -- Larger tuples are encoded more like custom ADTs
                            -- Use empty string since tuples don't have constructor names
                            TypedPath.HintCustom ""
            in
            all
                |> List.foldl
                    (\x ( index, acc ) ->
                        ( Index.next index
                        , ( TypedPath.Index index hint path, x ) :: acc
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


subPositions : ContainerHint -> Path -> List Can.Pattern -> List ( Path, Can.Pattern )
subPositions hint path patterns =
    Index.indexedMap (\index pattern -> ( TypedPath.Index index hint path, pattern )) patterns


dearg : Can.PatternCtorArg -> Can.Pattern
dearg (Can.PatternCtorArg _ _ pattern) =
    pattern



-- ====== SUCCESSFULLY MATCH ======


{-| If the first branch has no more "decision points" we can finally take that
path. If that is the case we give the resulting label and a mapping from free
variables to "how to get their value". So a pattern like (Just (x,\_)) will give
us something like ("x" => value.0.0)
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


testsAtPath : Path -> List Branch -> List Test
testsAtPath selectedPath branches =
    let
        allTests : List Test
        allTests =
            List.filterMap (testAtPath selectedPath) branches

        skipVisited : Test -> ( List Test, EverySet.EverySet String Test ) -> ( List Test, EverySet.EverySet String Test )
        skipVisited test (( uniqueTests, visitedTests ) as curr) =
            if EverySet.member (testEncoder >> Bytes.Encode.encode >> Hex.Convert.toString) test visitedTests then
                curr

            else
                ( test :: uniqueTests
                , EverySet.insert (testEncoder >> Bytes.Encode.encode >> Hex.Convert.toString) test visitedTests
                )
    in
    Tuple.first (List.foldr skipVisited ( [], EverySet.empty ) allTests)


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


edgesFor : Path -> List Branch -> Test -> ( Test, List Branch )
edgesFor path branches test =
    ( test
    , List.filterMap (toRelevantBranch test path) branches
    )


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
                                                    start ++ (( TypedPath.Unbox path, arg ) :: end)

                                                else
                                                    start ++ subPositions (TypedPath.HintCustom name) path args_ ++ end

                                            args_ ->
                                                start ++ subPositions (TypedPath.HintCustom name) path args_ ++ end
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
                            Just (Branch goal (start ++ subPositions TypedPath.HintList path [ hd, tl_ ] ++ end))

                        _ ->
                            Nothing

                Can.PCons hd tl ->
                    case test of
                        Test.IsCons ->
                            Just (Branch goal (start ++ subPositions TypedPath.HintList path [ hd, tl ] ++ end))

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
                    let
                        all =
                            a :: b :: cs

                        len =
                            List.length all

                        hint =
                            case len of
                                2 ->
                                    TypedPath.HintTuple2

                                3 ->
                                    TypedPath.HintTuple3

                                _ ->
                                    -- Larger tuples use empty string for constructor name
                                    TypedPath.HintCustom ""
                    in
                    Just
                        (Branch goal
                            (start
                                ++ subPositions hint path all
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


type Extract
    = NotFound
    | Found (List ( Path, Can.Pattern )) Can.Pattern (List ( Path, Can.Pattern ))


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


isIrrelevantTo : Path -> Branch -> Bool
isIrrelevantTo selectedPath (Branch _ pathPatterns) =
    case Utils.listLookup selectedPath pathPatterns of
        Nothing ->
            True

        Just pattern ->
            not (needsTests pattern)


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


isChoicePath : ( Path, Can.Pattern ) -> Maybe Path
isChoicePath ( path, pattern ) =
    if needsTests pattern then
        Just path

    else
        Nothing


addWeights : (Path -> Int) -> List Path -> List ( Path, Int )
addWeights toWeight paths =
    List.map (\path -> ( path, toWeight path )) paths


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


smallDefaults : List Branch -> Path -> Int
smallDefaults branches path =
    List.length (List.filter (isIrrelevantTo path) branches)


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



-- ====== ENCODERS and DECODERS ======


{-| Encode a Path to bytes for serialization.
Delegates to Compiler.AST.DecisionTree.TypedPath.
-}
pathEncoder : Path -> Bytes.Encode.Encoder
pathEncoder =
    TypedPath.pathEncoder


{-| Decode a Path from bytes.
Delegates to Compiler.AST.DecisionTree.TypedPath.
-}
pathDecoder : Bytes.Decode.Decoder Path
pathDecoder =
    TypedPath.pathDecoder


{-| Encode a Test to bytes for serialization.
Delegates to Compiler.AST.DecisionTree.Test.
-}
testEncoder : Test -> Bytes.Encode.Encoder
testEncoder =
    Test.testEncoder


{-| Decode a Test from bytes.
Delegates to Compiler.AST.DecisionTree.Test.
-}
testDecoder : Bytes.Decode.Decoder Test
testDecoder =
    Test.testDecoder
