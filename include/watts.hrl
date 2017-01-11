-define(APPLICATION, watts).
-define(CONFIG(K,D), application:get_env(?APPLICATION, K,D) ).
-define(ALLCONFIG, application:get_all_env(?APPLICATION) ).
-define(CONFIG_(K), application:get_env(?APPLICATION, K) ).
-define(GETKEY(K), application:get_key(?APPLICATION, K) ).
-define(CONFIG(K), ?CONFIG(K, undefined) ).
-define(SETCONFIG(K,V), application:set_env(?APPLICATION, K, V) ).
-define(UNSETCONFIG(K), application:unset_env(?APPLICATION, K) ).
-define(DEBUG_MODE, ?CONFIG(debug_mode, false)).