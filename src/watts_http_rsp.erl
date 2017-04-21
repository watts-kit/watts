-module(watts_http_rsp).
-behaviour(cowboy_http_handler).
-export([
         init/3,
         terminate/3,
         handle/2]).

-include("watts.hrl").

init(_Type, Req, _Opts) ->
    {ok, Req, []}.

terminate(_Reason, _Req, _State) ->
    ok.

handle(Req, _State) ->
    {Path, Req2} = cowboy_req:path(Req),
    {Referer, Req3} = cowboy_req:header(<<"referer">>, Req2),
    JwtData = lists:last(binary:split(Path, <<"/">>, [global, trim_all])),
    Result = watts_rsp:validate_jwt_get_rsp(JwtData, Referer),
    setup_session_and_start(Result, Req3).

setup_session_and_start({ok, Rsp}, Req) ->
    {ok, Session} = watts:session_for_rsp(Rsp),
    execute_or_error(watts_rsp:request_type(Rsp), Session, Rsp, Req);
setup_session_and_start(Error, Req) ->
    lager:warning("RST: failed due to ~p", [Error]),
    {ok, Req2} = cowboy_req:reply(400, Req),
    {ok, Req2, []}.


execute_or_error(rsp_no_ui_no_login, Session, Rsp, Req) ->
    {Iss, Sub} = watts_rsp:get_iss_sub(Rsp),
    ok = watts_session:set_iss_sub(Iss, Sub, Session),
    %% todo: trigger service
    Url = watts_rsp:get_return_url(Rsp),
    watts_http_util:redirect_to(Url, Req);
execute_or_error(rsp_no_ui_with_login, Session, Rsp, Req) ->
    Provider = watts_rsp:get_provider(Rsp),
    Path = io_lib:format("oidc?provider=~s", [binary_to_list(Provider)]),
    Url = watts_http_util:relative_path(Path),
    {ok, Max} = watts_session:get_max_age(Session),
    {ok, Token} = watts_session:get_sess_token(Session),
    {ok, Req2} = watts_http_util:perform_cookie_action(update, Max, Token, Req),
    watts_http_util:redirect_to(Url, Req2);
execute_or_error(rsp_with_ui_no_login, Session, Rsp, Req) ->
    lager:warning("rsp request failed with not yet supported: ~p",[Rsp]),
    watts:logout(Session),
    {ok, Req2} = cowboy_req:reply(400, Req),
    {ok, Req2, []};
execute_or_error(rsp_with_ui_with_login, Session, Rsp, Req) ->
    lager:warning("rsp request failed with not yet supported: ~p",[Rsp]),
    watts:logout(Session),
    {ok, Req2} = cowboy_req:reply(400, Req),
    {ok, Req2, []};
execute_or_error({error, Reason}, Session, Rsp, Req) ->
    % bad request type
    lager:warning("rsp request failed with ~p: ~p",[Reason, Rsp]),
    watts:logout(Session),
    {ok, Req2} = cowboy_req:reply(400, Req),
    {ok, Req2, []}.
