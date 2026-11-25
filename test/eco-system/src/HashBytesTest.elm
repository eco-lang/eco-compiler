module HashBytesTest exposing (main)

{-| `Hash.hash` of Bytes follows `==`, which compares Bytes by content in every form: a whole buffer
and a slice of a larger buffer (`Bytes.Decode.bytes` of 32 or more bytes makes one) with the same 64
bytes are equal, so they must hash alike (plans/hashed-values-and-hash-consing.md §2.1, definition
v5 row 3). On JavaScript every Bytes value hashes alike, so the checks hold there too.

-}

-- CHECK: equal: True
-- CHECK: sameHash: True
-- CHECK: inDict: True

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Hash
import SeqDict
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


payload : Int -> List Encode.Encoder
payload seed =
    List.map (\i -> Encode.unsignedInt8 (modBy 256 (i * 37 + seed))) (List.range 0 63)


report : () -> ()
report () =
    let
        whole : Bytes
        whole =
            Encode.encode (Encode.sequence (payload 5))

        larger : Bytes
        larger =
            Encode.encode (Encode.sequence (List.map Encode.unsignedInt8 (List.range 1 8) ++ payload 5))

        slice : Bytes
        slice =
            Decode.decode (Decode.map2 (\_ b -> b) (Decode.bytes 8) (Decode.bytes 64)) larger
                |> Maybe.withDefault whole

        dict =
            SeqDict.singleton whole "found"

        _ =
            Debug.log "equal" (whole == slice)

        _ =
            Debug.log "sameHash" (Hash.hash whole == Hash.hash slice)

        _ =
            Debug.log "inDict" (SeqDict.get slice dict == Just "found")
    in
    ()
