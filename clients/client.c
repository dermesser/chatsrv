# include <stdlib.h>
# include <stdio.h>
# include <unistd.h>
# include <libsocket/libinetsocket.h>
# include <time.h>
# include <stdint.h>
# include <string.h>

int main(int argc, char** argv)
{
	int fd = -1;
	const char* host = "127.0.0.1";

	fd = create_inet_stream_socket(host,"32768",IPv4,0);

	if ( fd < 0 )
	{
		perror("Couldn't create socket\n");
		exit(1);
	}


	// Log in
	char action1[32];
	memset(action1,0,32);

	action1[0] = 3;
	strcpy(action1+1,"lbo_fbsduser");

	// Join Channel 45
	char action2[9];
	memset(action2,0,9);

	action2[0] = 1;

	uint64_t channum = 45;

	memcpy(action2+1,&channum,8);

	write(fd,&action1,13);
	sleep(1);
	write(fd,&action2,9);



	int bytes = 0;
	char message_action = 2;

	char whole_mesg[73];
	memset(whole_mesg,0,73);
	memcpy(whole_mesg,&message_action,1);
	memcpy(whole_mesg+1,&channum,8);

	while ( 0 < (bytes = read(0,whole_mesg+9,63)) )
	{
		write(fd,whole_mesg,bytes+9);
	}

	char action3 = 4;

	write(fd,&action3,1);

	return 0;
}
