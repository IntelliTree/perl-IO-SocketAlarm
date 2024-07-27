use Test2::V0;
use Socket ':all';
use File::Temp;
use IO::SocketAlarm;

my @tests= (
   {  spec   => [ [ sleep => 1 ] ],
      result => [ 'sleep 1.000s' ],
   },
   {  spec   => [ [ run => 'echo', 'Test' ] ],
      result => [ "fork,fork,exec('echo','Test')" ],
   },
   {  spec   => [ [ exec => 'echo', 'Test' ] ],
      result => [ "exec('echo','Test')" ],
   },
   {  spec   => [ [ sig => 9 ] ],
      result => [ "kill sig=9 pid=$$" ],
   },
   {  spec   => [ [ kill => 10, 19000 ] ],
      result => [ "kill sig=10 pid=19000" ],
   },
   {  spec   => [ [ close => 0 ] ],
      result => [ 'close 0' ],
   },
   {  spec   => [ [ close => pack_sockaddr_in(42, inet_aton('127.0.0.1')) ] ],
      result => [ 'close peername inet 127.0.0.1:42' ],
   },
   {  spec   => [ [ shut_r => 0 ] ],
      result => [ 'shutdown SHUT_RD 0' ],
   },
   {  spec   => [ [ shut_w => 0 ] ],
      result => [ 'shutdown SHUT_WR 0' ],
   },
   {  spec   => [ [ shut_rw => 0 ] ],
      result => [ 'shutdown SHUT_RDWR 0' ],
   },
   # 'repeat' feature is probably more trouble than it is worth
   #{  spec   => [ [ sig => 10 ], [ sleep => 1 ], [ 'repeat' ] ],
   #   result => [ "kill sig=10 pid=$$", 'sleep 1.000s', 'goto 0' ],
   #},
   #{  spec   => [ [ sleep => 1 ], [ close => 1, 2, 3, 4, 5 ], [ sleep => 1 ], [ repeat => 2 ] ],
   #   result => [ 'sleep 1.000s', 'close 1', 'close 2', 'close 3', 'close 4', 'close 5', 'sleep 1.000s', 'goto 1' ],
   #},
);

socket my $s, AF_INET, SOCK_STREAM, 0;
for my $test (@tests) {
   my $name= join ' | ', @{$test->{result}};
   my $expected= join "\n",
      "watch fd: ".fileno($s),
      "event mask:",
      "actions:",
      (map sprintf("%4d: %s", $_, $test->{result}[$_]), 0..$#{$test->{result}}),
      '';
   my $sa= IO::SocketAlarm::_new_socketalarm($s, 0, $test->{spec});
   is( $sa->stringify, $expected, $name );
}

done_testing;