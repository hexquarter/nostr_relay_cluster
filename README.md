# Distributed Nostr Relay Infrastructure

A private, federated Nostr relay cluster built with [strfry](https://github.com/hoytech/strfry), designed to provide independent relay nodes, continuous event propagation, and eventual consistency across the network.

## Overview

This project explores a distributed infrastructure for operating multiple Nostr relays as a coordinated cluster.

Each relay remains an independent Nostr server with its own event database, WebSocket connections, subscriptions, and validation rules. The cluster provides replication between relays so that events published to one node can become available on the others.

The architecture combines:

- **strfry** — high-performance Nostr relay implementation.
- **strfry router** — continuous event propagation between relay nodes.
- **NIP-77 / Negentropy** — historical synchronization and periodic reconciliation.
- **Docker Compose** — local development and initial deployment.
- **Tailscale** — private connectivity and network access control.
- **HAProxy** — planned private ingress and WebSocket load balancing.

The initial implementation focuses on a small private cluster. Production concerns such as automated node provisioning, high availability, monitoring, and public ingress will be introduced incrementally.

## Architecture

### Core principles

1. **Independent relay nodes:** Each relay owns its database, connections, subscriptions, and local event processing.
2. **No shared database:** Relay instances never share an LMDB database or use a shared network filesystem for relay storage.
3. **Eventual consistency:** Replication is asynchronous. Events propagate between nodes without requiring a central coordinator.
4. **Private communication:** Internal relay-to-relay traffic uses a private network.
5. **Independent operation:** A relay should continue serving its local clients when another node becomes unavailable.
6. **Recoverability:** Historical reconciliation allows nodes to recover events missed during outages.

### High-level architecture

```text
                         Nostr Clients
                               |
                               v
                     +-------------------+
                     |   Private Ingress |
                     |      HAProxy      |
                     +-------------------+
                               |
                     Private Network
                         (Tailscale)
                               |
               +---------------+---------------+
               |                               |
               v                               v
       +---------------+               +---------------+
       |    Relay A    |               |    Relay B    |
       |               |               |               |
       |    strfry     |               |    strfry     |
       |    router     |<------------->|    router     |
       |   sync-agent  |               |   sync-agent  |
       |               |               |               |
       |   Local DB    |               |   Local DB    |
       +---------------+               +---------------+
```

The diagram represents the target architecture. In the current Docker experiment, ingress and Tailscale are not yet required.

### Relay layer

Each node runs an independent strfry instance.

A relay is responsible for:

- Accepting Nostr WebSocket connections.
- Validating incoming events.
- Managing subscriptions and filters.
- Persisting events in its own LMDB database.
- Serving events from its local database.

Relay databases are local to their respective nodes and must never be shared between relay processes.

### Synchronization layer

Synchronization uses two complementary mechanisms.

**1. Continuous replication — strfry router**

The native strfry router maintains connections between relay nodes and propagates events continuously.

For the initial topology, each relay connects to its peers using bidirectional streams:

```hocon
connectionTimeout = 20
verbose = true

streams {
  cluster {
    dir = "both"
    urls = ["ws://relay_b:7777"]
  }
}
```

Each node has its own router configuration referencing the other nodes.

Router replication handles live event propagation. It does not replace historical synchronization.

**2. Historical synchronization — NIP-77 / Negentropy**

NIP-77 reconciliation identifies differences between relay databases and allows missing events to be retrieved.

It is used for:

- Initial synchronization when a node joins the cluster.
- Periodic reconciliation.
- Recovery after network interruptions.
- Repairing inconsistencies between peers.

The installed strfry version supports the following command:

```bash
strfry sync ws://relay_b:7777 --dir=both
```

The `--dir` option accepts `both`, `down`, `up`, or `none`.

Reconciliation is a one-shot operation. A scheduler is responsible for invoking it periodically.

**Replication model**

| Mechanism | Responsibility |
|---|---|
| strfry router | Continuous event propagation |
| NIP-77 / Negentropy | Historical reconciliation |
| sync-agent | Synchronization orchestration and scheduling |

The synchronization layer is asynchronous. The cluster does not guarantee that every relay has identical data at every moment.

Replication scope, retention rules, event deletion behavior, and expiration policies must be defined consistently across nodes.

### Private network

The target deployment uses Tailscale to connect relay nodes, ingress infrastructure, and authorized administration devices.

Tailscale provides:

- Private connectivity between nodes.
- Device identity and network authentication.
- Access control through ACLs and grants.
- Restricted access to internal relay services.
- Administrative access without exposing relay nodes directly to the public internet.

Network authorization and Nostr authorization are separate concerns. Tailscale controls which devices can reach internal services; relay-level policies control publishing, subscriptions, and Nostr authentication.

### Ingress layer

A dedicated ingress component will provide a unified WebSocket endpoint for clients.

HAProxy is the initial candidate.

Its responsibilities include:

- WebSocket connection routing.
- TLS termination.
- Backend health checks.
- Connection timeouts and draining.
- Load balancing across healthy relay nodes.

Load balancing distributes client connections; it does not synchronize relay data or move existing WebSocket connections between nodes. Event replication is handled independently by the synchronization layer.

The initial deployment targets private ingress. A public WSS endpoint can be introduced later without exposing relay nodes directly.

## Current implementation

The current proof of concept runs two strfry relay instances using Docker Compose.

Each container runs:

- One strfry relay process.
- One strfry router process.
- A lightweight shell-based synchronization scheduler.

Each relay has its own persistent database directory.

### Requirements

- Docker
- Docker Compose
- A locally available `strfry:latest` image
- Bash-compatible container environment

The exact image and binary version should be pinned before production deployment.

### Project structure

A suggested structure for the current experiment:

```text
.
├── docker-compose.yml
├── conf/
│   ├── strfry.conf
│   ├── relay_a_router.conf
│   └── relay_b_router.conf
├── scripts/
│   └── start_node.sh
└── data/
    ├── relay_a/
    └── relay_b/
```

### Configuration

Both relay instances use the same base strfry configuration, with independent database directories supplied through the container mounts.

The relay must listen on `0.0.0.0` inside the Docker network so that peer containers can connect to it.

The internal WebSocket port is `7777`.

The database path must match the mounted persistent directory:

```hocon
db = "/app/strfry-db/"
```

The router configuration is specific to each relay.

For example, Relay A connects to Relay B:

```hocon
connectionTimeout = 20
verbose = true

streams {
  cluster {
    dir = "both"
    urls = ["ws://relay_b:7777"]
  }
}
```

Relay B uses the reciprocal configuration.

### Docker Compose

Example two-node deployment:

```yaml
services:
  relay_a:
    container_name: relay_a
    image: strfry:latest
    ports:
      - "7447:7777"
    volumes:
      - ./conf/strfry.conf:/etc/strfry.conf
      - ./data/relay_a:/app/strfry-db
      - ./conf/relay_a_router.conf:/etc/strfry-router.conf
      - ./scripts/start_node.sh:/app/start-node.sh
    environment:
      STRFRY_CONFIG: /etc/strfry.conf
      SYNC_PEERS: "ws://relay_b:7777"
    networks:
      - relay-network
    entrypoint: ["/bin/bash", "/app/start-node.sh"]

  relay_b:
    container_name: relay_b
    image: strfry:latest
    ports:
      - "7448:7777"
    volumes:
      - ./conf/strfry.conf:/etc/strfry.conf
      - ./data/relay_b:/app/strfry-db
      - ./conf/relay_b_router.conf:/etc/strfry-router.conf
      - ./scripts/start_node.sh:/app/start-node.sh
    environment:
      STRFRY_CONFIG: /etc/strfry.conf
      SYNC_PEERS: ""
    networks:
      - relay-network

networks:
  relay-network:
    driver: bridge
```

The example assigns periodic reconciliation ownership to Relay A. Relay B still runs its router and participates in bidirectional replication.

Only one reconciliation scheduler should own a peer pair at a time. Running simultaneous bidirectional reconciliation jobs from both ends is unnecessary and can cause overlapping work.

The host ports are for local testing:

| Relay | Host port | Container port |
|---|---:|---:|
| Relay A | 7447 | 7777 |
| Relay B | 7448 | 7777 |

From the host, the relay endpoints are:

```text
ws://localhost:7447
ws://localhost:7448
```

Inside the Docker network, peers use service/container DNS names and port `7777`.

### Starting the cluster

Create the database directories:

```bash
mkdir -p data/relay_a data/relay_b
```

Start both services:

```bash
docker compose up -d
```

Inspect logs:

```bash
docker compose logs -f relay_a relay_b
```

Check the published endpoints:

```text
ws://localhost:7447
ws://localhost:7448
```

Check the relay processes, router connections, and synchronization logs independently.

### Testing replication

A basic replication test should verify both directions.

1. Publish an event to Relay A.
2. Query Relay B for the event.
3. Publish a different event to Relay B.
4. Query Relay A for the event.
5. Stop one relay temporarily.
6. Publish events while the other relay remains available.
7. Restart the stopped relay.
8. Run reconciliation and verify that missing events are recovered.

Use event IDs to verify that the same events are available on both relays.

Also test duplicate delivery, event deletion, expiration, and behavior under intermittent connectivity before relying on the cluster in production.

## Synchronization and operational considerations

### Initial node synchronization

A new node must not be considered fully synchronized simply because its relay process is healthy.

A node joining the cluster should:

1. Start its relay and initialize local storage.
2. Establish connectivity with existing peers.
3. Perform historical reconciliation.
4. Activate continuous router replication.
5. Enable periodic reconciliation.
6. Verify convergence within the configured replication scope.

The exact ordering and readiness checks should be validated against the deployed strfry version.

### Periodic reconciliation

Periodic reconciliation is currently handled by a lightweight scheduler.

The interval should be configurable. The initial experimental default is 15 minutes.

Reconciliation jobs should be serialized per peer pair. Avoid starting a second job while the previous one is still running.

The installed strfry CLI does not expose a native `--timeout` option for `sync`. Any execution timeout must therefore be implemented by external process supervision, if required.

### Event deletion and expiration

Event replication requires an explicit policy for deletion and expiration.

In particular:

- Kind 5 deletion events must be handled consistently.
- Deleted events must not be reintroduced during later reconciliation.
- Expired events must follow a consistent retention policy.
- Relay-specific retention rules must be considered when defining expected cluster convergence.

These behaviors require dedicated integration tests.

### Network partitions

During a network partition, relays should continue operating independently.

When connectivity returns:

- Router connections should reconnect.
- Live event propagation should resume.
- Negentropy reconciliation should repair missed history.
- Duplicate events should not create duplicate database entries.

### Scaling considerations

The initial topology uses a full mesh.

For `N` relay nodes, a full mesh requires:

```text
N × (N - 1) / 2
```

peer relationships.

This is straightforward for a small cluster. Larger deployments may require a different topology based on bandwidth, connection count, geographic distribution, and reconciliation workload.

A central coordinator is not required for the initial implementation.

## Security

The initial target is a private relay cluster.

Security requirements include:

- Keep relay nodes off the public internet.
- Restrict internal services to authorized network identities.
- Use Tailscale ACLs or grants to limit peer and administrative access.
- Apply relay-level authorization independently of network access.
- Protect configuration files and private credentials.
- Expose only the required WebSocket endpoint through ingress.
- Restrict administrative and monitoring endpoints.

The Docker Compose setup is an experimental environment, not a production security baseline.

## Monitoring and observability

A production deployment should expose enough information to distinguish relay health from cluster synchronization health.

Important metrics and signals include:

| Area | What to monitor |
|---|---|
| Relay | Availability, WebSocket connections, request latency |
| Storage | LMDB size, disk usage, growth rate |
| Router | Peer connection status, reconnects, propagation errors |
| Synchronization | Last successful reconciliation, duration, failures |
| Network | Peer reachability, latency, bandwidth |
| Infrastructure | CPU, memory, disk health |

A relay can be healthy while its synchronization process is failing. These conditions must be monitored independently.

## Scope and status

This project is an evolving infrastructure experiment.

The two-node Docker Compose deployment is the initial implementation target. Tailscale integration, private ingress, automated provisioning, production monitoring, and multi-region capabilities are planned architectural extensions rather than assumed existing features.

The central objective is to build a reliable distributed Nostr relay infrastructure in which nodes remain independent while the network provides recoverable, asynchronous event propagation.