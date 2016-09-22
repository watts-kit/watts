module Service.Model exposing (..)


type alias Model =
    { id : String
    , description : String
    , enabled : Bool
    , host : String
    , port' : String
    , type' : String
    , credCount : Int
    , credLimit : Int
    , limitReached : Bool
    , parameter : List Param
    }


type alias Param =
    { name : String
    , value : String
    , mandatory : Bool
    }


onlyAdvanced : Model -> Bool
onlyAdvanced service =
    let
        countMandatory param count =
            case param.mandatory of
                True ->
                    count + 1

                False ->
                    count

        numMandatory =
            List.foldl countMandatory 0 service.parameter
    in
        numMandatory > 0
