-module(tts_session).
-behaviour(gen_server).


%% API.
-export([start_link/1]).
-export([close/1]).

-export([get_id/1]).
-export([get_max_age/1]).
-export([set_max_age/2]).
-export([get_oidc_state/1]).
-export([is_oidc_state/2]).
-export([get_oidc_nonce/1]).
-export([is_oidc_nonce/2]).

-export([set_user/2]).

-export([get_used_redirect/1]).
-export([set_used_redirect/2]).

-export([get_oidc_provider/1]).
-export([set_oidc_provider/2]).
-export([clear_oidc_state_nonce/1]).


-export([is_logged_in/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
          id = unkonwn,
          oidc_state = none,
          oidc_nonce = none,
          user = none,
          op = none,
          used_redirect = none,
          max_age = 900
}).

% calculate the miliseconds from max_age
-define(TIMEOUT(MaxAge), MaxAge*1000).


%% API.

-spec start_link(ID :: binary()) -> {ok, pid()}.
start_link(ID) ->
	gen_server:start_link(?MODULE, ID, []).

-spec close(Pid :: pid()) -> ok.
close(Pid) ->
	gen_server:call(Pid, close).

-spec get_id(Pid :: pid()) -> {ok, ID::binary()}.
get_id(Pid) ->
    gen_server:call(Pid, get_id).

-spec get_max_age(Pid :: pid()) -> {ok, MaxAge::non_neg_integer()}.
get_max_age(Pid) ->
    gen_server:call(Pid, get_max_age).

-spec set_max_age(MaxAge :: pos_integer(), Pid :: pid()) -> ok.
set_max_age(MaxAge, Pid) ->
    gen_server:call(Pid, {set_max_age, MaxAge}).

-spec get_used_redirect(Pid :: pid()) -> {ok, binary()} | none.
get_used_redirect(Pid) ->
    gen_server:call(Pid, get_used_redirect).

-spec set_used_redirect(Redirect ::binary(), Pid :: pid()) -> ok.
set_used_redirect(Redirect, Pid) ->
    gen_server:call(Pid, {set_used_redirect, Redirect}).

-spec get_oidc_provider(Pid :: pid()) -> {ok, map()} | none.
get_oidc_provider(Pid) ->
    gen_server:call(Pid, get_oidc_provider).

-spec set_oidc_provider(OidcProvider :: map(), Pid :: pid()) -> ok.
set_oidc_provider(OP, Pid) ->
    gen_server:call(Pid, {set_oidc_provider, OP}).

-spec set_user(User ::any(), Pid :: pid()) -> ok.
set_user(User, Pid) ->
    gen_server:call(Pid, {set_user, User}).

-spec is_logged_in(Pid :: pid()) -> true | false.
is_logged_in(Pid) ->
    gen_server:call(Pid, is_logged_in).

-spec get_oidc_state(Pid :: pid()) -> {ok, OidcState::binary()}.
get_oidc_state(Pid) ->
    gen_server:call(Pid, get_oidc_state).

-spec is_oidc_state(State :: binary(), Pid :: pid()) -> true | false.
is_oidc_state(State, Pid) ->
    gen_server:call(Pid, {compare_oidc_state, State}).

-spec get_oidc_nonce(Pid :: pid()) -> {ok, OidcNonce::binary()}.
get_oidc_nonce(Pid) ->
    gen_server:call(Pid, get_oidc_nonce).

-spec is_oidc_nonce(Nonce :: binary(), Pid :: pid()) -> true | false.
is_oidc_nonce(Nonce, Pid) ->
    gen_server:call(Pid, {compare_oidc_nonce, Nonce}).

-spec clear_oidc_state_nonce(Pid :: pid()) -> ok.
clear_oidc_state_nonce(Pid) -> 
    gen_server:call(Pid, clear_oidc_state_nonce).
   
%% gen_server.


init(ID) ->
    OidcState = create_random_state(16),
    OidcNonce = create_random_state(64),
	{ok, #state{id = ID, oidc_state = OidcState, oidc_nonce = OidcNonce}}.

handle_call(get_id, _From, #state{id=Id, max_age=MA}=State) ->
	{reply, {ok, Id}, State, ?TIMEOUT(MA)};
handle_call(get_max_age, _From, #state{max_age=MA}=State) ->
	{reply, {ok, MA}, State, ?TIMEOUT(MA)};
handle_call({set_max_age, MA}, _From, State) ->
	{reply, {ok, MA}, State#state{max_age=MA}, ?TIMEOUT(MA)};
handle_call(get_used_redirect, _From, #state{used_redirect=Redir,max_age=MA}=State) ->
	{reply, {ok, Redir}, State, ?TIMEOUT(MA)};
handle_call({set_used_redirect, Redir}, _From, #state{max_age=MA}=State) ->
	{reply, ok, State#state{used_redirect=Redir}, ?TIMEOUT(MA)};
handle_call(get_oidc_provider, _From, #state{op=OP,max_age=MA}=State) ->
	{reply, {ok, OP}, State, ?TIMEOUT(MA)};
handle_call({set_oidc_provider, OP}, _From, #state{max_age=MA}=State) ->
	{reply, ok, State#state{op=OP}, ?TIMEOUT(MA)};
handle_call({set_user, User}, _From, #state{max_age=MA}=State) ->
	{reply, ok, State#state{user=User}, ?TIMEOUT(MA)};
handle_call(is_logged_in, _From, #state{user=none, max_age=MA}=State) ->
	{reply, false, State, ?TIMEOUT(MA)};
handle_call(is_logged_in, _From, #state{user=_, max_age=MA}=State) ->
	{reply, true, State, ?TIMEOUT(MA)};
handle_call(get_oidc_state, _From, #state{oidc_state=OidcState, max_age=MA}=State) ->
	{reply, {ok, OidcState}, State, ?TIMEOUT(MA)};
handle_call({compare_oidc_state, OidcState}, _From,
            #state{oidc_state=OidcState, max_age=MA}=State) ->
	{reply, true, State, ?TIMEOUT(MA)};
handle_call({compare_oidc_state, _}, _From, #state{ max_age=MA } = State) ->
	{reply, false, State, ?TIMEOUT(MA)};
handle_call(get_oidc_nonce, _From, #state{oidc_nonce=OidcNonce, max_age=MA}=State) ->
	{reply, {ok, OidcNonce}, State, ?TIMEOUT(MA)};
handle_call({compare_oidc_nonce, OidcNonce}, _From,
            #state{oidc_nonce=OidcNonce, max_age=MA}=State) ->
	{reply, true, State, ?TIMEOUT(MA)};
handle_call({compare_oidc_nonce, _}, _From, #state{ max_age=MA } = State) ->
	{reply, false, State, ?TIMEOUT(MA)};
handle_call(clear_oidc_state_nonce, _From, #state{ max_age=MA } = State) ->
	{reply, ok, State#state{oidc_state=cleared,oidc_nonce=cleared}, ?TIMEOUT(MA)};
handle_call(close, _From, State) ->
	{stop, normal, State};
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(timeout, State) ->
    {stop,normal,State};
handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{id=ID}) ->
    tts_session_mgr:session_closing(ID), 
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.


create_random_state(Length) ->
    tts_utils:random_string(Length).
