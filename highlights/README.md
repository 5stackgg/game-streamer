# highlights

CS2 demo parser. Reads a `.dem` file, emits one JSON event per line on stdout
describing a highlight candidate. Downstream workers turn each line into a
render job (see `scripts/render.sh`).

## Build

```
cd highlights
go mod tidy
go build -o ../bin/highlights .
```

## Usage

```
highlights -match <match-id> -demo /cache/demos/foo.dem
```

Emits lines like:

```json
{"match_id":"abc","steam_id":"76561...","round":5,"start_tick":12345,"end_tick":12345,"spec_slot":3,"event_type":"kill"}
{"match_id":"abc","steam_id":"76561...","round":9,"start_tick":18000,"end_tick":18500,"spec_slot":3,"event_type":"ace"}
```

## Next step

Wire stdout into NATS/JetStream: each line becomes a job message; the
highlight-worker Deployment consumes them and launches CS2 with `playdemo`
per-clip (see `overlays/game-streamer/highlight-worker-deployment.yaml`).
