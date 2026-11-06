module UrlIssue12Ipv6HostTest exposing (main)

{-| `Url.fromString` rejects URLs whose host is an IPv6 address.

<https://github.com/elm/url/issues/12>

Elm 0.19.1 (elm/url 1.0.0) returns `Nothing` for "http://[::1]:7272/ui/" because it treats every
`:` in the authority as a port separator. The URL is valid (RFC 3986 IP-literal host) and must
parse, with host "[::1]" and port 7272.

-}

-- CHECK: host: Just "[::1]"
-- CHECK: port: Just (Just 7272)

import Html exposing (text)
import Url


main =
    let
        url =
            Url.fromString "http://[::1]:7272/ui/"

        _ =
            Debug.log "host" (Maybe.map .host url)

        _ =
            Debug.log "port" (Maybe.map .port_ url)
    in
    text "done"
