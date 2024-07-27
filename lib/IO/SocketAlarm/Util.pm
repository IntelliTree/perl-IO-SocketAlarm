# PODNAME: IO::SocketAlarm::Util
# This package is defined in XS loaded by IO::SocketAlarm.
# This file stub exists for documentation and to allow 'use ...Util'
require IO::SocketAlarm;

__END__

=head1 EXPORTS

=head2 socketalarm

  $alarm= socketalarm($socket);
  $alarm= socketalarm($socket, @actions);
  $alarm= socketalarm($socket, $event_mask, @actions);

This is a shortcut for L<IO::SocketAlarm-E<gt>new|IO::SocketAlarm/new>:

  $alarm= IO::SocketAlarm->new(
    socket => $socket,
    events => $event_mask,
    actions => \@actions,
  );

=head2 is_socket

  $bool= is_socket($thing);

Returns true if and only if the parameter is a socket.  It permits file handles or file
descriptor numbers.

=head2 render_fd_table

  $str= render_fd_table();

Return a string describing the current open file descriptors of this process.


