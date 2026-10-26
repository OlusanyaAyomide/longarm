import assert from "node:assert/strict";
import { createHmac, generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, test } from "node:test";
import { WebSocket } from "ws";
import { challengeText, idOf, type Role } from "../src/identity.ts";
import { Close, startRendezvous } from "../src/rendezvous.ts";

const turn = { urls: ["turn:relay.test:3478"], secret: "s".repeat(32), ttlSeconds: 600 };
let server: Server;
let rendezvous: { close: () => void };
let url: string;

before(async () => {
  server = createServer();
  rendezvous = startRendezvous(server, { turn, messagesPerMinute: 30, connectionsPerAddress: 20, log: () => {} });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  url = `ws://127.0.0.1:${(server.address() as AddressInfo).port}/v1`;
});

after(() => {
  rendezvous.close();
  server.closeAllConnections();
  server.close();
});

class Device {
  readonly key: KeyObject;
  readonly spki: Buffer;
  readonly id: string;
  socket!: WebSocket;
  private inbox: any[] = [];
  private waiting: ((message: any) => void)[] = [];
  /** Resolves with the close code of the current connection. */
  closed!: Promise<number>;

  constructor() {
    const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    this.key = pair.privateKey;
    this.spki = pair.publicKey.export({ format: "der", type: "spki" });
    this.id = idOf(this.spki);
  }

  async open(): Promise<string> {
    this.socket = new WebSocket(url);
    this.socket.on("message", (data) => {
      const message = JSON.parse(data.toString());
      const waiter = this.waiting.shift();
      if (waiter) waiter(message); else this.inbox.push(message);
    });
    const socket = this.socket;
    this.closed = new Promise((resolve) => socket.on("close", resolve));
    const challenge = await this.next();
    assert.equal(challenge.type, "challenge");
    return challenge.nonce;
  }

  next(): Promise<any> {
    const queued = this.inbox.shift();
    if (queued) return Promise.resolve(queued);
    return new Promise((resolve) => this.waiting.push(resolve));
  }

  send(message: object) {
    this.socket.send(JSON.stringify(message));
  }

  signature(nonce: string, role: Role): string {
    return sign("sha256", challengeText(nonce, role), { key: this.key, dsaEncoding: "der" }).toString("base64");
  }

  /** Connects and proves its key; returns the ready message. */
  async join(role: Role, allow: string[] = []): Promise<any> {
    const nonce = await this.open();
    this.send({ type: "hello", role, key: this.spki.toString("base64"), sig: this.signature(nonce, role), ...(role === "mac" && { allow }) });
    return this.next();
  }
}

test("a device that proves its key gets its id and relay credentials", async () => {
  const mac = new Device();
  const ready = await mac.join("mac");
  assert.equal(ready.type, "ready");
  assert.equal(ready.id, mac.id);
  assert.deepEqual(ready.turn.urls, turn.urls);
  const [expires, id] = ready.turn.username.split(":");
  assert.equal(id, mac.id);
  assert.ok(Number(expires) > Date.now() / 1000);
  assert.equal(ready.turn.credential, createHmac("sha1", turn.secret).update(ready.turn.username).digest("base64"));
  mac.socket.close();
});

test("a signature over someone else's nonce or role is refused", async () => {
  const device = new Device();
  const nonce = await device.open();
  device.send({ type: "hello", role: "mac", key: device.spki.toString("base64"), sig: device.signature(nonce, "phone") });
  assert.equal(await device.closed, Close.badHello);

  const thief = new Device();
  await thief.open();
  const victim = new Device();
  thief.send({ type: "hello", role: "phone", key: victim.spki.toString("base64"), sig: thief.signature("other", "phone") });
  assert.equal(await thief.closed, Close.badHello);
});

test("only phones the Mac lists can reach it, and it only them", async () => {
  const phone = new Device();
  const stranger = new Device();
  const mac = new Device();
  await mac.join("mac", [phone.id]);
  await phone.join("phone");
  await stranger.join("phone");

  phone.send({ type: "signal", to: mac.id, data: { offer: 1 } });
  assert.deepEqual(await mac.next(), { type: "signal", from: phone.id, data: { offer: 1 } });
  mac.send({ type: "signal", to: phone.id, data: { answer: 2 } });
  assert.deepEqual(await phone.next(), { type: "signal", from: mac.id, data: { answer: 2 } });

  // To a phone it doesn't list, the Mac looks the same as one that's offline.
  stranger.send({ type: "signal", to: mac.id, data: { offer: 3 } });
  assert.deepEqual(await stranger.next(), { type: "error", code: "unreachable", to: mac.id });
  stranger.send({ type: "signal", to: new Device().id, data: {} });
  assert.equal((await stranger.next()).code, "unreachable");
  mac.send({ type: "signal", to: stranger.id, data: {} });
  assert.equal((await mac.next()).code, "unreachable");

  // Taking a phone off the list cuts it off.
  mac.send({ type: "allow", ids: [] });
  phone.send({ type: "signal", to: mac.id, data: {} });
  assert.equal((await phone.next()).code, "unreachable");

  for (const device of [mac, phone, stranger]) device.socket.close();
});

test("a phone can't claim to be a Mac's allow list, or send it a list", async () => {
  const phone = new Device();
  await phone.join("phone");
  phone.send({ type: "allow", ids: [phone.id] });
  assert.equal((await phone.next()).code, "bad-message");
  phone.socket.close();
});

test("the same device connecting again replaces its old connection", async () => {
  const mac = new Device();
  await mac.join("mac");
  const first = mac.socket;
  const firstClosed = mac.closed;
  await mac.join("mac");
  assert.equal(await firstClosed, Close.replaced);
  assert.notEqual(first, mac.socket);
  mac.socket.close();
});

test("nothing is passed along before hello", async () => {
  const device = new Device();
  await device.open();
  device.send({ type: "signal", to: "x", data: {} });
  assert.equal((await device.next()).code, "not-ready");
  device.socket.close();
});

test("a flood of messages closes the connection", async () => {
  const phone = new Device();
  await phone.join("phone");
  for (let i = 0; i < 40; i++) phone.send({ type: "turn" });
  assert.equal(await phone.closed, Close.tooManyMessages);
});
