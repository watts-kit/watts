-module(watts_http_util_test).
-include_lib("eunit/include/eunit.hrl").
-include("watts.hrl").

perform_cookie_action_test() ->
    {ok, Meck} = start_meck(),
    try
        {ok, req2} = watts_http_util:perform_cookie_action(clear, ignored, ignored, req),
        {ok, req2} = watts_http_util:perform_cookie_action(update, 0, ignored, req),
        ?SETCONFIG(ssl, true),
        {ok, req2} = watts_http_util:perform_cookie_action(update, ignored, deleted, req),
        {ok, req2} = watts_http_util:perform_cookie_action(update, 10, <<"content">>, req),
        ?UNSETCONFIG(ssl)
    after
        ok = stop_meck(Meck)
    end,
    ok.


relative_path_test() ->
    ?SETCONFIG(ssl, true),
    %% the config ensures that ep_main always ends on /
    ?SETCONFIG( ep_main, <<"/non_default/">>),
    <<"/non_default/sub/">> = watts_http_util:relative_path("sub/"),
    ok.

whole_url_test() ->
    Path = "/api",
    ?SETCONFIG( hostname, "localhost"),
    TestUrl =
        fun({Ssl, Port, Exp}, Other) ->
                ?SETCONFIG( ssl, Ssl),
                ?SETCONFIG( port, Port),
                Exp = watts_http_util:whole_url(Path),
                ?UNSETCONFIG( ssl),
                ?UNSETCONFIG( port),
                Other
        end,
    Tests =
        [
         {false, 8080, <<"http://localhost:8080/api">>},
         {false, 443, <<"http://localhost:443/api">>},
         {false, 80, <<"http://localhost/api">>},
         {true, 8443, <<"https://localhost:8443/api">>},
         {true, 80, <<"https://localhost:80/api">>},
         {true, 443, <<"https://localhost/api">>}
        ],
   lists:foldl(TestUrl, ignored, Tests),
   ok.




start_meck() ->
    MeckModules = [cowboy_req],
    SetCookie = fun(Name, _Value, _Opts, Req) ->
                        Name = watts_http_util:cookie_name(),
                        case Req of
                            req ->
                                req2;
                            _ ->
                                {error, no_request}
                        end
                end,
    ok = test_util:meck_new(MeckModules),
    ok = meck:expect(cowboy_req, set_resp_cookie, SetCookie),
    {ok, {MeckModules}}.


stop_meck({MeckModules}) ->
    ok = test_util:meck_done(MeckModules),
    ok.
