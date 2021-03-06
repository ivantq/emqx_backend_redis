%%%-------------------------------------------------------------------
%%% @author jiefeng.chen
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 11. 6月 2020 15:06
%%%-------------------------------------------------------------------
-module(emqx_backend_redis_cli).
-author("jiefeng.chen").

-behaviour(ecpool_worker).

-include("emqx_backend_redis.hrl").

-include_lib("emqx/include/emqx.hrl").

-import(proplists, [get_value/2, get_value/3]).

-export([
    connect/1,
    q/2,
    q/3,
    scan/3,
    expire/2
]).

%%--------------------------------------------------------------------
%% Redis Connect/Query
%%--------------------------------------------------------------------

connect(Opts) ->
    Sentinel = get_value(sentinel, Opts),
    Host = case Sentinel =:= "" of
        true ->
            get_value(host, Opts);
        false ->
            eredis_sentinel:start_link([{get_value(host, Opts),
                get_value(port, Opts)}]),
            "sentinel:" ++ Sentinel
    end,
    % 使用eredis建立连接
    eredis:start_link(Host,
        get_value(port, Opts, 6379),
        get_value(database, Opts),
        get_value(password, Opts),
        no_reconnect).

%% Redis Query.
-spec(q(string(), emqx_types:credentials(), timeout())
        -> {ok, undefined | binary() | list()} | {error, atom() | binary()}).
q(Cmd, Timeout) ->
    case get_value(type, application:get_env(?APP, server, [])) of
        cluster -> eredis_cluster:q(?APP, Cmd);
        _ -> ecpool:with_client(?APP, fun(C) -> eredis:q(C, Cmd, Timeout) end)
    end.

q(CmdStr, Credentials, Timeout) ->
    %% 替换模板查询语句中的对应词 %c->clientId %u->username
    Cmd = string:tokens(replvar(CmdStr, Credentials), " "),
    q(Cmd, Timeout).

scan(Cursor, Match, Count) ->
    case q([?SCAN, Cursor, ?MATCH, Match, ?COUNT, Count]) of
        {ok, List} ->
            List;
        {error, Reason} ->
            ?LOG(error, "[Redis] scan failed: ~p", [Reason]),
            []
    end.

expire(Key, Time) ->
    case q(["expire", Key, Time]) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ?LOG(error, "[Redis] scan failed: ~p", [Reason]),
            fail
    end.

replvar(Cmd, Credentials = #{clientid := ClientId}) ->
    replvar(repl(Cmd, "%c", ClientId), maps:remove(clientid, Credentials));
replvar(Cmd, Credentials = #{username := Username}) ->
    replvar(repl(Cmd, "%u", Username), maps:remove(username, Credentials));
replvar(Cmd, Credentials = #{topic := Topic}) ->
    replvar(repl(Cmd, "%topic", Topic), maps:remove(topic, Credentials));
replvar(Cmd, Credentials = #{string := String}) ->
    replvar(repl(Cmd, "%s", String), maps:remove(string, Credentials));
replvar(Cmd, _) ->
    repl(Cmd, "%t", integer_to_list(erlang:system_time(second))).

repl(S, _Var, undefined) ->
    S;
repl(S, Var, Val) ->
    re:replace(S, Var, Val, [{return, list}]).