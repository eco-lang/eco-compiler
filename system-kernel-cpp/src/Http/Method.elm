module Http.Method exposing (Method(..), toString, fromString)

{-| The method of an HTTP request, shared by the server and the client side of this package.

[`Http.Server`](Http-Server) gives the method of every request it receives as a
[`Method`](#Method), and [`Http.Stream`](Http-Stream) takes one for every request it sends.
The type has a module of its own so that a program that only sends requests need not import the
server module to name a method. The rest of what an HTTP client needs, such as `Http.Header` and
`Http.Error`, comes from [elm/http](/packages/elm/http/latest/).

    import Http.Method exposing (Method(..))

    Http.Method.toString OPTIONS
    --> "OPTIONS"

@docs Method, toString, fromString

-}


{-| An HTTP method.

The constructors are the methods of RFC 9110 and `PATCH` (RFC 5789), spelled as they are sent.
`UNKNOWN` holds the name of any other method, as it was received or is to be sent, for example
`UNKNOWN "PROPFIND"`.

-}
type Method
    = GET
    | HEAD
    | POST
    | PUT
    | DELETE
    | CONNECT
    | OPTIONS
    | TRACE
    | PATCH
    | UNKNOWN String


{-| Returns the name of a method, for example `"GET"`. `UNKNOWN name` gives `name`.

    Http.Method.toString PATCH
    --> "PATCH"

    Http.Method.toString (UNKNOWN "PROPFIND")
    --> "PROPFIND"

-}
toString : Method -> String
toString method =
    case method of
        GET ->
            "GET"

        HEAD ->
            "HEAD"

        POST ->
            "POST"

        PUT ->
            "PUT"

        DELETE ->
            "DELETE"

        CONNECT ->
            "CONNECT"

        OPTIONS ->
            "OPTIONS"

        TRACE ->
            "TRACE"

        PATCH ->
            "PATCH"

        UNKNOWN name ->
            name


{-| Returns the method named `name`.

Method names are case-sensitive in HTTP, so the name is matched exactly: `"GET"` gives `GET`,
while `"get"` gives `UNKNOWN "get"`. Any name that is not one of the constructors gives
`UNKNOWN name`, so `fromString` and [`toString`](#toString) give back the name they were given.

    Http.Method.fromString "OPTIONS"
    --> OPTIONS

    Http.Method.fromString "get"
    --> UNKNOWN "get"

-}
fromString : String -> Method
fromString name =
    case name of
        "GET" ->
            GET

        "HEAD" ->
            HEAD

        "POST" ->
            POST

        "PUT" ->
            PUT

        "DELETE" ->
            DELETE

        "CONNECT" ->
            CONNECT

        "OPTIONS" ->
            OPTIONS

        "TRACE" ->
            TRACE

        "PATCH" ->
            PATCH

        _ ->
            UNKNOWN name
