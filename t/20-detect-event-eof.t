use Test2::V0;
use IO::SocketAlarm 'socketalarm';
use Socket;

socket(my $s, AF_INET, SOCK_STREAM, 0);
my $got_alarm= 0;
my $got_alarm_late= 0;
$SIG{ALRM}= sub { warn "Got alarm late"; $got_alarm_late++ };
{
   local $SIG{ALRM}= sub { warn "Got alarm"; $got_alarm++ };
   ok( my $alarm= socketalarm($s), 'socketalarm' );
   shutdown($s, SHUT_RD);
   sleep 1;
   $alarm->cancel;
}
is( $got_alarm, 1, 'got_alarm' );
is( $got_alarm_late, 0, 'didn\'t get alarm late' );

done_testing;