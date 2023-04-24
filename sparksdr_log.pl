#!/usr/bin/env perl
# Script connects SparkSDR with cloudlog via Websocket
# a) sends each change of frequency and mode for each konfigured receiver to cloudlog
# b) sends every 10 Miutes a keepalive to cloudlog
# c) sends log entries, received via websocket from SparkSDR to cloudlog
# should be started via cronjob:
# @reboot /home/pi/xxx/SparkSDR_Log/sparksdr_log.pl & 
# or with some logging
# @reboot /home/pi/xxx/sparksdr_log.pl or >>/home/pi/xxx/sparksdr_log.log
# add the logfile to /etc/logrotate.d/rsyslog

use v5.014;
use warnings;
use Time::Piece;
my $version = "1.10";

# WebSocket source taken from:
# Perl WebSocket test client
#  Greg Kennedy 2019
# https://greg-kennedy.com/wordpress/2019/03/11/writing-a-websocket-client-in-perl-5/
# https://github.com/vti/protocol-websocket/blob/master/lib/Protocol/WebSocket/Frame.pm
# SparkSDR WebSocket API
# needs: sudo apt-get install libprotocol-websocket-perl
# Achtung (21.02.2023), lässt sich nach update/upgrade auf Buster nicht mehr finden, Hack:
# /usr/share/perl5/Protocol/WebSocket manuell kopieren
# needs: sudo apt-get install -y libio-socket-ssl-perl
# needs a change in Frame.pm, located in /usr/share/perl5/Protocol/WebSocket
# delete or comment lines 230-231: 
#            die "Too many fragments"
#             if @{$self->{fragments}} > $self->{max_fragments_amount};
# (
# enhance $MAX_FRAGMENTS_AMOUNT to ?? 16384 in line 14
# our $MAX_FRAGMENTS_AMOUNT = 16384;
# )
# needs: git clone https://github.com/vti/protocol-websocket (for newer version of Client.pm)
# located in /usr/share/perl5/Protocol/WebSocket
# has handshake, otherweise the process will terminate after 60s of inactivity
# valid Commands:
# {"cmd":"getRadios"}
# {"cmd":"getReceivers"}
# {"cmd":"getVersion"}
# valid responses
# {"cmd":"getRadiosResponse","Radios":[{"ID":0,"Name":"Hermes Lite 2 hpsdr_0-28-192-162-19-221","Running":false}]}
# {"cmd":"ReceiverResponse","ID":0,"Mode":"FT8","Frequency":24915000.0,"FilterLow":100.0,"FilterHigh":5000.0}
# {"cmd":"getVersionResponse","ProtocolVersion":"0.1.4","Host":"SparkSDR","HostVersion":"2.0.944.0"}
# {"cmd":"logResponse","qso":{"mode":"FT8","submode":"","call":"G3PXT","station_callsign":"DL3EL","qso_date":"20230217","time_on":"150645","comment":"","rst_sent":"+25","rst_received":"+02","band":"20m","gridsquare":"JO02PP","my_gridsquare":"JO40HD"}}
# unsupported Commands:
# {"cmd":"subscribeToSpots","Enable":true}
# {"cmd":"subscribeToSpots","Enable":false}
# {"cmd":"subscribeToAudio","RxID":0,"Enable":true}
# {"cmd":"subscribeToAudio","RxID":0,"Enable":false}
# {"cmd":"getRadiosResponse","Radios":[{"ID":0,"Name":"Hermes Lite 2 hpsdr_0-28-192-162-19-221","Running":false}]}

# IO::Socket::SSL lets us open encrypted (wss) connections
use IO::Socket::SSL;
# IO::Select to "peek" IO::Sockets for activity
use IO::Select;
# Protocol handler for WebSocket HTTP protocol
use Protocol::WebSocket::Client;
#make sure, that all output is printed
STDOUT->autoflush(1);

#############################################################
# globals
use constant GETRECEIVERS => 1;
use constant GETVERSION => 2;

my $verbose = 0;
my $debug = 0;
my @array;
my $entry;
my $ws_counter = 0;
my $ws_connect = 0;
my $cloudlogApiKeyWR = "";
my @cloudlogApiKey;
my $cloudlogApiKey_Radio = 0;
my $cloudlog_keepalive = 0;
my $cloudlog_keepalive_sec = 600;
my @station_profile_id;
my $idnn = 0;
my @station_callsign;
my $opnn = 0;
my $cloudlogRadioId;
my $cloudlogApiUrlLog = "";
my $cloudlogApiUrlFreq = "";
my $OpenHABurl="";
my $par;
my $websocketcall = "";
my $data = "";
my $getversion = "{\"cmd\":\"getVersion\"}";
my $getreceivers = "{\"cmd\":\"getReceivers\"}";
my $nn = 0;
my $cmd = "";
my $SparkSDRactive = 0;
my $SparkSDRactive_counter = 0;
my $SparkSDR_terminated = 0;
my $time_failed = "";
my $auto_reboot = 1;
my $tx = 1;
my $crontab_min = 0;
my $cw_beacon_next = 0;
my $cw_beacon_last = 0;
my $cw_beacon_waiting = 0;
my $init_done = 0;
my $power = 5;
my $cmd2send = "";

############################################################
# get total arg passed to this script
	# get script name
	my $scriptname = $0;
	my $file_path = ($scriptname =~ /(.*)\/([\w]+).pl/s)? $1 : "undef";
	$file_path = $file_path . "/";
	$scriptname = $2;

	my $tm = localtime(time);
	my $tm_epoc = time();
	my $tmrenew_epoc = $tm_epoc + $cloudlog_keepalive_sec;
	printf("SparkSDR Controller & Cloudlog Connector [v$version] Start: %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year);
# init
	
	# Use loop to print all args stored in an array called @ARGV
	my $total = $#ARGV + 1;
	my $counter = 1;
	foreach my $a(@ARGV) {
		print "Arg # $counter : $a\n" if ($verbose >= 7);
		$counter++;
		if (substr($a,0,2) eq "v=") {
			$verbose = substr($a,2,1);
			print "Debug On, Level: $verbose\n" if $verbose;
		}
	}
	print "Total args passed to $scriptname : $total \n" if $verbose;

## Bei Änderungen des Pfades bitte auch /etc/logrotate.d/rsyslog anpassen
	my $confdatei = $file_path . $scriptname . ".conf";
	open(INPUT, $confdatei) or die "Fehler bei Eingabedatei: $confdatei\n";
		undef $/;#	
		$data = <INPUT>;
	close INPUT;
	print "Datei $confdatei erfolgreich geöffnet\n" if $verbose;
	@array = split (/\n/, $data);
	$nn=0;
	$idnn = 1;
	$opnn = 1;

	$cloudlogApiKey_Radio = 1;
	foreach $entry (@array) {
		if ((substr($entry,0,1) ne "#") && (substr($entry,0,1) ne "")) {
			printf "%d [%s]\n",$nn,$entry if ($verbose >= 4);
			$par = ($entry =~ /([\w]+).*\=.*\"(.*)\"/s)? $2 : "undef";
			$cloudlogApiKeyWR = $par if ($1 eq "cloudlogApiKeyWR");
			$cloudlogApiKey[$cloudlogApiKey_Radio] = $par if ($1 eq "cloudlogApiKey");
			++$cloudlogApiKey_Radio if ($cloudlogApiKey[$cloudlogApiKey_Radio]);
			$cloudlogApiUrlLog = $par if ($1 eq "cloudlogApiUrlLog");
			$cloudlogApiUrlFreq = $par if ($1 eq "cloudlogApiUrlFreq");
			$cloudlogRadioId = $par if ($1 eq "cloudlogRadioId");			
			$websocketcall =  $par if ($1 eq "websocketcall");
			$station_profile_id[$idnn] = $par if ($1 eq "station_profile_id");
			++$idnn if ($station_profile_id[$idnn]);
			$station_callsign[$opnn] = $par if ($1 eq "station_callsign");
			++$opnn if ($station_callsign[$opnn]);
			$OpenHABurl = $par if ($1 eq "OpenHABurl");
			$debug = $par if ($1 eq "debug");
			$power = $par if ($1 eq "power");
		}
		++$nn;
	}
	$verbose = $debug if (!$verbose);
	$cloudlogApiKey[$cloudlogApiKey_Radio] = "";
	$station_callsign[$opnn] = "";
	$station_profile_id[$idnn] = 0;
	printf "Parameter Key: %s (total: %s) ID: %s URL: %s ws: %s Debug: %s\n",$cloudlogApiKey[1],$cloudlogApiKey_Radio,$station_profile_id[1],$cloudlogApiUrlLog,$websocketcall,$verbose if $verbose;	


	$nn = 1;
	printf "Valid Station Profiles: \n" if $verbose;
	while ($station_profile_id[$nn]) {
		printf " %s with Call %s\n",$station_profile_id[$nn],$station_callsign[$nn] if $verbose;
		++$nn;
	}
	printf "Radio running with %sw\n",$power;
eval {
	
#############################################################
# Protocol::WebSocket takes a full URL, but IO::Socket::* uses only a host
#  and port.  This regex section retrieves host/port from URL.
my ($proto, $host, $port, $path);
	if ($websocketcall =~ m/^(?:(?<proto>ws|wss):\/\/)?(?<host>[^\/:]+)(?::(?<port>\d+))?(?<path>\/.*)?$/) {
		$host = $+{host};
		$path = $+{path};

		if (defined $+{proto} && defined $+{port}) {
			$proto = $+{proto};
			$port = $+{port};
		} 
		elsif (defined $+{port}) {
			$port = $+{port};
			if ($port == 443) { $proto = 'wss' } else { $proto = 'ws' }
		} 
		elsif (defined $+{proto}) {
			$proto = $+{proto};
			if ($proto eq 'wss') { $port = 443 } else { $port = 80 }
		} 
		else {
			$proto = 'ws';
			$port = 80;
		}
	} 
	else {
		die "Failed to parse Host/Port from URL.";
		goto exit_script;
	}

	$SparkSDRactive = 0;
# return here, when socket died during operation (in while(1) below)
create_socket:
	say "Attempting to open SSL socket to $proto://$host:$port..." if ($verbose);
# create a connecting socket
#  SSL_startHandshake is dependent on the protocol: this lets us use one socket
#  to work with either SSL or non-SSL sockets.
my $tcp_socket = IO::Socket::SSL->new(
	PeerAddr => $host,
	PeerPort => "$proto($port)",
	Proto => 'tcp',
	SSL_startHandshake => ($proto eq 'wss' ? 1 : 0),
	Blocking => 1
	) 
	or do {
############################
	print "Failed to connect to socket: $@, now waiting 60s\n";
	$time_failed = localtime(time) if (!$SparkSDRactive_counter);
	if (!$SparkSDRactive) {
		check_reboot($SparkSDRactive_counter,2);
	}	
############################
	
	sleep 60;
	print "and try again...\n";
	goto create_socket;
	};


# create a websocket protocol handler
#  this doesn't actually "do" anything with the socket:
#  it just encodes / decode WebSocket messages.  We have to send them ourselves.
	say "Trying to create Protocol::WebSocket::Client handler for $websocketcall..." if ($verbose >= 4);
my $client = Protocol::WebSocket::Client->new(url => $websocketcall);
	$tm = localtime(time);
	printf("WebSocket Created: %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year) if $verbose;
	++$ws_connect;
#######################
#  Set up the various methods for the WS Protocol handler
#  On Write: take the buffer (WebSocket packet) and send it on the socket.
	$client->on(
		write => sub {
			my $client = shift;
			my ($buf) = @_;
			syswrite $tcp_socket, $buf;
			}
	);

# On Connect: this is what happens after the handshake succeeds, and we
#  are "connected" to the service.
	$client->on(
		connect => sub {
		my $client = shift;
# You may wish to set a global variable here (our $isConnected), or
#  just put your logic as I did here.  Or nothing at all :)
		$SparkSDRactive = 1;
		printf("Successfully connected SparkSDR: %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year);
		$auto_reboot = 1;
		}
	);

# On Error, print to console.  This can happen if the handshake
#  fails for whatever reason.
	$client->on(
		error => sub {
			my $client = shift;
			my ($buf) = @_;
# needs testing, if we can avoid the exit here
			say "ERROR ON WEBSOCKET: $buf";
			$tcp_socket->close;
			$tm = localtime(time);
			printf("SparkSDR WebSocket connection terminated finally: %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year) if $verbose;
			goto Create_socket;
		}
	);

# On Read: This method is called whenever a complete WebSocket "frame"
#  is successfully parsed.
# We will simply print the decoded packet to screen.  Depending on the service,
#  you may e.g. call decode_json($buf) or whatever.
	$client->on(
		read => sub {
			my $client = shift;
			my ($buf) = @_;

			$tm = localtime(time) if ($verbose);
			printf("Time: %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year) if ($verbose);
			say "Received from socket: '$buf'" if ($verbose  >= 4);
#### evaluate Buffer
# Received if version was requested
# {"cmd":"getVersionResponse","ProtocolVersion":"0.1.4","Host":"SparkSDR","HostVersion":"2.0.944.0"}

# Received if qrg is changed on a radio
# {"cmd":"ReceiverResponse","ID":0,"Mode":"FT8","Frequency":24915000.0,"FilterLow":100.0,"FilterHigh":5000.0}

# Received if log was updated
# {"cmd":"logResponse","qso":{"mode":"FT8","submode":"","call":"ta1est","station_callsign":"DL3EL","qso_date":"20230217","time_on":"082149","comment":"commentar","rst_sent":"12","rst_received":"-15","band":"40m","gridsquare":"JO40HD","my_gridsquare":"JO40HD"}}

# Received if reveiver info was requested
# {"cmd":"getReceiversResponse","Receivers":[{"cmd":"ReceiverResponse","ID":0,"Mode":"FT8","Frequency":7074000.0,"FilterLow":100.0,"FilterHigh":5000.0},{"cmd":"ReceiverResponse","ID":1,"Mode":"FT8","Frequency":3573000.0,"FilterLow":100.0,"FilterHigh":5000.0},{"cmd":"ReceiverResponse","ID":2,"Mode":"FT8","Frequency":10136000.0,"FilterLow":100.0,"FilterHigh":5000.0},{"cmd":"ReceiverResponse","ID":3,"Mode":"FT8","Frequency":14074000.0,"FilterLow":100.0,"FilterHigh":5000.0},{"cmd":"ReceiverResponse","ID":4,"Mode":"CW","Frequency":10102150.0,"FilterLow":-250.0,"FilterHigh":250.0},{"cmd":"ReceiverResponse","ID":5,"Mode":"WSPR","Frequency":7038600.0,"FilterLow":1360.0,"FilterHigh":1640.0},{"cmd":"ReceiverResponse","ID":6,"Mode":"WSPR","Frequency":3568600.0,"FilterLow":1360.0,"FilterHigh":1640.0},{"cmd":"ReceiverResponse","ID":7,"Mode":"WSPR","Frequency":10138700.0,"FilterLow":1360.0,"FilterHigh":1640.0},{"cmd":"ReceiverResponse","ID":8,"Mode":"WSPR","Frequency":14095600.0,"FilterLow":1360.0,"FilterHigh":1640.0},{"cmd":"ReceiverResponse","ID":9,"Mode":"FT4","Frequency":7047500.0,"FilterLow":100.0,"FilterHigh":5000.0},{"cmd":"ReceiverResponse","ID":10,"Mode":"FT4","Frequency":3576000.0,"FilterLow":100.0,"FilterHigh":5000.0},{"cmd":"ReceiverResponse","ID":11,"Mode":"FT4","Frequency":10140000.0,"FilterLow":100.0,"FilterHigh":5000.0},{"cmd":"ReceiverResponse","ID":12,"Mode":"FT4","Frequency":14080000.0,"FilterLow":100.0,"FilterHigh":5000.0}]}

			@array = split (/,/, $buf);
			my $item = $cmd = "";
			$entry = shift(@array);
			print "Entry: $entry\n" if ($verbose > 1);
			$item = ($entry =~ /\"([\w]+)\"\:\"(.*)\"/)? $2 : "undef";
			if ($item ne "undef") {
				$cmd = $item if ($1 eq "cmd");
				if ($cmd eq "logResponse") { sparksdr2cloudlog($buf); }
				elsif ($cmd eq "getVersionResponse") { getVersionResponse($buf); }
				elsif ($cmd eq "ReceiverResponse") { ReceiverResponse($buf); }
				elsif ($cmd eq "getReceiversResponse") { getReceiversResponse($buf); }
				elsif ($cmd eq "getRadiosResponse") { getRadiosResponse($buf); }
				else {(print "unsupported command: $cmd\n$buf\n"); }
			}
		}
	);

# Now that we've set all that up, call connect on $client.
#  This causes the Protocol object to create a handshake and write it
#  (using the on_write method we specified - which includes sysread $tcp_socket)

	$client->connect;

# read until handshake is complete.
	while (! $client->{hs}->is_done) {
		my $recv_data;
		my $bytes_read = sysread $tcp_socket, $recv_data, 16384;

		if (!defined $bytes_read) { 
		# DL3EL: never die
			$SparkSDRactive = 0;		
			$SparkSDRactive_counter = 0;
			$time_failed = localtime(time);
			print "sysread on tcp_socket failed: $!" ;
			goto create_socket;
		}
		elsif ($bytes_read == 0) { 
		#    die "Connection terminated." }
		# DL3EL: never die
			print "0 Byte received \n\n"; 
		}
		$client->read($recv_data);
	}

# Create a Socket Set for Select.
#  We can then test this in a loop to see if we should call read.
	my $set = IO::Select->new($tcp_socket, \*STDIN);
# after a connection has been established, first check the version, has to be 2.0.946 at minimum
# thereafter get frequency and mode for alle configured receivers
# see https://perldoc.perl.org/IO::Select re timeout, should be implemented
	$cmd2send = GETVERSION;

	while (1) {
		$tm = localtime(time) if ($verbose >= 2);
		printf("Time: %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year) if ($verbose  >= 4);
		say "Checkpoint 3 WS_keepalive $ws_counter WS_Connect: $ws_connect" if ($verbose  >= 4);
		++$ws_counter;
		if ($cmd2send == GETVERSION) {
			say "sending $getversion ..." if ($verbose >= 4);
			$client->write($getversion);
			$cmd2send = 0;
		}  
		if ($cmd2send == GETRECEIVERS) {
			say "sending $getreceivers ..." if ($verbose >= 4);
			$client->write($getreceivers);
			$cmd2send = 0;
		}  
		# call select and see who's got data
		my ($ready) = IO::Select->select($set);

		foreach my $ready_socket (@$ready) {
		# read data from ready socket
			my $recv_data;
			my $bytes_read = sysread $ready_socket, $recv_data, 16384;

			# handler by socket type
			if ($ready_socket == \*STDIN) {
			# Input from user (keyboard, cat, etc)
				if (!defined $bytes_read) { die "Error reading from STDIN: $!" }
				elsif ($bytes_read == 0) {
				# STDIN closed (ctrl+D or EOF)
					say "Connection terminated by user, sending disconnect to remote.";
					$client->disconnect;
					$tcp_socket->close;
					$tm = localtime(time);
					printf("SparkSDR WebSocket connection terminated finally: %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year) if $verbose;
					exit;
				} 
				else {
					chomp $recv_data;
					$client->write($recv_data);
				}
			} 
			else {
			# Input arrived from remote WebSocket!
				if (!defined $bytes_read) {
					print "Error reading from tcp_socket: $!";
					goto exit_script;
				}
				elsif ($bytes_read == 0) {
				# Remote socket closed
					say "Connection terminated by remote.";
					print "0 Byte received Start again\n\n";
					$SparkSDRactive = 0;
					sleep 15;
					goto create_socket;
				} 
				else {
				# unpack response - this triggers any handler if a complete packet is read.
					$client->read($recv_data);
				}
			}
		}
# check Cloudlog keepalive & send send radio data every 10min
		$tm_epoc = time();
		if ($tm_epoc > $tmrenew_epoc) {
			$tmrenew_epoc = $tm_epoc + 600;
			# trgger getreceivers every 10 minutes
			$cmd2send = GETRECEIVERS;
			$cloudlog_keepalive = 1;
			$tm = localtime(time);
			printf("Cloudlog Keepalive: %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year);
		}
	}
};	

## End of Wecksocket routine
print "Folgender Fehler ist aufgetreten: $@\n" if($@);
exit_script:
	$tm = localtime(time);
	printf("SparkSDR_ctrl [v$version] exits @ %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year);
#################### routines which use the data received via Websocket

sub sparksdr2cloudlog {
my @array;
my @qso_array;
my %QSOtab;
my $station_callsign = "";
my $station_profile_id = "";
my $entry;
my $item;
my $tag;
my $qso = 0;
my $ii;

my $raw_logentry = $_[0]; 
# {"cmd":"logResponse","qso":{"mode":"FT8","submode":"","call":"G3PXT","station_callsign":"DL3EL","qso_date":"20230217","time_on":"150645","comment":"","rst_sent":"+25","rst_received":"+02","band":"20m","gridsquare":"JO02PP","my_gridsquare":"JO40HD"}}

	print "work on $raw_logentry\n" if $verbose;

	@array = split (/qso\"\:/, $raw_logentry);
	$entry = shift(@array);
	$entry = shift(@array);
	print "$entry\n" if $verbose;

	@qso_array = split (/{|,\"|}/, $entry);
	$ii = 0;
	%QSOtab = ();
	foreach $item (@qso_array) {
		$item = trim_quote($item);
		printf "item %s [$item]\n",$ii if ($verbose);

		$tag = ($item =~ /([\w]+)\:(.*)/)? $1 : "undef";
# Workaround, löschen sobald in SparkSDR gefixt			
		$tag = "rst_rcvd" if ($tag eq "rst_received"); # typo in SparkSDR, remove, if solved
# Workaround, löschen sobald in SparkSDR gefixt			
		if (($tag ne "undef") && ($tag ne "") && (length($2))) {
			push @{$QSOtab{$tag}}, length($2);
			push @{$QSOtab{$tag}}, $2; # substr($3,0,$2);
			push @{$QSOtab{$tag}}, 1;
			printf "Nr: %s, Tag: %s, Länge: %s, Inhalt: %s\n",$ii,$tag,length($2),$2 if ($verbose);
			++$ii;
		}
	}	
##### return here, if not enough data for log entry	
	if (!$QSOtab{'call'}[2] || (!$QSOtab{'freq'}[2] && !$QSOtab{'band'}[2])  || !$QSOtab{'rst_sent'}[2]) {
		print "Error QSO not accepted (Call || Freq/Band || RST missing)\n";
		return (-1);
	}
# HL2 has max 5w without PA, change in config if necessary
	if (not exists($QSOtab{'tx_pwr'})) {
		$QSOtab{'tx_pwr'}[0] = length($power);
		$QSOtab{'tx_pwr'}[1] = $power;
		$QSOtab{'tx_pwr'}[2] = 1;
		++$ii;
	}	
# HL2 has max 5w without PA, change in config if necessary

	$nn = 1;
	if (exists($QSOtab{'station_callsign'})) {
		while ($station_profile_id[$nn]) {
			if ($station_callsign[$nn] eq $QSOtab{'station_callsign'}[1]) {
				$station_profile_id = $station_profile_id[$nn];
				$station_callsign = $station_callsign[$nn];
				print "Profil found $station_callsign with $station_profile_id\n";
				last;
			}
			else {
				++$nn;
			}
		}			
	}

my $apistring_fix = sprintf("{\\\"key\\\":\\\"%s\\\",\\\"station_profile_id\\\":\\\"%s\\\",\\\"type\\\":\\\"adif\\\",\\\"string\\\":\\\"",$cloudlogApiKeyWR,$station_profile_id);
my $apistring_var = "";
my $apicall = "";

	$nn=0;
	for my $tag (sort keys %QSOtab) {
		if ($QSOtab{$tag}[2]) {
			++$nn;
			$apistring_var = $apistring_var . sprintf("<$tag:$QSOtab{$tag}[0]>$QSOtab{$tag}[1]");
		}	
	}
	if ($ii != $nn) {
		print "$QSOtab{'CALL'}[1] CHECK ITEMS! ($ii/$nn) \n" if $verbose;
	}	

	$apistring_fix = $apistring_fix . $apistring_var . "<EOR>\\\"}";
	$tm = localtime(time);
	if ($station_profile_id) {
		send_info_to_cloudlog($apistring_fix,$cloudlogApiUrlLog);
		printf "$apistring_var sent to Cloudlog @ %02d:%02d:%02d am %02d.%02d.%04d\n",$tm->hour, $tm->min, $tm->sec, $tm->mday, $tm->mon,$tm->year;
	}
	else {
		print "Error $apistring_fix,$cloudlogApiUrlLog not sent to Cloudlog (Check Station_ID)\n";
	}		
}  

sub getVersionResponse {
# Received if version was requested
# {"cmd":"getVersionResponse","ProtocolVersion":"0.1.4","Host":"SparkSDR","HostVersion":"2.0.944.0"}
my @array;
my $entry;
my $item = "";
my $version = "";
my $host = "";

	print "initializing SparkSDR Contoller\n" if !$init_done;
	print "start getVersionResponse\n" if $verbose;
	@array = split (/,|}/, $_[0]);
	foreach $entry (@array) {
		print "Entry: $entry\n" if ($verbose > 3);
		$item = ($entry =~ /\"([\w]+)\"\:\"(.*)\"/)? $2 : "undef";
		if (($item ne "undef") && ($2 ne "undef")) {		
			$item = $2;
			print "use [$1:$item]\n" if ($verbose > 3);
			$host = $item if ($1 eq "Host");
			$version = $item if ($1 eq "HostVersion");
		}	
	}
	printf "%s with %s\n",$host,$version;
# at script start first the version is  read (Logdata are only send if version is >=2.0.946.0
# after that, initially all frequency and modes are collected
	$cmd2send = GETRECEIVERS;
}	

sub ReceiverResponse {
# Received if qrg is changed on a radio
# {"cmd":"ReceiverResponse","ID":0,"Mode":"FT8","Frequency":24915000.0,"FilterLow":100.0,"FilterHigh":5000.0}
my @array;
my %fieldtab;
my $entry;
my $item = "";
my $cmd = "";
my $radioid = "";
my $mode = "";
my $frequency = "";
my $qso = 0;
my $httprequest = "";
my $tag;
my $ii;
	
	print "start ReceiverResponse\n" if ($verbose > 1);
	printf "Response: %s\n",$_[0] if ($verbose  >= 3);
	
	return if !$SparkSDRactive;
	
	@array = split (/,|}/, $_[0]);
	$ii = 0;
	foreach $entry (@array) {
		printf "Nr: %s, Entry: %s\n",$ii,$entry if ($verbose  >= 3);
		$item = ($entry =~ /\"([\w]+)\"\:[\"]*(.*)[\"]*/)? $1 : "undef";
		$item = trim_quote($item);
		if ($item ne "undef") {
			push @{$fieldtab{$item}}, trim_quote($2);
			printf "Nr: %s, Item: %s, Inhalt: %s\n",$ii,$item,$fieldtab{$item}[0] if ($verbose  >= 3);
			++$ii;
		}
	}	
	if (exists($fieldtab{"Frequency"})) {
		$fieldtab{"Frequency"}[0] =~ s/([\d]+).0/$1/ ;
		$frequency = $fieldtab{"Frequency"}[0];
	}	
	$radioid = $fieldtab{"ID"}[0] + 1 if (exists($fieldtab{"ID"})) ;
	$mode = $fieldtab{"Mode"}[0] if (exists($fieldtab{"Mode"})) ;

	if ($radioid < $cloudlogApiKey_Radio) {
		printf "Radio %s on %s in %s\n",$radioid,$frequency,$mode if (!$cloudlog_keepalive && ($init_done));
		printf "start send_info_to_cloudlog / OpenHAB for radio $radioid (max is %s)\n",$cloudlogApiKey_Radio-1 if ($verbose > 1);
# send info to OpenHAB, if configured
		if ($OpenHABurl ne "") {
			$httprequest = sprintf("curl --silent --insecure %s%d=%s%%20%s",$OpenHABurl,$radioid,$frequency,$mode);
			print "[$httprequest]\n" if ($verbose > 1);
			`$httprequest`;
		}	
# send info to Cloudlog
		my $rigID = $cloudlogRadioId . $radioid;
		my $apistring_fix = sprintf("{\\\"key\\\":\\\"%s\\\",\\\"radio\\\":\\\"%s\\\",\\\"frequency\\\":\\\"%s\\\",\\\"mode\\\":\\\"%s\\\"}",$cloudlogApiKey[$radioid],$rigID,$frequency,$mode);
		send_info_to_cloudlog($apistring_fix,$cloudlogApiUrlFreq);
	}
	else {
		printf "nothing sent, ReceiverID to high (%s > %s)\n",$radioid,$cloudlogApiKey_Radio-1 if ($verbose > 1);
	}
}

sub send_info_to_cloudlog {
my $apistring_fix = $_[0];
my $cloudlogApiUrlLog = $_[1];
my $apicall;
	
	$apicall = sprintf("curl --silent --insecure --header \"Content-Type: application/json\" --request POST --data \"%s\" %s >/dev/null 2>&1\n",$apistring_fix,$cloudlogApiUrlLog);
	if (!$SparkSDRactive) {
		print "SparkSDR not available, send data manually:\n";
		print $apicall;
	}
	else {	
		print $apicall if ($verbose > 1);
		`$apicall`;
	}	
}

sub getReceiversResponse {
my @array;
my $entry;
my $nn = 0;
	print "start getReceiversResponse\n" if ($verbose > 1);
	printf "Receivers: %s\n",$_[0] if ($verbose > 1);

	@array = split (/:\[|\]}/, $_[0]);
	$entry = shift(@array);
	print "$nn: $entry \n" if ($verbose > 3);
	++$nn;
	$entry = shift(@array);
	print "$nn: $entry \n" if ($verbose > 3);
	@array = split (/}/, $entry);
	$nn = 0;
	foreach $entry (@array) {
		printf "$nn [%s}]\n",substr($entry,1,length($entry)-1) if ($verbose > 3);
		ReceiverResponse(substr($entry,1,length($entry)-1));
		++$nn;
	}	
	$cloudlog_keepalive = 0 if $cloudlog_keepalive;
	if (!$init_done) {
		print "SparkSDR Cloudlog Connector [v$version] Init done, running\n";
		$init_done = 1;
	}	
}	

sub getRadiosResponse {
# Received if radio was shutdown
# {"cmd":"getRadiosResponse","Radios":[{"ID":0,"Name":"Hermes Lite 2 hpsdr_0-28-192-162-19-221","Running":false}]}
my @array;
my $entry;
my $item = "";
my $state = "";
my $radio = "";

	print "start getRadiosResponse\n" if ($verbose > 1);
	@array = split (/:\[|,|}/, $_[0]);
	foreach $entry (@array) {
		print "Entry: $entry\n" if ($verbose > 0);
		$item = ($entry =~ /\"([\w]+)\"\:[\"]*(.*)[\"]*/)? $1 : "undef";
		if (($item ne "undef") && ($2 ne "undef")) {		
			$item = $2;
			print "use [$1:$item]\n" if ($verbose > 3);
			$radio = $item if ($1 eq "Name");
			$state = $item if ($1 eq "Running");
		}	
	}
	printf "%s with state running:%s, SparkSDR ",$radio,$state;
	if ($state eq "true") {
		$SparkSDRactive = 1;
		print "online\n";
	}
	else {
		$SparkSDRactive = 0;	
		print "offline\n";
		$time_failed = localtime(time);
	}	
}	

sub trim_quote {
	my $string = $_[0];
	$string = shift;
	$string =~ s/\"//g;
	return $string;
}

