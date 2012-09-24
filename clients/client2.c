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
	const char* host = "192.168.1.8";

	fd = create_inet_stream_socket(host,"32768",IPv4,0);

	if ( fd < 0 )
	{
		perror("Couldn't create socket\n");
		exit(1);
	}

	char action1[32];
	memset(action1,0,32);

	action1[0] = 3;
	strcpy(action1+1,"lbo_unixuser");

	char action2[9];
	memset(action2,0,9);

	action2[0] = 1;

	uint64_t channum = 45;

	memcpy(action2+1,&channum,8);

	write(fd,&action1,13);
	sleep(1);
	write(fd,&action2,9);

	int bytes = 0;
	char buf[128];
	buf[127] = 0;

	unsigned long long cur_chan = 0;

	while ( bytes = read(fd,buf,127) )
	{
		printf("New message: ");
		cur_chan = *((uint64_t*)buf);
		printf("%llu: ",cur_chan);
		write(1,buf+8,bytes-8);
	}

	close(fd);

	return 0;
}
