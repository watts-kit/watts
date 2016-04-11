-module(tts_data).


-export([init/0]).

-export([
         sessions_get_list/0,
         sessions_create_new/1,
         sessions_get_pid/1,
         sessions_update_pid/2,
         sessions_delete/1
        ]).

-export([
         user_lookup_info/2,
         user_insert_info/2,
         user_delete_info/1,
         user_delete_info/2,
         user_delete_entries_older_than/1,
         user_delete_entries_not_accessed_for/1,
         user_clear_cache/0
        ]).

-export([
         oidc_add_op/5,
         oidc_op_set/3,
         oidc_get_op/1,
         oidc_get_op_list/0
        ]).

-export([
         service_add/2,
         service_get/1,
         service_get_list/0
        ]).
-export([
         credential_add/3,
         credential_remove/3,
         credential_get/1
        ]).
-define(TTS_SESSIONS, tts_sessions).
-define(TTS_OIDCP, tts_oidcp).
-define(TTS_USER, tts_user).
-define(TTS_USER_MAPPING, tts_user_mapping).
-define(TTS_SERVICE, tts_service).
-define(TTS_CRED_USER, tts_cred_user).

-define(TTS_TABLES, [
                    ?TTS_SESSIONS
                    , ?TTS_OIDCP
                    , ?TTS_USER_MAPPING
                    , ?TTS_USER
                    , ?TTS_SERVICE
                    %% , ?TTS_CRED_USER
                   ]).

init() ->
    create_tables().

% functions for session management
-spec sessions_get_list() -> [map()].
sessions_get_list() ->
    Entries = get_all_entries(?TTS_SESSIONS),
    ExtractValue = fun({Id, Pid}, List) ->
                           [#{id => Id, pid => Pid} | List]
                   end,
    lists:reverse(lists:foldl(ExtractValue, [], Entries)).


-spec sessions_create_new(ID :: binary()) -> ok | {error, Reason :: atom()}.
sessions_create_new(ID) ->
    return_ok_or_error(insert_new(?TTS_SESSIONS, {ID, none_yet})).


-spec sessions_get_pid(ID :: binary()) -> {ok, Pid :: pid()} |
                                          {error, Reason :: atom()}.
sessions_get_pid(ID) ->
    return_value(lookup(?TTS_SESSIONS, ID)).

-spec sessions_update_pid(ID :: binary(), Pid :: pid()) -> ok.
sessions_update_pid(ID, Pid) ->
    insert(?TTS_SESSIONS, {ID, Pid}),
    ok.

-spec sessions_delete(ID :: binary()) -> true.
sessions_delete(ID) ->
    delete(?TTS_SESSIONS, ID).

% functions for user management

-spec user_lookup_info(Issuer::binary(), Subject::binary()) ->
    {ok, Info :: map()} | {error, Reason :: atom()}.
user_lookup_info(Issuer, Subject) ->
    user_get_info(return_value(lookup(?TTS_USER_MAPPING, {Issuer, Subject}))).


-spec user_insert_info(Info::map(), MaxEntries::integer())  ->
    ok | {error, Reason :: atom()}.
user_insert_info(Info, MaxEntries) ->
    CurrentEntries = ets:info(?TTS_USER, size),
    remove_unused_entries_if_needed(CurrentEntries, MaxEntries),
    IssSubList = maps:get(userIds, Info, []),
    UserId = maps:get(uid, Info),
    Mappings = [{{Issuer, Subject}, UserId}||[Issuer, Subject] <- IssSubList ],
    CTime = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    Tuple = {UserId, Info, CTime, CTime},
    case  insert_new(?TTS_USER, Tuple) of
        true ->
            return_ok_or_error(insert_new(?TTS_USER_MAPPING, Mappings));
        false ->
            {error, already_exists}
    end.

-spec user_delete_info(Issuer :: binary(), Subject :: binary()) ->
    ok | {error, Reason :: term() }.
user_delete_info(Issuer, Subject) ->
    case lookup(?TTS_USER_MAPPING, {Issuer, Subject}) of
        {ok, UserId} ->
            user_delete_info(UserId);
        {error, _} = Error ->
            Error
    end.

-spec user_delete_info(InfoOrId :: map() | term()) ->
    ok | {error, Reason :: term() }.
user_delete_info(#{userIds := UserIds, uid := UserId}) ->
    user_delete_mappings(UserIds),
    delete(?TTS_USER, UserId),
    ok;
user_delete_info(UserId) ->
    case lookup(?TTS_USER, UserId) of
        {ok, UserInfo} -> user_delete_info(UserInfo);
        {error, _} = Error -> Error
    end.

-spec user_delete_entries_older_than(Duration::number()) ->
    {ok, NumDeleted::number()}.
user_delete_entries_older_than(Duration) ->
    Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    iterate_through_users_and_delete_before(ctime, Now-Duration).

-spec user_delete_entries_not_accessed_for(Duration::number()) ->
    {ok, NumDeleted::number()}.
user_delete_entries_not_accessed_for(Duration) ->
    Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    iterate_through_users_and_delete_before(atime, Now-Duration).

-spec user_clear_cache() -> ok.
user_clear_cache() ->
    true = ets:delete(?TTS_USER_MAPPING),
    true = ets:delete(?TTS_USER),
    ?TTS_USER = create_table(?TTS_USER),
    ?TTS_USER_MAPPING = create_table(?TTS_USER_MAPPING),
    ok.



user_get_info({ok, Id}) ->
    ATime = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    ets:update_element(?TTS_USER, Id, {3, ATime}),
    return_value(lookup(?TTS_USER, Id));
user_get_info({error, E}) ->
    {error, E}.

remove_unused_entries_if_needed(CurrentEntries, MaxEntries)
  when is_integer(CurrentEntries), is_integer(MaxEntries),
       CurrentEntries >= MaxEntries ->
    Number = 1 + (CurrentEntries - MaxEntries),
    iterate_through_users_and_delete_least_used_ones(Number);
remove_unused_entries_if_needed(_Current, _Max) ->
    ok.


iterate_through_users_and_delete_least_used_ones(Number) ->
    ets:safe_fixtable(?TTS_USER, true),
    First = ets:first(?TTS_USER),
    iterate_through_users_and_delete_least_used_ones(Number, First, []).

iterate_through_users_and_delete_least_used_ones(_Number, '$end_of_table'
                                                 , List) ->
    ets:safe_fixtable(?TTS_USER, false),
    DeleteID = fun({Info, _}, _)  ->
                       user_delete_info(Info)
               end,
    lists:foldl(DeleteID, [], List),
    ok;
iterate_through_users_and_delete_least_used_ones(Number, Key, List) ->
    {ok, {_UserId, Info, ATime, _CTime}} = lookup(?TTS_USER, Key),
    {NewNumber, NewList} = update_lru_list(Number, Info, ATime, List),
    Next = ets:next(?TTS_USER, Key),
    iterate_through_users_and_delete_least_used_ones(NewNumber, Next, NewList).

update_lru_list(0, Info, ATime, [H | T] = List) ->
    {_, LRU_Max } = H,
    case ATime < LRU_Max of
        true ->
            % if the ATime is older than the
            % newest on the list
            {0, lists:reverse(lists:keysort(2, [{Info, ATime}|T]))};
        false -> {0, List}
    end;
update_lru_list(Number, Info, ATime, List) ->
    NewList = lists:reverse(lists:keysort(2, [{Info, ATime} | List])),
    {Number-1, NewList}.


iterate_through_users_and_delete_before(TimeType, TimeStamp) ->
    ets:safe_fixtable(?TTS_USER, true),
    First = ets:first(?TTS_USER),
    iterate_through_users_and_delete_before(TimeType, TimeStamp, First, 0).
iterate_through_users_and_delete_before(_TimeType, _TimeStamp, '$end_of_table'
                                        , NumDeleted) ->
    ets:safe_fixtable(?TTS_USER, false),
    {ok, NumDeleted};
iterate_through_users_and_delete_before(TimeType, TimeStamp, Key, Deleted) ->
    {ok, User} = lookup(?TTS_USER, Key),
    NewDeleted = case delete_user_if_before(TimeType, TimeStamp, User) of
                     true -> Deleted + 1;
                     false -> Deleted
                 end,
    Next = ets:next(?TTS_USER, Key),
    iterate_through_users_and_delete_before(TimeType, TimeStamp
                                            , Next, NewDeleted).

delete_user_if_before(ctime, Timestamp, {_UserId, UserInfo, _ATime, CTime}) ->
    delete_user_if_true(Timestamp > CTime, UserInfo);
delete_user_if_before(atime, Timestamp, {_UserId, UserInfo, ATime, _CTime}) ->
    delete_user_if_true(Timestamp > ATime, UserInfo).

delete_user_if_true(true, UserInfo) ->
    user_delete_info(UserInfo),
    true;
delete_user_if_true(_, _UserInfo) ->
    false.

user_delete_mappings([]) ->
    true;
user_delete_mappings([H | T]) ->
    delete(?TTS_USER_MAPPING, H),
    user_delete_mappings(T).

% functions for oidc management
-spec oidc_add_op(Identifier::binary(), Description::binary(),
                  ClientId :: binary(), ClientSecret:: binary(),
                  ConfigEndpoint:: binary()) ->ok | {error, Reason :: atom()}.
oidc_add_op(Identifier, Description, ClientId, ClientSecret, ConfigEndpoint) ->
    Map = #{
      id => Identifier,
      desc => Description,
      client_id => ClientId,
      client_secret => ClientSecret,
      config_endpoint => ConfigEndpoint
     },
    return_ok_or_error(insert_new(?TTS_OIDCP, {Identifier, Map})).


-spec oidc_op_set(Key::atom(), Value::any(), Identifier::binary()) ->ok.
oidc_op_set(Key, Value, Id) ->
    {ok, {Id, Map0}} = oidc_get_op(Id),
    Map = maps:put(Key, Value, Map0),
    return_ok_or_error(insert(?TTS_OIDCP, {Id, Map})).

-spec oidc_get_op(RemoteEndpoint :: binary()) ->
    {ok, Info :: map()} | {error, Reason :: atom()}.
oidc_get_op(RemoteEndpoint) ->
    lookup(?TTS_OIDCP, RemoteEndpoint).

-spec oidc_get_op_list() -> [map()].
oidc_get_op_list() ->
    Entries = get_all_entries(?TTS_OIDCP),
    ExtractValue = fun({_, Val}, List) ->
                           [Val | List]
                   end,
    lists:reverse(lists:foldl(ExtractValue, [], Entries)).

% functions for service  management
-spec service_add(Identifier::binary(), Info :: map()) ->
    ok | {error, Reason :: atom()}.
service_add(Identifier, Info) ->
    return_ok_or_error(insert_new(?TTS_SERVICE, {Identifier, Info})).


-spec service_get(Identifier::binary()) ->ok.
service_get(Id) ->
    lookup(?TTS_SERVICE, Id).

-spec service_get_list() -> {ok, [map()]}.
service_get_list() ->
    Entries = get_all_entries(?TTS_SERVICE),
    ExtractValue = fun({_, Val}, List) ->
                           [Val | List]
                   end,
    {ok, lists:reverse(lists:foldl(ExtractValue, [], Entries))}.

% functions for credential  management
-spec credential_add(UserId::binary(), ServiceId::binary()
                     , CredState :: any()) -> ok | {error, Reason :: atom()}.
credential_add(UserId, ServiceId, CredState) ->
    Entry = {ServiceId, CredState},
    case lookup(?TTS_CRED_USER, UserId) of
        {ok, {UserId, CredList}} ->
            true = insert(?TTS_CRED_USER, {UserId, [Entry | CredList]}),
            ok;
        {error, not_found} ->
            true = insert_new(?TTS_CRED_USER, {UserId, [Entry]}),
            ok
    end.

-spec credential_get(UserId::binary()) ->ok.
credential_get(UserId) ->
    case lookup(?TTS_CRED_USER, UserId) of
        {ok, {UserId, CredList}} ->
            {ok, CredList};
        Other -> Other
    end.

-spec credential_remove(UserId::binary(), ServiceId::binary(),
                        CredState :: any()) ->ok | {error, Reason :: atom()}.
credential_remove(UserId, ServiceId, CredState) ->
    Entry = {ServiceId, CredState},
    case lookup(?TTS_CRED_USER, UserId) of
        {ok, {UserId, CredList}} ->
            case lists:member(Entry, CredList) of
                true ->
                    NewCredList = lists:delete(Entry, CredList),
                    true = insert(?TTS_CRED_USER, {UserId, NewCredList}),
                    ok;
                false ->
                    {error, credential_not_found}
            end;
        Other -> Other
    end.

%% internal functions


return_ok_or_error(true) ->
    ok;
return_ok_or_error(false) ->
    {error, already_exists}.

return_value({ok, {_Key, Value}}) ->
    {ok, Value};
return_value({ok, {_Key, Value, _ATime, _CTime}}) ->
    {ok, Value};
return_value({error, _} = Error) ->
    Error.


create_tables() ->
    CreateTable = fun(Table) ->
                          create_table(Table)
                  end,
    lists:map(CreateTable, ?TTS_TABLES),
    ok.

create_table(TableName) ->
    ets:new(TableName, [set, public, named_table, {keypos, 1}]).



get_all_entries(Table) ->
    GetVal = fun(Entry, List) ->
                     [Entry | List]
             end,
    Entries = ets:foldl(GetVal, [], Table),
    lists:reverse(Entries).

delete(Table, Key) ->
    true = ets:delete(Table, Key).


insert(Table, Entry) ->
    true = ets:insert(Table, Entry).

insert_new(Table, Entry) ->
    ets:insert_new(Table, Entry).

lookup(Table, Key) ->
    create_lookup_result(ets:lookup(Table, Key)).

create_lookup_result([Element]) ->
    {ok, Element};
create_lookup_result([]) ->
    {error, not_found};
create_lookup_result(_) ->
    {error, too_many}.

