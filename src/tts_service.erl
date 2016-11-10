-module(tts_service).
%%
%% Copyright 2016 SCC/KIT
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0 (see also the LICENSE file)
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-author("Bas Wegh, Bas.Wegh<at>kit.edu").


-export([get_list/0]).
-export([get_list/1]).
-export([get_info/1]).
-export([add/1]).
-export([update_params/1]).

-export([is_enabled/1]).
-export([is_allowed/2]).
-export([allows_same_state/1]).
-export([get_credential_limit/1]).
%% -export([group_plugin_configs/1]).

get_list() ->
     tts_data:service_get_list().

get_list(UserInfo) ->
    %TODO: implement a whitelist/blacklist per service
    {ok, ServiceList} = tts_data:service_get_list(),
    UpdateLimit = fun(Service, List) ->
                      #{ id := ServiceId
                       } = Service,
                      Limit = maps:get(cred_limit, Service, 0),
                      {ok, Count} = tts_credential:get_count(UserInfo,
                                                             ServiceId),
                      LimitReached = (Count >= Limit),
                      Update = #{ limit_reached => LimitReached,
                                  cred_limit => Limit,
                                  cred_count => Count
                                },
                      [ maps:merge(Service, Update) | List]
                  end,
    {ok, lists:reverse(lists:foldl(UpdateLimit, [], ServiceList))}.


get_info(ServiceId) ->
    case tts_data:service_get(ServiceId) of
        {ok, {_Id, Info}} -> {ok, Info};
        Other -> Other
    end.

get_credential_limit(ServiceId) ->
    case tts_data:service_get(ServiceId) of
        {ok, {_Id, Info}} -> {ok, maps:get(cred_limit, Info, 0)};
        _ -> {ok, 0}
    end.

is_enabled(ServiceId) ->
    case tts_data:service_get(ServiceId) of
        {ok, {_Id, Info}} -> maps:get(enabled, Info, false);
        _ -> false
    end.

allows_same_state(ServiceId) ->
    case tts_data:service_get(ServiceId) of
        {ok, {_Id, Info}} -> maps:get(allow_same_state, Info, false);
        _ -> false
    end.

is_allowed(_UserInfo, _ServiceId) ->
    %% TODO: implement a white/blacklist
    true.


add(#{ id := ServiceId } = ServiceInfo) when is_binary(ServiceId) ->
    tts_data:service_add(ServiceId, maps:put(enabled, false, ServiceInfo)),
    {ok, ServiceId};
add(_ServiceMap)  ->
    {error, invalid_config}.


update_params(Id) ->
    Service = tts_data:service_get(Id),
    get_and_validate_parameter(Service).

get_and_validate_parameter({ok, {Id, Info}}) ->
    Result = tts_credential:get_params(Id),
    validate_params_and_update_db(Id, Info, Result);
get_and_validate_parameter(_) ->
    {error, not_found}.


validate_params_and_update_db(Id, Info, {ok, ConfParams, RequestParams}) ->
     Ensure = #{plugin_conf => #{},
               params => []},
    Info0 = maps:merge(Info, Ensure),
    {ValidConfParam, Info1}=validate_conf_parameter(ConfParams, Info0),
    {ValidCallParam, Info2}=validate_call_parameter_sets(RequestParams, Info1),
    Info3 = list_skipped_parameter_and_delete_config(Info2),
    IsValid = ValidConfParam and ValidCallParam,
    Update = #{enabled => IsValid},
    NewInfo = maps:merge(Info3, Update),
    update_service(Id, NewInfo);
validate_params_and_update_db(_, _, _) ->
    {error, bad_config}.

validate_conf_parameter(Params, Info) ->
    validate_conf_parameter(Params, Info, true).
validate_conf_parameter([], Info, Result) ->
    {Result, Info};
validate_conf_parameter([#{name := Name,
                           default := Def,
                           type := Type} | T ], Info, Current) ->
    AtomType = to_conf_type(Type),
    Default = convert_to_type(Def, AtomType),
    {Res, NewInfo} = update_conf_parameter(Name, Default, AtomType, Info),
    validate_conf_parameter(T, NewInfo, Res and Current);
validate_conf_parameter(_, #{id := Id, cmd := Cmd} = Info, _) ->
    lager:error("service '~s': bad parameter for plugin ~s",
                [binary_to_list(Id), binary_to_list(Cmd)]),
    {false, Info}.


update_conf_parameter(Name, _Default, unknown, #{id := Id} = Info) ->
    lager:error("service ~p: unsupported datatype at setting ~p (from plugin)",
                [Id, Name]),
    {false, Info};
update_conf_parameter(Name, {ok, Default}, Type,
                      #{id := Id, plugin_conf_config:=RawConf,
                        plugin_conf:= Conf} = Info) ->
    EMsg = "service ~p: bad configuration ~p: ~p, using default: ~p",
    WMsg = "service ~p: plugin config ~p not set, using default: ~p",
    Value =
        case maps:is_key(Name, RawConf) of
            true ->
                Val = maps:get(Name, RawConf),
                case convert_to_type(Val, Type) of
                    {ok, V} -> V;
                    _ ->
                        lager:warning(EMsg, [Id, Name, Val, Default]),
                        Default
                end;
            false ->
                lager:warning(WMsg, [Id, Name, Default]),
                Default
        end,
    NewConf = maps:put(Name, Value, Conf),
    {true, maps:put(plugin_conf, NewConf, Info)};
update_conf_parameter(Name, _, _Type, #{id := Id} = Info) ->
    lager:error("service ~p: bad default at setting ~p (from plugin)",
                [Id, Name]),
    {false, Info}.

validate_call_parameter_sets(Params, Info) ->
    validate_call_parameter_sets(Params, Info, true).

validate_call_parameter_sets([], #{params := Params} =Info, Result) ->
    ValidInfo = case Params of
                    [] -> maps:put(params, [[]], Info);
                    _ -> Info
                end,
    {Result, ValidInfo};
validate_call_parameter_sets([ H | T ], Info, Current)
  when is_list(H) ->
    {Result, NewInfo} = validate_call_parameter_set(H, Info),
   validate_call_parameter_sets(T, NewInfo, Result and Current);
validate_call_parameter_sets([ H | T ], #{id := Id} = Info, _) ->
    lager:error("service ~p: bad request parameter set ~p (from plugin)",
                [Id, H]),
    validate_call_parameter_sets(T, Info, false).


validate_call_parameter_set(Set, Info) ->
    validate_call_parameter_set(Set, Info, [], true).
validate_call_parameter_set([], #{params := Params} = Info, ParamSet, Result)->
    NewParams = [ParamSet | Params ],
    NewInfo = maps:put(params, NewParams, Info),
    {Result, NewInfo};
validate_call_parameter_set([#{description:=Desc, name:=Name, key:=Key,
                               type:=Type }=Param | T],
                            #{id := Id} = Info, ParamSet, Current)
  when is_binary(Key), is_binary(Desc), is_binary(Name) ->
    EMsg = "service ~p: parameter ~p: bad type ~p (from plugin)",
    WMsg = "service ~p: parameter ~p: bad mandatory value ~p, using false",
    Mdtory = maps:get(mandatory, Param, false),
    Mandatory =
        case convert_to_type(Mdtory, boolean) of
            {error, _} ->
                lager:warning(WMsg, [Id, Name, Mdtory]),
                false;
            {ok, Bool} -> Bool
        end,

    {Result, NewParamSet } =
        case to_request_type(Type) of
            unknown ->
                lager:error(EMsg, [Id, Name, Type]),
                {false, ParamSet};
            AtomType ->
                {true, [#{ key => Key,
                           name => Name,
                           description => Desc,
                           type => AtomType,
                           mandatory => Mandatory
                         } | ParamSet]}
        end,
    validate_call_parameter_set(T, Info, NewParamSet, Current and Result);
validate_call_parameter_set([H | T], #{id := Id} = Info, ParamSet, _Current) ->
    EMsg = "service ~p: bad request parameter ~p (from plugin)",
    lager:error(EMsg, [Id, H]),
    validate_call_parameter_set(T, Info, ParamSet, false).


list_skipped_parameter_and_delete_config(#{plugin_conf := Conf,
                                           plugin_conf_config := RawConf,
                                           id := Id
                                          }
                                         = Info) ->
    WMsg = "service ~p: skipping unknown parameter ~p = ~p from configuration",
    Keys = maps:keys(RawConf),
    Warn =
        fun(Key, _) ->
                case maps:is_key(Key, Conf) of
                    false ->
                        lager:warning(WMsg, [Id, Key, maps:get(Key, RawConf)]);
                    _ ->
                        ok
                end
        end,
    lists:foldl(Warn, ok, Keys),
    maps:remove(plugin_conf_config, Info).




update_service(Id, NewInfo) when is_map(NewInfo) ->
    tts_data:service_update(Id, NewInfo);
update_service( _, _) ->
    {error, invalid_config}.

convert_to_type(Value, string)
  when is_binary(Value) ->
    {ok, Value};
convert_to_type(true, boolean) ->
    {ok, true};
convert_to_type(<<"True">>, boolean) ->
    {ok, true};
convert_to_type(<<"true">>, boolean) ->
    {ok, true};
convert_to_type(false, boolean) ->
    {ok, false};
convert_to_type(<<"False">>, boolean) ->
    {ok, false};
convert_to_type(<<"false">>, boolean) ->
    {ok, false};
convert_to_type(_, _ ) ->
    {error, bad_value}.



to_atom(Type)
  when is_binary(Type) ->
    try
        binary_to_existing_atom(Type, utf8)
    catch error:badarg ->
            unknown
    end;
to_atom(Type)
  when is_list(Type) ->
    to_atom(list_to_binary(Type));
to_atom(_) ->
    unknown.

to_conf_type(Type) ->
    ValidTypes = [boolean, string],
    to_valid_type(Type, ValidTypes).

to_request_type(Type) ->
    ValidTypes = [textarea],
    to_valid_type(Type, ValidTypes).

to_valid_type(Type, ValidTypes) ->
    AType = to_atom(Type),
    case lists:member(AType, ValidTypes) of
        true ->
            AType;
        _ ->
            unknown
    end.
