# Conduktor Passthrough Gateway — Quickstart

A local demo of the [Conduktor Passthrough Gateway](https://conduktor.io/gateway/passthrough). It spins up a private Kafka cluster, Karapace (Schema Registry), a [data generator](https://hub.docker.com/r/conduktor/conduktor-data-generator), and the [base Gateway image](https://hub.docker.com/r/conduktor/conduktor-gateway). 

Only the Gateway is exposed to your laptop, as Kafka itself stays unreachable. Clients connect through the Gateway using their existing SASL credentials, and the Gateway translates broker addresses on the way back so clients always see an address they can route to.

## Prerequisites

- Docker and Docker Compose
- Kafka CLI tools on your local machine
- A Passthrough Gateway license (free, see below).

## You'll need a license

The Passthrough Gateway is free but requires a license key. [Request one here](https://conduktor.io/gateway/passthrough#request-license).

After filling out your details, you should expect your license by email within 1 business day.

## Quickstart

Clone the repo:

```bash
git clone https://github.com/conduktor/ptg-quickstart.git
cd ptg-quickstart
```

Drop your license into a `.env` file:

```bash
echo "GATEWAY_LICENSE_KEY=<paste-key-from-email>" > .env
```

Start the stack:

```bash
docker compose up -d
```

Wait ~30 seconds, then check everything's up:

```bash
docker compose ps
```

## What's running

| Component | Purpose | Exposed |
|---|---|---|
| Conduktor Passthrough Gateway | The proxy. Only public entry point. | `localhost:6969` |
| Kafka broker (KRaft) | Private cluster. | Internal only |
| Kafka controller | Cluster metadata. | Internal only |
| Karapace | Schema Registry. | `localhost:8081` |
| Conduktor Data Generator | Produces test data. | Internal only |

## Demo credentials

The stack uses hardcoded SASL credentials (`admin` / `admin-secret`, plus a few app users). These are intentional for a local demo so you can run commands without any setup. They are not safe for production. Replace them with real secrets before running this anywhere outside your laptop.

## Verify it works

Run these from your laptop. Each one talks to Kafka through the Gateway on `localhost:6969`.

```bash
# 1. List topics. Confirms that Kafka is reachable via Gateway's exposed port.
kafka-topics --list --bootstrap-server localhost:6969 --command-config kafka-admin.properties

# 2. Check the schemas registered in Karapace.
curl -s http://localhost:8081/subjects

# 3. Consume messages. The output is Avro-encoded, so it looks like binary noise. See below for decoded output.
kafka-console-consumer --bootstrap-server localhost:6969 --topic customers --from-beginning --consumer.config kafka-admin.properties
```

### Decoded output

To see readable JSON instead of Avro bytes, use the tool of your choice: [`kcat`](https://github.com/edenhill/kcat), Confluent's `kafka-avro-console-consumer`, or a Kafka UI like [Conduktor Console](https://conduktor.io/get-started). Example with `kcat`:

```bash
kcat -b localhost:6969 -t customers -C -e -s value=avro -r http://localhost:8081 -Xsecurity.protocol=SASL_PLAINTEXT -Xsasl.mechanism=PLAIN -Xsasl.username=admin -Xsasl.password=admin-secret
```

### See the address translation in action

The Gateway is set up with debug logging on its address-rewriting component. Every time a client asks Kafka for broker addresses, the Gateway rewrites them on the way back so the client gets an address it can actually reach.

You can watch this happen live. In one terminal, follow the rewrite logs (Ctrl+C to stop):

```bash
docker logs -f conduktor-passthrough-gateway 2>&1 | grep "Rewriting METADATA" | sed 's/, MetadataResponseData.*$//'
```

In another terminal, trigger a metadata call:

```bash
kafka-topics --list --bootstrap-server localhost:6969 --command-config kafka-admin.properties
```

Lines like this will show up in the first terminal:

```
Rewriting METADATA: kafka:9092 (rack: null) -> localhost:6969 (rack: null)
```

That is the Gateway telling you what it just did. Kafka's real broker address inside Docker is `kafka:9092`. Your client gets back `localhost:6969`, which is the address it can route to. Same broker, two different addresses depending on where you connect from.


## From demo to production

This compose is wired for a local demo. If you're interested in running the Gateway on Kubernetes, AWS, or other production setups, see the [deployment options](https://docs.conduktor.io/platform/category/deployment-options/) and the [Gateway deployment guide](https://docs.conduktor.io/guide/conduktor-in-production/deploy-artifacts/deploy-gateway) for security configuration, multi-broker setup, and more.

## Learn more

- [Passthrough Gateway product page](https://conduktor.io/gateway/passthrough)
- [Read the official gateway docs](https://docs.conduktor.io/guide/conduktor-in-production/manage-licenses/passthrough-gateway)
- [Conduktor Slack community](https://conduktor.io/slack)
