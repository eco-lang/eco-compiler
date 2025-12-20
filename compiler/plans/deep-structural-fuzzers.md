# Deep Structural Fuzzers for Elm Syntax

## Overview

This plan introduces type-safe fuzzers that generate structurally varied Elm syntax for property-based testing. Unlike the current approach where fuzzers only vary leaf values (Int, String, etc.), these fuzzers will vary the **structure** of expressions, patterns, and definitions while maintaining type correctness.

## Problem Statement

Current tests in `tests/Compiler/*.elm` use fuzzers only for primitive values:
```elm
Test.fuzz Fuzz.int "test name" (\n ->
    -- n is fuzzed, but structure is fixed
    makeModule "testValue" (intExpr n)
)
```

The **shape** of AST nodes is always hand-coded, limiting test coverage to specific structural patterns chosen by the test author.

## Goals

1. Generate valid, type-correct Elm expressions with random structure
2. Vary nesting depth, binding counts, branch counts, etc.
3. Maintain proper scoping (variables defined before use)
4. Control recursion depth to prevent infinite generation
5. Enable shrinking to find minimal failing cases

## Design Principles

### Type-Indexed Generation

Each fuzzer is parameterized by the type it produces:
- `intExprFuzzer` generates expressions of type `Int`
- `boolExprFuzzer` generates expressions of type `Bool`
- etc.

This ensures type consistency throughout generated expressions.

### Depth Limiting

All recursive fuzzers take a `depth : Int` parameter:
- At depth 0: only generate leaf nodes (literals, variables)
- At depth N: can generate compound expressions with depth N-1 subexpressions

### Scope Threading

Track available variables and their types to generate valid references:
```elm
type alias Scope =
    { ints : List Name
    , floats : List Name
    , strings : List Name
    , bools : List Name
    , units : List Name
    , functions : List { name : Name, arity : Int, returnType : SimpleType }
    }
```

---

## Phase 1: Foundation

### File: `tests/Compiler/Fuzz/TypedExpr.elm`

#### 1.1 Simple Type Representation

```elm
type SimpleType
    = TInt
    | TFloat
    | TString
    | TChar
    | TBool
    | TUnit
    | TList SimpleType
    | TTuple SimpleType SimpleType
    | TTuple3 SimpleType SimpleType SimpleType
    | TRecord (List ( Name, SimpleType ))
    | TFunction (List SimpleType) SimpleType
```

#### 1.2 Scope Type

```elm
type alias Scope =
    { vars : List ( Name, SimpleType )
    , depth : Int
    }

emptyScope : Int -> Scope
emptyScope maxDepth =
    { vars = [], depth = maxDepth }

addVar : Name -> SimpleType -> Scope -> Scope
addVar name tipe scope =
    { scope | vars = ( name, tipe ) :: scope.vars }

decrementDepth : Scope -> Scope
decrementDepth scope =
    { scope | depth = scope.depth - 1 }

varsOfType : SimpleType -> Scope -> List Name
varsOfType tipe scope =
    List.filterMap
        (\( name, t ) -> if t == tipe then Just name else Nothing)
        scope.vars
```

#### 1.3 Core Int Expression Fuzzer

```elm
intExprFuzzer : Scope -> Fuzzer Src.Expr
intExprFuzzer scope =
    if scope.depth <= 0 then
        intLeafFuzzer scope
    else
        Fuzz.oneOf
            [ intLeafFuzzer scope
            , intLetFuzzer scope
            , intIfFuzzer scope
            , intNegateFuzzer scope
            , intCaseFuzzer scope
            ]

intLeafFuzzer : Scope -> Fuzzer Src.Expr
intLeafFuzzer scope =
    let
        availableVars = varsOfType TInt scope
    in
    if List.isEmpty availableVars then
        Fuzz.map intExpr Fuzz.int
    else
        Fuzz.oneOf
            [ Fuzz.map intExpr Fuzz.int
            , Fuzz.oneOfValues availableVars |> Fuzz.map varExpr
            ]

intLetFuzzer : Scope -> Fuzzer Src.Expr
intLetFuzzer scope =
    let
        innerScope = decrementDepth scope
    in
    Fuzz.map3
        (\bindingName bindingValue body ->
            letExpr
                [ define bindingName [] bindingValue ]
                body
        )
        nameFuzzer
        (intExprFuzzer innerScope)
        (Fuzz.lazy (\_ ->
            intExprFuzzer (addVar bindingName TInt innerScope)
        ))

intIfFuzzer : Scope -> Fuzzer Src.Expr
intIfFuzzer scope =
    let
        innerScope = decrementDepth scope
    in
    Fuzz.map3
        (\cond thenBranch elseBranch ->
            ifExpr cond thenBranch elseBranch
        )
        (boolExprFuzzer innerScope)
        (intExprFuzzer innerScope)
        (intExprFuzzer innerScope)

intNegateFuzzer : Scope -> Fuzzer Src.Expr
intNegateFuzzer scope =
    Fuzz.map negateExpr (intExprFuzzer (decrementDepth scope))

intCaseFuzzer : Scope -> Fuzzer Src.Expr
intCaseFuzzer scope =
    let
        innerScope = decrementDepth scope
    in
    Fuzz.map2
        (\subject branches ->
            caseExpr subject branches
        )
        (intExprFuzzer innerScope)
        (intCaseBranchesFuzzer innerScope)
```

#### 1.4 Int Pattern Fuzzer

```elm
intPatternFuzzer : Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
intPatternFuzzer =
    Fuzz.oneOf
        [ Fuzz.map (\n -> ( pInt n, [] )) Fuzz.int
        , Fuzz.map (\name -> ( pVar name, [ ( name, TInt ) ] )) nameFuzzer
        , Fuzz.constant ( pAnything, [] )
        , Fuzz.map2
            (\name innerPat ->
                ( pAlias (Tuple.first innerPat) name
                , ( name, TInt ) :: Tuple.second innerPat
                )
            )
            nameFuzzer
            (Fuzz.lazy (\_ -> intPatternFuzzer))
        ]
```

#### 1.5 Bool Expression Fuzzer

```elm
boolExprFuzzer : Scope -> Fuzzer Src.Expr
boolExprFuzzer scope =
    if scope.depth <= 0 then
        boolLeafFuzzer scope
    else
        Fuzz.oneOf
            [ boolLeafFuzzer scope
            , boolLetFuzzer scope
            , boolIfFuzzer scope
            ]

boolLeafFuzzer : Scope -> Fuzzer Src.Expr
boolLeafFuzzer scope =
    let
        availableVars = varsOfType TBool scope
    in
    if List.isEmpty availableVars then
        Fuzz.map boolExpr Fuzz.bool
    else
        Fuzz.oneOf
            [ Fuzz.map boolExpr Fuzz.bool
            , Fuzz.oneOfValues availableVars |> Fuzz.map varExpr
            ]
```

---

## Phase 2: Type Variety

### File: `tests/Compiler/Fuzz/TypedExpr.elm` (continued)

#### 2.1 String Expression Fuzzer

```elm
stringExprFuzzer : Scope -> Fuzzer Src.Expr
stringExprFuzzer scope =
    if scope.depth <= 0 then
        stringLeafFuzzer scope
    else
        Fuzz.oneOf
            [ stringLeafFuzzer scope
            , stringLetFuzzer scope
            , stringIfFuzzer scope
            , stringCaseFuzzer scope
            ]

stringLeafFuzzer : Scope -> Fuzzer Src.Expr
stringLeafFuzzer scope =
    let
        availableVars = varsOfType TString scope
    in
    if List.isEmpty availableVars then
        Fuzz.map strExpr Fuzz.string
    else
        Fuzz.oneOf
            [ Fuzz.map strExpr Fuzz.string
            , Fuzz.oneOfValues availableVars |> Fuzz.map varExpr
            ]
```

#### 2.2 Float Expression Fuzzer

```elm
floatExprFuzzer : Scope -> Fuzzer Src.Expr
floatExprFuzzer scope =
    if scope.depth <= 0 then
        floatLeafFuzzer scope
    else
        Fuzz.oneOf
            [ floatLeafFuzzer scope
            , floatLetFuzzer scope
            , floatIfFuzzer scope
            , floatNegateFuzzer scope
            ]
```

#### 2.3 Tuple Expression Fuzzer

```elm
tupleExprFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tupleExprFuzzer scope typeA typeB =
    if scope.depth <= 0 then
        tupleLeafFuzzer scope typeA typeB
    else
        Fuzz.oneOf
            [ tupleLeafFuzzer scope typeA typeB
            , tupleLetFuzzer scope typeA typeB
            , tupleIfFuzzer scope typeA typeB
            ]

tupleLeafFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
tupleLeafFuzzer scope typeA typeB =
    Fuzz.map2 tupleExpr
        (exprFuzzerForType (decrementDepth scope) typeA)
        (exprFuzzerForType (decrementDepth scope) typeB)
```

#### 2.4 List Expression Fuzzer

```elm
listExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
listExprFuzzer scope elemType =
    if scope.depth <= 0 then
        listLeafFuzzer scope elemType
    else
        Fuzz.oneOf
            [ listLeafFuzzer scope elemType
            , listLetFuzzer scope elemType
            , listIfFuzzer scope elemType
            ]

listLeafFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
listLeafFuzzer scope elemType =
    Fuzz.listOfLengthBetween 0 5
        (exprFuzzerForType (decrementDepth scope) elemType)
        |> Fuzz.map listExpr
```

#### 2.5 Record Expression Fuzzer

```elm
recordExprFuzzer : Scope -> List ( Name, SimpleType ) -> Fuzzer Src.Expr
recordExprFuzzer scope fields =
    let
        innerScope = decrementDepth scope
        fieldFuzzers =
            List.map
                (\( name, tipe ) ->
                    Fuzz.map (\expr -> ( name, expr ))
                        (exprFuzzerForType innerScope tipe)
                )
                fields
    in
    Fuzz.sequence fieldFuzzers |> Fuzz.map recordExpr
```

#### 2.6 Unified Type Dispatcher

```elm
exprFuzzerForType : Scope -> SimpleType -> Fuzzer Src.Expr
exprFuzzerForType scope tipe =
    case tipe of
        TInt ->
            intExprFuzzer scope

        TFloat ->
            floatExprFuzzer scope

        TString ->
            stringExprFuzzer scope

        TBool ->
            boolExprFuzzer scope

        TUnit ->
            Fuzz.constant unitExpr

        TList elemType ->
            listExprFuzzer scope elemType

        TTuple a b ->
            tupleExprFuzzer scope a b

        TTuple3 a b c ->
            tuple3ExprFuzzer scope a b c

        TRecord fields ->
            recordExprFuzzer scope fields

        TFunction _ _ ->
            -- Functions handled separately
            lambdaExprFuzzer scope tipe
```

#### 2.7 Pattern Fuzzers for All Types

```elm
patternFuzzerForType : SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
patternFuzzerForType tipe =
    case tipe of
        TInt ->
            intPatternFuzzer

        TString ->
            stringPatternFuzzer

        TBool ->
            -- Bool patterns are constructor patterns (True/False)
            boolPatternFuzzer

        TUnit ->
            Fuzz.constant ( pUnit, [] )

        TList elemType ->
            listPatternFuzzer elemType

        TTuple a b ->
            tuplePatternFuzzer a b

        TRecord fields ->
            recordPatternFuzzer (List.map Tuple.first fields)

        _ ->
            -- Fallback to variable or wildcard
            Fuzz.oneOf
                [ Fuzz.map (\name -> ( pVar name, [ ( name, tipe ) ] )) nameFuzzer
                , Fuzz.constant ( pAnything, [] )
                ]

tuplePatternFuzzer : SimpleType -> SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
tuplePatternFuzzer typeA typeB =
    Fuzz.oneOf
        [ -- Full destructure
          Fuzz.map2
            (\( patA, bindingsA ) ( patB, bindingsB ) ->
                ( pTuple patA patB, bindingsA ++ bindingsB )
            )
            (patternFuzzerForType typeA)
            (patternFuzzerForType typeB)
        , -- Variable binding
          Fuzz.map (\name -> ( pVar name, [ ( name, TTuple typeA typeB ) ] )) nameFuzzer
        , -- Wildcard
          Fuzz.constant ( pAnything, [] )
        ]

listPatternFuzzer : SimpleType -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
listPatternFuzzer elemType =
    Fuzz.oneOf
        [ -- Empty list
          Fuzz.constant ( pList [], [] )
        , -- Cons pattern
          Fuzz.map2
            (\( headPat, headBindings ) ( tailPat, tailBindings ) ->
                ( pCons headPat tailPat, headBindings ++ tailBindings )
            )
            (patternFuzzerForType elemType)
            (Fuzz.oneOf
                [ Fuzz.map (\name -> ( pVar name, [ ( name, TList elemType ) ] )) nameFuzzer
                , Fuzz.constant ( pList [], [] )
                ]
            )
        , -- Fixed-length list pattern
          Fuzz.listOfLengthBetween 1 3 (patternFuzzerForType elemType)
            |> Fuzz.map
                (\pats ->
                    ( pList (List.map Tuple.first pats)
                    , List.concatMap Tuple.second pats
                    )
                )
        , -- Variable
          Fuzz.map (\name -> ( pVar name, [ ( name, TList elemType ) ] )) nameFuzzer
        , -- Wildcard
          Fuzz.constant ( pAnything, [] )
        ]
```

---

## Phase 3: Structural Complexity

### File: `tests/Compiler/Fuzz/Structure.elm`

#### 3.1 Binding Count Fuzzer

```elm
bindingCountFuzzer : Fuzzer Int
bindingCountFuzzer =
    Fuzz.frequency
        [ ( 3, Fuzz.constant 1 )
        , ( 2, Fuzz.constant 2 )
        , ( 1, Fuzz.constant 3 )
        , ( 1, Fuzz.intRange 4 5 )
        ]
```

#### 3.2 Multi-Binding Let Fuzzer

```elm
multiBindingLetFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
multiBindingLetFuzzer scope resultType =
    bindingCountFuzzer
        |> Fuzz.andThen (\count ->
            multiBindingLetFuzzerN scope resultType count []
        )

multiBindingLetFuzzerN : Scope -> SimpleType -> Int -> List Src.Def -> Fuzzer Src.Expr
multiBindingLetFuzzerN scope resultType remaining accDefs =
    if remaining <= 0 then
        exprFuzzerForType scope resultType
            |> Fuzz.map (\body -> letExpr (List.reverse accDefs) body)
    else
        -- Pick a random type for this binding
        simpleTypeFuzzer
            |> Fuzz.andThen (\bindingType ->
                Fuzz.map2
                    (\name value ->
                        let
                            def = define name [] value
                            newScope = addVar name bindingType scope
                        in
                        ( def, newScope )
                    )
                    (uniqueNameFuzzer scope)
                    (exprFuzzerForType (decrementDepth scope) bindingType)
            )
            |> Fuzz.andThen (\( def, newScope ) ->
                multiBindingLetFuzzerN newScope resultType (remaining - 1) (def :: accDefs)
            )
```

#### 3.3 Case Branch Count Fuzzer

```elm
branchCountFuzzer : Fuzzer Int
branchCountFuzzer =
    Fuzz.frequency
        [ ( 3, Fuzz.constant 2 )
        , ( 2, Fuzz.constant 3 )
        , ( 1, Fuzz.constant 4 )
        , ( 1, Fuzz.intRange 5 6 )
        ]
```

#### 3.4 Multi-Branch Case Fuzzer

```elm
multiBranchCaseFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer Src.Expr
multiBranchCaseFuzzer scope subjectType resultType =
    Fuzz.map2
        (\subject branches ->
            caseExpr subject branches
        )
        (exprFuzzerForType (decrementDepth scope) subjectType)
        (caseBranchesFuzzer scope subjectType resultType)

caseBranchesFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer (List ( Src.Pattern, Src.Expr ))
caseBranchesFuzzer scope subjectType resultType =
    branchCountFuzzer
        |> Fuzz.andThen (\count ->
            -- Generate count-1 specific patterns, then a catch-all
            Fuzz.listOfLength (count - 1) (specificBranchFuzzer scope subjectType resultType)
                |> Fuzz.map2 (\catchAll specifics -> specifics ++ [ catchAll ])
                    (catchAllBranchFuzzer scope subjectType resultType)
        )

specificBranchFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer ( Src.Pattern, Src.Expr )
specificBranchFuzzer scope subjectType resultType =
    patternFuzzerForType subjectType
        |> Fuzz.andThen (\( pattern, bindings ) ->
            let
                branchScope = List.foldl (\( n, t ) s -> addVar n t s) scope bindings
            in
            exprFuzzerForType (decrementDepth branchScope) resultType
                |> Fuzz.map (\body -> ( pattern, body ))
        )

catchAllBranchFuzzer : Scope -> SimpleType -> SimpleType -> Fuzzer ( Src.Pattern, Src.Expr )
catchAllBranchFuzzer scope subjectType resultType =
    Fuzz.oneOf
        [ -- Wildcard
          exprFuzzerForType (decrementDepth scope) resultType
            |> Fuzz.map (\body -> ( pAnything, body ))
        , -- Variable binding
          Fuzz.map2
            (\name body -> ( pVar name, body ))
            nameFuzzer
            (nameFuzzer |> Fuzz.andThen (\name ->
                exprFuzzerForType (decrementDepth (addVar name subjectType scope)) resultType
            ))
        ]
```

#### 3.5 Nested Let Fuzzer

```elm
nestedLetFuzzer : Scope -> SimpleType -> Int -> Fuzzer Src.Expr
nestedLetFuzzer scope resultType nestingLevels =
    if nestingLevels <= 0 then
        exprFuzzerForType scope resultType
    else
        Fuzz.map2
            (\name innerExpr ->
                letExpr [ define name [] innerExpr ] (varExpr name)
            )
            nameFuzzer
            (nestedLetFuzzer (decrementDepth scope) resultType (nestingLevels - 1))
```

#### 3.6 Lambda Arity Fuzzer

```elm
arityFuzzer : Fuzzer Int
arityFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.constant 1 )
        , ( 3, Fuzz.constant 2 )
        , ( 2, Fuzz.constant 3 )
        , ( 1, Fuzz.constant 4 )
        ]
```

#### 3.7 Multi-Arg Lambda Fuzzer

```elm
lambdaExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
lambdaExprFuzzer scope resultType =
    arityFuzzer
        |> Fuzz.andThen (\arity ->
            lambdaWithArityFuzzer scope resultType arity
        )

lambdaWithArityFuzzer : Scope -> SimpleType -> Int -> Fuzzer Src.Expr
lambdaWithArityFuzzer scope resultType arity =
    Fuzz.listOfLength arity (paramFuzzer scope)
        |> Fuzz.andThen (\params ->
            let
                patterns = List.map Tuple.first params
                bindings = List.concatMap Tuple.second params
                bodyScope = List.foldl (\( n, t ) s -> addVar n t s) scope bindings
            in
            exprFuzzerForType (decrementDepth bodyScope) resultType
                |> Fuzz.map (\body -> lambdaExpr patterns body)
        )

paramFuzzer : Scope -> Fuzzer ( Src.Pattern, List ( Name, SimpleType ) )
paramFuzzer scope =
    simpleTypeFuzzer
        |> Fuzz.andThen (\paramType ->
            Fuzz.oneOf
                [ Fuzz.map (\name -> ( pVar name, [ ( name, paramType ) ] )) nameFuzzer
                , Fuzz.constant ( pAnything, [] )
                , case paramType of
                    TTuple a b ->
                        tuplePatternFuzzer a b
                    TRecord fields ->
                        recordPatternFuzzer (List.map Tuple.first fields)
                    _ ->
                        Fuzz.map (\name -> ( pVar name, [ ( name, paramType ) ] )) nameFuzzer
                ]
        )
```

#### 3.8 Binop Chain Fuzzer

```elm
type BinopCategory
    = Arithmetic  -- +, -, *, /
    | Comparison  -- <, >, <=, >=
    | Equality    -- ==, /=
    | Boolean     -- &&, ||
    | Append      -- ++

binopChainFuzzer : Scope -> BinopCategory -> Fuzzer Src.Expr
binopChainFuzzer scope category =
    chainLengthFuzzer
        |> Fuzz.andThen (\length ->
            binopChainFuzzerN scope category length
        )

chainLengthFuzzer : Fuzzer Int
chainLengthFuzzer =
    Fuzz.frequency
        [ ( 3, Fuzz.constant 1 )  -- single operator: a + b
        , ( 2, Fuzz.constant 2 )  -- two operators: a + b + c
        , ( 1, Fuzz.constant 3 )  -- three operators: a + b + c + d
        ]

binopChainFuzzerN : Scope -> BinopCategory -> Int -> Fuzzer Src.Expr
binopChainFuzzerN scope category length =
    let
        ( operandType, operators ) = categoryInfo category
        innerScope = decrementDepth scope
    in
    Fuzz.map2
        (\ops final ->
            binopsExpr ops final
        )
        (Fuzz.listOfLength length
            (Fuzz.map2 Tuple.pair
                (exprFuzzerForType innerScope operandType)
                (Fuzz.oneOfValues operators)
            )
        )
        (exprFuzzerForType innerScope operandType)

categoryInfo : BinopCategory -> ( SimpleType, List String )
categoryInfo category =
    case category of
        Arithmetic ->
            ( TInt, [ "+", "-", "*" ] )
        Comparison ->
            ( TInt, [ "<", ">", "<=", ">=" ] )
        Equality ->
            ( TInt, [ "==", "/=" ] )  -- Using Int for simplicity
        Boolean ->
            ( TBool, [ "&&", "||" ] )
        Append ->
            ( TString, [ "++" ] )
```

---

## Phase 4: Full Composition

### File: `tests/Compiler/Fuzz/Module.elm`

#### 4.1 Top-Level Definition Fuzzer

```elm
topLevelDefFuzzer : Scope -> Fuzzer ( Name, List Src.Pattern, Src.Expr, Scope )
topLevelDefFuzzer scope =
    Fuzz.oneOf
        [ -- Simple value definition
          simpleTypeFuzzer
            |> Fuzz.andThen (\defType ->
                Fuzz.map2
                    (\name body ->
                        ( name, [], body, addVar name defType scope )
                    )
                    (uniqueNameFuzzer scope)
                    (exprFuzzerForType scope defType)
            )
        , -- Function definition
          Fuzz.map2 Tuple.pair simpleTypeFuzzer arityFuzzer
            |> Fuzz.andThen (\( returnType, arity ) ->
                Fuzz.map3
                    (\name params body ->
                        let
                            patterns = List.map Tuple.first params
                            funcType = TFunction (List.map (\_ -> TInt) params) returnType
                        in
                        ( name, patterns, body, addVar name funcType scope )
                    )
                    (uniqueNameFuzzer scope)
                    (Fuzz.listOfLength arity (paramFuzzer scope))
                    (Fuzz.lazy (\_ ->
                        let
                            paramBindings = List.concatMap Tuple.second params
                            bodyScope = List.foldl (\( n, t ) s -> addVar n t s) scope paramBindings
                        in
                        exprFuzzerForType bodyScope returnType
                    ))
            )
        ]
```

#### 4.2 Multi-Definition Module Fuzzer

```elm
defCountFuzzer : Fuzzer Int
defCountFuzzer =
    Fuzz.frequency
        [ ( 2, Fuzz.constant 1 )
        , ( 3, Fuzz.constant 2 )
        , ( 2, Fuzz.constant 3 )
        , ( 1, Fuzz.intRange 4 6 )
        ]

multiDefModuleFuzzer : Int -> Fuzzer Src.Module
multiDefModuleFuzzer maxDepth =
    defCountFuzzer
        |> Fuzz.andThen (\count ->
            multiDefModuleFuzzerN (emptyScope maxDepth) count []
        )

multiDefModuleFuzzerN : Scope -> Int -> List ( Name, List Src.Pattern, Src.Expr ) -> Fuzzer Src.Module
multiDefModuleFuzzerN scope remaining accDefs =
    if remaining <= 0 then
        Fuzz.constant (makeModuleWithDefs (List.reverse accDefs))
    else
        topLevelDefFuzzer scope
            |> Fuzz.andThen (\( name, args, body, newScope ) ->
                multiDefModuleFuzzerN newScope (remaining - 1) (( name, args, body ) :: accDefs)
            )
```

#### 4.3 Mixed Container Fuzzer

```elm
mixedContainerFuzzer : Scope -> Fuzzer Src.Expr
mixedContainerFuzzer scope =
    Fuzz.oneOf
        [ -- List of tuples
          listExprFuzzer scope (TTuple TInt TString)
        , -- Tuple of lists
          tupleExprFuzzer scope (TList TInt) (TList TString)
        , -- Record with list field
          recordExprFuzzer scope
            [ ( "items", TList TInt )
            , ( "count", TInt )
            ]
        , -- List of records
          listExprFuzzer scope
            (TRecord [ ( "x", TInt ), ( "y", TInt ) ])
        , -- Nested tuples
          tupleExprFuzzer scope
            (TTuple TInt TInt)
            (TTuple TString TBool)
        ]
```

#### 4.4 Complex Expression Fuzzer

Combines all expression types with weighted probabilities:

```elm
complexExprFuzzer : Scope -> SimpleType -> Fuzzer Src.Expr
complexExprFuzzer scope resultType =
    if scope.depth <= 0 then
        exprFuzzerForType scope resultType
    else
        Fuzz.frequency
            [ ( 3, exprFuzzerForType scope resultType )  -- Basic typed expr
            , ( 2, multiBindingLetFuzzer scope resultType )  -- Multi-binding let
            , ( 2, multiBranchCaseFuzzer scope TInt resultType )  -- Multi-branch case
            , ( 1, nestedLetFuzzer scope resultType 2 )  -- Nested lets
            , ( 1, case resultType of
                    TInt -> binopChainFuzzer scope Arithmetic
                    TBool -> binopChainFuzzer scope Boolean
                    _ -> exprFuzzerForType scope resultType
              )
            ]
```

#### 4.5 Cross-Definition Reference Fuzzer

Generates modules where definitions reference each other:

```elm
mutualReferenceModuleFuzzer : Int -> Fuzzer Src.Module
mutualReferenceModuleFuzzer maxDepth =
    let
        scope = emptyScope maxDepth
    in
    Fuzz.map4
        (\name1 name2 body1 body2 ->
            makeModuleWithDefs
                [ ( name1, [ pVar "x" ], body1 )
                , ( name2, [ pVar "y" ], body2 )
                ]
        )
        nameFuzzer
        nameFuzzer
        -- body1 can call name2
        (Fuzz.lazy (\_ ->
            let
                bodyScope = addVar "x" TInt (addVar name2 (TFunction [TInt] TInt) scope)
            in
            Fuzz.oneOf
                [ intExprFuzzer bodyScope
                , Fuzz.map (\arg -> callExpr (varExpr name2) [ arg ])
                    (intExprFuzzer bodyScope)
                ]
        ))
        -- body2 uses its parameter
        (intExprFuzzer (addVar "y" TInt scope))
```

---

## Integration

### File: `tests/Compiler/Fuzz/Fuzzers.elm`

Main entry point exposing all fuzzers:

```elm
module Compiler.Fuzz.Fuzzers exposing
    ( -- Type-indexed expression fuzzers
      intExprFuzzer
    , floatExprFuzzer
    , stringExprFuzzer
    , boolExprFuzzer
    , listExprFuzzer
    , tupleExprFuzzer
    , recordExprFuzzer
    , exprFuzzerForType

    -- Pattern fuzzers
    , intPatternFuzzer
    , patternFuzzerForType

    -- Structural fuzzers
    , multiBindingLetFuzzer
    , multiBranchCaseFuzzer
    , nestedLetFuzzer
    , lambdaExprFuzzer
    , binopChainFuzzer

    -- Module fuzzers
    , multiDefModuleFuzzer
    , mixedContainerFuzzer
    , complexExprFuzzer

    -- Scope utilities
    , Scope
    , SimpleType(..)
    , emptyScope
    )
```

### New Test File: `tests/Compiler/DeepFuzzTests.elm`

Following the same pattern as other test files (`FunctionTests.elm`, `CaseTests.elm`, etc.), this module exposes an `expectSuite` function that takes an expectation function and condition string:

```elm
module Compiler.DeepFuzzTests exposing (expectSuite)

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (makeModule)
import Compiler.Fuzz.Fuzzers exposing (..)
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Deep structural fuzz tests " ++ condStr)
        [ intExprTests expectFn condStr
        , multiDefTests expectFn condStr
        , complexExprTests expectFn condStr
        , binopTests expectFn condStr
        ]


intExprTests : (Src.Module -> Expectation) -> String -> Test
intExprTests expectFn condStr =
    Test.describe ("Random int expressions " ++ condStr)
        [ Test.fuzz (intExprFuzzer (emptyScope 3))
            ("Fuzzed int expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (intExprFuzzer (emptyScope 4))
            ("Deeper fuzzed int expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


multiDefTests : (Src.Module -> Expectation) -> String -> Test
multiDefTests expectFn condStr =
    Test.describe ("Random multi-definition modules " ++ condStr)
        [ Test.fuzz (multiDefModuleFuzzer 3)
            ("Fuzzed multi-def module " ++ condStr)
            expectFn
        , Test.fuzz (mutualReferenceModuleFuzzer 3)
            ("Fuzzed mutual reference module " ++ condStr)
            expectFn
        ]


complexExprTests : (Src.Module -> Expectation) -> String -> Test
complexExprTests expectFn condStr =
    Test.describe ("Complex random expressions " ++ condStr)
        [ Test.fuzz (complexExprFuzzer (emptyScope 4) TInt)
            ("Complex fuzzed int expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (mixedContainerFuzzer (emptyScope 3))
            ("Mixed container expression " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]


binopTests : (Src.Module -> Expectation) -> String -> Test
binopTests expectFn condStr =
    Test.describe ("Random binop expressions " ++ condStr)
        [ Test.fuzz (binopChainFuzzer (emptyScope 3) Arithmetic)
            ("Arithmetic binop chain " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (binopChainFuzzer (emptyScope 3) Boolean)
            ("Boolean binop chain " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        , Test.fuzz (binopChainFuzzer (emptyScope 3) Comparison)
            ("Comparison binop chain " ++ condStr)
            (\expr -> expectFn (makeModule "testValue" expr))
        ]
```

### Integration with Top-Level Test Suites

Add `DeepFuzzTests.expectSuite` to the existing test aggregation files:

**In `tests/Compiler/Type/Constrain/TypedErasedCheckingParityTest.elm`:**

```elm
import Compiler.DeepFuzzTests as DeepFuzzTests

expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe "Type solver constrain and constrainWithIds type check equivalently"
        [ AsPatternTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        -- ... existing test suites ...
        , MultiDefTests.expectSuite expectFn condStr

        -- Deep structural fuzz tests
        , DeepFuzzTests.expectSuite expectFn condStr
        ]
```

**In `tests/Compiler/IdAssignmentTest.elm`:**

```elm
import Compiler.DeepFuzzTests as DeepFuzzTests

expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe "ID assignment verification"
        [ AsPatternTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        -- ... existing test suites ...
        , MultiDefTests.expectSuite expectFn condStr

        -- Deep structural fuzz tests
        , DeepFuzzTests.expectSuite expectFn condStr
        ]
```

This ensures the deep fuzz tests run with both:
- `expectEquivalentTypeChecking` (type checking parity)
- `expectUniqueIds` (ID assignment correctness)

---

## File Structure

```
tests/Compiler/Fuzz/
├── TypedExpr.elm      -- Type-indexed expression and pattern fuzzers
├── Structure.elm      -- Structural complexity fuzzers
├── Module.elm         -- Module-level fuzzers
└── Fuzzers.elm        -- Main export module

tests/Compiler/
├── DeepFuzzTests.elm  -- Test suite using new fuzzers (exports expectSuite)
├── IdAssignmentTest.elm          -- Includes DeepFuzzTests.expectSuite
└── Type/Constrain/
    └── TypedErasedCheckingParityTest.elm  -- Includes DeepFuzzTests.expectSuite
```

---

## Testing Strategy

1. **Incremental Validation**: After each phase, run existing tests to ensure no regressions
2. **Shrinking Verification**: Verify that failing cases shrink to minimal examples
3. **Depth Limiting**: Start with depth 2-3, increase gradually
4. **Performance Monitoring**: Track test execution time as complexity increases

---

## Success Criteria

- [ ] All generated expressions are syntactically valid
- [ ] All generated expressions type-check successfully
- [ ] Fuzzers shrink to minimal failing cases when errors occur
- [ ] Test suite runs in reasonable time (<60s for 100 iterations)
- [ ] Edge cases discovered that hand-written tests missed
