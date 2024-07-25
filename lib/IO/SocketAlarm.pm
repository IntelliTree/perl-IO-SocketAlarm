package IO::SocketAlarm;

# VERSION
# ABSTRACT: Perform asynchronous actions when a socket changes status

use strict;
use warnings;
use Carp;
use Scalar::Util ();
require XSLoader;
XSLoader::load('IO::SocketAlarm', $IO::SocketAlarm::VERSION);

# All exports are part of the Util sub-package.
# They are declared in XS
package IO::SocketAlarm::Util {
   our @EXPORT_OK= qw( render_fd_table is_socket );
   use Exporter 'import';
}

sub import {
   splice(@_, 0, 1, 'IO::SocketAlarm::Util');
   goto \&IO::SocketAlarm::Util::import;
}

=head1 SYNOPSIS

  use IO::SocketAlarm qw( socketalarm :events );
  use POSIX ':signal_h';
  
  local $SIG{ALRM}= sub { die "got alarm"; };
  # When the client goes away, send SIGALRM
  my $alarm= socketalarm($socket);
  ...
  $alarm->cancel;  # stop receiving signal
  
  # More extreme example: when client goes away, terminate
  # the current process and also kill the mysql query.
  my $mysql_conn_id= $dbh->selectcoll_arrayref("SELECT CONNECTION_ID()")->[0];
  my $alarm= socketalarm($socket, EVENT_EOF|EVENT_EPIPE,
    [ exec => 'mysql', -e => "kill $mysql_conn_id" ]);

=head1 DESCRIPTION

Sometimes you have a blocking system call, or blocking library, and it prevents you from
checking whether the initiator of this request (like a http client) is still waiting for the
answer.  The right way to solve the problem is an event loop, where you are waiting both for
the long-tunning task and also watching for events on the client connection and your program
can respond to either of them.  But, if you don't have the luxury of refactoring your whole
project to be event-driven, and you'd really just like a way to kill the current script when
the client is lost and you're blocking in a long-running database call, this module is for
you.

This module oeprates by creating a second C-level thread, regardless of whether your perl
was compiled with threading support.  While the module is thread-safe, per-se, it does
introduce the sorts of confusion caused by concurrency, like checking C<< $watch->pending >>
and having that status change before the very next line of code you run.

The background thread also limits the types of actions you can take.  For example, you
definitely can't run perl code in response to the status change.  This module tries to provide
a useful toolkit of actions, including forking off a command.

Also beware that the signals you send to yourself won't take effect until control returns to
the perl interpreter, so if you are blocking in a C library, it might be that the only way to
wake it up is to close the file handles it is using.  For mysql, this can be extremely
problematic if it is using mysql_auto_reconnect, and besides which, mysql servers don't notice
that clients are gone until the current query ends.  Stopping a long-running mysql query can
mostly only be accomplished from the server side.

=head1 EXPORTS

This module exports everything from L<IO::SocketAlarm::Util>.  Of particular note:

=head2 socketalarm

  $alarm= socketalarm($socket); # sends SIGALRM when EVENT_EOF|EVENT_EPIPE
  $alarm= socketalarm($socket, @actions);
  $alarm= socketalarm($socket, $event_mask, @actions);

This creates a new alarm on C<$socket>, waiting for C<$event_mask> to occur, and if it does,
a background thread will run C<@actions>.  It is a shortcut for L<new|/new> as follows:

  $alarm= IO::SocketAlarm->new(
    socket => $socket,
    events => $event_mask,
    actions => \@actions,
  );

=head1 ALARM OBJECT

An Alarm object represents the scope of the alarm.  You can undefine it or call
C<< $alarm->cancel >> to disable the alarm, but beware that you might have a race condition
between letting it go out of scope and letting your local signal handler go out of scope, so
use the same precautions that you would use when using C<alarm()>.

When triggered, the alarm only runs its actions once.

=head2 Attributes

=head3 socket

The C<$socket> must be an operating system level socket (having a 'fileno', as opposed to a
Perl virtual handle of some sort), and still be open.

=head3 events

This is a bit-mask of which events to trigger on.  Combine them with the bitwise-or operator:

  # the default:
  events => EVENT_EOF|EVENT_EPIPE,

=over

=item EVENT_EOF

Triggers when the peer has closed the connection, or shut down writing from their end.
(there may still be data available to be read from the socket's buffer)

=item EVENT_EPIPE

Triggers when writing the socket would generate an EPIPE signal.

=item EVENT_CLOSE

Triggers when the status of C<is_socket($fd)> changes to false.  Due to the asynchronous nature
of this module, a file descriptor could get recycled with a new socket before this module sees
it as closed.  To detect that case, you probably also want EVENT_RENAME.

(it is a better idea to make sure you cancel the watch before returning to any code which might
 close your end of the socket)

=item EVENT_RENAME

Every connected socket has a bound address, retrievable with C<getsockname>.  If this module
sees that a socket's name has changed, it assumes a race condition where the socket was closed
and the FD recycled for a new connection.  So, normally this event causes the alarm to cancel
itself, but if you want it to trigger instead, then include this bit in the events.  But, it is
also possible you called C<bind> on the socket to set a new name...

=back

=head3 actions

  # the default:
  actions => [ [ sig => SIGALRM ] ],

The C<@actions> are an array of one or more action specifications.  When the C<$events> are
detected, this list will be performed in sequence.  You can't just specify a coderef for an
action because they run in a separate C thread that isn't permitted to touch the perl
interpreter.  The available actions are:

=over

=item sig

  [ sig => $signal ],

Send yourself a signal. The signal constants come from C<< use POSIX ':signal_h'; >>.

=item kill

  [ kill => $pid, $signal ],

Send a signal to any process.

=item close

  [ close => $fd1, $fd2, $fd3... ],

Close one or more file descriptors.  This could have uses like killing database connections.

=item close_all

  [ close_all => $sockname1, $sockname2... ],

Close all sockets which are connected to one of the given names.  These "names" are byte
strings as per the C<getpeername> function.  You can either specify one directly, or provide
them as "$host_ip:$portnumber" and the library will convert to a socket name for you.

=item run

  [ run => @argv ],

Fork and exec an external program.  The program shares your STDOUT and STDERR, but is connected
to /dev/null on STDIN.  The library does not wait to see whether the program succeeded.

=item exec

  [ exec => @argv ],

Replace the current running process with a different process, just like C<exec>.  This
completely aborts the main perl script and loses any work, without calling 'atexit' or any
other cleanup your perl script might have intended to do.  Sometimes, this is what you want,
though.  This can fail if C<< $argv[0] >> isn't found in the PATH.

=item sleep

  [ sleep => $seconds ],

Wait before running the next action.

=item repeat

  [ repeat => $n ],

Repeat the previous C<$n> actions.

=back

=head3 triggered

Whether or not 

=head2 Methods

=head3 start

Begin listening for the alarm events.  Returns a boolean of whether the alarm was inactive
prior to this call. (i.e. whether the call changed the state of the alarm)

=head3 cancel

Stop listening for the alarm events.  Returns a boolean of whether the alarm was active prior
to this call.  (i.e. whether the call changed the state of the alarm)

=cut

END { _terminate_all() }

1;
