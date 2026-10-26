import { createHmac } from "node:crypto";

/**
 * Credentials for the TURN relay (coturn with `use-auth-secret`), which carries the encrypted
 * connection when the phone and Mac can't reach each other directly. They're the standard
 * time-limited kind: the relay checks them against the same shared secret, so it needs no user list.
 */
export interface TurnConfig {
  urls: string[];
  secret: string;
  ttlSeconds: number;
}

export interface TurnCredentials {
  urls: string[];
  username: string;
  credential: string;
  expires: number;   // Unix seconds
}

export function turnCredentials(config: TurnConfig, id: string, nowMs: number): TurnCredentials {
  const expires = Math.floor(nowMs / 1000) + config.ttlSeconds;
  const username = `${expires}:${id}`;
  const credential = createHmac("sha1", config.secret).update(username).digest("base64");
  return { urls: config.urls, username, credential, expires };
}
