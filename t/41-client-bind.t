#!/usr/bin/env perl

use strict;
use warnings;
use AnyEvent::Impl::Perl;
use AnyEvent;
use AnyEvent::Socket;


use Test::More;
BEGIN {
	eval { require Net::Interface;1 } or plan skip_all => 'Net::Interface required';
}
use lib::abs '../lib';
use AnyEvent::SMTP qw/ smtp_server sendmail /;
use List::MoreUtils qw/ first_value /;
use Data::Dump qw/ pp /;

our $port = 1024 + $$ % ( 65535 - 1024 );
our $ready = 0;
$SIG{INT} = $SIG{TERM} = sub { exit 0 };

our $child;

plan skip_all => '$ENV{BIND_TEST} not enabled' unless $ENV{BIND_TEST};

unless ( $child = fork ) {

	# Start server and wait for connections
	my $cv          = AnyEvent->condvar;
	my $smtp_server = AnyEvent::SMTP::Server->new(
		port => $port,
	);
	# Always deny EHLO/HELO requests with "554 mail not allowed from ip={CLIENT_IP}".
	my $helo_cb = sub {
		my ( $s, $con, @args ) = @_;
		$con->{helo} = "@args";
		$con->new_m();
		$con->reply(
			sprintf( '554 mail not allowed from ip=%s:%d', $con->{host}, $con->{port} ) );
	};
	$smtp_server->reg_cb(
		HELO => $helo_cb,
		EHLO => $helo_cb,
	);
	$smtp_server->start;
	$cv->recv;
}
else {
	# Wait for server to start
	my $cv = AnyEvent->condvar;
	my ( $conn, $cg );
	$cv->begin(
		sub {
			undef $conn;
			undef $cg;
			$cv->send;
		}
	);
	$conn = sub {
		$cg = tcp_connect '127.0.0.1', $port, sub {
			return $cv->end if @_;
			$!{ENODATA}
			  or $!{ECONNREFUSED}
			  or plan skip_all => "Bad response from server connect: ["
			  . ( 0 + $! ) . "] $!";
			my $t;
			$t = AnyEvent->timer(
				after => 0.05,
				cb    => sub { undef $t; $conn->() }
			);
		};
	};
	$conn->();
	$cv->recv;
}

# XXX: This isn't a great test because certain interfaces may contain addresses
# we cannot bind to such as virtual interfaces (tun/tap devices).
#
# Try to bind to the first N interfaces
my $test_n_addrs = 2;
my @top_local_addrs;
foreach my $interface (Net::Interface->interfaces()) {
	last if @top_local_addrs == $test_n_addrs;
	next unless $interface->address;
	my $local_addr = Net::Interface::inet_ntoa($interface->address);
	# next if $local_addr eq '127.0.0.1';
	push @top_local_addrs, $local_addr;
}

# 4 tests per address:
#  - local_addr => "$addr"
#  - local_addr => "$addr:$myport"
#  - local_host => "$addr"
#  - local_host => "$addr:$myport"
plan tests => scalar(@top_local_addrs) * 4;

my $cv = AnyEvent->condvar;
$cv->begin( sub { $cv->send; } );

# XXX: Pick a random port and hope it is not being used.
my $get_random_port = sub {
  return 1024 + int(rand(65535));
};

foreach my $local_addr (@top_local_addrs) {

	# test local_addr without a specific port
	for my $key (qw(local_addr local_host)) {
		sendmail(
			# debug  => 1,
			host => '127.0.0.1',
			$key => $local_addr,
			port => $port,
			from => 'test@test.test',
			to   => 'tset@tset.tset',
			data => 'body',
			cv   => $cv,
			cb   => sub {
				like $_[1],
				  qr/^554 mail not allowed from ip=\Q$local_addr\E\b/,
				  "$key binds to $local_addr"
				  or diag "  Error: $_[1]";
			}
		);

		# test local_addr with a specific port
		my $local_port = $get_random_port->();
		sendmail(
			# debug  => 1,
			host => '127.0.0.1',
			$key => "$local_addr:$local_port",
			port => $port,
			from => 'test@test.test',
			to   => 'tset@tset.tset',
			data => 'body',
			cv   => $cv,
			cb   => sub {
				like $_[1],
				  qr/^554 mail not allowed from ip=\Q$local_addr:$local_port\E$/,
				  "$key binds to $local_addr:$local_port (specific host:port)"
				  or diag "  Error: $_[1]";
			}
		);
	}
}
$cv->end;
$cv->recv;

END {
	if ($child) {

		#warn "Killing child $child";
		$child and kill TERM => $child or warn "$!";
		waitpid( $child, 0 );
		exit 0;
	}
}

