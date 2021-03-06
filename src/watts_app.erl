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
%% @doc this is just starting the supervisor tree nothing more.
%% The main supervisor is watts_sup.
%% This implements the 'application' behaviour.
%% @see watts_sup
-module(watts_app).
-author("Bas Wegh, Bas.Wegh<at>kit.edu").

-behaviour(application).
-include("watts.hrl").

-export([start/2]).
-export([stop/1]).

%% @doc start the OTP application 'watts'.
-spec start(any(), any()) ->  {ok, pid()} | {error, Reason::term()}.
start(_Type, _Args) ->
    lager:info("WaTTS starting ..."),
    watts_sup:start_link().

%% @doc this is called at stop.
-spec stop(any()) -> ok.
stop(_State) ->
    ok.
