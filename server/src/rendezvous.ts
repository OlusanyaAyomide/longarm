import { randomBytes } from "node:crypto";
import type { IncomingMessage, Server } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { challengeText, idOf, isValidSignature, parseKey, type Role } from "./identity.ts";
import { turnCredentials, type TurnConfig } from "./turn.ts";

/**
 * Helps a paired phone and Mac find each other over the internet, so they can open a direct
 * WebRTC connection (or one through the TURN relay). It only passes their connection setup along:
 * the screen, input and audio never come through here, and the setup messages are signed end to
 * end by the devices themselves, so this server can't stand in for either one.
 *
 * One WebSocket per device, at /v1, JSON messages:
 *
 *   server → device  challenge {nonce}
 *   device → server  hello {role: mac | phone, key: SPKI DER base64, sig: over challengeText(),
 *                    allow: [phone ids] (Mac only)}
 *   server → device  ready {id, turn?}   (after that:)
 *   device → server  signal {to, data}   → the other device gets signal {from, data}
 *   Mac → server     allow {ids}          which phones may reach it, replacing the list
 *   device → server  turn                 → turn {turn}: fresh relay credentials
 *   server → device  error {code, to?}    unreachable | not-ready | bad-message | unknown-type
 *
 * A phone can only reach a Mac that lists it, and a Mac only phones it lists; to anyone else the
 * Mac is simply "unreachable", whether it's online or not. Connections close with the codes in
 * `Close`.
 */

export interface Options {
  turn?: TurnConfig;
  /** Behind a reverse proxy: take the client's address from X-Forwarded-For. */
  trustProxy?: boolean;
  helloTimeoutMs?: number;
  messagesPerMinute?: number;
  connectionsPerAddress?: number;
  maxAllowed?: number;
  pingIntervalMs?: number;
  now?: () => number;
  log?: (line: string) => void;
}

export const Close = {
  helloTimeout: 4000,
  replaced: 4001,       // the same device connected again
  badHello: 4002,
  tooManyMessages: 4008,
  tooManyConnections: 4009,
} as const;

interface Client {
  socket: WebSocket;
  address: string;
  nonce: string;
  role?: Role;
  id?: string;
  allowed: Set<string>;   // Mac only
  window: { start: number; count: number };
  alive: boolean;
}

const short = (id: string) => id.slice(0, 8);

export function startRendezvous(server: Server, options: Options = {}): { close: () => void } {
  const now = options.now ?? Date.now;
  const log = options.log ?? ((line: string) => console.log(line));
  const helloTimeoutMs = options.helloTimeoutMs ?? 10_000;
  const messagesPerMinute = options.messagesPerMinute ?? 240;
  const connectionsPerAddress = options.connectionsPerAddress ?? 16;
  const maxAllowed = options.maxAllowed ?? 32;

  const wss = new WebSocketServer({ server, path: "/v1", maxPayload: 64 * 1024 });
  const devices: Record<Role, Map<string, Client>> = { mac: new Map(), phone: new Map() };
  const perAddress = new Map<string, number>();
  const clients = new Set<Client>();

  const send = (client: Client, message: object) => {
    if (client.socket.readyState === WebSocket.OPEN) client.socket.send(JSON.stringify(message));
  };

  const allowList = (value: unknown): Set<string> | null => {
    if (!Array.isArray(value) || value.length > maxAllowed) return null;
    if (!value.every((id) => typeof id === "string" && /^[A-Za-z0-9_-]{43}$/.test(id))) return null;
    return new Set(value as string[]);
  };

  const hello = (client: Client, message: Record<string, unknown>) => {
    const role = message.role;
    const parsed = typeof message.key === "string" ? parseKey(message.key) : null;
    const allowed = role === "mac" ? allowList(message.allow ?? []) : new Set<string>();
    if ((role !== "mac" && role !== "phone") || !parsed || !allowed || typeof message.sig !== "string" ||
        !isValidSignature(parsed.key, challengeText(client.nonce, role), message.sig)) {
      return client.socket.close(Close.badHello, "bad hello");
    }
    const id = idOf(parsed.spki);
    const previous = devices[role].get(id);
    if (previous) {
      devices[role].delete(id);
      previous.socket.close(Close.replaced, "connected again");
    }
    Object.assign(client, { role, id, allowed });
    devices[role].set(id, client);
    log(`${role} ${short(id)} online`);
    send(client, { type: "ready", id, ...(options.turn && { turn: turnCredentials(options.turn, id, now()) }) });
  };

  const signal = (client: Client, message: Record<string, unknown>) => {
    const to = message.to;
    if (typeof to !== "string" || typeof message.data !== "object" || message.data === null) {
      return send(client, { type: "error", code: "bad-message" });
    }
    const target = client.role === "phone" ? devices.mac.get(to) : devices.phone.get(to);
    const mac = client.role === "phone" ? target : client;
    const phoneId = client.role === "phone" ? client.id! : to;
    if (!target || !mac?.allowed.has(phoneId)) return send(client, { type: "error", code: "unreachable", to });
    send(target, { type: "signal", from: client.id, data: message.data });
  };

  const handle = (client: Client, message: Record<string, unknown>) => {
    if (!client.id) {
      if (message.type === "hello") return hello(client, message);
      return send(client, { type: "error", code: "not-ready" });
    }
    switch (message.type) {
      case "signal":
        return signal(client, message);
      case "allow": {
        const allowed = client.role === "mac" ? allowList(message.ids) : null;
        if (!allowed) return send(client, { type: "error", code: "bad-message" });
        client.allowed = allowed;
        return;
      }
      case "turn":
        return send(client, { type: "turn", turn: options.turn ? turnCredentials(options.turn, client.id, now()) : null });
      default:
        return send(client, { type: "error", code: "unknown-type" });
    }
  };

  wss.on("connection", (socket: WebSocket, request: IncomingMessage) => {
    const forwarded = options.trustProxy ? String(request.headers["x-forwarded-for"] ?? "").split(",")[0].trim() : "";
    const address = forwarded || request.socket.remoteAddress || "unknown";
    const count = (perAddress.get(address) ?? 0) + 1;
    perAddress.set(address, count);
    const client: Client = {
      socket, address, nonce: randomBytes(16).toString("base64url"),
      allowed: new Set(), window: { start: now(), count: 0 }, alive: true,
    };
    clients.add(client);
    if (count > connectionsPerAddress) socket.close(Close.tooManyConnections, "too many connections");

    const helloTimer = setTimeout(() => {
      if (!client.id) socket.close(Close.helloTimeout, "no hello");
    }, helloTimeoutMs);

    socket.on("pong", () => { client.alive = true; });
    socket.on("message", (data, isBinary) => {
      const time = now();
      if (time - client.window.start >= 60_000) client.window = { start: time, count: 0 };
      if (++client.window.count > messagesPerMinute) return socket.close(Close.tooManyMessages, "too many messages");
      let message: unknown;
      try {
        message = isBinary ? null : JSON.parse(data.toString());
      } catch {
        message = null;
      }
      if (typeof message !== "object" || message === null || Array.isArray(message)) {
        return send(client, { type: "error", code: "bad-message" });
      }
      handle(client, message as Record<string, unknown>);
    });
    socket.on("close", () => {
      clearTimeout(helloTimer);
      clients.delete(client);
      const left = (perAddress.get(address) ?? 1) - 1;
      if (left > 0) perAddress.set(address, left); else perAddress.delete(address);
      if (client.role && client.id && devices[client.role].get(client.id) === client) {
        devices[client.role].delete(client.id);
        log(`${client.role} ${short(client.id)} offline`);
      }
    });

    send(client, { type: "challenge", nonce: client.nonce });
  });

  // Mobile networks drop idle connections silently: ping, and let go of what stops answering.
  const pinger = setInterval(() => {
    for (const client of clients) {
      if (!client.alive) { client.socket.terminate(); continue; }
      client.alive = false;
      client.socket.ping();
    }
  }, options.pingIntervalMs ?? 25_000);

  return {
    close: () => {
      clearInterval(pinger);
      for (const client of clients) client.socket.terminate();
      wss.close();
    },
  };
}
