-module(chatsrv).
-compile(export_all).

-include("/usr/lib/erlang/lib/stdlib-1.18.1/include/qlc.hrl").

-record(channels,{cnumber,pid,topic,members}).
-record(users,{uid,uname,pid}).

%% Start server process and DB
start_server(New) ->
	start_mnesia(New),
	spawn(fun start_client_listen/0).

%% Start DB and create schema
start_mnesia(true) ->
	mnesia:create_schema([node()]),
	mnesia:start(),
	mnesia:create_table(channels,[{attributes,record_info(fields,channels)},{disc_copies,[node()]}]),
	mnesia:create_table(users,[{attributes,record_info(fields,users)},{disc_copies,[node()]}]);

%% Only start DB
start_mnesia(false) ->
	mnesia:start().

%% Listen
start_client_listen() ->
	{ok,Socket} = gen_tcp:listen(32768,[binary,{packet,0}]),
	accept_loop(Socket).

%% Accept connections
accept_loop(Socket) ->
	{ok,ClSock} = gen_tcp:accept(Socket),
	spawn(?MODULE,accept_loop,[Socket]),
	handle_client(ClSock,"").

%% Handle clients in a loop
%% UserName is the state. It's the associated user.
handle_client(Socket,UserName) ->
	receive
		{tcp,Socket,Data} ->
			case handle_data(Data,UserName) of
				%%error -> gen_tcp:send(Socket,"Error at action.\n"), handle_client(Socket,UserName); %% Abort communication
				String when is_list(String) -> handle_client(Socket,String)
			end;
		{tcp,closed} -> void;
		{mesg,Message} -> gen_tcp:send(Socket,Message)
	end.

%% Handle received Data
handle_data(Data,UserName) ->
	case split_binary(Data,1) of
		{<<1>>,ChanName} ->
			<<ChanNumber:64/native>> = ChanName,
			join_channel(ChanNumber,UserName),
			UserName;
		%{<<2>>,ChanAndMesg} -> UserName;%send_message(parse_message(ChanAndMesg))
		{<<3>>,NewUserName} ->
			try add_user(binary_to_list(NewUserName)) of
				{atomic,ok} -> binary_to_list(NewUserName)
			catch
				throw: userExistsAlready -> error
			end
	end.

%% Put a user in a channel
join_channel(Channel,User) ->
	%% Get UID of user
	case mnesia:transaction(fun() ->
				qlc:e(qlc:q([U#users.uid || U <- mnesia:table(users), string:equal(U#users.uname,User)]))
		end) of

		{atomic,[UID]} -> UID;
		{atomic,[]}    -> UID = 42, exit(noSuchUser) %% Abort - no such user. Should break the connection
	end,

	%% Get list which users are already in this channel
	case mnesia:transaction(fun() ->
				qlc:e(qlc:q([C#channels.members || C <- mnesia:table(channels), string:equal(C#channels.cnumber,Channel)]))
		end) of

		{atomic,[ListOfJoinedUsersInThisChannel]} -> fine;
		{atomic,[]} -> ListOfJoinedUsersInThisChannel = []
	end,

	case lists:member(UID,ListOfJoinedUsersInThisChannel) of
		%% User is not yet in this channel
		false -> {atomic,ok} = mnesia:transaction(fun() ->
					case mnesia:read(channels,Channel) of
						%% Channel already exists
						[{channels,Number,Pid,Topic,Members}] -> Record = #channels{cnumber=Number,pid=Pid,topic=Topic,members=[UID|Members]};
						%% Channel gets created
						[] ->
							{atomic,ChanNums} = mnesia:transaction(fun() ->
										qlc:e(qlc:q([C#channels.cnumber || C <- mnesia:table(channels)]))
								end),
							Record = #channels{cnumber=Channel, pid=spawn(?MODULE,chanproc,[Channel]), topic="",members=[UID]}
					end,
					mnesia:write(Record)
			end);
		%% User is already in this channel
		true -> goodAsWell
	end.

%% Add a user
add_user(UserName) ->
	Pid = self(),

	{atomic,PreviousUser} = mnesia:transaction(fun() ->
				qlc:e(qlc:q([U#users.uname || U <- mnesia:table(users), string:equal(UserName,U#users.uname)]))
		end),

	case PreviousUser of
		[] -> fine;
		Other -> throw(userExistsAlready)
	end,

	{atomic,ok} = mnesia:transaction(fun() ->
				Record = #users{uid=make_ref(),uname=UserName, pid=Pid},
				mnesia:write(Record)
		end).


%% Channel server: This channel sends the messages appearing in a channel to all users in this channel.
chanproc(Number) ->
	receive
		{mesg,Message} ->
			{atomic,[Members]} = mnesia:transaction(fun() ->
						qlc:e(qlc:q([C#channels.members || C <- mnesia:table(channels), C#channels.cnumber =:= Number]))
				end),
			lists:foreach(fun(U) ->
						{atomic,[Pid]} = mnesia:transaction(fun() ->
									qlc:e(qlc:q([V#users.pid || V <- mnesia:table(users), V#users.uid =:= U]))
							end),
						Pid ! Message end), chanproc(Number)
	end.

parse_message(Message) ->
	Limit = chat_util:find_mesg_limit(Message).
