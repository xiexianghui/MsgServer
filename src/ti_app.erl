-module(ti_app).

-behaviour(application).

-export([start/0, start/2, stop/1]).

-define(DEF_PORT, 6000).
-define(DEF_PORT_MAN, 6001).
-define(DEF_DB, "127.0.0.1").
-define(DEF_PORT_DB, 6002).

start() ->
	start(normal, [?DEF_PORT, ?DEF_PORT_MAN, ?DEF_DB, ?DEF_PORT_DB]).

%start(_StartType, _StartArgs) ->
start(_StartType, StartArgs) ->
	[DefPort, DefPortMan, DefDB, DefPortDB] = StartArgs,
    %Port = case application:get_env(tcp_interface, port) of
    %           {ok, P} -> P;
    %           undefined -> ?DEF_PORT
    %       end,
    case ti_sup_db:start_link(DefDB, DefPortDB) of % Error
        {ok, PidDB} ->
            ti_sup:start_child(),
            %{ok, PidDB};
			PidDB,
		    {ok, LSockMan} = gen_tcp:listen(DefPortMan, [{active, true}]),
		    case ti_sup_man:start_link() of
		        {ok, PidMan} ->
		            ti_sup:start_child(LSockMan),
		            %{ok, PidMan};
					PidMan,
				    {ok, LSock} = gen_tcp:listen(DefPort, [{active, true}]),
				    case ti_sup:start_link(LSock) of
				        {ok, Pid} ->
				            ti_sup:start_child(),
				            {ok, Pid};
				        Other ->
							error_logger:error_msg("Cannot start listen from the VDR : ~p~nExit.~n", Other),
				            {error, Other}
				    end;
		        OtherMan ->
					error_logger:error_msg("Cannot start listen from the management server : ~p~nExit.~n", OtherMan),
		            {error, OtherMan}
		    end;
        OtherDB ->
			error_logger:error_msg("Cannot start connection to the database : ~p:~p~nExit.~n", [OtherDB, DefPortDB]),
            {error, OtherDB}
    end.

stop(_State) ->
    ok.
