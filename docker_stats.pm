#!/usr/bin/perl

package Collectd::Plugins::docker_stats;

use strict;
use warnings;

use Collectd qw( :all );

use WWW::Curl::Easy;
use JSON;

# debug
use Data::Dumper;

my $CONFIG = {};
my $CONTAINERS = {};
my $DOCKER_UNIX_SOCKET = '/var/run/docker.sock';
my $DATA = {};
my $API_VERSION;
my $PLUGIN_NAME = 'docker_stats';
my $CURL;
my $API_DOWN = 0;
my $CGROUP_BASE = '/sys/fs/cgroup';

# search for hash with key "$key" among the children of the given ref
# optionally takes a value, in which case only the key(s) with that value
# is selected
sub get_key {

  my ($key, $ref, $value) = (shift, shift, shift);    # string, array ref, string (optional)

  # array of hash references (usually one element)
  my @results = grep { lc($_->{'key'}) eq lc($key) } @{$ref->{'children'}};

  if (defined($value)) {
    @results = grep { $_->{'values'}->[0] eq $value } @results;
  }

  return @results;
}

sub init_func {
  plugin_log(LOG_INFO, "$PLUGIN_NAME: init function");    
  get_api_version() or $API_VERSION = '1.24';    # improve this
  plugin_log(LOG_INFO, "$PLUGIN_NAME: supported API version is $API_VERSION");
}

sub do_curl {

  my ($path) = @_;

  my $body;

  $CURL->setopt(CURLOPT_URL, "http://v${API_VERSION}${path}");
  $CURL->setopt(CURLOPT_UNIX_SOCKET_PATH, $CONFIG->{'docker_unix_socket'});
  $CURL->setopt(CURLOPT_WRITEDATA, \$body);
 
  my $ret = $CURL->perform();

  my ($code, $json);
  $code = $CURL->getinfo(CURLINFO_HTTP_CODE);

  if ($ret == 0) {
    $json = decode_json($body);
  } else {
    # error code, type of error, error message
    $API_DOWN = 1;
    die ((caller(0))[3] . ": error connecting to the API: " . $CURL->strerror($ret) . ", code: $code, err: " . $CURL->errbuf . " ($ret)");
  }

  return ($json);

}

sub get_api_version {
  $API_VERSION = '1.12';
  my $json = do_curl('/version');
  my ($engine) = grep { $_->{'Name'} eq 'Engine' } @{$json->{'Components'}};
  $API_VERSION = $engine->{'Details'}->{'ApiVersion'};
}

sub get_container_pid {
  my $id = shift;
  my $json = do_curl("/containers/${id}/json");
  my $pid = $json->{'State'}->{'Pid'};
  return $pid;
}

sub get_containers {

  my $C = {};

  my $json;

  eval { $json = do_curl("/containers/json?$CONFIG->{'size_url'}&filters={\"status\":[\"running\"]}") };

  if ($API_DOWN != 0) {
    $CONTAINERS = {};
    if ($@) {
      die $@;
    } else {
      return;
    } 
  }

  for my $container (@{$json}) {
    my $id = $container->{'Id'};
    my $names = $container->{'Names'};
    (my $name = $names->[0]) =~ s|^/||;
    $C->{$name}->{'id'} = $id;

    # don't call the api to get the pid if cached
    if ( (not exists $CONTAINERS->{$name}->{'pid'}) || ($CONTAINERS->{$name}->{'id'} ne $id)) {
      my $pid = get_container_pid($id);
      $C->{$name}->{'pid'} = $pid;
    } else {
      $C->{$name}->{'pid'} = $CONTAINERS->{$name}->{'pid'};
    }

    if ($CONFIG->{'size_wanted'} == 1) {
      for my $type ('SizeRootFs', 'SizeRw') {
	# apparently, SizeRw is missing until it has a value or something like that
        $C->{$name}->{'size_stats'}->{$type} = ($container->{$type} ? $container->{$type} : 0 );
      }
    }
  }

  $CONTAINERS = $C;
}

#$VAR1 = {
#	 'values' => ['docker_stats'],
#	 'children' => [
#		        {'key' => 'SizeStats',
#			 'children' => [],
#			 'values' => ['True']
#		        }
#		       ],
#	 'key' => 'Plugin'};


sub config_func {

  my $config = shift;

  #$Data::Dumper::Indent = 0;
  #plugin_log(LOG_INFO, Dumper($config));  

  plugin_log(LOG_INFO, "$PLUGIN_NAME: configuration");

  $CONFIG->{'size_wanted'} = 0;
  $CONFIG->{'size_url'} = "size=false";
  my $size_stats = (get_key('SizeStats', $config))[0];

  if ($size_stats) {
    if ($size_stats->{'values'}->[0] =~ /^(1|[Tt]rue|[Oo]n)$/) {
      $CONFIG->{'size_wanted'} = 1;
    }
  }

  if ($CONFIG->{'size_wanted'}) {
    plugin_log(LOG_INFO, "$PLUGIN_NAME: including container size stats");
    $CONFIG->{'size_url'} = "size=true";
  }

  $CONFIG->{'cgroup_base'} = $CGROUP_BASE;
  my $cgroup_base = (get_key('CgroupBase', $config))[0];
  if ($cgroup_base) {
    $CONFIG->{'cgroup_base'} = $cgroup_base->{'values'}->[0];
  }

  if (! -d $CONFIG->{'cgroup_base'}) {
    plugin_log(LOG_ERR, "$PLUGIN_NAME: cgroup base dir $CONFIG->{'cgroup_base'} not found!");
    exit 1;
  } else {
    plugin_log(LOG_INFO, "$PLUGIN_NAME: cgroup base dir is at $CONFIG->{'cgroup_base'}");
  }

  $CONFIG->{'docker_unix_socket'} = $DOCKER_UNIX_SOCKET;
  my $docker_unix_socket = (get_key('DockerUnixSocket', $config))[0];
  if ($docker_unix_socket) {
    $CONFIG->{'docker_unix_socket'} = $docker_unix_socket->{'values'}->[0];
  }

  if (! -S $CONFIG->{'docker_unix_socket'}) {
    plugin_log(LOG_ERR, "$PLUGIN_NAME: docker unix socket at $CONFIG->{'docker_unix_socket'} not found!");
    exit 1;
  } else {
    plugin_log(LOG_INFO, "$PLUGIN_NAME: docker unix socket is at $CONFIG->{'docker_unix_socket'}");
  }

  $CURL = WWW::Curl::Easy->new();
}

sub slurp_file {
  my $file = shift;
  my @lines;
  open(FH, $file) or die ((caller(0))[3] . ": Error opening file $file");
  @lines = <FH>;
  close(FH);
  return @lines;
}


sub get_mem_stats_from_files {

  my $id = shift;

  my $memory_stats;
  my @lines;

  @lines = slurp_file("$CONFIG->{'cgroup_base'}/memory/docker/$id/memory.stat");
  for (@lines) {
    my ($key, $value) = split / +/;
    chomp ($memory_stats->{'stats'}->{$key} = $value);
  }

  @lines = slurp_file("$CONFIG->{'cgroup_base'}/memory/docker/$id/memory.usage_in_bytes");
  chomp ($memory_stats->{'usage'} = $lines[0]);

  @lines = slurp_file("$CONFIG->{'cgroup_base'}/memory/docker/$id/memory.max_usage_in_bytes");
  chomp ($memory_stats->{'max_usage'} = $lines[0]);

  @lines = slurp_file("$CONFIG->{'cgroup_base'}/memory/docker/$id/memory.limit_in_bytes");
  chomp ($memory_stats->{'limit'} = $lines[0]);

  if ($memory_stats->{'limit'} > (1024 * 1024 * 1024 * 1024)) {
    # no limit set, use host's memlimit from /proc/meminfo
    @lines = slurp_file("/proc/meminfo");
    $memory_stats->{'limit'} = (split " ", $lines[0])[1] * 1024;
  }

  return ($memory_stats);
}

sub get_net_stats_from_files {

  my $pid = shift;

  my $net_stats = {};
  my @lines;

  @lines = slurp_file("/proc/$pid/net/dev");

  for (@lines[2..$#lines]) {
    my @line = split(" ");

    (my $ifname = $line[0]) =~ s/://;

    next if ($ifname eq "lo");

    $net_stats->{$ifname}->{rx_bytes} = $line[1];
    $net_stats->{$ifname}->{rx_packets} = $line[2];
    $net_stats->{$ifname}->{rx_errors} = $line[3];
    $net_stats->{$ifname}->{rx_dropped} = $line[4];
    #$net_stats->{$ifname}->{rxfifo} = $line[5];
    #$net_stats->{$ifname}->{rxframe} = $line[6];
    #$net_stats->{$ifname}->{rxcompressed} = $line[7];
    #$net_stats->{$ifname}->{rxmulticast} = $line[8];
    $net_stats->{$ifname}->{tx_bytes} = $line[9];
    $net_stats->{$ifname}->{tx_packets} = $line[10];
    $net_stats->{$ifname}->{tx_errors} = $line[11];
    $net_stats->{$ifname}->{tx_dropped} = $line[12];
    #$net_stats->{$ifname}->{txfifo} = $line[13];
    #$net_stats->{$ifname}->{txcolls} = $line[14];
    #$net_stats->{$ifname}->{txcarrier} = $line[15];
    #$net_stats->{$ifname}->{txcompressed} = $line[16];
  }

  return ($net_stats);
}


sub get_cpu_stats_from_files {

  my $id = shift;

  my $cpu_stats = {};
  my $line;
  my @lines;

  @lines = slurp_file("$CONFIG->{'cgroup_base'}/cpu/docker/$id/cpu.stat");
  chomp ($line = $lines[0]);
  $cpu_stats->{'throttling_data'}->{'periods'} = (split " ", $line)[1];
  chomp ($line = $lines[1]);
  $cpu_stats->{'throttling_data'}->{'throttled_periods'} = (split " ", $line)[1];
  chomp ($line = $lines[2]);
  $cpu_stats->{'throttling_data'}->{'throttled_time'} = (split " ", $line)[1];

  @lines = slurp_file("$CONFIG->{'cgroup_base'}/cpuacct/docker/$id/cpuacct.stat");
  chomp ($line = $lines[0]);
  $cpu_stats->{'cpu_usage'}->{'usage_in_usermode'} = (split " ", $line)[1] * 10000000;
  chomp ($line = $lines[1]);
  $cpu_stats->{'cpu_usage'}->{'usage_in_kernelmode'} = (split " ", $line)[1] * 10000000;


  @lines = slurp_file("/proc/stat");
  chomp ($line = $lines[0]);
  my @f = split " ", $line;
  $cpu_stats->{'system_cpu_usage'} = ($f[1] + $f[2] + $f[3] + $f[4] + $f[5] + $f[6] + $f[7]) * 10000000;

  @lines = slurp_file("$CONFIG->{'cgroup_base'}/cpuacct/docker/$id/cpuacct.usage");
  chomp ($line = $lines[0]);
  $cpu_stats->{'cpu_usage'}->{'total_usage'} = $line;
 
  @lines = slurp_file("$CONFIG->{'cgroup_base'}/cpuacct/docker/$id/cpuacct.usage_percpu");
  chomp ($line = $lines[0]);
  push @{$cpu_stats->{'cpu_usage'}->{'percpu_usage'}}, (split " ", $line);

  # TODO is this correct?
  $cpu_stats->{'online_cpus'} = scalar @{$cpu_stats->{'cpu_usage'}->{'percpu_usage'}}; 

  # $Data::Dumper::Indent = 0;
  # plugin_log(LOG_INFO, "$PLUGIN_NAME, cpu_stats: " . Dumper($cpu_stats));

  return ($cpu_stats);
}

sub get_blkio_stats_from_files {

  my $id = shift;

  my $blkio_stats = {};
  my $line;
  my @lines;

  my @files = ( 'io_service_bytes_recursive',
                'io_serviced_recursive',
                'io_queued_recursive',
                'io_service_time_recursive',
                'io_wait_time_recursive',
                'io_merged_recursive' );

  for my $file (@files) {
    @lines = slurp_file("$CONFIG->{'cgroup_base'}/blkio/docker/$id/blkio.$file");
    for $line (@lines) {
      if($line =~ /^(\d+):(\d+) (\S+) (\d+)$/){
        push @{$blkio_stats->{'cfq'}->{$file}}, { 'major' => $1, 'minor' => $2, 'op' => $3, 'value' => $4 };
      }
    }
  }

  # files without "op"
  @files = ( 'time_recursive',  
             'sectors_recursive' );

  for my $file (@files) {
    @lines = slurp_file("$CONFIG->{'cgroup_base'}/blkio/docker/$id/blkio.$file");
    for $line (@lines) {
      if($line =~ /^(\d+):(\d+) (\d+)$/){
        push @{$blkio_stats->{'cfq'}->{$file}}, { 'major' => $1, 'minor' => $2, 'value' => $3 };
      }
    }
  }

  # throttle files
  @files = ( 'io_service_bytes',
             'io_serviced' );

  for my $file (@files) {
    @lines = slurp_file("$CONFIG->{'cgroup_base'}/blkio/docker/$id/blkio.throttle.$file");
    for $line (@lines) {
      if($line =~ /^(\d+):(\d+) (\S+) (\d+)$/){
        push @{$blkio_stats->{'throttle'}->{$file}}, { 'major' => $1, 'minor' => $2, 'op' => $3, 'value' => $4 };
      }
    }
  }

  return ($blkio_stats);
}


sub do_read {

  my $container = shift;

  my ($id, $pid) = ($CONTAINERS->{$container}->{'id'}, $CONTAINERS->{$container}->{'pid'});

  $DATA->{$container}->{'memory_stats'} = get_mem_stats_from_files($id);
  $DATA->{$container}->{'network'} = get_net_stats_from_files($pid);
  $DATA->{$container}->{'cpu_stats'} = get_cpu_stats_from_files($id);
  $DATA->{$container}->{'blkio_stats'} = get_blkio_stats_from_files($id);
}



sub read_func {

  eval { get_containers() };
  if ($@) {
    chomp $@;
    plugin_log(LOG_WARNING, "$PLUGIN_NAME: error getting containers: $@. Not doing anything in this iteration.");
  }
  if ($API_DOWN || $@) {
    # do nothing
    return 1;
  }
 
  my $v = {
    interval => plugin_get_interval()
  };

  for my $container (keys %{$CONTAINERS}) {

    eval { do_read($container) };

    if ($@) {
      chomp $@;
      plugin_log(LOG_WARNING, "$PLUGIN_NAME: error reading data for container $container: $@. Skipping container");
      next;
    }

    if ($CONFIG->{'size_wanted'} == 1) {
      $v->{'plugin'} = "${PLUGIN_NAME}_size";
      $v->{'type'} = "counter";
      $v->{'plugin_instance'} = $container;

      for my $type ('SizeRootFs', 'SizeRw') {
        $v->{'type_instance'} = $type;
        $v->{'values'} = [ $CONTAINERS->{$container}->{'size_stats'}->{$type} ];
        plugin_dispatch_values($v);
      }
    }

    ######## net

    my $network = $DATA->{$container}->{'network'};

    $v->{'plugin'} = "${PLUGIN_NAME}_net";
    for my $net (keys %{$network}) {
      $v->{'type'} = "network.usage";
      $v->{'plugin_instance'} = $container;
      $v->{'type_instance'} = $net;
      $v->{'values'} = [ $network->{$net}->{'rx_bytes'},
                         $network->{$net}->{'rx_dropped'},
                         $network->{$net}->{'rx_errors'},
                         $network->{$net}->{'rx_packets'},
                         $network->{$net}->{'tx_bytes'},
                         $network->{$net}->{'tx_dropped'},
                         $network->{$net}->{'tx_errors'},
                         $network->{$net}->{'tx_packets'} ];

      plugin_dispatch_values($v);
    }

    ######## memory

    my $memory_stats = $DATA->{$container}->{'memory_stats'};

    $v->{'plugin'} = "${PLUGIN_NAME}_memory";

    for my $type_instance ('usage', 'max_usage', 'limit') {
      $v->{'type'} = "gauge";
      $v->{plugin_instance} = $container;
      $v->{type_instance} = $type_instance;
      $v->{values} = [ $memory_stats->{$type_instance} ];
      plugin_dispatch_values($v);
    }

    # "docker stats"-style memory usage
    # per https://github.com/moby/moby/issues/10824
    $v->{'type'} = "gauge";
    $v->{plugin_instance} = $container;
    $v->{type_instance} = 'usage_stats';
    $v->{values} = [ $memory_stats->{'usage'} - $memory_stats->{'stats'}->{'cache'} ];
    plugin_dispatch_values($v);

    ######## blkio
    my $blkio_stats = $DATA->{$container}->{'blkio_stats'};

    my %oper = ();

    # throttle
    for my $blkio_stat (keys %{$blkio_stats->{'throttle'}}) {    # io_serviced, io_service_bytes
      for my $elem (@{$blkio_stats->{'throttle'}->{$blkio_stat}}) {
        $oper{"$elem->{'major'}_$elem->{'minor'}"}->{$blkio_stat}->{$elem->{'op'}} = $elem->{'value'};
      }
    }

    for my $device (keys %oper) {

      for my $op ('Read', 'Write', 'Sync', 'Async', 'Total') {

        $v->{'plugin'} = "${PLUGIN_NAME}_blkio_throttle_${op}";
        $v->{'type'} = "blkio.throttle";
        $v->{plugin_instance} = $container;
        $v->{type_instance} = "${device}";
        $v->{values} = [ $oper{$device}->{'io_serviced'}->{$op},
                         $oper{$device}->{'io_service_bytes'}->{$op} ];
        plugin_dispatch_values($v);
      }
    }

    # cfq
    for my $blkio_stat (keys %{$blkio_stats->{'cfq'}}) {
      #plugin_log(LOG_INFO, $blkio_stat);
      if ($blkio_stat =~ /^(?:time_|sectors_)/) {
        # these don't have an "op" field
        for my $elem (@{$blkio_stats->{'cfq'}->{$blkio_stat}}) {
          $oper{"$elem->{'major'}_$elem->{'minor'}"}->{$blkio_stat} = $elem->{'value'};
        }
      } else {
        for my $elem (@{$blkio_stats->{'cfq'}->{$blkio_stat}}) {
          $oper{"$elem->{'major'}_$elem->{'minor'}"}->{$blkio_stat}->{$elem->{'op'}} = $elem->{'value'};
        }
      }
    }

    for my $device (keys %oper) {
      for my $op ('Read', 'Write', 'Sync', 'Async', 'Total') {
        $v->{'plugin'} = "${PLUGIN_NAME}_blkio_cfq_${op}";
        $v->{'type'} = "blkio.cfq";
        $v->{'plugin_instance'} = $container;
        $v->{'type_instance'} = "${device}";

        $v->{'values'} = [ $oper{$device}->{'io_service_bytes_recursive'}->{$op},
                           $oper{$device}->{'io_serviced_recursive'}->{$op},
                           $oper{$device}->{'io_queued_recursive'}->{$op},
                           $oper{$device}->{'io_service_time_recursive'}->{$op},
                           $oper{$device}->{'io_wait_time_recursive'}->{$op},
                           $oper{$device}->{'io_merged_recursive'}->{$op},
                         ];
        plugin_dispatch_values($v);
      }

      # entries without "operation"
      $v->{'plugin'} = "${PLUGIN_NAME}_blkio_cfq_time_sectors";
      $v->{'type'} = "blkio.cfq_time_sectors";
      $v->{'plugin_instance'} = $container;
      $v->{'type_instance'} = "${device}";

      $v->{'values'} = [ $oper{$device}->{'time_recursive'},
                         $oper{$device}->{'sectors_recursive'},
                       ];
      plugin_dispatch_values($v);
    }
 
    ######## cpu

    my $cpu_stats = $DATA->{$container}->{'cpu_stats'};

    $v->{'plugin'} = "${PLUGIN_NAME}_cpu_throttling";
    $v->{'type'} = "cpu.throttling_data";
    $v->{plugin_instance} = $container;
    $v->{type_instance} = 'throttling_data';
    $v->{values} = [ $cpu_stats->{'throttling_data'}->{'periods'}, $cpu_stats->{'throttling_data'}->{'throttled_periods'}, $cpu_stats->{'throttling_data'}->{'throttled_time'} ];
    plugin_dispatch_values($v);

    # the precpu part is not read from stats; 
    # it's just the values from the previous collectd dispatch
    # less accurate but lighter for the system

    if (exists $DATA->{$container}->{'precpu_stats'}) {

      my $cpu_percent = 0;

      my $precpu_stats = $DATA->{$container}->{'precpu_stats'};	   

      my $cpu_usage = $cpu_stats->{'cpu_usage'}->{'total_usage'};
      my $pre_cpu_usage = $precpu_stats->{'cpu_usage'}->{'total_usage'};

      my $cpu_system_usage = $cpu_stats->{'system_cpu_usage'};
      my $pre_cpu_system_usage = $precpu_stats->{'system_cpu_usage'};

      my $cpu_delta = $cpu_usage - $pre_cpu_usage;
      my $system_delta = $cpu_system_usage - $pre_cpu_system_usage;

      if ($system_delta > 0 && $cpu_delta > 0) {
        $cpu_percent = ($cpu_delta / $system_delta) * $cpu_stats->{'online_cpus'} * 100;
      }

      $v->{'plugin'} = "${PLUGIN_NAME}_cpu_usage";
      $v->{'type'} = "cpu.percent";
      $v->{plugin_instance} = $container;
      $v->{type_instance} = 'cpu_usage';
      $v->{values} = [ $cpu_percent ];
      plugin_dispatch_values($v);
    }

    $DATA->{$container}->{'precpu_stats'} = $DATA->{$container}->{'cpu_stats'};

  }

  return 1;

}

plugin_register(TYPE_CONFIG, $PLUGIN_NAME, "config_func");
plugin_register(TYPE_INIT, $PLUGIN_NAME, "init_func");
plugin_register(TYPE_READ, $PLUGIN_NAME, "read_func");

1;

