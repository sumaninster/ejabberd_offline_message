%% name of module must match file name
%% Update: info@ph-f.nl
-module(mod_http_offline).
-author("messengerawesome@gmail.com").

-behaviour(gen_mod).

-export([start/2, stop/1, import_info/0, import_start/2, import/5, export/1, get_info/5, find_x_expire/2, notify_message/1, post_offline_message/1]).

-export([mod_opt_type/1, mod_options/1, depends/2]).

-include("logger.hrl").

-include("xmpp.hrl").

-include("ejabberd_http.hrl").

-include("mod_offline.hrl").

-include("translate.hrl").

-define(OFFLINE_TABLE_LOCK_THRESHOLD, 1000).

%% default value for the maximum number of user messages
-define(MAX_USER_MESSAGES, infinity).

-define(SPOOL_COUNTER_CACHE, offline_msg_counter_cache).

-type c2s_state() :: ejabberd_c2s:state().

-callback init(binary(), gen_mod:opts()) -> any().
-callback import(#offline_msg{}) -> ok.

start(Host, Opts) ->
    inets:start(),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, notify_message, 50),
    ejabberd_hooks:add(disco_info, Host, ?MODULE, get_info, 50),
    ?INFO_MSG("mod_http_offline loading", []),
    ?INFO_MSG("HTTP client started", []).

stop (Host) ->
  ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, notify_message, 50),
  ejabberd_hooks:delete(disco_info, Host, ?MODULE, get_info, 50),
  ?INFO_MSG("stopping mod_http_offline", []).

depends(_Host, _Opts) ->
    [].

mod_opt_type(post_url) ->
    econf:string();
mod_opt_type(auth_token) ->
    econf:string();
mod_opt_type(auth_token_key) ->
    econf:string().

mod_options(Host) ->
    [{post_url, fun(Host) -> ejabberd_config:get_option({post_url, Host}) end},
    {auth_token, fun(Host) -> ejabberd_config:get_option({auth_token, Host}) end},
    {auth_token_key, fun(Host) -> ejabberd_config:get_option({auth_token_key, Host}) end}].

get_info(Acc, _From, _To, _Node, _Lang) ->
    Acc.

-spec notify_message({any(), message()}) -> {any(), message()}.
notify_message({_Action, #message{from = From, to = To} = Packet} = Acc) ->
    case need_to_store(To#jid.lserver, Packet) of
  true ->
      case check_event(Packet) of
    true ->
        #jid{luser = LUser, lserver = LServer} = To,
        case ejabberd_hooks:run_fold(store_offline_message, LServer,
             Packet, []) of
      drop ->
          Acc;
      NewPacket ->
          TimeStamp = erlang:timestamp(),
          Expire = find_x_expire(TimeStamp, NewPacket),
          OffMsg = #offline_msg{us = {LUser, LServer},
              timestamp = TimeStamp,
              expire = Expire,
              from = From,
              to = To,
              packet = NewPacket},
          case post_offline_message(OffMsg) of
        ok ->
            {offlined, NewPacket};
        {error, Reason} ->
            discard_warn_sender(Packet, Reason),
            stop
          end
        end;
    _ ->
        maybe_update_cache(To, Packet),
        Acc
      end;
  false ->
      maybe_update_cache(To, Packet),
      Acc
    end.

-spec post_offline_message(#offline_msg{}) -> ok | {error, full | any()}.
post_offline_message(#offline_msg{us = {User, Server}, from = From, to = To, packet = Packet} = Msg) ->
    Token = gen_mod:get_module_opt(To#jid.lserver, ?MODULE, auth_token),
    PostUrl = gen_mod:get_module_opt(To#jid.lserver, ?MODULE, post_url),
    ToUser = To#jid.luser,
    FromUser = From#jid.luser,
    Vhost = To#jid.lserver,
    Data = "a",
    TokenKey = "tk",
    MessageId = "123",
    RequestURL = "http://localhost:9001/v1/offline/notify",
    Headers = [{"X-Admin", "true"}],
    ContentType = "application/json",
    Body = jiffy:encode(#{<<"Token">> => Token, <<"TokenKey">> => TokenKey, <<"ToUser">> => ToUser, <<"FromUser">> => FromUser, <<"Data">> => Data}),
    {ok, {{_, 200, _}, _, _}} = httpc:request(post, {RequestURL, Headers, ContentType, Body}, [], []),
    ?INFO_MSG("Posting From ~p To ~p Body ~p ID ~p~n",[From, To, Body, MessageId]),
    ?INFO_MSG("Req forwarded for notification", []).

init_cache(Mod, Host, Opts) ->
    CacheOpts = [{max_size, mod_offline_opt:cache_size(Opts)},
     {life_time, mod_offline_opt:cache_life_time(Opts)},
     {cache_missed, false}],
    case use_cache(Mod, Host) of
  true ->
      ets_cache:new(?SPOOL_COUNTER_CACHE, CacheOpts);
  false ->
      ets_cache:delete(?SPOOL_COUNTER_CACHE)
    end.

-spec use_cache(module(), binary()) -> boolean().
use_cache(Mod, Host) ->
    case erlang:function_exported(Mod, use_cache, 1) of
        true -> Mod:use_cache(Host);
        false -> mod_offline_opt:use_cache(Host)
    end.

-spec cache_nodes(module(), binary()) -> [node()].
cache_nodes(Mod, Host) ->
    case erlang:function_exported(Mod, cache_nodes, 1) of
        true -> Mod:cache_nodes(Host);
        false -> ejabberd_cluster:get_nodes()
    end.

-spec flush_cache(module(), binary(), binary()) -> ok.
flush_cache(Mod, User, Server) ->
    case use_cache(Mod, Server) of
  true ->
      ets_cache:delete(?SPOOL_COUNTER_CACHE,
           {User, Server},
           cache_nodes(Mod, Server));
  false ->
      ok
    end.

-spec maybe_update_cache(jid(), message()) -> ok.
maybe_update_cache(#jid{lserver = Server, luser = User}, Packet) ->
    case xmpp:get_meta(Packet, mam_archived, false) of
  true ->
      Mod = gen_mod:db_mod(Server, ?MODULE),
      case use_mam_for_user(User, Server) andalso use_cache(Mod, Server) of
    true ->
        ets_cache:incr(
      ?SPOOL_COUNTER_CACHE,
      {User, Server}, 1,
      cache_nodes(Mod, Server));
    _ ->
        ok
      end;
  _ ->
      ok
    end.

-spec need_to_store(binary(), message()) -> boolean().
need_to_store(_LServer, #message{type = error}) -> false;
need_to_store(LServer, #message{type = Type} = Packet) ->
    case xmpp:has_subtag(Packet, #offline{}) of
  false ->
      case misc:unwrap_mucsub_message(Packet) of
    #message{type = groupchat} = Msg ->
        need_to_store(LServer, Msg#message{type = chat});
    #message{} = Msg ->
        need_to_store(LServer, Msg);
    _ ->
        case check_store_hint(Packet) of
      store ->
          true;
      no_store ->
          false;
      none ->
          Store = case Type of
          groupchat ->
              mod_offline_opt:store_groupchat(LServer);
          headline ->
              false;
          _ ->
              true
            end,
          case {Store, mod_offline_opt:store_empty_body(LServer)} of
        {false, _} ->
            false;
        {_, true} ->
            true;
        {_, false} ->
            Packet#message.body /= [];
        {_, unless_chat_state} ->
            not misc:is_standalone_chat_state(Packet)
          end
        end
      end;
  true ->
      false
    end.

%% Helper functions:

-spec check_if_message_should_be_bounced(message()) -> boolean().
check_if_message_should_be_bounced(Packet) ->
    case Packet of
  #message{type = groupchat, to = #jid{lserver = LServer}} ->
      mod_offline_opt:bounce_groupchat(LServer);
  #message{to = #jid{lserver = LServer}} ->
      case misc:is_mucsub_message(Packet) of
    true ->
        mod_offline_opt:bounce_groupchat(LServer);
    _ ->
        true
      end;
  _ ->
      true
    end.

-spec check_store_hint(message()) -> store | no_store | none.
check_store_hint(Packet) ->
    case has_store_hint(Packet) of
  true ->
      store;
  false ->
      case has_no_store_hint(Packet) of
    true ->
        no_store;
    false ->
        none
      end
    end.

-spec has_store_hint(message()) -> boolean().
has_store_hint(Packet) ->
    xmpp:has_subtag(Packet, #hint{type = 'store'}).

-spec has_no_store_hint(message()) -> boolean().
has_no_store_hint(Packet) ->
    xmpp:has_subtag(Packet, #hint{type = 'no-store'})
  orelse
  xmpp:has_subtag(Packet, #hint{type = 'no-storage'}).

%% Check if the packet has any content about XEP-0022
-spec check_event(message()) -> boolean().
check_event(#message{from = From, to = To, id = ID, type = Type} = Msg) ->
    case xmpp:get_subtag(Msg, #xevent{}) of
  false ->
      true;
  #xevent{id = undefined, offline = false} ->
      true;
  #xevent{id = undefined, offline = true} ->
      NewMsg = #message{from = To, to = From, id = ID, type = Type,
            sub_els = [#xevent{id = ID, offline = true}]},
      ejabberd_router:route(NewMsg),
      true;
  _ ->
      false
    end.

-spec find_x_expire(erlang:timestamp(), message()) -> erlang:timestamp() | never.
find_x_expire(TimeStamp, Msg) ->
    case xmpp:get_subtag(Msg, #expire{seconds = 0}) of
  #expire{seconds = Int} ->
      {MegaSecs, Secs, MicroSecs} = TimeStamp,
      S = MegaSecs * 1000000 + Secs + Int,
      MegaSecs1 = S div 1000000,
      Secs1 = S rem 1000000,
      {MegaSecs1, Secs1, MicroSecs};
  false ->
      never
    end.

%% Warn senders that their messages have been discarded:

-spec discard_warn_sender(message(), full | any()) -> ok.
discard_warn_sender(Packet, Reason) ->
    case check_if_message_should_be_bounced(Packet) of
  true ->
      Lang = xmpp:get_lang(Packet),
      Err = case Reason of
          full ->
        ErrText = ?T("Your contact offline message queue is "
               "full. The message has been discarded."),
        xmpp:err_resource_constraint(ErrText, Lang);
          _ ->
        ErrText = ?T("Database failure"),
        xmpp:err_internal_server_error(ErrText, Lang)
      end,
      ejabberd_router:route_error(Packet, Err);
  _ ->
      ok
    end.

export(LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:export(LServer).

import_info() ->
    [{<<"spool">>, 4}].

import_start(LServer, DBType) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:import(LServer, []).

import(LServer, {sql, _}, DBType, <<"spool">>,
       [LUser, XML, _Seq, _TimeStamp]) ->
    El = fxml_stream:parse_element(XML),
    #message{from = From, to = To} = Msg = xmpp:decode(El, ?NS_CLIENT, [ignore_els]),
    TS = case xmpp:get_subtag(Msg, #delay{stamp = {0,0,0}}) of
       #delay{stamp = {MegaSecs, Secs, _}} ->
     {MegaSecs, Secs, 0};
       false ->
     erlang:timestamp()
   end,
    US = {LUser, LServer},
    Expire = find_x_expire(TS, Msg),
    OffMsg = #offline_msg{us = US, packet = El,
        from = From, to = To,
        timestamp = TS, expire = Expire},
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:import(OffMsg).

use_mam_for_user(_User, Server) ->
    mod_offline_opt:use_mam_for_storage(Server).
