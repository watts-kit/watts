%% @doc supervisor to start the rsp key gen_server
-module(watts_rsp_keys_sup).
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

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([new_rsp_keys/1]).

%% @doc start the supverisor linked to its parent
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, noparams).

%% @doc start a new linked rsp key gen_server child
-spec new_rsp_keys(watts_rsp_keys:config()) -> {ok, pid()}.
new_rsp_keys(Map) ->
    supervisor:start_child(?MODULE, [Map]).


%% @doc setup the simple_one_for_one supervisor
init(noparams) ->
    RspKeys = #{
      id => rsp_keys,
      start => {watts_rsp_keys, start_link, []},
      restart => transient
     },
    Procs = [RspKeys],
    Flags = #{ strategy => simple_one_for_one  },
    {ok, {Flags, Procs}}.
