// TRON addresses, three ways (copied from vault/tron/lib/address.mjs; the repos do not import each
// other's runners):
//   - EVM form    0x12ee…9823        (what Solidity and ABI encoding use)
//   - TRON hex    4112ee…9823        (0x41 network byte in front; what the HTTP API uses)
//   - base58check T…                  (what wallets and Tronscan show)

import { getAddress, sha256, toBeHex } from "ethers";

const BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/** Any of the three forms → checksummed EVM form. */
export function toEvm(address) {
  if (typeof address !== "string") throw new Error(`not an address: ${address}`);
  if (address.startsWith("T")) return getAddress("0x" + base58CheckDecode(address).slice(2 + 2));
  if (/^41[0-9a-fA-F]{40}$/.test(address)) return getAddress("0x" + address.slice(2));
  return getAddress(address);
}

/** Any form → TRON hex (41…), as the HTTP API takes it. */
export function toTronHex(address) {
  return "41" + toEvm(address).slice(2).toLowerCase();
}

/** Any form → base58check (T…). */
export function toBase58(address) {
  return base58CheckEncode("0x" + toTronHex(address));
}

function base58CheckEncode(hex) {
  const payload = Buffer.from(hex.slice(2), "hex");
  const checksum = Buffer.from(sha256(sha256(payload)).slice(2, 10), "hex");
  let n = BigInt("0x" + Buffer.concat([payload, checksum]).toString("hex"));
  let out = "";
  while (n > 0n) {
    out = BASE58[Number(n % 58n)] + out;
    n /= 58n;
  }
  return out;
}

function base58CheckDecode(text) {
  let n = 0n;
  for (const c of text) {
    const i = BASE58.indexOf(c);
    if (i < 0) throw new Error(`bad base58 character in ${text}`);
    n = n * 58n + BigInt(i);
  }
  const bytes = Buffer.from(toBeHex(n).slice(2), "hex");
  const payload = bytes.subarray(0, bytes.length - 4);
  const checksum = bytes.subarray(bytes.length - 4);
  const expected = Buffer.from(sha256(sha256(payload)).slice(2, 10), "hex");
  if (!checksum.equals(expected)) throw new Error(`bad base58check checksum in ${text}`);
  return "0x" + payload.toString("hex");
}
