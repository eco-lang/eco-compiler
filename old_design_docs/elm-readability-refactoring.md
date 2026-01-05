# Rules for Refactoring Deeply Nested Monadic Code into Flat Semantic Pipelines

This guide describes how to refactor deeply nested monadic code into flat, readable pipelines with semantic helper functions that are not themselves pipelines. The style is exemplified by the `createChannel` example: a single orchestration pipeline at the top, with small domain helpers for each step. We call this the "barbell strategy".

---

## 1. All sequencing belongs in one top-level pipeline

Deep nesting of `Task.andThen` (or similar monads) must be collapsed into one linear pipeline at the orchestration level.

Bad:
```elm
something
  |> Task.andThen (\x ->
        f x |> Task.andThen (\y ->
            g x y |> Task.andThen h
        )
     )
```

Good:
```elm
initState
  |> Task.andThen stepLoad
  |> Task.andThen stepValidate
  |> Task.andThen stepCompile
  |> Task.andThen stepFinalize
```

The pipeline should read like a story: load -> validate -> compile -> finalize.

---

## 2. Pipeline steps must be named top-level functions

Each pipeline function should be a top-level declaration with a meaningful domain name. Prefer partial application over lambdas.

Good:
```elm
state
  |> Task.andThen (setupChannelWebhook component channelName)
  |> Task.andThen (recordChannel component channelName)
```

---

## 3. No lambdas in the orchestration pipeline

All non-trivial logic belongs in helper functions. The pipeline itself must contain only named or partially-applied functions.

Bad:
```elm
|> Task.andThen (\env -> crawl env config)
```

Good:
```elm
|> Task.andThen (crawl config)
```

---

## 4. Helpers must avoid being pipelines themselves

Helper functions should express domain logic in straight-line Elm, with `let`, `case`, pattern matching, etc. They should not chain multiple `andThen`s.

Bad helper:
```elm
smallHelper =
  base
    |> Task.andThen next
```

Good helper:
```elm
recordChannel component name sessionKey =
    let
        channelRecord = ...
    in
    Apis.channelTableApi.put ...
        |> Procedure.fetchResult
        |> Procedure.map (always channelRecord)
```

---

## 5. State flows through the pipeline explicitly

When intermediate values are required by later steps, the pipeline returns and takes state that accumulates needed values.

- If a step needs 1 or 2 values, return a tuple.
- If a step needs 3 or more, define a record `type alias` with named fields.
- Define the type alias immediately above the first function that uses it.
- Try to choose good names for records and fields.

Example:
```elm
type alias ChannelSetup =
    { component : CreateChannel a
    , channelName : String
    , sessionKey : MomentoSessionKey
    }

setupChannelWebhook : ChannelSetup -> Task Never ...
```

---

## 6. Helpers may contain branching, let-bindings, and local values

All case expressions and branching should live inside helpers, not in pipeline lambdas.

Allowed:
```elm
setupChannelWebhook component channelName sessionKey =
    Apis.momentoApi.webhook sessionKey ...
        |> Procedure.fetchResult
        |> Procedure.mapError ...
```

---

## 7. Pipelines must narrate domain semantics

Use domain verbs and nouns: setupChannelWebhook, recordChannel, openCache, loadDependencies, etc. Avoid plumbing names like `continue`, `next`, or `bind`.

The pipeline should read like:
provide -> open cache -> setup webhook -> record metadata -> record channel.

---

## 8. Refactor nested binds into stepwise transitions.

Every nested monadic sequence should be converted into a series of small steps, each accepting a state and returning a state. This keeps helpers small and pipelines readable.

Before:
```elm
Task.bind (\x ->
  Task.bind (\y ->
    Task.bind (\z -> ...)
  )
)
```

After:
```elm
initial
  |> Task.andThen stepA
  |> Task.andThen stepB
  |> Task.andThen stepC
```

Each `stepX` extracts what it needs, updates state, and returns the new state — without creating another pipeline inside itself.

---

## 9. Helpers do semantic work, not plumbing

If a helper only removes a lambda or forwards parameters, delete it and instead use partial application directly in the pipeline. Helpers should contain real business logic, not just glue.

---

## 10. The orchestration pipeline is long; helpers are short

This is the barbell pattern:

- Heavy orchestration: long pipeline at the top-level.
- Heavy semantics: logic inside helpers.
- Thin connections: each step is a single function call.

Never mix long pipelines inside helpers; never put deep logic in the pipeline.

---

## 11. The orchestration pipeline should read as a narrative

- No deep indentation
- No nested binds
- No large anonymous lambdas
- A sequence of named, semantic actions

Ideal:
```elm
provide channelName
    |> Procedure.andThen openMomento
    |> Procedure.andThen (setupChannelWebhook component channelName)
    |> Procedure.andThen (recordEventsLogMetaData component channelName)
    |> Procedure.andThen (recordChannel component channelName)
    |> Procedure.mapError encodeError
    |> Procedure.map encodeSuccess
```

---

## 12. The rules should be applied recursively to reduce all deeply nested code into pipelines and helpers.

- It may take several passes to complete the recursive reduction.
- We want to eliminate all deeply nested code that can be transformed into flat pipeline.

## Summary

- Flatten all monadic sequencing into a single top-level pipeline.
- Use named top-level step functions (partial application, no lambdas).
- Helpers contain semantic logic but do not contain pipelines.
- Pass state explicitly; when ≥3 fields are needed, create a record type alias.
- Name everything by domain meaning.
- The orchestration should read like a well-written story of the domain.

This produces fully readable, maintainable, and extensible code in large Elm applications.

Below is a nice example of pipelined code that you can draw on for inspiration:

```elm
module EventLog.CreateChannel exposing (createChannel)

import AWS.Dynamo as Dynamo exposing (Error(..))
import Codec
import DB.ChannelTable as ChannelTable
import DB.EventLogTable
import ErrorFormat exposing (ErrorFormat)
import EventLog.Apis as Apis
import EventLog.Model exposing (Model(..), ReadyState)
import EventLog.Msg exposing (Msg(..))
import EventLog.OpenMomentoCache as OpenMomentoCache
import Http.Response as Response exposing (Response)
import HttpServer exposing (ApiRequest, Error, HttpSessionKey)
import Momento exposing (CacheItem, Error, MomentoSessionKey)
import Names
import Procedure
import Random
import Time
import Update2 as U2


type alias CreateChannel a =
    { a
        | momentoApiKey : String
        , channelApiUrl : String
        , channelTable : String
        , eventLogTable : String
        , eventLog : Model
    }


setModel : CreateChannel a -> Model -> CreateChannel a
setModel m x =
    { m | eventLog = x }


switchState : (a -> Model) -> a -> ( Model, Cmd Msg )
switchState cons state =
    ( cons state
    , Cmd.none
    )


{-| Channel creation:

    * Create the cache or confirm it already exists.
    * Create a webhook on the save topic.
    * Create the meta-data record for the channel in the events table.
    * Record the channel information in the channels table.
    * Return a confirmation that everything has been set up.

-}
createChannel : HttpSessionKey -> ReadyState -> CreateChannel a -> ( CreateChannel a, Cmd Msg )
createChannel session state component =
    let
        ( channelName, nextSeed ) =
            Random.step Names.nameGenerator state.seed

        procedure : Procedure.Procedure Response Response Msg
        procedure =
            Procedure.provide channelName
                |> Procedure.andThen (OpenMomentoCache.openMomentoCache component)
                |> Procedure.andThen (setupChannelWebhook component channelName)
                |> Procedure.andThen (recordEventsLogMetaData component channelName)
                |> Procedure.andThen (recordChannel component channelName)
                |> Procedure.mapError (ErrorFormat.encodeErrorFormat >> Response.err500json)
                |> Procedure.map (Codec.encoder ChannelTable.recordCodec >> Response.ok200json)
    in
    ( { seed = nextSeed
      , procedure = state.procedure
      , cache = state.cache
      }
    , Procedure.try ProcedureMsg (HttpResponse session) procedure
    )
        |> U2.andMap (ModelReady |> switchState)
        |> Tuple.mapFirst (setModel component)


setupChannelWebhook :
    CreateChannel a
    -> String
    -> MomentoSessionKey
    -> Procedure.Procedure ErrorFormat MomentoSessionKey Msg
setupChannelWebhook component channelName sessionKey =
    Apis.momentoApi.webhook
        sessionKey
        { name = Names.webhookName channelName
        , topic = Names.notifyTopicName channelName
        , url = component.channelApiUrl ++ "/v1/channel/" ++ channelName
        }
        |> Procedure.fetchResult
        |> Procedure.mapError Momento.errorToDetails
        |> Procedure.map (always sessionKey)


recordEventsLogMetaData :
    CreateChannel a
    -> String
    -> MomentoSessionKey
    -> Procedure.Procedure ErrorFormat MomentoSessionKey Msg
recordEventsLogMetaData component channelName sessionKey =
    Procedure.fromTask Time.now
        |> Procedure.andThen
            (\timestamp ->
                let
                    metadataRecord =
                        { id = Names.metadataKeyName channelName
                        , seq = 0
                        , updatedAt = timestamp
                        , lastId = 0
                        }
                in
                Apis.eventLogTableMetadataApi.put
                    { tableName = component.eventLogTable
                    , item = metadataRecord
                    }
                    |> Procedure.fetchResult
                    |> Procedure.map (always sessionKey)
                    |> Procedure.mapError Dynamo.errorToDetails
            )


recordChannel :
    CreateChannel a
    -> String
    -> MomentoSessionKey
    -> Procedure.Procedure ErrorFormat ChannelTable.Record Msg
recordChannel component channelName sessionKey =
    Procedure.fromTask Time.now
        |> Procedure.andThen
            (\timestamp ->
                let
                    channelRecord =
                        { id = channelName
                        , updatedAt = timestamp
                        , modelTopic = Names.modelTopicName channelName
                        , saveTopic = Names.notifyTopicName channelName
                        , saveList = Names.saveListName channelName
                        , webhook = Names.webhookName channelName
                        }
                in
                Apis.channelTableApi.put
                    { tableName = component.channelTable
                    , item = channelRecord
                    }
                    |> Procedure.fetchResult
                    |> Procedure.map (always channelRecord)
                    |> Procedure.mapError Dynamo.errorToDetails
            ) 
```