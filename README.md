# Conduktor Gateway Community Edition Quickstart

Conduktor Gateway Community Edition is a **free Kafka proxy that connects clients to clusters sitting in other VPCs, clouds, or private networks, with no changes to your brokers or credentials.** For free, it runs in passthrough mode, where it translates the broker addresses Kafka advertises into ones the client can reach, and it leaves authentication to the cluster.

This quickstart recreates that situation on your laptop: a Kafka cluster the clients **can't reach directly**, and a Gateway that proxies those clients to the cluster.

## What it's for

- **Reach Kafka without adding peerings.** Route many client VPCs through one proxy in an already-peered VPC. The cluster keeps one attachment, however many client networks connect.
- **Reach a private cluster from outside.** When the cluster has no public endpoint, a proxy on the boundary lets external clients, partners, or cross-cloud workloads in, with no cluster changes.
- **Single egress point.** Many internal clients funnel through one proxy to a remote cluster: one firewall rule, one TLS termination, one audit trail.

## What's included

Starting the quickstart runs six containers:

- **kafka**: a single-node Kafka cluster (the private cluster).
- **karapace**: Schema Registry, holding the Avro schemas.
- **conduktor-data-generator**: produces sample Avro data (`customers`, `products`, `purchases`, and so on).
- **conduktor-gateway**: the proxy.
- **kafka-consumer-a** and **kafka-consumer-b**: two consumers, in two separate networks, reading through the Gateway as different principals.

## How it works

The containers are placed in **three isolated Docker networks** that stand in for separate VPCs. A container can only reach another container on a network it shares.

```
          cluster-vpc  (private; no port published to your laptop)
        +-----------------------------------+
        |  kafka          data-generator    |
        +-----------------+-----------------+
                          |  only the Gateway can reach Kafka
        +-----------------+-----------------+
        |         conduktor-gateway         |  (a member of all three networks)
        +------+--------------------+-------+
               |                    |
        client-vpc-a          client-vpc-b
        +------------------+  +------------------+
        | kafka-consumer-a |  | kafka-consumer-b |
        +------------------+  +------------------+
        consumers can't reach Kafka directly: different networks, no route
```

- **kafka** is only in `cluster-vpc`, so it's unreachable from the client networks and from your laptop.
- **kafka-consumer-a** is only in `client-vpc-a`; **kafka-consumer-b** is only in `client-vpc-b`. Neither shares a network with the cluster, so neither can route to `kafka`.
- **conduktor-gateway** is the only container joined to all three networks, so it's the only path from a consumer to the cluster.
- **karapace** (the Schema Registry, not shown above) is attached to all three networks, so the consumers can fetch schemas to decode Avro. Kafka stays reachable only through the Gateway; the registry is reachable directly, as it commonly is in real setups.

When a client connects through the Gateway, the Gateway opens its own connection to the broker and rewrites the address the broker advertises (`kafka:9092`, which the client can't reach) into its own address (which the client can). The cluster and the client credentials are never changed.

## Before you start

- Docker and Docker Compose.
- A Gateway Community Edition license, free. [Request one here](https://conduktor.io/gateway/community-edition#request-license).

You don't need Kafka installed locally; the consumer containers bundle `kcat`. The one-liner needs `git` (it clones the repo); the manual path doesn't.

## Get started

```bash
bash <(curl -fsSL https://releases.conduktor.io/gateway-community-quickstart)
```

It downloads and runs `start.sh`, which clones the repo into `./gateway-community-quickstart`, asks for your license, and points you to the checks in [See it work](#see-it-work) below.

Prefer to do it by hand? Download [`docker-compose.yaml`](https://github.com/conduktor/gateway-community-quickstart/blob/main/docker-compose.yaml), put your license in a `.env` file beside it (`GATEWAY_LICENSE_KEY=<your-key>`), and run `docker compose up`. To read the script before running it: `curl -fsSL https://releases.conduktor.io/gateway-community-quickstart -o start.sh && less start.sh`.

Stop with `docker compose down` or `./stop.sh` from that folder.

## See it work

First bring the stack up (the one-liner above, or `./start.sh`). Then, from the `gateway-community-quickstart` folder, run the guided walkthrough, which runs each check and explains it. `start.sh` also offers to run it for you when it finishes.

```bash
./demo.sh
```

Or run the steps by hand. Each uses `docker exec` into a consumer, so you don't need Kafka on your laptop.

**1. Confirm a consumer can't reach Kafka directly.**

```bash
docker exec kafka-consumer-a kcat -b kafka:9092 -L -m 5
# -> Failed to resolve 'kafka:9092'
```

`kafka` is in a different network, so the name doesn't resolve. There's no route from the consumer to the cluster.

**2. Read the data through the Gateway (Avro decoded via Karapace).**

```bash
docker exec kafka-consumer-a kcat -b conduktor-gateway:9092 -t customers -C -e -c 3 \
  -s value=avro -r http://karapace:8081 \
  -X security.protocol=SASL_PLAINTEXT -X sasl.mechanism=PLAIN \
  -X sasl.username=consumer-a -X sasl.password=consumer-a-secret
# -> readable JSON records
```

Reached only through the Gateway. `kafka-consumer-b`, in its own VPC and as a different principal (`consumer-b`), does exactly the same.

**3. See the address translation that makes it work.**

```bash
docker logs conduktor-gateway 2>&1 | grep "Rewriting METADATA"
# kafka:9092 -> conduktor-gateway:9092
```

The broker advertises `kafka:9092`. The Gateway rewrites that to its own address before the consumer ever sees it, so the consumer always gets an address it can reach.

## In a real deployment

The Gateway sits in its own hub VPC, peered (or connected via PrivateLink) to the cluster VPC and to each client VPC. The peerings land on the hub, never directly between a client and the cluster, so the cluster keeps one attachment. Docker has no peering, so this quickstart achieves the same isolation by making the Gateway a member of each network.

**Why not just add a second broker listener instead of a proxy?** In most managed Kafka services (Confluent Cloud, Aiven) you can't add a listener at all or it's too cumbersome to do so out of the box. And even where you can, every broker's advertised address still has to be routable from the client's network, which means an endpoint per broker. The Gateway is one entry point that translates addresses and routes to the brokers behind it.

## Good to know

- Credentials (`admin` / `admin-secret` for the infrastructure, plus `consumer-a` and `consumer-b`) are hardcoded for a local demo. Replace them before using this anywhere else.
- Karapace is attached to the client VPCs so the consumers can decode Avro, which means the registry is reachable from clients even though Kafka isn't. In production you'd front the registry with a Schema Registry proxy.
- The consumers run on the `kcat` image (published for amd64 only). That's fine on Intel/AMD natively and on Apple Silicon via Docker Desktop's emulation; the `platform: linux/amd64` pin just silences the arch warning. The only setup that won't run it is a bare arm64 Linux host without QEMU configured.
- For real deployments (multi-broker, TLS, Kubernetes, AWS), see the [deployment options](https://docs.conduktor.io/platform/category/deployment-options/) and [Configure multiple listeners](https://docs.conduktor.io/guide/conduktor-in-production/deploy-artifacts/deploy-gateway/multiple-listeners).

## Learn more

- [Product page](https://conduktor.io/gateway/community-edition)
- [Official docs](https://docs.conduktor.io/guide/conduktor-in-production/manage-licenses/gateway-community-edition)
- [Conduktor Slack community](https://conduktor.io/slack)
