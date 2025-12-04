module Compiler.Optimize.TypedExpression exposing
    ( Cycle
    , destructArgs
    , optimize
    , optimizePotentialTailCall
    )

{-| Typed expression optimization.

Like Expression.elm but preserves type information on every expression.
The key differences:

1.  Every expression carries its Can.Type
2.  We look up types from annotations and track local variable types
3.  Function types are decomposed to get argument/return types

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.TypedCase as Case
import Compiler.Optimize.TypedNames as Names
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Utils.Main as Utils



-- OPTIMIZE


type alias Cycle =
    EverySet String Name


type alias Annotations =
    TOpt.Annotations


{-| Optimize a canonical expression to a typed optimized expression.
The type is either provided from context or inferred from the expression.
-}
optimize : Cycle -> Annotations -> Can.Expr -> Names.Tracker TOpt.Expr
optimize cycle annotations (A.At region expression) =
    case expression of
        Can.VarLocal name ->
            Names.getVarType name
                |> Names.fmap
                    (\maybeType ->
                        let
                            tipe =
                                Maybe.withDefault unknownType maybeType
                        in
                        TOpt.TrackedVarLocal region name tipe
                    )

        Can.VarTopLevel home name ->
            let
                tipe : Can.Type
                tipe =
                    lookupAnnotationType name annotations
            in
            if EverySet.member identity name cycle then
                Names.pure (TOpt.VarCycle region home name tipe)

            else
                Names.registerGlobal region home name tipe

        Can.VarKernel home name ->
            -- Kernel functions don't have types in annotations
            Names.registerKernel home (TOpt.VarKernel region home name unknownType)

        Can.VarForeign home name annotation ->
            let
                tipe : Can.Type
                tipe =
                    annotationType annotation
            in
            Names.registerGlobal region home name tipe

        Can.VarCtor opts home name index annotation ->
            let
                tipe : Can.Type
                tipe =
                    annotationType annotation
            in
            Names.registerCtor region home (A.At region name) index opts tipe

        Can.VarDebug home name annotation ->
            let
                tipe : Can.Type
                tipe =
                    annotationType annotation
            in
            Names.registerDebug name home region tipe

        Can.VarOperator _ home name annotation ->
            let
                tipe : Can.Type
                tipe =
                    annotationType annotation
            in
            Names.registerGlobal region home name tipe

        Can.Chr chr ->
            Names.registerKernel Name.utils (TOpt.Chr region chr charType)

        Can.Str str ->
            Names.pure (TOpt.Str region str stringType)

        Can.Int int ->
            Names.pure (TOpt.Int region int intType)

        Can.Float float ->
            Names.pure (TOpt.Float region float floatType)

        Can.List entries ->
            Names.traverse (optimize cycle annotations) entries
                |> Names.bind
                    (\items ->
                        let
                            elemType : Can.Type
                            elemType =
                                case items of
                                    first :: _ ->
                                        TOpt.typeOf first

                                    [] ->
                                        -- Empty list - element type is unknown
                                        Can.TVar "a"

                            listType : Can.Type
                            listType =
                                Can.TType ModuleName.list "List" [ elemType ]
                        in
                        Names.registerKernel Name.list (TOpt.List region items listType)
                    )

        Can.Negate expr ->
            Names.registerGlobal region ModuleName.basics Name.negate negateType
                |> Names.bind
                    (\func ->
                        optimize cycle annotations expr
                            |> Names.fmap
                                (\arg ->
                                    let
                                        resultType : Can.Type
                                        resultType =
                                            TOpt.typeOf arg
                                    in
                                    TOpt.Call region func [ arg ] resultType
                                )
                    )

        Can.Binop _ home name annotation left right ->
            let
                opType : Can.Type
                opType =
                    annotationType annotation
            in
            Names.registerGlobal region home name opType
                |> Names.bind
                    (\optFunc ->
                        optimize cycle annotations left
                            |> Names.bind
                                (\optLeft ->
                                    optimize cycle annotations right
                                        |> Names.fmap
                                            (\optRight ->
                                                let
                                                    resultType : Can.Type
                                                    resultType =
                                                        getCallResultType opType 2
                                                in
                                                TOpt.Call region optFunc [ optLeft, optRight ] resultType
                                            )
                                )
                    )

        Can.Lambda args body ->
            destructArgs annotations args
                |> Names.bind
                    (\( typedArgNames, destructors ) ->
                        let
                            -- Extend context with argument types
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames
                        in
                        Names.withVarTypes argTypes
                            (optimize cycle annotations body)
                            |> Names.fmap
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) bodyType
                                    in
                                    TOpt.TrackedFunction typedArgNames (List.foldr (wrapDestruct bodyType) obody destructors) funcType
                                )
                    )

        Can.Call func args ->
            optimize cycle annotations func
                |> Names.bind
                    (\optFunc ->
                        Names.traverse (optimize cycle annotations) args
                            |> Names.fmap
                                (\optArgs ->
                                    let
                                        funcType : Can.Type
                                        funcType =
                                            TOpt.typeOf optFunc

                                        resultType : Can.Type
                                        resultType =
                                            getCallResultType funcType (List.length optArgs)
                                    in
                                    TOpt.Call region optFunc optArgs resultType
                                )
                    )

        Can.If branches finally ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( TOpt.Expr, TOpt.Expr )
                optimizeBranch ( condition, branch ) =
                    optimize cycle annotations condition
                        |> Names.bind
                            (\expr ->
                                optimize cycle annotations branch
                                    |> Names.fmap (Tuple.pair expr)
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.bind
                    (\optimizedBranches ->
                        optimize cycle annotations finally
                            |> Names.fmap
                                (\ofinally ->
                                    let
                                        resultType : Can.Type
                                        resultType =
                                            TOpt.typeOf ofinally
                                    in
                                    TOpt.If optimizedBranches ofinally resultType
                                )
                    )

        Can.Let def body ->
            optimizeDefAndBody cycle annotations def body

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef cycle annotations def
                        |> Names.bind
                            (\tailCallDef ->
                                let
                                    -- Get the name and type from the def
                                    ( defName, defType ) =
                                        getDefNameAndType def annotations
                                in
                                Names.withVarType defName defType
                                    (optimize cycle annotations body)
                                    |> Names.fmap
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let tailCallDef obody bodyType
                                        )
                            )

                _ ->
                    optimizeLetRecDefs cycle annotations defs body

        Can.LetDestruct pattern expr body ->
            destruct annotations pattern
                |> Names.bind
                    (\( A.At nameRegion name, patternType, destructs ) ->
                        optimize cycle annotations expr
                            |> Names.bind
                                (\oexpr ->
                                    Names.withVarType name patternType
                                        (optimize cycle annotations body)
                                        |> Names.fmap
                                            (\obody ->
                                                let
                                                    exprType : Can.Type
                                                    exprType =
                                                        TOpt.typeOf oexpr

                                                    bodyType : Can.Type
                                                    bodyType =
                                                        TOpt.typeOf obody
                                                in
                                                TOpt.Let (TOpt.Def nameRegion name oexpr exprType)
                                                    (List.foldr (wrapDestruct bodyType) obody destructs)
                                                    bodyType
                                            )
                                )
                    )

        Can.Case expr branches ->
            let
                optimizeBranch : Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, TOpt.Expr )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase annotations root pattern
                        |> Names.bind
                            (\( destructors, bindings ) ->
                                Names.withVarTypes bindings
                                    (optimize cycle annotations branch)
                                    |> Names.fmap
                                        (\obranch ->
                                            let
                                                branchType : Can.Type
                                                branchType =
                                                    TOpt.typeOf obranch
                                            in
                                            ( pattern, List.foldr (wrapDestruct branchType) obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.bind
                    (\temp ->
                        optimize cycle annotations expr
                            |> Names.bind
                                (\oexpr ->
                                    let
                                        scrutineeType : Can.Type
                                        scrutineeType =
                                            TOpt.typeOf oexpr
                                    in
                                    case oexpr of
                                        TOpt.VarLocal root tipe ->
                                            Names.withVarType root tipe
                                                (Names.traverse (optimizeBranch root) branches)
                                                |> Names.fmap (Case.optimize temp root)

                                        TOpt.TrackedVarLocal _ root tipe ->
                                            Names.withVarType root tipe
                                                (Names.traverse (optimizeBranch root) branches)
                                                |> Names.fmap (Case.optimize temp root)

                                        _ ->
                                            Names.withVarType temp scrutineeType
                                                (Names.traverse (optimizeBranch temp) branches)
                                                |> Names.fmap
                                                    (\obranches ->
                                                        let
                                                            caseExpr : TOpt.Expr
                                                            caseExpr =
                                                                Case.optimize temp temp obranches

                                                            caseType : Can.Type
                                                            caseType =
                                                                TOpt.typeOf caseExpr
                                                        in
                                                        TOpt.Let (TOpt.Def region temp oexpr scrutineeType) caseExpr caseType
                                                    )
                                )
                    )

        Can.Accessor field ->
            -- Accessor is a function: { r | field : a } -> a
            let
                -- We don't know the exact record type, so use a type variable
                fieldVar : Can.Type
                fieldVar =
                    Can.TVar "a"

                recordVar : Can.Type
                recordVar =
                    Can.TRecord (Dict.singleton identity field (Can.FieldType 0 fieldVar)) (Just "r")

                accessorType : Can.Type
                accessorType =
                    Can.TLambda recordVar fieldVar
            in
            Names.registerField field (TOpt.Accessor region field accessorType)

        Can.Access record (A.At fieldPosition field) ->
            optimize cycle annotations record
                |> Names.bind
                    (\optRecord ->
                        let
                            recordType : Can.Type
                            recordType =
                                TOpt.typeOf optRecord

                            fieldType : Can.Type
                            fieldType =
                                getFieldType field recordType
                        in
                        Names.registerField field (TOpt.Access optRecord fieldPosition field fieldType)
                    )

        Can.Update record updates ->
            Names.mapTraverse A.toValue A.compareLocated (optimizeUpdate cycle annotations) updates
                |> Names.bind
                    (\optUpdates ->
                        optimize cycle annotations record
                            |> Names.bind
                                (\optRecord ->
                                    let
                                        recordType : Can.Type
                                        recordType =
                                            TOpt.typeOf optRecord
                                    in
                                    Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue updates)
                                        (TOpt.Update region optRecord optUpdates recordType)
                                )
                    )

        Can.Record fields ->
            Names.mapTraverse A.toValue A.compareLocated (optimize cycle annotations) fields
                |> Names.bind
                    (\optFields ->
                        let
                            fieldTypes : Dict String Name Can.FieldType
                            fieldTypes =
                                Dict.map
                                    (\_ expr -> Can.FieldType 0 (TOpt.typeOf expr))
                                    (Utils.mapMapKeys identity A.compareLocated A.toValue optFields)

                            recordType : Can.Type
                            recordType =
                                Can.TRecord fieldTypes Nothing
                        in
                        Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue fields)
                            (TOpt.TrackedRecord region optFields recordType)
                    )

        Can.Unit ->
            Names.registerKernel Name.utils (TOpt.Unit unitType)

        Can.Tuple a b cs ->
            optimize cycle annotations a
                |> Names.bind
                    (\optA ->
                        optimize cycle annotations b
                            |> Names.bind
                                (\optB ->
                                    Names.traverse (optimize cycle annotations) cs
                                        |> Names.bind
                                            (\optCs ->
                                                let
                                                    tupleType : Can.Type
                                                    tupleType =
                                                        Can.TTuple
                                                            (TOpt.typeOf optA)
                                                            (TOpt.typeOf optB)
                                                            (List.map TOpt.typeOf optCs)
                                                in
                                                Names.registerKernel Name.utils (TOpt.Tuple region optA optB optCs tupleType)
                                            )
                                )
                    )

        Can.Shader src (Shader.Types attributes uniforms _) ->
            -- Shader type is opaque
            Names.pure
                (TOpt.Shader src
                    (EverySet.fromList identity (Dict.keys compare attributes))
                    (EverySet.fromList identity (Dict.keys compare uniforms))
                    unknownType
                )



-- HELPER FUNCTIONS


{-| Placeholder for unknown/unresolved types
-}
unknownType : Can.Type
unknownType =
    Can.TVar "_unknown"


charType : Can.Type
charType =
    Can.TType ModuleName.char "Char" []


stringType : Can.Type
stringType =
    Can.TType ModuleName.string "String" []


intType : Can.Type
intType =
    Can.TType ModuleName.basics "Int" []


floatType : Can.Type
floatType =
    Can.TType ModuleName.basics "Float" []


unitType : Can.Type
unitType =
    Can.TUnit


negateType : Can.Type
negateType =
    -- number -> number
    Can.TLambda (Can.TVar "number") (Can.TVar "number")


annotationType : Can.Annotation -> Can.Type
annotationType (Can.Forall _ tipe) =
    tipe


lookupAnnotationType : Name -> Annotations -> Can.Type
lookupAnnotationType name annotations =
    case Dict.get identity name annotations of
        Just (Can.Forall _ tipe) ->
            tipe

        Nothing ->
            unknownType


{-| Get the result type of a function call.
Peels off n TLambda wrappers.
-}
getCallResultType : Can.Type -> Int -> Can.Type
getCallResultType funcType numArgs =
    case ( funcType, numArgs ) of
        ( _, 0 ) ->
            funcType

        ( Can.TLambda _ result, n ) ->
            getCallResultType result (n - 1)

        _ ->
            -- Not enough lambdas - return what we have
            funcType


{-| Build a function type from argument types and result type.
-}
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes


{-| Get the type of a field from a record type.
-}
getFieldType : Name -> Can.Type -> Can.Type
getFieldType field recordType =
    case recordType of
        Can.TRecord fields _ ->
            case Dict.get identity field fields of
                Just (Can.FieldType _ tipe) ->
                    tipe

                Nothing ->
                    unknownType

        Can.TAlias _ _ _ (Can.Filled tipe) ->
            getFieldType field tipe

        _ ->
            unknownType


{-| Get name and type from a definition.
-}
getDefNameAndType : Can.Def -> Annotations -> ( Name, Can.Type )
getDefNameAndType def annotations =
    case def of
        Can.Def (A.At _ name) _ _ ->
            ( name, lookupAnnotationType name annotations )

        Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
            let
                argTypes : List Can.Type
                argTypes =
                    List.map Tuple.second typedArgs

                funcType : Can.Type
                funcType =
                    buildFunctionType argTypes resultType
            in
            ( name, funcType )


{-| Wrap a destructor around a body expression.
-}
wrapDestruct : Can.Type -> TOpt.Destructor -> TOpt.Expr -> TOpt.Expr
wrapDestruct bodyType destructor body =
    TOpt.Destruct destructor body bodyType



-- UPDATE


optimizeUpdate : Cycle -> Annotations -> Can.FieldUpdate -> Names.Tracker TOpt.Expr
optimizeUpdate cycle annotations (Can.FieldUpdate _ expr) =
    optimize cycle annotations expr



-- DEFINITION


optimizeDefAndBody : Cycle -> Annotations -> Can.Def -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeDefAndBody cycle annotations def body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp cycle annotations region name args expr body

        Can.TypedDef (A.At region name) _ typedArgs expr resultType ->
            optimizeTypedDefHelp cycle annotations region name typedArgs expr resultType body


optimizeDefHelp : Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeDefHelp cycle annotations region name args expr body =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations
    in
    case args of
        [] ->
            optimize cycle annotations expr
                |> Names.bind
                    (\oexpr ->
                        let
                            exprType : Can.Type
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        Names.withVarType name exprType
                            (optimize cycle annotations body)
                            |> Names.fmap
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let (TOpt.Def region name oexpr exprType) obody bodyType
                                )
                    )

        _ ->
            destructArgs annotations args
                |> Names.bind
                    (\( typedArgNames, destructors ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames
                        in
                        Names.withVarTypes argTypes
                            (optimize cycle annotations expr)
                            |> Names.bind
                                (\oexpr ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf oexpr

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) bodyType

                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct bodyType) oexpr destructors)
                                                funcType
                                    in
                                    Names.withVarType name funcType
                                        (optimize cycle annotations body)
                                        |> Names.fmap
                                            (\obody ->
                                                let
                                                    resultType : Can.Type
                                                    resultType =
                                                        TOpt.typeOf obody
                                                in
                                                TOpt.Let (TOpt.Def region name ofunc funcType) obody resultType
                                            )
                                )
                    )


optimizeTypedDefHelp : Cycle -> Annotations -> A.Region -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeTypedDefHelp cycle annotations region name typedArgs expr resultType body =
    case typedArgs of
        [] ->
            optimize cycle annotations expr
                |> Names.bind
                    (\oexpr ->
                        Names.withVarType name resultType
                            (optimize cycle annotations body)
                            |> Names.fmap
                                (\obody ->
                                    let
                                        bodyType : Can.Type
                                        bodyType =
                                            TOpt.typeOf obody
                                    in
                                    TOpt.Let (TOpt.Def region name oexpr resultType) obody bodyType
                                )
                    )

        _ ->
            destructTypedArgs typedArgs
                |> Names.bind
                    (\( typedArgNames, destructors ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            funcType : Can.Type
                            funcType =
                                buildFunctionType (List.map Tuple.second typedArgNames) resultType
                        in
                        Names.withVarTypes argTypes
                            (optimize cycle annotations expr)
                            |> Names.bind
                                (\oexpr ->
                                    let
                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct resultType) oexpr destructors)
                                                funcType
                                    in
                                    Names.withVarType name funcType
                                        (optimize cycle annotations body)
                                        |> Names.fmap
                                            (\obody ->
                                                let
                                                    bodyType : Can.Type
                                                    bodyType =
                                                        TOpt.typeOf obody
                                                in
                                                TOpt.Let (TOpt.Def region name ofunc funcType) obody bodyType
                                            )
                                )
                    )


optimizeLetRecDefs : Cycle -> Annotations -> List Can.Def -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeLetRecDefs cycle annotations defs body =
    -- For multiple recursive defs, we add all their types to scope first
    let
        defBindings : List ( Name, Can.Type )
        defBindings =
            List.map (\d -> getDefNameAndType d annotations) defs
    in
    Names.withVarTypes defBindings
        (List.foldl
            (\def bod ->
                Names.bind (optimizeRecDefToLet cycle annotations def) bod
            )
            (optimize cycle annotations body)
            defs
        )


optimizeRecDefToLet : Cycle -> Annotations -> Can.Def -> TOpt.Expr -> Names.Tracker TOpt.Expr
optimizeRecDefToLet cycle annotations def body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeRecDefHelp cycle annotations region name args expr body

        Can.TypedDef (A.At region name) _ typedArgs expr resultType ->
            optimizeTypedRecDefHelp cycle annotations region name typedArgs expr resultType body


optimizeRecDefHelp : Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> TOpt.Expr -> Names.Tracker TOpt.Expr
optimizeRecDefHelp cycle annotations region name args expr body =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations

        bodyType : Can.Type
        bodyType =
            TOpt.typeOf body
    in
    case args of
        [] ->
            optimize cycle annotations expr
                |> Names.fmap
                    (\oexpr ->
                        TOpt.Let (TOpt.Def region name oexpr defType) body bodyType
                    )

        _ ->
            destructArgs annotations args
                |> Names.bind
                    (\( typedArgNames, destructors ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames
                        in
                        Names.withVarTypes argTypes
                            (optimize cycle annotations expr)
                            |> Names.fmap
                                (\oexpr ->
                                    let
                                        exprType : Can.Type
                                        exprType =
                                            TOpt.typeOf oexpr

                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) exprType

                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct exprType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body bodyType
                                )
                    )


optimizeTypedRecDefHelp : Cycle -> Annotations -> A.Region -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> TOpt.Expr -> Names.Tracker TOpt.Expr
optimizeTypedRecDefHelp cycle annotations region name typedArgs expr resultType body =
    let
        bodyType : Can.Type
        bodyType =
            TOpt.typeOf body
    in
    case typedArgs of
        [] ->
            optimize cycle annotations expr
                |> Names.fmap
                    (\oexpr ->
                        TOpt.Let (TOpt.Def region name oexpr resultType) body bodyType
                    )

        _ ->
            destructTypedArgs typedArgs
                |> Names.bind
                    (\( typedArgNames, destructors ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            funcType : Can.Type
                            funcType =
                                buildFunctionType (List.map Tuple.second typedArgNames) resultType
                        in
                        Names.withVarTypes argTypes
                            (optimize cycle annotations expr)
                            |> Names.fmap
                                (\oexpr ->
                                    let
                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct resultType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body bodyType
                                )
                    )



-- DESTRUCTURING


destructArgs : Annotations -> List Can.Pattern -> Names.Tracker ( List ( A.Located Name, Can.Type ), List TOpt.Destructor )
destructArgs annotations args =
    Names.traverse (destruct annotations) args
        |> Names.fmap
            (\results ->
                let
                    ( names, types, destructorLists ) =
                        List.foldr
                            (\( n, t, ds ) ( ns, ts, dss ) -> ( n :: ns, t :: ts, ds ++ dss ))
                            ( [], [], [] )
                            results
                in
                ( List.map2 Tuple.pair names types, destructorLists )
            )


destructTypedArgs : List ( Can.Pattern, Can.Type ) -> Names.Tracker ( List ( A.Located Name, Can.Type ), List TOpt.Destructor )
destructTypedArgs typedArgs =
    Names.traverse destructTypedArg typedArgs
        |> Names.fmap
            (\results ->
                let
                    ( names, destructorLists ) =
                        List.foldr
                            (\( n, ds ) ( ns, dss ) -> ( n :: ns, ds ++ dss ))
                            ( [], [] )
                            results
                in
                ( names, destructorLists )
            )


destructTypedArg : ( Can.Pattern, Can.Type ) -> Names.Tracker ( ( A.Located Name, Can.Type ), List TOpt.Destructor )
destructTypedArg ( pattern, tipe ) =
    destructWithType tipe pattern
        |> Names.fmap (\( locName, destructors ) -> ( ( locName, tipe ), destructors ))


destructCase : Annotations -> Name -> Can.Pattern -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
destructCase annotations rootName pattern =
    let
        patternType : Can.Type
        patternType =
            getPatternType annotations pattern
    in
    destructHelpCollectBindings (TOpt.Root rootName) patternType pattern ( [], [] )
        |> Names.fmap (\( revDs, bindings ) -> ( List.reverse revDs, bindings ))


destruct : Annotations -> Can.Pattern -> Names.Tracker ( A.Located Name, Can.Type, List TOpt.Destructor )
destruct annotations ((A.At region ptrn) as pattern) =
    let
        patternType : Can.Type
        patternType =
            getPatternType annotations pattern
    in
    case ptrn of
        Can.PVar name ->
            Names.pure ( A.At region name, patternType, [] )

        Can.PAlias subPattern name ->
            destructHelp (TOpt.Root name) patternType subPattern []
                |> Names.fmap (\revDs -> ( A.At region name, patternType, List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.bind
                    (\name ->
                        destructHelp (TOpt.Root name) patternType pattern []
                            |> Names.fmap (\revDs -> ( A.At region name, patternType, List.reverse revDs ))
                    )


destructWithType : Can.Type -> Can.Pattern -> Names.Tracker ( A.Located Name, List TOpt.Destructor )
destructWithType tipe ((A.At region ptrn) as pattern) =
    case ptrn of
        Can.PVar name ->
            Names.pure ( A.At region name, [] )

        Can.PAlias subPattern name ->
            destructHelp (TOpt.Root name) tipe subPattern []
                |> Names.fmap (\revDs -> ( A.At region name, List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.bind
                    (\name ->
                        destructHelp (TOpt.Root name) tipe pattern []
                            |> Names.fmap (\revDs -> ( A.At region name, List.reverse revDs ))
                    )


{-| Try to infer type from pattern structure.
This is a best-effort approach for patterns.
-}
getPatternType : Annotations -> Can.Pattern -> Can.Type
getPatternType _ (A.At _ pattern) =
    case pattern of
        Can.PAnything ->
            unknownType

        Can.PVar _ ->
            unknownType

        Can.PRecord _ ->
            unknownType

        Can.PAlias _ _ ->
            unknownType

        Can.PUnit ->
            unitType

        Can.PTuple _ _ [] ->
            unknownType

        Can.PTuple _ _ _ ->
            unknownType

        Can.PList _ ->
            unknownType

        Can.PCons _ _ ->
            unknownType

        Can.PChr _ ->
            charType

        Can.PStr _ _ ->
            stringType

        Can.PInt _ ->
            intType

        Can.PBool _ _ ->
            Can.TType ModuleName.basics "Bool" []

        Can.PCtor { union, name } ->
            let
                (Can.Union vars _ _ _) =
                    union
            in
            -- Use the constructor's type from the union
            -- This is simplified - would need full type from annotation
            unknownType


destructHelp : TOpt.Path -> Can.Type -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructHelp path tipe (A.At _ pattern) revDs =
    case pattern of
        Can.PAnything ->
            Names.pure revDs

        Can.PVar name ->
            Names.pure (TOpt.Destructor name path tipe :: revDs)

        Can.PRecord fields ->
            let
                toDestruct : Name -> TOpt.Destructor
                toDestruct name =
                    let
                        fieldType : Can.Type
                        fieldType =
                            getFieldType name tipe
                    in
                    TOpt.Destructor name (TOpt.Field name path) fieldType
            in
            Names.registerFieldList fields (List.map toDestruct fields ++ revDs)

        Can.PAlias subPattern name ->
            destructHelp (TOpt.Root name) tipe subPattern <|
                (TOpt.Destructor name path tipe :: revDs)

        Can.PUnit ->
            Names.pure revDs

        Can.PTuple a b [] ->
            destructTwo path tipe a b revDs

        Can.PTuple a b [ c ] ->
            let
                ( aType, bType, cType ) =
                    case tipe of
                        Can.TTuple t1 t2 [ t3 ] ->
                            ( t1, t2, t3 )

                        _ ->
                            ( unknownType, unknownType, unknownType )
            in
            case path of
                TOpt.Root _ ->
                    destructHelp (TOpt.Index Index.first path) aType a revDs
                        |> Names.bind (destructHelp (TOpt.Index Index.second path) bType b)
                        |> Names.bind (destructHelp (TOpt.Index Index.third path) cType c)

                _ ->
                    Names.generate
                        |> Names.bind
                            (\name ->
                                let
                                    newRoot : TOpt.Path
                                    newRoot =
                                        TOpt.Root name
                                in
                                destructHelp (TOpt.Index Index.first newRoot) aType a (TOpt.Destructor name path tipe :: revDs)
                                    |> Names.bind (destructHelp (TOpt.Index Index.second newRoot) bType b)
                                    |> Names.bind (destructHelp (TOpt.Index Index.third newRoot) cType c)
                            )

        Can.PTuple a b cs ->
            let
                ( aType, bType, csTypes ) =
                    case tipe of
                        Can.TTuple t1 t2 ts ->
                            ( t1, t2, ts )

                        _ ->
                            ( unknownType, unknownType, List.map (\_ -> unknownType) cs )
            in
            case path of
                TOpt.Root _ ->
                    List.foldl
                        (\( index, ( arg, argType ) ) ->
                            Names.bind (destructHelp (TOpt.ArrayIndex index (TOpt.Field "cs" path)) argType arg)
                        )
                        (destructHelp (TOpt.Index Index.first path) aType a revDs
                            |> Names.bind (destructHelp (TOpt.Index Index.second path) bType b)
                        )
                        (List.map2 Tuple.pair (List.range 0 (List.length cs - 1)) (List.map2 Tuple.pair cs csTypes))

                _ ->
                    Names.generate
                        |> Names.bind
                            (\name ->
                                let
                                    newRoot : TOpt.Path
                                    newRoot =
                                        TOpt.Root name
                                in
                                List.foldl
                                    (\( index, ( arg, argType ) ) ->
                                        Names.bind (destructHelp (TOpt.ArrayIndex index (TOpt.Field "cs" newRoot)) argType arg)
                                    )
                                    (destructHelp (TOpt.Index Index.first newRoot) aType a (TOpt.Destructor name path tipe :: revDs)
                                        |> Names.bind (destructHelp (TOpt.Index Index.second newRoot) bType b)
                                    )
                                    (List.map2 Tuple.pair (List.range 0 (List.length cs - 1)) (List.map2 Tuple.pair cs csTypes))
                            )

        Can.PList [] ->
            Names.pure revDs

        Can.PList (hd :: tl) ->
            let
                elemType : Can.Type
                elemType =
                    case tipe of
                        Can.TType _ "List" [ t ] ->
                            t

                        _ ->
                            unknownType
            in
            destructTwo path tipe hd (A.At (A.Region (A.Position 0 0) (A.Position 0 0)) (Can.PList tl)) revDs

        Can.PCons hd tl ->
            let
                elemType : Can.Type
                elemType =
                    case tipe of
                        Can.TType _ "List" [ t ] ->
                            t

                        _ ->
                            unknownType
            in
            destructTwo path tipe hd tl revDs

        Can.PChr _ ->
            Names.pure revDs

        Can.PStr _ _ ->
            Names.pure revDs

        Can.PInt _ ->
            Names.pure revDs

        Can.PBool _ _ ->
            Names.pure revDs

        Can.PCtor { union, args } ->
            case args of
                [ Can.PatternCtorArg _ argType arg ] ->
                    let
                        (Can.Union _ _ _ opts) =
                            union
                    in
                    case opts of
                        Can.Normal ->
                            destructHelp (TOpt.Index Index.first path) argType arg revDs

                        Can.Unbox ->
                            destructHelp (TOpt.Unbox path) argType arg revDs

                        Can.Enum ->
                            destructHelp (TOpt.Index Index.first path) argType arg revDs

                _ ->
                    case path of
                        TOpt.Root _ ->
                            List.foldl (\arg -> Names.bind (\revDs_ -> destructCtorArg path revDs_ arg))
                                (Names.pure revDs)
                                args

                        _ ->
                            Names.generate
                                |> Names.bind
                                    (\name ->
                                        List.foldl (\arg -> Names.bind (\revDs_ -> destructCtorArg (TOpt.Root name) revDs_ arg))
                                            (Names.pure (TOpt.Destructor name path tipe :: revDs))
                                            args
                                    )


destructTwo : TOpt.Path -> Can.Type -> Can.Pattern -> Can.Pattern -> List TOpt.Destructor -> Names.Tracker (List TOpt.Destructor)
destructTwo path tipe a b revDs =
    let
        ( aType, bType ) =
            case tipe of
                Can.TTuple t1 t2 [] ->
                    ( t1, t2 )

                Can.TType _ "List" [ elemType ] ->
                    ( elemType, tipe )

                _ ->
                    ( unknownType, unknownType )
    in
    case path of
        TOpt.Root _ ->
            destructHelp (TOpt.Index Index.first path) aType a revDs
                |> Names.bind (destructHelp (TOpt.Index Index.second path) bType b)

        _ ->
            Names.generate
                |> Names.bind
                    (\name ->
                        let
                            newRoot : TOpt.Path
                            newRoot =
                                TOpt.Root name
                        in
                        destructHelp (TOpt.Index Index.first newRoot) aType a (TOpt.Destructor name path tipe :: revDs)
                            |> Names.bind (destructHelp (TOpt.Index Index.second newRoot) bType b)
                    )


destructCtorArg : TOpt.Path -> List TOpt.Destructor -> Can.PatternCtorArg -> Names.Tracker (List TOpt.Destructor)
destructCtorArg path revDs (Can.PatternCtorArg index argType arg) =
    destructHelp (TOpt.Index index path) argType arg revDs


destructHelpCollectBindings : TOpt.Path -> Can.Type -> Can.Pattern -> ( List TOpt.Destructor, List ( Name, Can.Type ) ) -> Names.Tracker ( List TOpt.Destructor, List ( Name, Can.Type ) )
destructHelpCollectBindings path tipe (A.At _ pattern) ( revDs, bindings ) =
    case pattern of
        Can.PAnything ->
            Names.pure ( revDs, bindings )

        Can.PVar name ->
            Names.pure ( TOpt.Destructor name path tipe :: revDs, ( name, tipe ) :: bindings )

        Can.PRecord fields ->
            let
                newBindings : List ( Name, Can.Type )
                newBindings =
                    List.map (\f -> ( f, getFieldType f tipe )) fields

                toDestruct : Name -> TOpt.Destructor
                toDestruct name =
                    TOpt.Destructor name (TOpt.Field name path) (getFieldType name tipe)
            in
            Names.registerFieldList fields ( List.map toDestruct fields ++ revDs, newBindings ++ bindings )

        Can.PAlias subPattern name ->
            destructHelpCollectBindings (TOpt.Root name) tipe subPattern
                ( TOpt.Destructor name path tipe :: revDs, ( name, tipe ) :: bindings )

        _ ->
            -- For other patterns, use the simpler destructHelp
            destructHelp path tipe (A.At (A.Region (A.Position 0 0) (A.Position 0 0)) pattern) revDs
                |> Names.fmap (\newRevDs -> ( newRevDs, bindings ))



-- TAIL CALL


optimizePotentialTailCallDef : Cycle -> Annotations -> Can.Def -> Names.Tracker TOpt.Def
optimizePotentialTailCallDef cycle annotations def =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizePotentialTailCall cycle annotations region name args expr

        Can.TypedDef (A.At region name) _ typedArgs expr resultType ->
            optimizeTypedPotentialTailCall cycle annotations region name typedArgs expr resultType


optimizePotentialTailCall : Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> Names.Tracker TOpt.Def
optimizePotentialTailCall cycle annotations region name args expr =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations
    in
    destructArgs annotations args
        |> Names.bind
            (\( typedArgNames, destructors ) ->
                let
                    argTypes : List ( Name, Can.Type )
                    argTypes =
                        List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                    returnType : Can.Type
                    returnType =
                        getCallResultType defType (List.length args)
                in
                Names.withVarTypes argTypes
                    (optimizeTail cycle annotations name typedArgNames returnType expr)
                    |> Names.fmap (toTailDef region name typedArgNames destructors returnType)
            )


optimizeTypedPotentialTailCall : Cycle -> Annotations -> A.Region -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> Names.Tracker TOpt.Def
optimizeTypedPotentialTailCall cycle annotations region name typedArgs expr resultType =
    destructTypedArgs typedArgs
        |> Names.bind
            (\( typedArgNames, destructors ) ->
                let
                    argTypes : List ( Name, Can.Type )
                    argTypes =
                        List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames
                in
                Names.withVarTypes argTypes
                    (optimizeTail cycle annotations name typedArgNames resultType expr)
                    |> Names.fmap (toTailDef region name typedArgNames destructors resultType)
            )


optimizeTail : Cycle -> Annotations -> Name -> List ( A.Located Name, Can.Type ) -> Can.Type -> Can.Expr -> Names.Tracker TOpt.Expr
optimizeTail cycle annotations rootName typedArgNames returnType ((A.At region expression) as locExpr) =
    case expression of
        Can.Call func args ->
            Names.traverse (optimize cycle annotations) args
                |> Names.bind
                    (\oargs ->
                        let
                            isMatchingName : Bool
                            isMatchingName =
                                case A.toValue func of
                                    Can.VarLocal n ->
                                        rootName == n

                                    Can.VarTopLevel _ n ->
                                        rootName == n

                                    _ ->
                                        False
                        in
                        if isMatchingName then
                            case Index.indexedZipWith (\_ ( a, _ ) b -> ( A.toValue a, b )) typedArgNames oargs of
                                Index.LengthMatch pairs ->
                                    Names.pure (TOpt.TailCall rootName pairs returnType)

                                Index.LengthMismatch _ _ ->
                                    optimize cycle annotations func
                                        |> Names.fmap
                                            (\ofunc ->
                                                let
                                                    funcType : Can.Type
                                                    funcType =
                                                        TOpt.typeOf ofunc

                                                    resultType : Can.Type
                                                    resultType =
                                                        getCallResultType funcType (List.length oargs)
                                                in
                                                TOpt.Call region ofunc oargs resultType
                                            )

                        else
                            optimize cycle annotations func
                                |> Names.fmap
                                    (\ofunc ->
                                        let
                                            funcType : Can.Type
                                            funcType =
                                                TOpt.typeOf ofunc

                                            resultType : Can.Type
                                            resultType =
                                                getCallResultType funcType (List.length oargs)
                                        in
                                        TOpt.Call region ofunc oargs resultType
                                    )
                    )

        Can.If branches finally ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( TOpt.Expr, TOpt.Expr )
                optimizeBranch ( condition, branch ) =
                    optimize cycle annotations condition
                        |> Names.bind
                            (\optimizeCondition ->
                                optimizeTail cycle annotations rootName typedArgNames returnType branch
                                    |> Names.fmap (Tuple.pair optimizeCondition)
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.bind
                    (\obranches ->
                        optimizeTail cycle annotations rootName typedArgNames returnType finally
                            |> Names.fmap
                                (\ofinally ->
                                    let
                                        resultType : Can.Type
                                        resultType =
                                            TOpt.typeOf ofinally
                                    in
                                    TOpt.If obranches ofinally resultType
                                )
                    )

        Can.Let def body ->
            let
                ( defName, defType ) =
                    getDefNameAndType def annotations
            in
            case def of
                Can.Def (A.At defRegion _) defArgs defExpr ->
                    optimizeDefForTail cycle annotations defRegion defName defArgs defExpr defType
                        |> Names.bind
                            (\odef ->
                                Names.withVarType defName defType
                                    (optimizeTail cycle annotations rootName typedArgNames returnType body)
                                    |> Names.fmap
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let odef obody bodyType
                                        )
                            )

                Can.TypedDef (A.At defRegion _) _ defTypedArgs defExpr defResultType ->
                    optimizeTypedDefForTail cycle annotations defRegion defName defTypedArgs defExpr defResultType
                        |> Names.bind
                            (\odef ->
                                Names.withVarType defName defType
                                    (optimizeTail cycle annotations rootName typedArgNames returnType body)
                                    |> Names.fmap
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let odef obody bodyType
                                        )
                            )

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef cycle annotations def
                        |> Names.bind
                            (\odef ->
                                let
                                    ( defName, defType ) =
                                        getDefNameAndType def annotations
                                in
                                Names.withVarType defName defType
                                    (optimizeTail cycle annotations rootName typedArgNames returnType body)
                                    |> Names.fmap
                                        (\obody ->
                                            let
                                                bodyType : Can.Type
                                                bodyType =
                                                    TOpt.typeOf obody
                                            in
                                            TOpt.Let odef obody bodyType
                                        )
                            )

                _ ->
                    -- Multiple recursive defs - fall back to regular optimization
                    optimizeLetRecDefs cycle annotations defs body

        Can.LetDestruct pattern expr body ->
            destruct annotations pattern
                |> Names.bind
                    (\( A.At dregion dname, patternType, destructors ) ->
                        optimize cycle annotations expr
                            |> Names.bind
                                (\oexpr ->
                                    Names.withVarType dname patternType
                                        (optimizeTail cycle annotations rootName typedArgNames returnType body)
                                        |> Names.fmap
                                            (\obody ->
                                                let
                                                    bodyType : Can.Type
                                                    bodyType =
                                                        TOpt.typeOf obody
                                                in
                                                TOpt.Let (TOpt.Def dregion dname oexpr patternType)
                                                    (List.foldr (wrapDestruct bodyType) obody destructors)
                                                    bodyType
                                            )
                                )
                    )

        Can.Case expr branches ->
            let
                optimizeBranch : Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, TOpt.Expr )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase annotations root pattern
                        |> Names.bind
                            (\( destructors, patternBindings ) ->
                                Names.withVarTypes patternBindings
                                    (optimizeTail cycle annotations rootName typedArgNames returnType branch)
                                    |> Names.fmap
                                        (\obranch ->
                                            let
                                                branchType : Can.Type
                                                branchType =
                                                    TOpt.typeOf obranch
                                            in
                                            ( pattern, List.foldr (wrapDestruct branchType) obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.bind
                    (\temp ->
                        optimize cycle annotations expr
                            |> Names.bind
                                (\oexpr ->
                                    let
                                        exprType : Can.Type
                                        exprType =
                                            TOpt.typeOf oexpr
                                    in
                                    case oexpr of
                                        TOpt.VarLocal root tipe ->
                                            Names.withVarType root tipe
                                                (Names.traverse (optimizeBranch root) branches)
                                                |> Names.fmap (Case.optimize temp root)

                                        TOpt.TrackedVarLocal _ root tipe ->
                                            Names.withVarType root tipe
                                                (Names.traverse (optimizeBranch root) branches)
                                                |> Names.fmap (Case.optimize temp root)

                                        _ ->
                                            Names.withVarType temp exprType
                                                (Names.traverse (optimizeBranch temp) branches)
                                                |> Names.fmap
                                                    (\obranches ->
                                                        let
                                                            caseExpr : TOpt.Expr
                                                            caseExpr =
                                                                Case.optimize temp temp obranches

                                                            caseType : Can.Type
                                                            caseType =
                                                                TOpt.typeOf caseExpr
                                                        in
                                                        TOpt.Let (TOpt.Def region temp oexpr exprType) caseExpr caseType
                                                    )
                                )
                    )

        _ ->
            optimize cycle annotations locExpr


optimizeDefForTail : Cycle -> Annotations -> A.Region -> Name -> List Can.Pattern -> Can.Expr -> Can.Type -> Names.Tracker TOpt.Def
optimizeDefForTail cycle annotations region name args expr defType =
    case args of
        [] ->
            optimize cycle annotations expr
                |> Names.fmap
                    (\oexpr ->
                        TOpt.Def region name oexpr defType
                    )

        _ ->
            destructArgs annotations args
                |> Names.bind
                    (\( typedArgNames, destructors ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            returnType : Can.Type
                            returnType =
                                getCallResultType defType (List.length args)
                        in
                        Names.withVarTypes argTypes
                            (optimize cycle annotations expr)
                            |> Names.fmap
                                (\oexpr ->
                                    let
                                        funcType : Can.Type
                                        funcType =
                                            buildFunctionType (List.map Tuple.second typedArgNames) returnType

                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct returnType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Def region name ofunc funcType
                                )
                    )


optimizeTypedDefForTail : Cycle -> Annotations -> A.Region -> Name -> List ( Can.Pattern, Can.Type ) -> Can.Expr -> Can.Type -> Names.Tracker TOpt.Def
optimizeTypedDefForTail cycle annotations region name typedArgs expr resultType =
    case typedArgs of
        [] ->
            optimize cycle annotations expr
                |> Names.fmap (\oexpr -> TOpt.Def region name oexpr resultType)

        _ ->
            destructTypedArgs typedArgs
                |> Names.bind
                    (\( typedArgNames, destructors ) ->
                        let
                            argTypes : List ( Name, Can.Type )
                            argTypes =
                                List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                            funcType : Can.Type
                            funcType =
                                buildFunctionType (List.map Tuple.second typedArgNames) resultType
                        in
                        Names.withVarTypes argTypes
                            (optimize cycle annotations expr)
                            |> Names.fmap
                                (\oexpr ->
                                    let
                                        ofunc : TOpt.Expr
                                        ofunc =
                                            TOpt.TrackedFunction typedArgNames
                                                (List.foldr (wrapDestruct resultType) oexpr destructors)
                                                funcType
                                    in
                                    TOpt.Def region name ofunc funcType
                                )
                    )



-- DETECT TAIL CALLS


toTailDef : A.Region -> Name -> List ( A.Located Name, Can.Type ) -> List TOpt.Destructor -> Can.Type -> TOpt.Expr -> TOpt.Def
toTailDef region name typedArgNames destructors returnType body =
    if hasTailCall body then
        TOpt.TailDef region name typedArgNames (List.foldr (wrapDestruct returnType) body destructors) returnType

    else
        let
            funcType : Can.Type
            funcType =
                buildFunctionType (List.map Tuple.second typedArgNames) returnType
        in
        TOpt.Def region name (TOpt.TrackedFunction typedArgNames (List.foldr (wrapDestruct returnType) body destructors) funcType) funcType


hasTailCall : TOpt.Expr -> Bool
hasTailCall expression =
    case expression of
        TOpt.TailCall _ _ _ ->
            True

        TOpt.If branches finally _ ->
            hasTailCall finally || List.any (hasTailCall << Tuple.second) branches

        TOpt.Let _ body _ ->
            hasTailCall body

        TOpt.Destruct _ body _ ->
            hasTailCall body

        TOpt.Case _ _ decider jumps _ ->
            deciderHasTailCall decider || List.any (hasTailCall << Tuple.second) jumps

        _ ->
            False


deciderHasTailCall : TOpt.Decider TOpt.Choice -> Bool
deciderHasTailCall decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline expr ->
                    hasTailCall expr

                TOpt.Jump _ ->
                    False

        TOpt.Chain _ success failure ->
            deciderHasTailCall success || deciderHasTailCall failure

        TOpt.FanOut _ tests fallback ->
            deciderHasTailCall fallback || List.any (deciderHasTailCall << Tuple.second) tests
