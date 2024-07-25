use Test2::V0;
use Socket ':all';
use File::Temp;
use IO::SocketAlarm 'render_fd_table';

my $f= File::Temp->new;
socket my $s, AF_INET, SOCK_STREAM, 0;
my $file_fd= fileno($f);
my $sock_fd= fileno($s);

ok( my $table= render_fd_table, 'render_fd_table' );
note $table;
like( $table, qr/^ *$file_fd: $f$/m,    'includes known file' );
like( $table, qr/^ *$sock_fd: inet \[0\.0\.0\.0\]:0$/m, 'includes known socket' );
like( $table, qr/\}\n\Z/, 'ends with }\\n' );

done_testing;