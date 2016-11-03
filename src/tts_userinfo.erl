-module(tts_userinfo).

-export([
         new/0,
         update_iss_sub/3,
         update_id_token/2,
         update_id_info/2,
         return/2
        ]).

-record(user_info, {
          issuer = undefined,
          subject = undefined,
          id_token = #{},
          id_info = #{}
         }).

new() ->
    {ok, #user_info{}}.


update_iss_sub(Issuer, Subject, Info) ->
    {ok, Info#user_info{issuer=Issuer, subject=Subject}}.

update_id_token(IdToken, #user_info{issuer=Issuer, subject=Subject}=Info) ->
    Claims = maps:get(claims, IdToken, #{}),
    Iss = maps:get(iss, Claims),
    Sub = maps:get(sub, Claims),
    case {Issuer, Subject} of
        {Iss, Sub} ->
            {ok, Info#user_info{id_token=IdToken}};
        {undefined, undefined} ->
            {ok, Info#user_info{id_token=IdToken, issuer=Iss, subject=Sub}};
        _ ->
            {error, not_match}
    end.

update_id_info(IdInfo0, #user_info{subject=Subject}=Info) ->
    IdInfo = parse_known_fields(IdInfo0),
    Sub = maps:get(sub, IdInfo),
    case Sub of
        Subject ->
            {ok, Info#user_info{id_info=IdInfo}};
        _ ->
            {error, not_match}
    end.
return(plugin_info, Info) ->
    plugin_info(Info);
return(issuer_subject, Info) ->
    {ok, Issuer} = return(issuer, Info),
    {ok, Subject} = return(subject, Info),
    {ok, Issuer, Subject};
return( subject, #user_info{subject =Subject}) ->
    {ok, Subject};
return( issuer, #user_info{issuer=Issuer}) ->
    {ok, Issuer};
return( id, Info) ->
    userid(Info);
return( display_name, Info) ->
    display_name(Info);
return( logged_in, Info) ->
    logged_in(Info).



userid(#user_info{issuer=Issuer, subject=Subject})
  when is_binary(Issuer), is_binary(Subject) ->
    Id = base64url:encode(jsx:encode(#{issuer => Issuer, subject => Subject})),
    {ok, Id};
userid(_) ->
    {error, not_set}.

display_name(#user_info{subject=Subject, issuer=Issuer, id_info=IdInfo})
  when is_binary(Subject), is_binary(Issuer)->
    case maps:get(name, IdInfo, undefined) of
        undefined -> {ok, << Subject/binary, <<"@">>/binary, Issuer/binary >>};
        Other -> {ok, Other}
    end;
display_name(_) ->
    {error, not_set}.

logged_in(#user_info{subject=Subject, issuer=Issuer})
  when is_binary(Subject), is_binary(Issuer)->
    true;
logged_in(_) ->
    false.

parse_known_fields(Map) ->
    List = maps:to_list(Map),
    parse_known_fields(List, []).

parse_known_fields([], List) ->
    maps:from_list(lists:reverse(List));
parse_known_fields([ {groups, GroupData} | T], List)
  when is_binary(GroupData) ->
    Groups = binary:split(GroupData, [<<",">>], [global, trim_all]),
    parse_known_fields(T, [{groups, Groups} | List]);
parse_known_fields([H | T], List) ->
    parse_known_fields(T, [H | List]).

plugin_info(#user_info{id_info=IdInfo, id_token=IdToken}) ->
    RemoveClaims = [aud, exp, nbf, iat, jti, azp, kid, aud, auth_time, at_hash,
                    c_hash],
    ReducedClaims = maps:without(RemoveClaims, maps:get(claims, IdToken, #{})),
    InfoMap = maps:merge(IdInfo, ReducedClaims),
    {ok, InfoMap}.
