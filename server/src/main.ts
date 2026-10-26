import { createServer } from "node:http";
import { startRendezvous } from "./rendezvous.ts";

/**
 * Runs the rendezvous server. Settings come from the environment:
 *   PORT, HOST    where to listen (default 127.0.0.1:8080); put TLS in front of it (see deploy/)
 *   TURN_URLS     the relay, comma-separated, e.g. turn:relay.example.com:3478?transport=udp
 *   TURN_SECRET   the secret shared with coturn's static-auth-secret
 *   TURN_TTL      seconds relay credentials last (default 3600)
 *   TRUST_PROXY   1 when behind a reverse proxy that sets X-Forwarded-For
 */
const port = Number(process.env.PORT ?? 8080);
const host = process.env.HOST ?? "127.0.0.1";
const turnUrls = (process.env.TURN_URLS ?? "").split(",").map((url) => url.trim()).filter(Boolean);
const turnSecret = process.env.TURN_SECRET ?? "";
if (turnUrls.length > 0 && turnSecret.length < 32) {
  console.error("TURN_SECRET must be at least 32 characters when TURN_URLS is set");
  process.exit(1);
}

const server = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "text/plain" }).end("ok\n");
  } else {
    response.writeHead(404).end();
  }
});

const rendezvous = startRendezvous(server, {
  turn: turnUrls.length > 0 ? { urls: turnUrls, secret: turnSecret, ttlSeconds: Number(process.env.TURN_TTL ?? 3600) } : undefined,
  trustProxy: process.env.TRUST_PROXY === "1",
});

server.listen(port, host, () => console.log(`Longarm rendezvous on ${host}:${port}${turnUrls.length ? `, relay ${turnUrls.join(", ")}` : ", no relay"}`));

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    rendezvous.close();
    server.close(() => process.exit(0));
  });
}
