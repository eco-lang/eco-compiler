module Compiler.Optimize.TypedModule exposing
    ( Annotations
    , MResult
    , optimize
    )

{-| Typed module optimization.

Like Module.elm but produces TypedOptimized.LocalGraph with full type information.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Type as Type
import Compiler.Canonicalize.Effects as Effects
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.TypedExpression as Expr
import Compiler.Optimize.TypedNames as Names
import Compiler.Optimize.TypedPort as Port
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Main as E
import Compiler.Reporting.Result as R
import Compiler.Reporting.Warning as W
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO
import Utils.Main as Utils



-- OPTIMIZE


type alias MResult i w a =
    R.RResult i w E.Error a


type alias Annotations =
    Dict String Name.Name Can.Annotation


optimize : Annotations -> Can.Module -> MResult i (List W.Warning) TOpt.LocalGraph
optimize annotations (Can.Module home _ _ decls unions aliases _ effects) =
    addDecls home annotations decls <|
        addEffects home annotations effects <|
            addUnions home annotations unions <|
                addAliases home annotations aliases <|
                    TOpt.LocalGraph Nothing Dict.empty Dict.empty annotations



-- UNION


type alias Nodes =
    Dict (List String) TOpt.Global TOpt.Node


addUnions : IO.Canonical -> Annotations -> Dict String Name.Name Can.Union -> TOpt.LocalGraph -> TOpt.LocalGraph
addUnions home annotations unions (TOpt.LocalGraph main nodes fields ann) =
    TOpt.LocalGraph main (Dict.foldr compare (\_ -> addUnion home annotations) nodes unions) fields ann


addUnion : IO.Canonical -> Annotations -> Can.Union -> Nodes -> Nodes
addUnion home annotations (Can.Union _ ctors _ opts) nodes =
    List.foldl (addCtorNode home annotations opts) nodes ctors


addCtorNode : IO.Canonical -> Annotations -> Can.CtorOpts -> Can.Ctor -> Nodes -> Nodes
addCtorNode home annotations opts (Can.Ctor name index numArgs ctorType) nodes =
    let
        -- Build the constructor type from its arguments and result type
        ctorFullType : Can.Type
        ctorFullType =
            buildCtorType ctorType

        node : TOpt.Node
        node =
            case opts of
                Can.Normal ->
                    TOpt.Ctor index numArgs ctorFullType

                Can.Unbox ->
                    TOpt.Box ctorFullType

                Can.Enum ->
                    TOpt.Enum index ctorFullType
    in
    Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) node nodes


{-| Build the full constructor type.
For a constructor like `Just : a -> Maybe a`, this builds `a -> Maybe a`.
-}
buildCtorType : List Can.Type -> Can.Type
buildCtorType types =
    case types of
        [] ->
            Can.TVar "_unknown"

        [ result ] ->
            result

        argType :: rest ->
            Can.TLambda argType (buildCtorType rest)



-- ALIAS


addAliases : IO.Canonical -> Annotations -> Dict String Name.Name Can.Alias -> TOpt.LocalGraph -> TOpt.LocalGraph
addAliases home annotations aliases graph =
    Dict.foldr compare (addAlias home annotations) graph aliases


addAlias : IO.Canonical -> Annotations -> Name.Name -> Can.Alias -> TOpt.LocalGraph -> TOpt.LocalGraph
addAlias home annotations name (Can.Alias _ tipe) ((TOpt.LocalGraph main nodes fieldCounts ann) as graph) =
    case tipe of
        Can.TRecord fields Nothing ->
            let
                fieldNames : List Name.Name
                fieldNames =
                    List.map Tuple.first (Can.fieldsToList fields)

                -- Build the record constructor function type
                fieldTypes : List Can.Type
                fieldTypes =
                    List.map Tuple.second (Can.fieldsToList fields)

                recordType : Can.Type
                recordType =
                    tipe

                funcType : Can.Type
                funcType =
                    List.foldr Can.TLambda recordType fieldTypes

                function : TOpt.Expr
                function =
                    TOpt.Function
                        (List.map2 Tuple.pair fieldNames fieldTypes)
                        (TOpt.Record
                            (Dict.map (\field _ -> TOpt.VarLocal field (getFieldTypeFromFields field fields)) fields)
                            recordType
                        )
                        funcType

                node : TOpt.Node
                node =
                    TOpt.Define function EverySet.empty funcType
            in
            TOpt.LocalGraph
                main
                (Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) node nodes)
                (Dict.foldr compare addRecordCtorField fieldCounts fields)
                ann

        _ ->
            graph


getFieldTypeFromFields : Name.Name -> Dict String Name.Name Can.FieldType -> Can.Type
getFieldTypeFromFields name fields =
    case Dict.get identity name fields of
        Just (Can.FieldType _ t) ->
            t

        Nothing ->
            Can.TVar "_unknown"


addRecordCtorField : Name.Name -> Can.FieldType -> Dict String Name.Name Int -> Dict String Name.Name Int
addRecordCtorField name _ fields =
    Utils.mapInsertWith identity (+) name 1 fields



-- ADD EFFECTS


addEffects : IO.Canonical -> Annotations -> Can.Effects -> TOpt.LocalGraph -> TOpt.LocalGraph
addEffects home annotations effects ((TOpt.LocalGraph main nodes fields ann) as graph) =
    case effects of
        Can.NoEffects ->
            graph

        Can.Ports ports ->
            Dict.foldr compare (addPort home annotations) graph ports

        Can.Manager _ _ _ manager ->
            let
                fx : TOpt.Global
                fx =
                    TOpt.Global home "$fx$"

                cmd : TOpt.Global
                cmd =
                    TOpt.Global home "command"

                sub : TOpt.Global
                sub =
                    TOpt.Global home "subscription"

                link : TOpt.Node
                link =
                    TOpt.Link fx

                newNodes : Dict (List String) TOpt.Global TOpt.Node
                newNodes =
                    case manager of
                        Can.Cmd _ ->
                            Dict.insert TOpt.toComparableGlobal cmd link <|
                                Dict.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Cmd) nodes

                        Can.Sub _ ->
                            Dict.insert TOpt.toComparableGlobal sub link <|
                                Dict.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Sub) nodes

                        Can.Fx _ _ ->
                            Dict.insert TOpt.toComparableGlobal cmd link <|
                                Dict.insert TOpt.toComparableGlobal sub link <|
                                    Dict.insert TOpt.toComparableGlobal fx (TOpt.Manager TOpt.Fx) nodes
            in
            TOpt.LocalGraph main newNodes fields ann


addPort : IO.Canonical -> Annotations -> Name.Name -> Can.Port -> TOpt.LocalGraph -> TOpt.LocalGraph
addPort home annotations name port_ graph =
    case port_ of
        Can.Incoming { payload } ->
            let
                ( deps, fieldCounts, decoder ) =
                    Names.run annotations (Port.toDecoder payload)

                portType : Can.Type
                portType =
                    lookupAnnotationType name annotations

                node : TOpt.Node
                node =
                    TOpt.PortIncoming decoder deps portType
            in
            addToGraph (TOpt.Global home name) node fieldCounts graph

        Can.Outgoing { payload } ->
            let
                ( deps, fieldCounts, encoder ) =
                    Names.run annotations (Port.toEncoder payload)

                portType : Can.Type
                portType =
                    lookupAnnotationType name annotations

                node : TOpt.Node
                node =
                    TOpt.PortOutgoing encoder deps portType
            in
            addToGraph (TOpt.Global home name) node fieldCounts graph


lookupAnnotationType : Name.Name -> Annotations -> Can.Type
lookupAnnotationType name annotations =
    case Dict.get identity name annotations of
        Just (Can.Forall _ tipe) ->
            tipe

        Nothing ->
            Can.TVar "_unknown"



-- HELPER


addToGraph : TOpt.Global -> TOpt.Node -> Dict String Name.Name Int -> TOpt.LocalGraph -> TOpt.LocalGraph
addToGraph name node fieldCounts (TOpt.LocalGraph main nodes fields ann) =
    TOpt.LocalGraph
        main
        (Dict.insert TOpt.toComparableGlobal name node nodes)
        (Utils.mapUnionWith identity compare (+) fieldCounts fields)
        ann



-- ADD DECLS


addDecls : IO.Canonical -> Annotations -> Can.Decls -> TOpt.LocalGraph -> MResult i (List W.Warning) TOpt.LocalGraph
addDecls home annotations decls graph =
    R.loop (addDeclsHelp home annotations) ( decls, graph )


addDeclsHelp : IO.Canonical -> Annotations -> ( Can.Decls, TOpt.LocalGraph ) -> MResult i (List W.Warning) (R.Step ( Can.Decls, TOpt.LocalGraph ) TOpt.LocalGraph)
addDeclsHelp home annotations ( decls, graph ) =
    case decls of
        Can.Declare def subDecls ->
            addDef home annotations def graph
                |> R.fmap (R.Loop << Tuple.pair subDecls)

        Can.DeclareRec d ds subDecls ->
            let
                defs : List Can.Def
                defs =
                    d :: ds
            in
            case findMain defs of
                Nothing ->
                    R.pure (R.Loop ( subDecls, addRecDefs home annotations defs graph ))

                Just region ->
                    R.throw <| E.BadCycle region (defToName d) (List.map defToName ds)

        Can.SaveTheEnvironment ->
            R.ok (R.Done graph)


findMain : List Can.Def -> Maybe A.Region
findMain defs =
    case defs of
        [] ->
            Nothing

        def :: rest ->
            case def of
                Can.Def (A.At region name) _ _ ->
                    if name == Name.main_ then
                        Just region

                    else
                        findMain rest

                Can.TypedDef (A.At region name) _ _ _ _ ->
                    if name == Name.main_ then
                        Just region

                    else
                        findMain rest


defToName : Can.Def -> Name.Name
defToName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name



-- ADD DEFS


addDef : IO.Canonical -> Annotations -> Can.Def -> TOpt.LocalGraph -> MResult i (List W.Warning) TOpt.LocalGraph
addDef home annotations def graph =
    case def of
        Can.Def (A.At region name) args body ->
            let
                (Can.Forall _ tipe) =
                    Utils.find identity name annotations
            in
            R.warn (W.MissingTypeAnnotation region name tipe)
                |> R.bind (\_ -> addDefHelp region annotations home name args body Nothing graph)

        Can.TypedDef (A.At region name) _ typedArgs body resultType ->
            addDefHelp region annotations home name (List.map Tuple.first typedArgs) body (Just ( typedArgs, resultType )) graph


addDefHelp : A.Region -> Annotations -> IO.Canonical -> Name.Name -> List Can.Pattern -> Can.Expr -> Maybe ( List ( Can.Pattern, Can.Type ), Can.Type ) -> TOpt.LocalGraph -> MResult i w TOpt.LocalGraph
addDefHelp region annotations home name args body maybeTypedArgs ((TOpt.LocalGraph _ nodes fieldCounts ann) as graph) =
    if name /= Name.main_ then
        R.ok (addDefNode home annotations region name args body maybeTypedArgs EverySet.empty graph)

    else
        let
            (Can.Forall _ tipe) =
                Utils.find identity name annotations

            addMain : ( EverySet (List String) TOpt.Global, Dict String Name.Name Int, TOpt.Main ) -> TOpt.LocalGraph
            addMain ( deps, localFields, main ) =
                addDefNode home annotations region name args body maybeTypedArgs deps <|
                    TOpt.LocalGraph (Just main) nodes (Utils.mapUnionWith identity compare (+) localFields fieldCounts) ann
        in
        case Type.deepDealias tipe of
            Can.TType hm nm [ _ ] ->
                if hm == ModuleName.virtualDom && nm == Name.node then
                    R.ok <| addMain <| Names.run annotations <| Names.registerKernel Name.virtualDom TOpt.Static

                else
                    R.throw (E.BadType region tipe)

            Can.TType hm nm [ flags, _, message ] ->
                if hm == ModuleName.platform && nm == Name.program then
                    case Effects.checkPayload flags of
                        Ok () ->
                            R.ok <| addMain <| Names.run annotations <| Names.fmap (TOpt.Dynamic message) <| Port.toFlagsDecoder flags

                        Err ( subType, invalidPayload ) ->
                            R.throw (E.BadFlags region subType invalidPayload)

                else
                    R.throw (E.BadType region tipe)

            _ ->
                R.throw (E.BadType region tipe)


addDefNode : IO.Canonical -> Annotations -> A.Region -> Name.Name -> List Can.Pattern -> Can.Expr -> Maybe ( List ( Can.Pattern, Can.Type ), Can.Type ) -> EverySet (List String) TOpt.Global -> TOpt.LocalGraph -> TOpt.LocalGraph
addDefNode home annotations region name args body maybeTypedArgs mainDeps graph =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations

        ( deps, localFields, def ) =
            Names.run annotations <|
                case ( args, maybeTypedArgs ) of
                    ( [], _ ) ->
                        Expr.optimize EverySet.empty annotations body
                            |> Names.fmap
                                (\oexpr ->
                                    TOpt.TrackedFunction [] oexpr defType
                                )

                    ( _, Just ( typedArgs, resultType ) ) ->
                        Expr.destructArgs annotations args
                            |> Names.bind
                                (\( typedArgNames, destructors ) ->
                                    let
                                        argBindings : List ( Name.Name, Can.Type )
                                        argBindings =
                                            List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames
                                    in
                                    Names.withVarTypes argBindings
                                        (Expr.optimize EverySet.empty annotations body)
                                        |> Names.fmap
                                            (\obody ->
                                                let
                                                    wrappedBody : TOpt.Expr
                                                    wrappedBody =
                                                        List.foldr (wrapDestruct resultType) obody destructors
                                                in
                                                TOpt.TrackedFunction typedArgNames wrappedBody defType
                                            )
                                )

                    ( _, Nothing ) ->
                        Expr.destructArgs annotations args
                            |> Names.bind
                                (\( typedArgNames, destructors ) ->
                                    let
                                        argBindings : List ( Name.Name, Can.Type )
                                        argBindings =
                                            List.map (\( loc, t ) -> ( A.toValue loc, t )) typedArgNames

                                        returnType : Can.Type
                                        returnType =
                                            getReturnType defType (List.length args)
                                    in
                                    Names.withVarTypes argBindings
                                        (Expr.optimize EverySet.empty annotations body)
                                        |> Names.fmap
                                            (\obody ->
                                                let
                                                    wrappedBody : TOpt.Expr
                                                    wrappedBody =
                                                        List.foldr (wrapDestruct returnType) obody destructors
                                                in
                                                TOpt.TrackedFunction typedArgNames wrappedBody defType
                                            )
                                )
    in
    addToGraph (TOpt.Global home name) (TOpt.TrackedDefine region def (EverySet.union deps mainDeps) defType) localFields graph


wrapDestruct : Can.Type -> TOpt.Destructor -> TOpt.Expr -> TOpt.Expr
wrapDestruct bodyType destructor body =
    TOpt.Destruct destructor body bodyType


getReturnType : Can.Type -> Int -> Can.Type
getReturnType tipe numArgs =
    case ( tipe, numArgs ) of
        ( _, 0 ) ->
            tipe

        ( Can.TLambda _ result, n ) ->
            getReturnType result (n - 1)

        _ ->
            tipe



-- ADD RECURSIVE DEFS


type State
    = State
        { values : List ( Name.Name, TOpt.Expr )
        , functions : List TOpt.Def
        }


addRecDefs : IO.Canonical -> Annotations -> List Can.Def -> TOpt.LocalGraph -> TOpt.LocalGraph
addRecDefs home annotations defs (TOpt.LocalGraph main nodes fieldCounts ann) =
    let
        names : List Name.Name
        names =
            List.reverse (List.map toName defs)

        cycleName : TOpt.Global
        cycleName =
            TOpt.Global home (Name.fromManyNames names)

        cycle : EverySet String Name.Name
        cycle =
            List.foldr addValueName EverySet.empty defs

        links : Dict (List String) TOpt.Global TOpt.Node
        links =
            List.foldr (addLink home (TOpt.Link cycleName)) Dict.empty defs

        ( deps, localFields, State { values, functions } ) =
            Names.run annotations <|
                List.foldl (\def -> Names.bind (\state -> addRecDef cycle annotations state def))
                    (Names.pure (State { values = [], functions = [] }))
                    defs
    in
    TOpt.LocalGraph
        main
        (Dict.insert TOpt.toComparableGlobal cycleName (TOpt.Cycle names values functions deps) (Dict.union links nodes))
        (Utils.mapUnionWith identity compare (+) localFields fieldCounts)
        ann


toName : Can.Def -> Name.Name
toName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


addValueName : Can.Def -> EverySet String Name.Name -> EverySet String Name.Name
addValueName def names =
    case def of
        Can.Def (A.At _ name) args _ ->
            if List.isEmpty args then
                EverySet.insert identity name names

            else
                names

        Can.TypedDef (A.At _ name) _ args _ _ ->
            if List.isEmpty args then
                EverySet.insert identity name names

            else
                names


addLink : IO.Canonical -> TOpt.Node -> Can.Def -> Dict (List String) TOpt.Global TOpt.Node -> Dict (List String) TOpt.Global TOpt.Node
addLink home link def links =
    case def of
        Can.Def (A.At _ name) _ _ ->
            Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) link links

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            Dict.insert TOpt.toComparableGlobal (TOpt.Global home name) link links



-- ADD RECURSIVE DEFS


addRecDef : EverySet String Name.Name -> Annotations -> State -> Can.Def -> Names.Tracker State
addRecDef cycle annotations state def =
    case def of
        Can.Def (A.At region name) args body ->
            addRecDefHelp cycle annotations region state name args body Nothing

        Can.TypedDef (A.At region name) _ args body resultType ->
            addRecDefHelp cycle annotations region state name (List.map Tuple.first args) body (Just ( args, resultType ))


addRecDefHelp : EverySet String Name.Name -> Annotations -> A.Region -> State -> Name.Name -> List Can.Pattern -> Can.Expr -> Maybe ( List ( Can.Pattern, Can.Type ), Can.Type ) -> Names.Tracker State
addRecDefHelp cycle annotations region (State { values, functions }) name args body maybeTypedArgs =
    let
        defType : Can.Type
        defType =
            lookupAnnotationType name annotations
    in
    case args of
        [] ->
            Expr.optimize cycle annotations body
                |> Names.fmap
                    (\obody ->
                        State
                            { values = ( name, obody ) :: values
                            , functions = functions
                            }
                    )

        _ :: _ ->
            Expr.optimizePotentialTailCall cycle annotations region name args body
                |> Names.fmap
                    (\odef ->
                        State
                            { values = values
                            , functions = odef :: functions
                            }
                    )
