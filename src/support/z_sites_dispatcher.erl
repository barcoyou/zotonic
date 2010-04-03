%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2009 Marc Worrell
%% @date 2009-12-15
%% @doc Server for matching the request path to correct site and dispatch rule.

%% Copyright 2009 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(z_sites_dispatcher).
-author("Marc Worrell <marc@worrell.nl>").

% Authors of the Webmachine dispatch matcher.
-author('Robert Ahrens <rahrens@basho.com>').
-author('Justin Sheehy <justin@basho.com>').
-author('Bryan Fink <bryan@basho.com>').

-behaviour(gen_server).

%% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start_link/0, start_link/1]).

%% interface functions
-export([
	dispatch/3,
	set_dispatch_rules/1,
	get_fallback_site/0
]).

-include_lib("zotonic.hrl").
-include_lib("wm_host_dispatch_list.hrl").

-record(state, {rules, fallback_site}).

%%====================================================================
%% API
%%====================================================================
%% @spec start_link() -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
start_link() -> 
    start_link([]).
start_link(Args) when is_list(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).



%% @doc Match the host and path to a dispatch rule.
%% @spec dispatch(Host::string(), Path::string(), ReqData::wm_reqdata) -> {dispatch(), NewReqData}
%% @type dispatch() -> {no_dispatch_match, _UnmatchedHost, _UnmatchedPathTokens}
%%                   | {Mod, ModOpts, HostTokens, Port, PathTokens, Bindings, AppRoot, StringPath}
%%                   | handled
dispatch(Host, Path, ReqData) ->
    case gen_server:call(?MODULE, {dispatch, Host, Path, ReqData}) of
        {{no_dispatch_match, MatchedHost, NonMatchedPathTokens}, ReqData1} when MatchedHost =/= undefined ->
            %% Check if there is a matching resource page_path for the host
            Context = z_context:new(MatchedHost),
            case m_rsc:page_path_to_id(Path, Context) of
                {ok, Id} ->
                    %% We found the id, lookup the page uri
                    DefaultPagePath = lists:flatten(m_rsc:p_no_acl(Id, default_page_url, Context)),
                    gen_server:call(?MODULE, {dispatch, Host, DefaultPagePath, ReqData});
                {error, _} ->
                    {{no_dispatch_match, MatchedHost, NonMatchedPathTokens}, ReqData1}
            end;
        Result ->
            Result
    end.


%% @doc Store a new set of dispatch rules, called when a site refreshes its modules or when a site is restarted.
set_dispatch_rules(DispatchRules) ->
	gen_server:cast(?MODULE, {set_dispatch_rules, DispatchRules}).

%% @doc Retrieve the fallback site.
get_fallback_site() ->
	gen_server:call(?MODULE, {get_fallback_site}).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore               |
%%                     {stop, Reason}
%% @doc Initiates the server.
init(_Args) ->
    application:set_env(webmachine, dispatcher, ?MODULE),
    {ok, #state{rules=[], fallback_site=z_sites_sup:get_fallback_site()}}.

%% @spec handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%% @doc Match a host/path to the dispatch rules.  Return a match result or a no_dispatch_match tuple.
handle_call({dispatch, HostAsString, PathAsString, ReqData}, _From, State) ->
    Reply = case get_host_dispatch_list(HostAsString, State#state.rules, State#state.fallback_site, ReqData) of
        {ok, Host, DispatchList} ->
            {ok, RDHost} = webmachine_request:set_metadata(zotonic_host, Host, ReqData),
            case dispatch(PathAsString, DispatchList) of
                {no_dispatch_match, UnmatchedPathTokens} ->
                    {{no_dispatch_match, Host, UnmatchedPathTokens}, RDHost};
                {DispatchName, Mod, ModOpts, PathTokens, Bindings, AppRoot, StringPath} ->
                    {{Mod, ModOpts, 
                        [], none, % Host info
                        PathTokens, [{zotonic_dispatch, DispatchName},{zotonic_host, Host}|Bindings], 
                        AppRoot, StringPath}, 
                     RDHost}
            end;
        {redirect, Hostname} ->
            %% Redirect to another host name.
            RawPath = wrq:raw_path(ReqData),
            Uri = "http://" ++ Hostname ++ RawPath,
            RD1 = wrq:set_resp_header("Location", Uri, ReqData),
            {ok, RD2} = webmachine_request:send_response(301, RD1),
            LogData = webmachine_request:log_data(RD2),
            LogModule = 
                case application:get_env(webmachine,webmachine_logger_module) of
                    {ok, Val} -> Val;
                    _ -> webmachine_logger
                end,
            spawn(LogModule, log_access, [LogData]),
            {handled, RD2};
        no_host_match ->
            {{no_dispatch_match, undefined, undefined}, ReqData}
    end,
    {reply, Reply, State};

%% @doc Return the fallback site
handle_call({get_fallback_site}, _From, State) ->
    {reply, State#state.fallback_site, State};

%% @doc Trap unknown calls
handle_call(Message, _From, State) ->
    {stop, {unknown_call, Message}, State}.


%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @doc Load a new set of dispatch rules.
handle_cast({set_dispatch_rules, Rules}, State) ->
    {noreply, State#state{rules=Rules}};

%% @doc Trap unknown casts
handle_cast(Message, State) ->
    {stop, {unknown_cast, Message}, State}.



%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% @doc Handling all non call/cast messages
handle_info(_Info, State) ->
    {noreply, State}.

%% @spec terminate(Reason, State) -> void()
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
terminate(_Reason, _State) ->
    ok.

%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @doc Convert process state when code is changed

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% support functions
%%====================================================================


%% @doc Fetch the host and dispatch list for the request
%% @spec get_host_dispatch_list(webmachine_request()) -> {ok, Host::atom(), DispatchList::list()} | {redirect, Hostname::string()} | no_host_match
get_host_dispatch_list(WMHost, DispatchList, Fallback, ReqData) ->
    case DispatchList of
        [#wm_host_dispatch_list{}|_] ->
            {Host, Port} = split_host(WMHost),
            case get_dispatch_host(Host, DispatchList) of
                {ok, DL} ->
                    {ok, DL#wm_host_dispatch_list.host, DL#wm_host_dispatch_list.dispatch_list};

                undefined ->
                    FoundHost = case get_dispatch_alias(Host, DispatchList) of
                                    {ok, _} = Found -> Found;
                                    undefined -> get_dispatch_fallback(DispatchList, Fallback)
                                end,
                    case FoundHost of
                        {ok, DL} ->
                            Method = wrq:method(ReqData),
                            case DL#wm_host_dispatch_list.redirect andalso is_hostname(DL#wm_host_dispatch_list.hostname) andalso Method =:= 'GET' of
                                true ->
                                    % Redirect, keep the port number
                                    Hostname = DL#wm_host_dispatch_list.hostname,
                                    Hostname1 = case Port of
                                                    "80" -> Hostname;
                                                    _ -> Hostname ++ [$:|Port]
                                                end,
                                    {redirect, Hostname1};
                                false ->
                                    {ok, DL#wm_host_dispatch_list.host, DL#wm_host_dispatch_list.dispatch_list}
                            end;
                        undefined ->
                            no_host_match
                    end
            end;
        _ ->
            {ok, Fallback, DispatchList} 
    end.


split_host(Host) ->
    case Host of
        undefined -> 
            {"", "80"};
        [] -> 
            {"", "80"};
        _ -> 
            % Split the optional port number from the host name
            [H|Rest] = string:tokens(string:to_lower(Host), ":"),
            case Rest of
                [] -> {H, "80"};
                [Port|_] -> {H, Port}
            end
    end.


%% @doc Search the host where the main hostname matches the requested host
get_dispatch_host(_Host, []) ->
    undefined;
get_dispatch_host(Host, [#wm_host_dispatch_list{hostname=Host} = DL|_]) ->
    {ok, DL};
get_dispatch_host(Host, [_|Rest]) ->
    get_dispatch_host(Host, Rest).


%% @doc Search the host where the req hostname is an alias of main host
get_dispatch_alias(_Host, []) ->
    undefined;
get_dispatch_alias(Host, [#wm_host_dispatch_list{hostalias=Alias} = DL|Rest]) ->
    case lists:member(Host, Alias) of
        true  -> {ok, DL};
        false -> get_dispatch_alias(Host, Rest)
    end.


%% @doc Retrieve the dispatch list of the fallback site for unknown hostnames.
get_dispatch_fallback([], _FallbackHost) ->
    undefined;
get_dispatch_fallback([#wm_host_dispatch_list{host=FallbackHost} = DL|_], FallbackHost) ->
    {ok, DL};
get_dispatch_fallback([_|Rest], FallbackHost) ->
    get_dispatch_fallback(Rest, FallbackHost).


%% @doc Check if the hostname is a hostname suitable to redirect to
is_hostname(undefined) -> false;
is_hostname("") -> false;
is_hostname("localhost") -> false;
is_hostname("127.0.0.1") -> false;
is_hostname(_) -> true.



%%%%%%% Adapted version of Webmachine dispatcher %%%%%%%%
% Main difference is that we want to know which dispatch rule was choosen.

%% @author Robert Ahrens <rahrens@basho.com>
%% @author Justin Sheehy <justin@basho.com>
%% @copyright 2007-2009 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

-define(SEPARATOR, $\/).
-define(MATCH_ALL, '*').

%% @spec dispatch(Path::string(), DispatchList::[matchterm()]) ->
%%                                            dispterm() | dispfail()
%% @doc Interface for URL dispatching.
%% See also http://bitbucket.org/justin/webmachine/wiki/DispatchConfiguration
dispatch(PathAsString, DispatchList) ->
    Path = string:tokens(PathAsString, [?SEPARATOR]),
    % URIs that end with a trailing slash are implicitly one token
    % "deeper" than we otherwise might think as we are "inside"
    % a directory named by the last token.
    ExtraDepth = case lists:last(PathAsString) == ?SEPARATOR of
		     true -> 1;
		     _ -> 0
		 end,
    try_path_binding(DispatchList, Path, [], ExtraDepth).

try_path_binding([], PathTokens, _, _) ->
    {no_dispatch_match, PathTokens};
try_path_binding([{DispatchName, PathSchema, Mod, Props}|Rest], PathTokens, Bindings, ExtraDepth) ->
    case bind(PathSchema, PathTokens, Bindings, 0) of
        {ok, Remainder, NewBindings, Depth} ->
            {DispatchName, Mod, Props, Remainder, NewBindings, calculate_app_root(Depth + ExtraDepth), reconstitute(Remainder)};
        fail -> 
            try_path_binding(Rest, PathTokens, Bindings, ExtraDepth)
    end.

bind([], [], Bindings, Depth) ->
    {ok, [], Bindings, Depth};
bind([?MATCH_ALL], Rest, Bindings, Depth) when is_list(Rest) ->
    {ok, Rest, Bindings, Depth + length(Rest)};
bind(_, [], _, _) ->
    fail;
bind([Token|RestToken],[Match|RestMatch],Bindings,Depth) when is_atom(Token) ->
    bind(RestToken, RestMatch, [{Token, Match}|Bindings], Depth + 1);
bind([Token|RestToken], [Token|RestMatch], Bindings, Depth) ->
    bind(RestToken, RestMatch, Bindings, Depth + 1);
bind(_, _, _, _) ->
    fail.

reconstitute([]) -> "";
reconstitute(UnmatchedTokens) -> string:join(UnmatchedTokens, [?SEPARATOR]).

calculate_app_root(1) -> ".";
calculate_app_root(N) when N > 1 ->
    string:join(lists:duplicate(N, ".."), [?SEPARATOR]).


