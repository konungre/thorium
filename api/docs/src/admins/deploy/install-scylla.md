## Deploy ScyllaDB

ScyllaDB is a highly-scalable distributed wide-column data store. Thorium uses Scylla for data storage
that requires eventual, but not immediate consistency. Thorium will greatly benefit from a high
performance deployment of ScyllaDB via fast backing storage and scaled up ScyllaDB cluster membership.


### 1) Deploy the Cert Manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.1/cert-manager.yaml
kubectl wait --for condition=established crd/certificates.cert-manager.io crd/issuers.cert-manager.io
sleep 10
kubectl -n cert-manager rollout status deployment.apps/cert-manager-webhook -w
```

### 2) Create the Scylla Operator

```bash
git clone github.com/scylladb/scylla-operator.git
kubectl apply -f scylla-operator/deploy/operator.yaml
sleep 10
kubectl wait --for condition=established crd/scyllaclusters.scylla.scylladb.com
kubectl -n scylla-operator rollout status deployment.apps/scylla-operator -w
```

### 3) Create the ScyllaDB Cluster

Consider updating these fields in the following resource file before applying them with `kubectl`:

- `version`
- `agentVersion`
- `members`
- `capacity`
- `storageClassName`
- `resources.[requests,limits].memory`
- `resources.[requests,limits].cpu`

```yaml,editable
cat <<EOF | kubectl apply -f -
# Namespace where the Scylla Cluster will be created
apiVersion: v1
kind: Namespace
metadata:
  name: scylla
---
# Simple Scylla Cluster
apiVersion: scylla.scylladb.com/v1
kind: ScyllaCluster
metadata:
  labels:
    controller-tools.k8s.io: "1.0"
  name: scylla
  namespace: scylla
spec:
  version: 5.4.9
  agentVersion: 3.4.1
  developerMode: false
  sysctls:
    - fs.aio-max-nr=30000000
  datacenter:
    name: us-east-1
    racks:
      - name: us-east-1a
        scyllaConfig: "scylla-config"
        scyllaAgentConfig: "scylla-agent-config"
        members: 3
        storage:
          capacity: 20Ti
          storageClassName: csi-rbd-sc
        resources:
          requests:
            cpu: 8
            memory: 32Gi
          limits:
            cpu: 8
            memory: 32Gi
        volumes:
          - name: coredumpfs
            hostPath:
              path: /tmp/coredumps
        volumeMounts:
          - mountPath: /tmp/coredumps
            name: coredumpfs
EOF
```

### 4) Update Scylla config and restart nodes

Copy the YAML config from the appendices of this section and write it to a file called `scylla.yaml`.
Then create a K8s `ConfigMap` using that file and run a rolling reboot of Scylla's StatefulSet so the
DB will use that config upon restart.

```bash
kubectl rollout status --watch --timeout=600s statefulset/scylla-us-east-1-us-east-1a -n scylla
kubectl create cm scylla-config --from-file ./scylla.yaml -n scylla
sleep 10
kubectl rollout restart -n scylla statefulset.apps/scylla-us-east-1-us-east-1a
sleep 10
kubectl rollout status --watch --timeout=600s statefulset/scylla-us-east-1-us-east-1a -n scylla
```

### 5) Configure thorium role and replication settings

Once all Scylla nodes are up and `Running` you can configure the Thorium role and keyspace and disable
the default cassandra user with it's insecure default password. Be sure to update the
`INSECURE_SCYLLA_PASSWORD` value below to an appropriately secure value. The text block can be edited
before copy-pasting the command into a terminal. You may also want to change the `replication_factor`
for small deployments with less than 3 `Scylla` nodes.

```bash,editable
# setup thorium role
kubectl -n scylla exec -i --tty=false pod/scylla-us-east-1-us-east-1a-0 -- /bin/bash << EOF
cqlsh 'scylla-us-east-1-us-east-1a-0.scylla.svc.cluster.local' -u cassandra -p cassandra -e "CREATE ROLE admin with SUPERUSER = true"
cqlsh 'scylla-us-east-1-us-east-1a-0.scylla.svc.cluster.local' -u cassandra -p cassandra -e "CREATE ROLE thorium WITH PASSWORD = 'INSECURE_SCYLLA_PASSWORD' AND LOGIN = true"
cqlsh 'scylla-us-east-1-us-east-1a-0.scylla.svc.cluster.local' -u cassandra -p cassandra -e "GRANT admin to thorium"
cqlsh 'scylla-us-east-1-us-east-1a-0.scylla.svc.cluster.local' -u cassandra -p cassandra -e "CREATE KEYSPACE IF NOT EXISTS thorium WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 3}"
cqlsh 'scylla-us-east-1-us-east-1a-0.scylla.svc.cluster.local' -u cassandra -p cassandra -e "GRANT ALL ON KEYSPACE thorium TO thorium"
cqlsh 'scylla-us-east-1-us-east-1a-0.scylla.svc.cluster.local' -u cassandra -p cassandra -e "GRANT CREATE ON ALL KEYSPACES TO thorium"
cqlsh 'scylla-us-east-1-us-east-1a-0.scylla.svc.cluster.local' -u thorium -p INSECURE_SCYLLA_PASSWORD -e "DROP ROLE cassandra"
EOF
```

### Appendices

#### Example scylla.yaml config:

```yaml
# Scylla storage config YAML

#######################################
# This file is split to two sections:
# 1. Supported parameters
# 2. Unsupported parameters: reserved for future use or backwards
#    compatibility.
# Scylla will only read and use the first segment
#######################################

### Supported Parameters

# The name of the cluster. This is mainly used to prevent machines in
# one logical cluster from joining another.
# It is recommended to change the default value when creating a new cluster.
# You can NOT modify this value for an existing cluster
#cluster_name: 'Test Cluster'

# This defines the number of tokens randomly assigned to this node on the ring
# The more tokens, relative to other nodes, the larger the proportion of data
# that this node will store. You probably want all nodes to have the same number
# of tokens assuming they have equal hardware capability.
num_tokens: 256

# Directory where Scylla should store all its files, which are commitlog,
# data, hints, view_hints and saved_caches subdirectories. All of these
# subs can be overriden by the respective options below.
# If unset, the value defaults to /var/lib/scylla
# workdir: /var/lib/scylla

# Directory where Scylla should store data on disk.
# data_file_directories:
#    - /var/lib/scylla/data

# commit log.  when running on magnetic HDD, this should be a
# separate spindle than the data directories.
# commitlog_directory: /var/lib/scylla/commitlog

# commitlog_sync may be either "periodic" or "batch."
#
# When in batch mode, Scylla won't ack writes until the commit log
# has been fsynced to disk.  It will wait
# commitlog_sync_batch_window_in_ms milliseconds between fsyncs.
# This window should be kept short because the writer threads will
# be unable to do extra work while waiting.  (You may need to increase
# concurrent_writes for the same reason.)
#
# commitlog_sync: batch
# commitlog_sync_batch_window_in_ms: 2
#
# the other option is "periodic" where writes may be acked immediately
# and the CommitLog is simply synced every commitlog_sync_period_in_ms
# milliseconds.
commitlog_sync: periodic
commitlog_sync_period_in_ms: 10000

# The size of the individual commitlog file segments.  A commitlog
# segment may be archived, deleted, or recycled once all the data
# in it (potentially from each columnfamily in the system) has been
# flushed to sstables.
#
# The default size is 32, which is almost always fine, but if you are
# archiving commitlog segments (see commitlog_archiving.properties),
# then you probably want a finer granularity of archiving; 8 or 16 MB
# is reasonable.
commitlog_segment_size_in_mb: 32

# seed_provider class_name is saved for future use.
# A seed address is mandatory.
seed_provider:
    # The addresses of hosts that will serve as contact points for the joining node.
    # It allows the node to discover the cluster ring topology on startup (when
    # joining the cluster).
    # Once the node has joined the cluster, the seed list has no function.
    - class_name: org.apache.cassandra.locator.SimpleSeedProvider
      parameters:
          # In a new cluster, provide the address of the first node.
          # In an existing cluster, specify the address of at least one existing node.
          # If you specify addresses of more than one node, use a comma to separate them.
          # For example: "<IP1>,<IP2>,<IP3>"
          - seeds: "127.0.0.1"

# Address to bind to and tell other Scylla nodes to connect to.
# You _must_ change this if you want multiple nodes to be able to communicate!
#
# If you leave broadcast_address (below) empty, then setting listen_address
# to 0.0.0.0 is wrong as other nodes will not know how to reach this node.
# If you set broadcast_address, then you can set listen_address to 0.0.0.0.
listen_address: 0.0.0.0

# Address to broadcast to other Scylla nodes
# Leaving this blank will set it to the same value as listen_address
broadcast_address: 10.233.13.110


# When using multiple physical network interfaces, set this to true to listen on broadcast_address
# in addition to the listen_address, allowing nodes to communicate in both interfaces.
# Ignore this property if the network configuration automatically routes between the public and private networks such as EC2.
#
# listen_on_broadcast_address: false

# port for the CQL native transport to listen for clients on
# For security reasons, you should not expose this port to the internet. Firewall it if needed.
# To disable the CQL native transport, remove this option and configure native_transport_port_ssl.
native_transport_port: 9042

# Like native_transport_port, but clients are forwarded to specific shards, based on the
# client-side port numbers.
native_shard_aware_transport_port: 19042

# Enabling native transport encryption in client_encryption_options allows you to either use
# encryption for the standard port or to use a dedicated, additional port along with the unencrypted
# standard native_transport_port.
# Enabling client encryption and keeping native_transport_port_ssl disabled will use encryption
# for native_transport_port. Setting native_transport_port_ssl to a different value
# from native_transport_port will use encryption for native_transport_port_ssl while
# keeping native_transport_port unencrypted.
#native_transport_port_ssl: 9142

# Like native_transport_port_ssl, but clients are forwarded to specific shards, based on the
# client-side port numbers.
#native_shard_aware_transport_port_ssl: 19142

# How long the coordinator should wait for read operations to complete
read_request_timeout_in_ms: 5000

# How long the coordinator should wait for writes to complete
write_request_timeout_in_ms: 2000
# how long a coordinator should continue to retry a CAS operation
# that contends with other proposals for the same row
cas_contention_timeout_in_ms: 1000

# phi value that must be reached for a host to be marked down.
# most users should never need to adjust this.
# phi_convict_threshold: 8

# IEndpointSnitch.  The snitch has two functions:
# - it teaches Scylla enough about your network topology to route
#   requests efficiently
# - it allows Scylla to spread replicas around your cluster to avoid
#   correlated failures. It does this by grouping machines into
#   "datacenters" and "racks."  Scylla will do its best not to have
#   more than one replica on the same "rack" (which may not actually
#   be a physical location)
#
# IF YOU CHANGE THE SNITCH AFTER DATA IS INSERTED INTO THE CLUSTER,
# YOU MUST RUN A FULL REPAIR, SINCE THE SNITCH AFFECTS WHERE REPLICAS
# ARE PLACED.
#
# Out of the box, Scylla provides
#  - SimpleSnitch:
#    Treats Strategy order as proximity. This can improve cache
#    locality when disabling read repair.  Only appropriate for
#    single-datacenter deployments.
#  - GossipingPropertyFileSnitch
#    This should be your go-to snitch for production use.  The rack
#    and datacenter for the local node are defined in
#    cassandra-rackdc.properties and propagated to other nodes via
#    gossip.  If cassandra-topology.properties exists, it is used as a
#    fallback, allowing migration from the PropertyFileSnitch.
#  - PropertyFileSnitch:
#    Proximity is determined by rack and data center, which are
#    explicitly configured in cassandra-topology.properties.
#  - Ec2Snitch:
#    Appropriate for EC2 deployments in a single Region. Loads Region
#    and Availability Zone information from the EC2 API. The Region is
#    treated as the datacenter, and the Availability Zone as the rack.
#    Only private IPs are used, so this will not work across multiple
#    Regions.
#  - Ec2MultiRegionSnitch:
#    Uses public IPs as broadcast_address to allow cross-region
#    connectivity.  (Thus, you should set seed addresses to the public
#    IP as well.) You will need to open the storage_port or
#    ssl_storage_port on the public IP firewall.  (For intra-Region
#    traffic, Scylla will switch to the private IP after
#    establishing a connection.)
#  - RackInferringSnitch:
#    Proximity is determined by rack and data center, which are
#    assumed to correspond to the 3rd and 2nd octet of each node's IP
#    address, respectively.  Unless this happens to match your
#    deployment conventions, this is best used as an example of
#    writing a custom Snitch class and is provided in that spirit.
#
# You can use a custom Snitch by setting this to the full class name
# of the snitch, which will be assumed to be on your classpath.
endpoint_snitch: SimpleSnitch

# The address or interface to bind the Thrift RPC service and native transport
# server to.
#
# Set rpc_address OR rpc_interface, not both. Interfaces must correspond
# to a single address, IP aliasing is not supported.
#
# Leaving rpc_address blank has the same effect as on listen_address
# (i.e. it will be based on the configured hostname of the node).
#
# Note that unlike listen_address, you can specify 0.0.0.0, but you must also
# set broadcast_rpc_address to a value other than 0.0.0.0.
#
# For security reasons, you should not expose this port to the internet.  Firewall it if needed.
#
# If you choose to specify the interface by name and the interface has an ipv4 and an ipv6 address
# you can specify which should be chosen using rpc_interface_prefer_ipv6. If false the first ipv4
# address will be used. If true the first ipv6 address will be used. Defaults to false preferring
# ipv4. If there is only one address it will be selected regardless of ipv4/ipv6.
rpc_address: localhost
# rpc_interface: eth1
# rpc_interface_prefer_ipv6: false

# port for Thrift to listen for clients on
rpc_port: 9160

# port for REST API server
api_port: 10000

# IP for the REST API server
api_address: 127.0.0.1

# Log WARN on any batch size exceeding this value. 128 kiB per batch by default.
# Caution should be taken on increasing the size of this threshold as it can lead to node instability.
batch_size_warn_threshold_in_kb: 128

# Fail any multiple-partition batch exceeding this value. 1 MiB (8x warn threshold) by default.
batch_size_fail_threshold_in_kb: 1024

# Authentication backend, identifying users
# Out of the box, Scylla provides org.apache.cassandra.auth.{AllowAllAuthenticator,
# PasswordAuthenticator}.
#
# - AllowAllAuthenticator performs no checks - set it to disable authentication.
# - PasswordAuthenticator relies on username/password pairs to authenticate
#   users. It keeps usernames and hashed passwords in system_auth.credentials table.
#   Please increase system_auth keyspace replication factor if you use this authenticator.
# - com.scylladb.auth.TransitionalAuthenticator requires username/password pair
#   to authenticate in the same manner as PasswordAuthenticator, but improper credentials
#   result in being logged in as an anonymous user. Use for upgrading clusters' auth.
authenticator: PasswordAuthenticator 

# Authorization backend, implementing IAuthorizer; used to limit access/provide permissions
# Out of the box, Scylla provides org.apache.cassandra.auth.{AllowAllAuthorizer,
# CassandraAuthorizer}.
#
# - AllowAllAuthorizer allows any action to any user - set it to disable authorization.
# - CassandraAuthorizer stores permissions in system_auth.permissions table. Please
#   increase system_auth keyspace replication factor if you use this authorizer.
# - com.scylladb.auth.TransitionalAuthorizer wraps around the CassandraAuthorizer, using it for
#   authorizing permission management. Otherwise, it allows all. Use for upgrading
#   clusters' auth.
authorizer: CassandraAuthorizer

# initial_token allows you to specify tokens manually.  While you can use # it with
# vnodes (num_tokens > 1, above) -- in which case you should provide a 
# comma-separated list -- it's primarily used when adding nodes # to legacy clusters 
# that do not have vnodes enabled.
# initial_token:

# RPC address to broadcast to drivers and other Scylla nodes. This cannot
# be set to 0.0.0.0. If left blank, this will be set to the value of
# rpc_address. If rpc_address is set to 0.0.0.0, broadcast_rpc_address must
# be set.
# broadcast_rpc_address: 1.2.3.4

# Uncomment to enable experimental features
# experimental_features:
#     - udf
#     - alternator-streams
#     - alternator-ttl
#     - raft

# The directory where hints files are stored if hinted handoff is enabled.
# hints_directory: /var/lib/scylla/hints
 
# The directory where hints files are stored for materialized-view updates
# view_hints_directory: /var/lib/scylla/view_hints

# See https://docs.scylladb.com/architecture/anti-entropy/hinted-handoff
# May either be "true" or "false" to enable globally, or contain a list
# of data centers to enable per-datacenter.
# hinted_handoff_enabled: DC1,DC2
# hinted_handoff_enabled: true

# this defines the maximum amount of time a dead host will have hints
# generated.  After it has been dead this long, new hints for it will not be
# created until it has been seen alive and gone down again.
# max_hint_window_in_ms: 10800000 # 3 hours


# Validity period for permissions cache (fetching permissions can be an
# expensive operation depending on the authorizer, CassandraAuthorizer is
# one example). Defaults to 10000, set to 0 to disable.
# Will be disabled automatically for AllowAllAuthorizer.
# permissions_validity_in_ms: 10000

# Refresh interval for permissions cache (if enabled).
# After this interval, cache entries become eligible for refresh. Upon next
# access, an async reload is scheduled and the old value returned until it
# completes. If permissions_validity_in_ms is non-zero, then this also must have
# a non-zero value. Defaults to 2000. It's recommended to set this value to
# be at least 3 times smaller than the permissions_validity_in_ms.
# permissions_update_interval_in_ms: 2000

# The partitioner is responsible for distributing groups of rows (by
# partition key) across nodes in the cluster.  You should leave this
# alone for new clusters.  The partitioner can NOT be changed without
# reloading all data, so when upgrading you should set this to the
# same partitioner you were already using.
#
# Murmur3Partitioner is currently the only supported partitioner,
#
partitioner: org.apache.cassandra.dht.Murmur3Partitioner

# Total space to use for commitlogs.
#
# If space gets above this value (it will round up to the next nearest
# segment multiple), Scylla will flush every dirty CF in the oldest
# segment and remove it.  So a small total commitlog space will tend
# to cause more flush activity on less-active columnfamilies.
#
# A value of -1 (default) will automatically equate it to the total amount of memory
# available for Scylla.
commitlog_total_space_in_mb: -1

# TCP port, for commands and data
# For security reasons, you should not expose this port to the internet.  Firewall it if needed.
# storage_port: 7000

# SSL port, for encrypted communication.  Unused unless enabled in
# encryption_options
# For security reasons, you should not expose this port to the internet.  Firewall it if needed.
# ssl_storage_port: 7001

# listen_interface: eth0
# listen_interface_prefer_ipv6: false

# Whether to start the native transport server.
# Please note that the address on which the native transport is bound is the
# same as the rpc_address. The port however is different and specified below.
# start_native_transport: true

# The maximum size of allowed frame. Frame (requests) larger than this will
# be rejected as invalid. The default is 256MB.
# native_transport_max_frame_size_in_mb: 256

# Whether to start the thrift rpc server.
# start_rpc: true

# enable or disable keepalive on rpc/native connections
# rpc_keepalive: true

# Set to true to have Scylla create a hard link to each sstable
# flushed or streamed locally in a backups/ subdirectory of the
# keyspace data.  Removing these links is the operator's
# responsibility.
# incremental_backups: false

# Whether or not to take a snapshot before each compaction.  Be
# careful using this option, since Scylla won't clean up the
# snapshots for you.  Mostly useful if you're paranoid when there
# is a data format change.
# snapshot_before_compaction: false

# Whether or not a snapshot is taken of the data before keyspace truncation
# or dropping of column families. The STRONGLY advised default of true 
# should be used to provide data safety. If you set this flag to false, you will
# lose data on truncation or drop.
# auto_snapshot: true

# When executing a scan, within or across a partition, we need to keep the
# tombstones seen in memory so we can return them to the coordinator, which
# will use them to make sure other replicas also know about the deleted rows.
# With workloads that generate a lot of tombstones, this can cause performance
# problems and even exaust the server heap.
# (http://www.datastax.com/dev/blog/cassandra-anti-patterns-queues-and-queue-like-datasets)
# Adjust the thresholds here if you understand the dangers and want to
# scan more tombstones anyway.  These thresholds may also be adjusted at runtime
# using the StorageService mbean.
# tombstone_warn_threshold: 1000
# tombstone_failure_threshold: 100000

# Granularity of the collation index of rows within a partition.
# Increase if your rows are large, or if you have a very large
# number of rows per partition.  The competing goals are these:
#   1) a smaller granularity means more index entries are generated
#      and looking up rows withing the partition by collation column
#      is faster
#   2) but, Scylla will keep the collation index in memory for hot
#      rows (as part of the key cache), so a larger granularity means
#      you can cache more hot rows
# column_index_size_in_kb: 64

# Auto-scaling of the promoted index prevents running out of memory
# when the promoted index grows too large (due to partitions with many rows
# vs. too small column_index_size_in_kb).  When the serialized representation
# of the promoted index grows by this threshold, the desired block size
# for this partition (initialized to column_index_size_in_kb)
# is doubled, to decrease the sampling resolution by half.
#
# To disable promoted index auto-scaling, set the threshold to 0.
# column_index_auto_scale_threshold_in_kb: 10240

# Log a warning when writing partitions larger than this value
# compaction_large_partition_warning_threshold_mb: 1000

# Log a warning when writing rows larger than this value
# compaction_large_row_warning_threshold_mb: 10

# Log a warning when writing cells larger than this value
# compaction_large_cell_warning_threshold_mb: 1

# Log a warning when row number is larger than this value
# compaction_rows_count_warning_threshold: 100000

# Log a warning when writing a collection containing more elements than this value
# compaction_collection_elements_count_warning_threshold: 10000

# How long the coordinator should wait for seq or index scans to complete
# range_request_timeout_in_ms: 10000
# How long the coordinator should wait for writes to complete
# counter_write_request_timeout_in_ms: 5000
# How long a coordinator should continue to retry a CAS operation
# that contends with other proposals for the same row
# cas_contention_timeout_in_ms: 1000
# How long the coordinator should wait for truncates to complete
# (This can be much longer, because unless auto_snapshot is disabled
# we need to flush first so we can snapshot before removing the data.)
# truncate_request_timeout_in_ms: 60000
# The default timeout for other, miscellaneous operations
# request_timeout_in_ms: 10000

# Enable or disable inter-node encryption. 
# You must also generate keys and provide the appropriate key and trust store locations and passwords. 
#
# The available internode options are : all, none, dc, rack
# If set to dc scylla  will encrypt the traffic between the DCs
# If set to rack scylla  will encrypt the traffic between the racks
#
# SSL/TLS algorithm and ciphers used can be controlled by 
# the priority_string parameter. Info on priority string
# syntax and values is available at:
#   https://gnutls.org/manual/html_node/Priority-Strings.html
#
# The require_client_auth parameter allows you to 
# restrict access to service based on certificate 
# validation. Client must provide a certificate 
# accepted by the used trust store to connect.
# 
# server_encryption_options:
#    internode_encryption: none
#    certificate: conf/scylla.crt
#    keyfile: conf/scylla.key
#    truststore: <not set, use system trust>
#    certficate_revocation_list: <not set>
#    require_client_auth: False
#    priority_string: <not set, use default>

# enable or disable client/server encryption.
# client_encryption_options:
#    enabled: false
#    certificate: conf/scylla.crt
#    keyfile: conf/scylla.key
#    truststore: <not set, use system trust>
#    certficate_revocation_list: <not set>
#    require_client_auth: False
#    priority_string: <not set, use default>

# internode_compression controls whether traffic between nodes is
# compressed.
# can be:  all  - all traffic is compressed
#          dc   - traffic between different datacenters is compressed
#          none - nothing is compressed.
# internode_compression: none

# Enable or disable tcp_nodelay for inter-dc communication.
# Disabling it will result in larger (but fewer) network packets being sent,
# reducing overhead from the TCP protocol itself, at the cost of increasing
# latency if you block for cross-datacenter responses.
# inter_dc_tcp_nodelay: false

# Relaxation of environment checks.
#
# Scylla places certain requirements on its environment.  If these requirements are
# not met, performance and reliability can be degraded.
#
# These requirements include:
#    - A filesystem with good support for aysnchronous I/O (AIO). Currently,
#      this means XFS.
#
# false: strict environment checks are in place; do not start if they are not met.
# true: relaxed environment checks; performance and reliability may degraade.
#
developer_mode: false


# Idle-time background processing
#
# Scylla can perform certain jobs in the background while the system is otherwise idle,
# freeing processor resources when there is other work to be done.
#
# defragment_memory_on_idle: true
#
# prometheus port
# By default, Scylla opens prometheus API port on port 9180
# setting the port to 0 will disable the prometheus API.
# prometheus_port: 9180
#
# prometheus address
# Leaving this blank will set it to the same value as listen_address.
# This means that by default, Scylla listens to the prometheus API on the same
# listening address (and therefore network interface) used to listen for
# internal communication. If the monitoring node is not in this internal
# network, you can override prometheus_address explicitly - e.g., setting
# it to 0.0.0.0 to listen on all interfaces.
# prometheus_address: 1.2.3.4

# Distribution of data among cores (shards) within a node
#
# Scylla distributes data within a node among shards, using a round-robin
# strategy:
#  [shard0] [shard1] ... [shardN-1] [shard0] [shard1] ... [shardN-1] ...
#
# Scylla versions 1.6 and below used just one repetition of the pattern;
# this intefered with data placement among nodes (vnodes).
#
# Scylla versions 1.7 and above use 4096 repetitions of the pattern; this
# provides for better data distribution.
#
# the value below is log (base 2) of the number of repetitions.
#
# Set to 0 to avoid rewriting all data when upgrading from Scylla 1.6 and
# below.
#
# Keep at 12 for new clusters.
murmur3_partitioner_ignore_msb_bits: 12

# Bypass in-memory data cache (the row cache) when performing reversed queries.
# reversed_reads_auto_bypass_cache: false

# Use a new optimized algorithm for performing reversed reads.
# Set to `false` to fall-back to the old algorithm.
# enable_optimized_reversed_reads: true

# Use on a new, parallel algorithm for performing aggregate queries.
# Set to `false` to fall-back to the old algorithm.
# enable_parallelized_aggregation: true

# When enabled, the node will start using separate commit log for schema changes
# right from the boot. Without this, it only happens following a restart after
# all nodes in the cluster were upgraded.
#
# Having this option ensures that new installations don't need a rolling restart
# to use the feature, but upgrades do.
#
# WARNING: It's unsafe to set this to false if the node previously booted
# with the schema commit log enabled. In such case, some schema changes
# may be lost if the node was not cleanly stopped.
force_schema_commit_log: true
```