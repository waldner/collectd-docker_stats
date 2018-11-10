# collectd-docker_stats
Container metric collection for collectd

### What's this?

This is a [collectd](https://collectd.org/) plugin to collect Docker container stats, similar to what the stats API provides, but hopefully more lightweight as data is collected reading pseudo-files from the `/proc` and `/sys` filesystems. The Docker API _is_ called, but only to get the list of running containers.

### Prerequisites

The perl modules `WWW::Curl` and `JSON` are the only dependencies. In Debian/Ubuntu, they come packaged as `libwww-curl-perl` and `libjson-perl` respectively.


### Configuration

Let collectd know about the custom data types used by the plugin by copying the `docker_stats.db` files somewhere and referencing its location in collectd's configuration, eg (in `collectd.conf`):

```
TypesDB "/usr/share/collectd/types.db" "/path/to/docker_stats.db"

...
# Load Perl plugin if you weren't loading it already
<LoadPlugin perl>
  Globals true
</LoadPlugin>
...

<Plugin perl>
  IncludeDir "/path/to/collectd_plugins"
  BaseName "Collectd::Plugins"

  ...

  LoadPlugin docker_stats

  <Plugin docker_stats>
#    SizeStats true                         # optional: whether to obtain SizeRootFs and SizeRw values from containers, default false
#    CgroupBase /sys/fs/cgroup              # optional: where to look for cgroup pseudo-files, default /sys/fs/cgroup
#    DockerUnixSocket var/run/docker.sock   # optional: where to find docker API Unix socket, default /var/run/docker.sock
  </Plugin>

</Plugin>
```

Put the actual plugin (`docker_stats.pm`) inside `/path/to/collectd_plugins/Collectd/Plugins` (or whatever your `IncludeDir` and `BaseName` above are). Note however that the plugin package name assumes you're using Collectd::Plugins as `BaseName`.
Finally, restart collectd and hopefully see the values being collected.

### Filtering

If you don't want all the data that is reported by the plugin, you can of course use [collectd's filters](https://collectd.org/documentation/manpages/collectd.conf.5.shtml#filter_configuration) to exclude part of the values, with different levels of granularity.

The following example (to be put in collectd's config file) discards all network values for container `mycontainer`:

```
LoadPlugin match_regex
...

PreCacheChain "DiscardSomeNetStats"
<Chain "DiscardSomeNetStats">
  <Rule "1">
    <Match "regex">
      Plugin "^docker_stats_net$"
      PluginInstance "^mycontainer$"
    </Match>
    <Target "stop">
    </Target>
  </Rule>
  <Target "write">
  </Target>
</Chain>
```


### Internal working and data collection

The plugin never invokes the `/stats` API, but rather collects its data from some cgroup and `/proc` pseudo-files. However, it *does* call the API at each iteration to get the list of running containers, which of course could change over time.

Four types of data are collected:

- CPU stats. The percentage is calculated using the same formula that `docker stats` uses, however the calculation is performed at each collectd iteration (eg, 10 seconds) rather than each second, so the results might be less accurate than those obtained with `docker stats`.

- Memory stats. Four numbers are reported: `usage`, `max_usage`, `limit` are taken straight from the cgroup files `memory.usage_in_bytes`, `memory.max_usage_in_bytes` and `memory.limit_in_bytes` respectively. The fourth value, `usage_stats`, is calculated similarly to how `docker stats` seems to compute the used memory, that is, by taking the usage and subtracting the cache.

- BLKIO stats. There are two types of statistics, those taken from the `blkio.throttle.*` set of files and those taken from the plain `blkio.*` files (part of the `CFQ` disk scheduler). Both *should* theoretically show the same data, however it seems like the CFQ stats are only updated when the underlying device is using the CFQ scheduler, which may not always be the case. The throttle stats seem to be more consistent.

- Network stats. These are taken straight from the `/proc/<pid>/net/dev` pseudo-file for each container's main process.

### Caveats

Only works on Linux (obviously) and might break if the location or contents of some pseudo-file ever changes (which is almost guaranteed to happen when cgroups v2 arrive, and possibly even within v1 at any time).

It's racy in certain parts, especially network stats, altough the corner cases are very unlikely to happen and it should work fine most of the time. The idea is to avoid doing full API queries to inspect each ocntainer at each iteration.

