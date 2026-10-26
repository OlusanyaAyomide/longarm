import { createHash, createPublicKey, verify, type KeyObject } from "node:crypto";

/**
 * A device's identity is its long-term P-256 key, made at pairing: the Mac's in its Keychain, the
 * phone's in the Android Keystore. Its id is the SHA-256 of the public key (SPKI DER), base64url.
 * Signatures are ECDSA with SHA-256, DER-encoded, which is what CryptoKit and Android both produce.
 */

export type Role = "mac" | "phone";

export function idOf(spki: Buffer): string {
  return createHash("sha256").update(spki).digest("base64url");
}

/** The public key from base64 SPKI DER, or null unless it's a P-256 EC key. */
export function parseKey(base64: string): { key: KeyObject; spki: Buffer } | null {
  try {
    const spki = Buffer.from(base64, "base64");
    const key = createPublicKey({ key: spki, format: "der", type: "spki" });
    if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") return null;
    return { key, spki };
  } catch {
    return null;
  }
}

/** What a device signs to prove it holds its key: tied to this connection's nonce and its role. */
export function challengeText(nonce: string, role: Role): Buffer {
  return Buffer.from(`longarm-rendezvous-v1\n${nonce}\n${role}`, "utf8");
}

export function isValidSignature(key: KeyObject, data: Buffer, base64Signature: string): boolean {
  try {
    return verify("sha256", data, { key, dsaEncoding: "der" }, Buffer.from(base64Signature, "base64"));
  } catch {
    return false;
  }
}
