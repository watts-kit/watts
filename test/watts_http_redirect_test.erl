-module(watts_http_redirect_test).
-include_lib("eunit/include/eunit.hrl").
-include("watts.hrl").

basic_test() ->
    {ok, req, []} = watts_http_redirect:init(ignored, req, ignored),
    ok = watts_http_redirect:terminate( ignored, ignored, ignored).


redirect_test() ->
    MeckModules = [cowboy_req],
    Reply = fun(Status, Header, Req) ->
                    LocationFound =
                        case lists:keyfind(<<"location">>,1,Header) of
                            {<<"location">>, _} ->
                                true;
                            _ ->
                                false
                        end,
                    case {Status, Req, LocationFound} of
                        {302, req, true} ->
                            {ok, req2};
                        _ ->
                            {error, not_a_redirection}
                    end
            end,
    Path = fun(Req) ->
                   {<<"/">>, Req}
           end,
    ok = test_util:meck_new(MeckModules),
    ok = meck:expect(cowboy_req, reply, Reply),
    ok = meck:expect(cowboy_req, path, Path),
    set_needed_env(),
    {ok, req2, ignored} = watts_http_redirect:handle(req, ignored),
    unset_env(),
    ok = test_util:meck_done(MeckModules),
    ok.


set_needed_env() ->
    ?SETCONFIG( hostname, "localhost"),
    ?SETCONFIG( port, 8080),
    ?SETCONFIG( ssl, false),
    ok.

unset_env() ->
    ?UNSETCONFIG( hostname),
    ?UNSETCONFIG( port),
    ?UNSETCONFIG( ssl),
    ok.
