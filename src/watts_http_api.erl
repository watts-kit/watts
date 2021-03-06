%%
%% Copyright 2016 - 2017 SCC/KIT
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
%% @doc This module implements the validation of a request and once it is valid
%% execute the corresponding action, which is always calling the main interface
%% to actions on the WaTTS system.
%% @see watts
-module(watts_http_api).
-author("Bas Wegh, Bas.Wegh<at>kit.edu").

-include("watts.hrl").


-export([init/3]).
-export([rest_init/2]).
-export([rest_terminate/2]).
-export([service_available/2]).
-export([allowed_methods/2]).
-export([allow_missing_post/2]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([is_authorized/2]).
-export([malformed_request/2]).
-export([resource_exists/2]).
-export([get_json/2]).
-export([post_json/2]).
-export([delete_resource/2]).

%%
%% REST implementation
%%

-define(LATEST_VERSION, 2).


%% @doc upgrade to cowboy rest
-spec init(any(), any(), any()) -> {upgrade, protocol, cowboy_rest}.
init(_, _Req, _Opts) ->
    {upgrade, protocol, cowboy_rest}.

-record(state, {
          in = #{},
          method = undefined,
          version = undefined,
          type = undefined,
          id = undefined,
          queue_token = undefined,

          token = undefined,
          issuer = undefined,
          json = undefined,
          session_pid = undefined
         }).

-type state() :: #state{}.

-type request_type() :: oidcp | info | logout | service | credential |
                        access_token | cred_data | undefined.

%% @doc intialize the rest request by creating a state with all preparsed infos
-spec rest_init(cowboy_req:req(), any()) -> {ok, cowboy_req:req(), state()}.
rest_init(Req0, _Opts) ->
    {State, Req1} = extract_info(Req0),
    Req2 = cowboy_req:set_resp_header(<<"Cache-control">>, <<"no-cache">>, Req1),
    {ok, Req2, State}.

%% @doc terminate the rest request, this ensures the token is given back
-spec rest_terminate(cowboy_req:req(), state()) -> ok.
rest_terminate(_Req, #state{queue_token = undefined}) ->
    ok;
rest_terminate(_Req, #state{queue_token = Token}) ->
    jobs:done(Token),
    ok.

%% @doc check if the service is available (still within the rate limit)
%% cred_data is not checked, they always pass
-spec service_available(cowboy_req:req(), state())
                       -> {boolean(), cowboy_req:req(), state()}.
service_available(Req, #state{in = #{type := cred_data}} = State) ->
    %% they for sure need to get their data
    {true, Req, State};
service_available(Req, State) ->
    QueueUsed = ?CONFIG(watts_web_queue, undefined),
    {Result, NewState} = request_queue_if_configured(QueueUsed, State),
    {Result, Req, NewState}.

%% @doc stand in the queue and request a token, if configured
-spec request_queue_if_configured(boolean(), state()) -> {boolean(), state()}.
request_queue_if_configured(true, State) ->
    Result = jobs:ask(watts_web_queue),
    handle_queue_result(Result, State);
request_queue_if_configured(_, State) ->
    {true, State}.

%% @doc handle the result of a queue request
-spec handle_queue_result({ok, any()} | any(), state()) -> {boolean(), state()}.
handle_queue_result({ok, Token}, State) ->
    {true, State#state{queue_token = Token}};
handle_queue_result(_, State) ->
    {false, State}.


%% @doc return the allowed methods
-spec allowed_methods(cowboy_req:req(), state())
                     -> {[binary()], cowboy_req:req(), state()}.
allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>]
     , Req, State}.

%% @doc it is not allowed to post to urls that do not exist
-spec allow_missing_post(cowboy_req:req(), state())
                        -> {false, cowboy_req:req(), state()}.
allow_missing_post(Req, State) ->
    {false, Req, State}.

%% @doc extrac information from the request and put them into the state
-spec extract_info(cowboy_req:req()) -> {state(), cowboy_req:req()}.
extract_info(Req) ->
    CookieName = watts_http_util:cookie_name(),
    {CookieSessionToken, Req2} = cowboy_req:cookie(CookieName, Req),
    InCookieSession = watts_session_mgr:get_session(CookieSessionToken),

    {PathInfo, Req3} = cowboy_req:path_info(Req2),
    {InToken, Req4} = cowboy_req:header(<<"authorization">>, Req3),
    {HIssuer, Req5} = cowboy_req:header(<<"x-openid-connect-issuer">>,
                                         Req4),
    {InVersion, InIssuer, InType, InId, HeaderUsed} =
        case {PathInfo, HIssuer} of
            {[V, Iss, T, IdIn], undefined} ->
                {V, Iss, T, IdIn, false};
            {[V, Iss, T], undefined} ->
                {V, Iss, T, undefined, false};
            {[V, T], undefined} ->
                {V, undefined, T, undefined, false};
            {_, undefined} ->
                {no_version, undefined, undefined, undefined, false};
            {[V, T], Iss} ->
                {V, Iss, T, undefined, true};
            {[V, T, IdIn], Iss} ->
                {V, Iss, T, IdIn, true};
            _ ->
                {no_version, undefined, undefined, undefined, false}
        end,
    {Res, InContentType, Req6} = cowboy_req:parse_header(<<"content-type">>,
                                                       Req5),
    {InMethod, Req7} = cowboy_req:method(Req6),
    {ok, InBody, Req8} = cowboy_req:body(Req7),
    Version = verify_version(InVersion),
    Type = verify_type(InType),
    Id = verify_id(InId),
    Token = verify_token(InToken),
    Issuer = verify_issuer(InIssuer),
    CookieSession = verify_session(InCookieSession),
    Method = verify_method(InMethod),
    ContentType = verify_content_type({Res, InContentType}),
    Body = verify_body(InBody),
    {#state{
        in = #{version => Version,
               type => Type,
               id => Id,
               token => Token,
               issuer => Issuer,
               session => CookieSession,
               method => Method,
               content => ContentType,
               body => Body,
               header_used => HeaderUsed}
       }, Req8}.

%% @doc return if a request is malformed
-spec malformed_request(cowboy_req:req(), state())
                       -> { boolean(), cowboy_req:req(), state() }.
malformed_request(Req, State) ->
    {Result, NewState} = is_malformed(State),
    NewReq =
        case Result of
            true ->
                Msg = <<"Bad request, please check all parameter">>,
                Body = jsone:encode(#{result => error, user_msg => Msg}),
                cowboy_req:set_resp_body(Body, Req);
            false ->
                Req
        end,
    {Result, NewReq, NewState}.

%% @doc check if the user is authorized to perform the request
-spec is_authorized(cowboy_req:req(), state())
                       -> { boolean(), cowboy_req:req(), state() }.
is_authorized(Req, #state{type=oidcp} = State) ->
    {true, Req, State};
is_authorized(Req, #state{type=info} = State) ->
    {true, Req, State};
is_authorized(Req, #state{type=logout} = State) ->
    {true, Req, State};
is_authorized(Req, #state{type=Type, session_pid=Pid} = State)
  when is_pid(Pid) ->
    ValidType = lists:member(Type, [oidcp, info, logout, service, credential,
                                    cred_data, access_token]),
    LoggedIn = watts_session:is_logged_in(Pid),
    {{Ip, _}, Req1} = cowboy_req:peer(Req),
    SameIp = watts_session:is_same_ip(Ip, Pid),
    {Agent, Req2} = cowboy_req:header(<<"user-agent">>, Req1),
    SameAgent = watts_session:is_user_agent(Agent, Pid),
    case {ValidType, LoggedIn, SameAgent and SameIp} of
        {false, _, _} ->
            Msg = list_to_binary(io_lib:format("unsupported path ~p", [Type])),
            Body = jsone:encode(#{result => error, user_msg => Msg}),
            Req3 = cowboy_req:set_resp_body(Body, Req2),
            {{false, <<"authorization">>}, Req3, State};
        {_, false, _} ->
            Msg = <<"seems like the session expired">>,
            Body = jsone:encode(#{result => error, user_msg => Msg}),
            Req3 = cowboy_req:set_resp_body(Body, Req2),
            {{false, <<"authorization">>}, Req3, State};
        {_, _, false} ->
            Msg = <<"sorry, you can't be identified">>,
            Body = jsone:encode(#{result => error, user_msg => Msg}),
            Req3 = cowboy_req:set_resp_body(Body, Req2),
            {ok, Req4} = perform_cookie_logout(Pid, Req3),
            {{false, <<"authorization">>}, Req4, State};
        {true, true, true} ->
            {true,  Req2, State}
    end;
is_authorized(Req, #state{type=Type, token=Token, issuer=Issuer,
                          session_pid=undefined} = State)
  when Type==service; Type==credential; Type==cred_data; Type == oidcp ;
       Type == info ->
    case watts:login_with_access_token(Token, Issuer) of
        {ok, #{session_pid := SessionPid}} ->
            {true, Req, State#state{session_pid = SessionPid}};
        {error, internal} ->
            Msg = <<"Authorization failed, please check the access token">>,
            Body = jsone:encode(#{result => error, user_msg => Msg}),
            Req1 = cowboy_req:set_resp_body(Body, Req),
            {{false, <<"authorization">>}, Req1, State};
        {error, Reason} ->
            Body = jsone:encode(#{result => error, user_msg => Reason}),
            Req1 = cowboy_req:set_resp_body(Body, Req),
            {{false, <<"authorization">>}, Req1, State}

    end;
is_authorized(Req, State) ->
    Msg = <<"invalid token has been received">>,
    Body = jsone:encode(#{result => error, user_msg => Msg}),
    Req1 = cowboy_req:set_resp_body(Body, Req),
    {{false, <<"authorization">>}, Req1, State}.


%% @doc return the provided content types (only json)
-spec content_types_provided(cowboy_req:req(), state())
                       -> { [tuple()], cowboy_req:req(), state() }.
content_types_provided(Req, State) ->
    {[
      {{<<"application">>, <<"json">>, '*'}, get_json}
     ], Req, State}.

%% @doc return the accepted content types (only json)
-spec content_types_accepted(cowboy_req:req(), state())
                       -> { [tuple()], cowboy_req:req(), state() }.
content_types_accepted(Req, State) ->
    {[
      {{<<"application">>, <<"json">>, '*'}, post_json }
     ], Req, State}.

%% @doc return if a resource exists
-spec resource_exists(cowboy_req:req(), state())
                       -> { boolean(), cowboy_req:req(), state() }.
resource_exists(Req, #state{type=Type, id=undefined} = State)
    when Type == oidcp; Type == info; Type == logout; Type == service;
         Type == credential; Type == access_token ->
    {true, Req, State};
resource_exists(Req, #state{type=credential, id=Id, session_pid=Session}
                = State) ->
    Exists = watts:does_credential_exist(Id, Session),
    {Exists, Req, State};
resource_exists(Req, #state{type=cred_data, id=Id, session_pid=Session}
                = State) ->
    Exists = watts:does_temp_cred_exist(Id, Session),
    {Exists, Req, State};
resource_exists(Req, State) ->
    Msg = <<"resource not found">>,
    Body = jsone:encode(#{result => error, user_msg => Msg}),
    Req1 = cowboy_req:set_resp_body(Body, Req),
    {false, Req1, State}.

%% @doc perform a deletion of a resource.
%% this is revoking a credential
-spec delete_resource(cowboy_req:req(), state())
                       -> { boolean(), cowboy_req:req(), state() }.
delete_resource(Req, #state{type=credential,
                            id=CredentialId, session_pid=Session}=State) ->
    {Result, Req2}  =
        case watts:revoke_credential_for(CredentialId, Session) of
            ok ->
                Body = jsone:encode(#{result => ok}),
                Req1 = cowboy_req:set_resp_body(Body, Req),
                {true, Req1};
            {error, Msg} ->
                Body = jsone:encode(#{result => error, user_msg => Msg}),
                Req1 = cowboy_req:set_resp_body(Body, Req),
                {false, Req1}
        end,
    {ok, Req3} = update_cookie_or_end_session(Req2, State),
    {Result, Req3, State#state{session_pid=undefined}}.

%% @doc handle the get requests
-spec get_json(cowboy_req:req(), state())
              -> {binary(), cowboy_req:req(), state()}.
get_json(Req, #state{version=Version, type=Type, id=Id, method=get,
                     session_pid=Session} = State) ->
    Content = perform_get(Type, Id, Session, Version),
    {ok, Req2} = update_cookie_or_end_session(Req, State),
    {Content, Req2, State#state{session_pid=undefined}}.

%% @doc handle the post requests
-spec post_json(cowboy_req:req(), state())
              -> {{true, binary()} | false, cowboy_req:req(), state()}.
post_json(Req, #state{version=Version, type=Type, id=Id, method=post,
                      session_pid=Session, json=Json} = State) ->
    {Req1, Result} = perform_post(Req, Type, Id, Json, Session, Version),
    {ok, Req2} = update_cookie_or_end_session(Req1, State),
    {Result, Req2, State#state{session_pid=undefined}}.

%% @doc handle the get requests.
%% This includes:
%% <ul>
%% <li> the list of services </li>
%% <li> the list of OpenID Connect provider </li>
%% <li> the info endpoint </li>
%% <li> the access token, issuer, its id, and subject  </li>
%% <li> the credential list  </li>
%% <li> the temporarly stored credential  </li>
%% </ul>
-spec perform_get(RequestType, Id, Session, Version) -> binary()
   when
      RequestType :: request_type(),
      Id :: undefined | binary(),
      Session :: undefined | pid(),
      Version :: integer().
perform_get(service, undefined, Session, Version) ->
    {ok, ServiceList} = watts:get_service_list_for(Session),
    Keys = case Version of
               1 -> [id, type, host, port];
               _ -> [id, description, enabled, cred_count, cred_limit,
                     limit_reached, params, authorized, authz_tooltip,
                     pass_access_token]
           end,
    return_json_service_list(ServiceList, Keys);
perform_get(oidcp, _, _, 1) ->
    {ok, OIDCList} = watts:get_openid_provider_list(),
    return_json_oidc_list(OIDCList);
perform_get(oidcp, _, _, _) ->
    {ok, OIDCList} = watts:get_openid_provider_list(),
    jsone:encode(#{openid_provider_list => OIDCList});
perform_get(info, undefined, Session, _) ->
    return_json_info(Session);
perform_get(logout, undefined, _, _) ->
    jsone:encode(#{result => ok});
perform_get(access_token, undefined, Session, _) ->
    {ok, AccessToken} = watts:get_access_token_for(Session),
    {ok, Iss, Id, Sub} = watts:get_iss_id_sub_for(Session),
    jsone:encode(#{access_token => AccessToken,
                   issuer => Iss,
                   subject => Sub,
                   issuer_id => Id
                  });
perform_get(credential, undefined, Session, Version) ->
    {ok, CredList} = watts:get_credential_list_for(Session),
    return_json_credential_list(CredList, Version);
perform_get(cred_data, Id, Session, Version) ->
    case watts:get_temp_cred(Id, Session) of
        {ok, Cred} ->
            return_json_credential(Cred, Version);
        _ ->
            Msg = <<"Sorry, the requested data was not found">>,
            jsone:encode(#{result => error, user_msg => Msg})
    end.

%% @doc perform a post, meaning a translation
-spec perform_post(cowboy_req:req(), credential, undefined,
                   watts_service:info(), pid(), integer())
                  -> {cowboy_req:req(), {true, binary()} | false}.
perform_post(Req, credential, undefined, #{service_id:=ServiceId} = Data,
             Session, Ver) ->
    Params = maps:get(params, Data, #{}),
    case  watts:request_credential_for(ServiceId, Session, Params) of
        {ok, CredData} ->
            {ok, Id} = watts:store_temp_cred(CredData, Session),
            {ok, _Iss, IssuerId, _Sub} = watts:get_iss_id_sub_for(Session),
            Url = temp_cred_id_to_url(Id, IssuerId, Ver),
            {Req, {true, Url}};
        {error, ErrorInfo} ->
            Body = jsone:encode(ErrorInfo),
            Req1 = cowboy_req:set_resp_body(Body, Req),
            {Req1, false}
    end.

%% @doc create and return the info data
-spec return_json_info(pid()) -> binary().
return_json_info(Session) ->
    {LoggedIn, DName, IssId, Error, AutoService, SuccessRedir, ErrorRedir}  =
        case is_pid(Session) of
            false ->
                {false, <<"">>, <<"">>, <<"">>, undefined, undefined,
                 undefined};
            true ->
                {ok, Name} = watts:get_display_name_for(Session),
                {ok, _Iss, Id, _Sub} = watts:get_iss_id_sub_for(Session),
                {ok, Err} = watts_session:get_error(Session),
                {ok, Redir} = watts_session:get_redirection(Session),
                ok = watts_session:clear_redirection(Session),
                {ok, Rsp} = watts_session:get_rsp(Session),
                {SuccessUrl, ErrorUrl} = get_return_urls(Rsp),
                {watts_session:is_logged_in(Session), Name, Id, Err, Redir,
                 SuccessUrl, ErrorUrl}
        end,
    {ok, Version} = ?CONFIG_(vsn),
    Redirect = io_lib:format("~s~s", [?CONFIG(ep_main), "oidc"]),
    EnableUserDocs = ?CONFIG(enable_user_doc),
    EnableCodeDocs = ?CONFIG(enable_code_doc),
    Info = #{version => list_to_binary(Version),
              redirect_path => list_to_binary(Redirect),
              error => Error,
              logged_in => LoggedIn,
              display_name => DName,
              issuer_id => IssId,
              user_documentation => EnableUserDocs,
              code_documentation => EnableCodeDocs
            },
    Info1 = case AutoService of
               undefined  -> Info;
               _ ->
                   SuppKeys = [service, params],
                   maps:put(service_request, maps:with(SuppKeys, AutoService),
                            Info)
           end,
    Info2 = case SuccessRedir of
               undefined  -> Info1;
               _ ->
                    ErrRedir = case ErrorRedir of
                                   undefined -> SuccessRedir;
                                   _ -> ErrorRedir
                               end,
                    Update = #{rsp_success => SuccessRedir,
                               rsp_error => ErrRedir},
                   maps:merge(Info1, Update)
           end,
    jsone:encode(Info2).


%% @doc return the list of the services limited to the given keys
-spec return_json_service_list([map()], [atom()]) -> binary().
return_json_service_list(Services, Keys) ->
    Extract = fun(Map0, List) ->
                      CredLimit = case maps:get(cred_limit, Map0) of
                                      infinite ->
                                          -1;
                                      Num when is_integer(Num), Num >= 0 ->
                                          Num;
                                      _ -> 0
                                  end,
                      Update = #{type => none, host => localhost,
                                port => <<"1234">>},
                      Map = maps:put(cred_limit, CredLimit, Map0),
                      [ maps:with(Keys, maps:merge(Update, Map)) | List]
              end,
    List = lists:reverse(lists:foldl(Extract, [], Services)),
    jsone:encode(#{service_list => List}).

%% @doc return the list of supported OpenID Connect provider
-spec return_json_oidc_list([map()]) -> binary().
return_json_oidc_list(Oidc) ->
    Id = fun(OidcInfo, List) ->
                 case OidcInfo of
                 #{issuer := Issuer, id := Id, ready := true}  ->
                         [#{ id => Id, issuer => Issuer} | List];
                     _ -> List
                 end
         end,
    List = lists:reverse(lists:foldl(Id, [], Oidc)),
    jsone:encode(#{openid_provider_list => List}).

%% @doc return a single temp_credential (includes oidc_login) as json
%% @todo check spec
-spec return_json_credential(watts:temp_cred(), integer()) -> binary().
-dialyzer({nowarn_function, return_json_credential/2}).
return_json_credential(#{result := ok, credential := Cred } , 1) ->
    #{id := Id,
      entries := Entries
     } = Cred,
    IdEntry = #{name => id, type => text, value => Id},
    jsone:encode([ IdEntry | Entries ]);
return_json_credential(Cred, _) ->
    jsone:encode(Cred).


%% @doc return the credential list in json format
-spec return_json_credential_list([map()], integer()) -> binary().
return_json_credential_list(Credentials, Version)->
    Keys = [cred_id, ctime, interface, service_id],
    Adjust =
        fun(Cred0, List) ->
                Cred = maps:with(Keys, Cred0),
                case Version of
                    1 ->
                        [ #{ id => maps:put(cred_state, hidden, Cred)} | List];
                    _ ->
                        [ Cred | List]
                end
        end,
    List = lists:reverse(lists:foldl(Adjust, [], Credentials)),
    jsone:encode(#{credential_list => List}).

%% @doc check if the state is a malformed request
-spec is_malformed(state()) -> {boolean(), state()}.
is_malformed(#state{in = #{
                      version := Version,
                      type := Type,
                      id := Id,
                      token := Token,
                      issuer := Issuer,
                      method := Method,
                      session := CookieSession,
                      content := ContentType,
                      body := Body,
                      header_used := HeaderUsed
                     }} = State) ->
    case is_bad_version(Version, HeaderUsed) of
        true -> {true, State};
        false -> Result = is_malformed(Method, ContentType, Type, Id, Issuer,
                                       Body),
                 {Result, State#state{method=Method, version=Version, type=Type,
                                      id=Id, token=Token, issuer=Issuer,
                                      session_pid=CookieSession, json=Body,
                                      in = #{}
                                     }}
    end.

%% @doc verify the passed version
-spec verify_version(binary() | undefined) -> integer().
verify_version(<< V:1/binary, Version/binary >>) when V==<<"v">>; V==<<"V">> ->
     safe_binary_to_integer(Version);
verify_version(_) ->
    0.

%% @doc verify the token passed
-spec verify_token(binary() | undefined) -> binary() | undefined | bad_token.
verify_token(<< Prefix:7/binary, Token/binary >>) when
      Prefix == <<"Bearer ">> ->
    Token;
verify_token(Token) when is_binary(Token) ->
    bad_token;
verify_token(undefined) ->
    undefined.

%% @doc verify the content is json or undefined
-spec verify_content_type(tuple()) -> json | undefined | unsupported.
verify_content_type({ok, {<<"application">>, <<"json">>, _}}) ->
    json;
verify_content_type({ok, undefined}) ->
    undefined;
verify_content_type({undefined, _}) ->
    undefined;
verify_content_type(_) ->
    unsupported.

%% @doc verify the issuer
-spec verify_issuer(binary() | undefined)
                   -> binary() | undefined | rsps_disabled | unkonwn_rsp
                          | bad_issuer .
verify_issuer(undefined) ->
    undefined;
verify_issuer(<< Prefix:4/binary, RspId/binary>> = Rsp)
  when Prefix == <<"rsp-">> ->
    Exists = watts_rsp:exists(RspId),
    Enabled = ?CONFIG(enable_rsp, false),
    return_rsp_if_enabled(Rsp, Exists, Enabled);
verify_issuer(Issuer) when is_binary(Issuer) ->
    case watts:get_openid_provider_info(Issuer) of
        {ok, #{issuer := IssuerUrl}} ->
            IssuerUrl;
        _ ->
            case (byte_size(Issuer) > 8) andalso
                 (binary_part(Issuer, {0, 8}) == <<"https://">>) of
                true -> Issuer;
                false -> bad_issuer
            end
    end.

%% @doc return the given rsp, if it is enabled
-spec return_rsp_if_enabled(binary(), boolean(), boolean())
                           -> binary() | unknown_rsp | rsps_disabled.
return_rsp_if_enabled(Rsp, true, true) ->
    Rsp;
return_rsp_if_enabled(_, false, true) ->
    unkonwn_rsp;
return_rsp_if_enabled(_, _, false) ->
    rsps_disabled.


%% @doc verify the session, just check if it is a pid
-spec verify_session({ok, pid()} | any()) -> pid() | undefined.
verify_session({ok, Pid}) when is_pid(Pid) ->
    Pid;
verify_session(_) ->
    undefined.

%% @doc verify the method
-spec verify_method(binary()) -> get | post | delete.
verify_method(<<"GET">>) ->
    get;
verify_method(<<"POST">>) ->
    post;
verify_method(<<"DELETE">>) ->
    delete.

%% @doc verify the passed body, try to parse the json
-spec verify_body(binary()) -> undefined | map().
verify_body(Data) ->
    case jsone:try_decode(Data, [{object_format, map}, {keys, attempt_atom}]) of
        {ok, Json, _} ->
            Json;
        _ ->
            undefined
    end.

%% @doc safe conversion of binary to integer
-spec safe_binary_to_integer(binary()) -> integer().
safe_binary_to_integer(Version) ->
    try binary_to_integer(Version) of
        Number -> Number
    catch
        _:_ ->
            0
    end.

%% @doc convert a temp cred Id to its url
-spec temp_cred_id_to_url(binary(), binary(), pos_integer()) -> binary().
temp_cred_id_to_url(Id, IssuerId, Version) ->
    ApiBase = watts_http_util:whole_url("/api"),
    temp_cred_id_to_url(ApiBase, Id, IssuerId, Version).

%% @doc create the url depending on the version of the api used
-spec temp_cred_id_to_url(binary(), binary(), binary(), pos_integer())
                         -> binary().
temp_cred_id_to_url(ApiBase, Id, _IssuerId, 1) ->
    Path = << <<"/v1/credential_data/">>/binary, Id/binary >>,
    << ApiBase/binary, Path/binary>>;
temp_cred_id_to_url(ApiBase, Id, IssuerId, ApiVersion) ->
    Version = list_to_binary(io_lib:format("v~p", [ApiVersion])),
    PathElements =[Version, IssuerId, <<"credential_data">>, Id],
    Concat = fun(Element, Path) ->
                     Sep = <<"/">>,
                     << Path/binary, Sep/binary, Element/binary >>
             end,
    Path = lists:foldl(Concat, <<>>, PathElements),
    << ApiBase/binary, Path/binary>>.


-define(TYPE_MAPPING, [
                       {<<"oidcp">>, oidcp},
                       {<<"info">>, info},
                       {<<"logout">>, logout},
                       {<<"service">>, service},
                       {<<"credential">>, credential},
                       {<<"access_token">>, access_token},
                       {<<"credential_data">>, cred_data }
                      ]).

%% @doc verify the request type
-spec verify_type(binary() | undefined) -> request_type().
verify_type(Type) ->
    case lists:keyfind(Type, 1, ?TYPE_MAPPING) of
        false -> undefined;
        {Type, AtomType} -> AtomType
    end.

%% @doc verify the id
-spec verify_id(binary() | undefined) -> binary() | undefined.
verify_id(Id) ->
    Id.

%% @doc check if the request is malformed
-spec is_malformed(Method, ContentType, Type, Id, Issuer, Body) -> boolean()
    when
      Method :: get | post | delete,
      ContentType :: json | undefined,
      Type :: request_type(),
      Id :: binary() | undefined,
      Issuer :: binary() | undefined,
      Body :: binary() | undefined.
is_malformed(get, _, oidcp, undefined, _, undefined) ->
    false;
is_malformed(get, _, info, undefined, _, undefined) ->
    false;
is_malformed(get, _, logout, undefined, _, undefined) ->
    false;
is_malformed(get, _, service, undefined, Iss, undefined)
  when is_binary(Iss)  ->
    false;
is_malformed(get, _, credential, undefined, Iss, undefined)
  when is_binary(Iss) ->
    false;
is_malformed(get, _, access_token, undefined, _, undefined) ->
    false;
is_malformed(get, _, cred_data, Id, Iss, undefined)
  when is_binary(Iss) ->
    not is_binary(Id);
is_malformed(post, json, credential, undefined, Iss, #{service_id:=Id})
  when is_binary(Iss) ->
    not is_binary(Id);
is_malformed(delete, _, credential, Id, Iss, undefined)
  when is_binary(Iss) ->
    not is_binary(Id);
is_malformed(_, _, _, _, _, _) ->
    true.

%% @doc return if the given version is bad
-spec is_bad_version(integer() | any(), HeaderUsed ::boolean()) -> boolean().
is_bad_version(1, true) ->
    false;
is_bad_version(_, true) ->
    true;
is_bad_version(Version, false) when is_integer(Version) ->
   (Version =< 0) or (Version > ?LATEST_VERSION);
is_bad_version(_, _) ->
    true.

%% @doc decide to update the cookie for the session or logout
-spec update_cookie_or_end_session(cowboy_req:req(), state())
                    -> {ok, cowboy_req:req()}.
update_cookie_or_end_session(Req, #state{session_pid = Session,
                                          type=RequestType}) ->
    {ok, SessionType} =  watts_session:get_type(Session),
    KeepAlive = keep_session_alive(SessionType, RequestType),
    update_cookie_or_end_session(KeepAlive, Session, SessionType, Req).

%% @doc decide if the session should be closed or not
-spec keep_session_alive(watts_session:type(), atom()) -> boolean().
keep_session_alive(_, logout) ->
    false;
keep_session_alive(oidc, _) ->
    true;
keep_session_alive({rsp, _, _}, cred_data) ->
    false;
keep_session_alive({rsp, _, _}, _) ->
    true;
keep_session_alive(_, _) ->
    false.

%% @doc either update the cookie for the session or logout
-spec update_cookie_or_end_session(boolean(), pid(), watts_session:type(),
                                   cowboy_req:req())
                    -> {ok, cowboy_req:req()}.
update_cookie_or_end_session(true, Session, SessType, Req) ->
    case watts_session:is_logged_in(Session) of
        true ->
            {ok, Max, Token} = watts_session_mgr:get_cookie_data(Session),
            watts_http_util:perform_cookie_action(update, Max, Token, Req);
        _ ->
            perform_logout(Session, SessType, Req)
    end;
update_cookie_or_end_session(false, Session, SessType, Req) ->
    perform_logout(Session, SessType, Req).

%% @doc perform a logout, either by cookie or by just closing the session
-spec perform_logout(pid(), watts_session:type(), cowboy_req:req())
                    -> {ok, cowboy_req:req()}.
perform_logout(Session, oidc, Req) ->
    perform_cookie_logout(Session, Req);
perform_logout(Session, {rsp, _, _}, Req) ->
    perform_cookie_logout(Session, Req);
perform_logout(Session, _, Req) ->
    watts:logout(Session),
    {ok, Req}.

%% @doc logout by deleteing the cookie
-spec perform_cookie_logout(pid(), cowboy_req:req()) -> {ok, cowboy_req:req()}.
perform_cookie_logout(Session, Req) ->
    Result = watts_http_util:perform_cookie_action(clear, 0, deleted, Req),
    watts:logout(Session),
    Result.

%% @doc get the return urls of an rsp, if valid
-spec get_return_urls(undefined | binary()) -> {undefined, undefined} |
                                               {binary(), binary()}.
get_return_urls(undefined) ->
    {undefined, undefined};
get_return_urls(Rsp) ->
    watts_rsp:get_return_urls(Rsp).
