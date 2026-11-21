# Spotless share relay

Jam and collaborative-playlist channels, plus the web pages behind invite links. A Cloudflare
Worker with one Durable Object per channel, on the personal account (`tanthompsig.workers.dev`).

- A channel is 16 random bytes of id and a 32-byte AES-256-GCM key. The key only ever lives in the
  link's `#fragment`, so neither this relay nor Cloudflare can read a message.
- Access: `token = hex(SHA-256(key || "relay"))`. The first connection claims the channel; later ones
  must match.
- `GET /c/<id>/ws?token=&after=` WebSocket: backlog from the latest snapshot, then live messages.
  Send `{from, box, snap?}`. `GET /c/<id>?token=&after=` reads the same log over HTTP.
- `GET /j` Jam guest page (listen along through a YouTube embed, add/remove songs, play/pause/skip;
  searches go through the host's app). `GET /p` playlist invite page (opens the app).
- Channels untouched for 90 days are deleted.

Message shapes (sealed JSON) are defined in `ios/Encore/Encore/App/Share.swift` and `src/pages.js`.

Local test: `wrangler dev --local --port 8789`, then the script in the PR description.
