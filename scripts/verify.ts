/**
 * Chui Protocol — 訂單結算驗證工具。
 *
 * 給定訂單明細（任意 JSON）與 salt，重算 order_digest，
 * 然後查詢鏈上 SettlementRegistry，比對這筆訂單是否已結算。
 *
 * digest 演算法（協定規格，詳見 SPEC.md）：
 *   order_digest = SHA-256( salt_bytes || canonical_json_utf8_bytes )
 *   - salt：32-byte 隨機值（hex 表示，可帶 0x 前綴）
 *   - canonical JSON：物件鍵依 Unicode code point 遞增排序、無空白、
 *     僅允許整數數值（金額一律用整數最小單位，禁止浮點數）
 *
 * 用法：
 *   node --experimental-strip-types scripts/verify.ts \
 *     --order order.json --salt <64位hex> [--network testnet] [--amount <u64>] \
 *     [--digest-only true]
 *
 * --digest-only true 時只計算並輸出 digest，不查詢鏈上狀態
 * （chui-app 送出結算交易前產生 order_digest 也可以直接用這個模式）。
 *
 * 結束碼：0 = 已結算（或 digest-only 完成）、2 = 未結算、1 = 錯誤。
 */

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ===== 參數解析 =====

interface Args {
  order: string;
  salt: string;
  network: string;
  amount?: bigint;
  digestOnly: boolean;
}

function parseArgs(argv: string[]): Args {
  const args: Record<string, string> = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error(`參數格式錯誤：${key ?? "(空)"}`);
    }
    args[key.slice(2)] = value;
  }
  if (!args.order || !args.salt) {
    throw new Error(
      "用法：verify.ts --order <訂單JSON路徑> --salt <64位hex> [--network testnet] [--amount <u64>]",
    );
  }
  return {
    order: args.order,
    salt: args.salt,
    network: args.network ?? "testnet",
    amount: args.amount !== undefined ? BigInt(args.amount) : undefined,
    digestOnly: args["digest-only"] === "true",
  };
}

// ===== 正規化 JSON（RFC 8785 子集）=====

/** 遞迴檢查並序列化：物件鍵排序、無空白、僅允許整數數值。 */
function canonicalize(value: unknown): string {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) {
      throw new Error(`訂單 JSON 內出現非整數數值：${value}（金額必須用整數最小單位）`);
    }
    return String(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([k, v]) => `${JSON.stringify(k)}:${canonicalize(v)}`);
    return `{${entries.join(",")}}`;
  }
  throw new Error(`訂單 JSON 內出現不支援的型別：${typeof value}`);
}

function hexToBytes(hex: string): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (!/^[0-9a-fA-F]*$/.test(clean) || clean.length % 2 !== 0) {
    throw new Error(`不是合法的 hex 字串：${hex}`);
  }
  return Uint8Array.from(Buffer.from(clean, "hex"));
}

/** 協定規格的 digest：SHA-256( salt || canonical_json ) */
export function computeOrderDigest(order: unknown, saltHex: string): Uint8Array {
  const salt = hexToBytes(saltHex);
  if (salt.length !== 32) {
    throw new Error(`salt 必須是 32 bytes（64 個 hex 字元），目前是 ${salt.length} bytes`);
  }
  const canonical = Buffer.from(canonicalize(order), "utf8");
  return Uint8Array.from(
    createHash("sha256").update(salt).update(canonical).digest(),
  );
}

/** 與鏈上 chui::settlement::amount_bucket 相同的對數級距 */
export function amountBucket(amount: bigint): number {
  if (amount < 1n) throw new Error("amount 必須 ≥ 1");
  let k = 0;
  let v = amount;
  while (v > 1n) {
    v >>= 1n;
    k += 1;
  }
  return k;
}

// ===== Sui JSON-RPC =====

async function rpc(url: string, method: string, params: unknown[]): Promise<any> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!res.ok) throw new Error(`RPC HTTP ${res.status}（${method}）`);
  const body = (await res.json()) as { result?: unknown; error?: { message: string } };
  if (body.error) throw new Error(`RPC 錯誤（${method}）：${body.error.message}`);
  return body.result;
}

/** 讀取 SettlementRegistry 物件，取得內部 Table 的物件 ID */
async function fetchRegistryTableId(url: string, registryId: string): Promise<string> {
  const result = await rpc(url, "sui_getObject", [
    registryId,
    { showContent: true },
  ]);
  const fields = result?.data?.content?.fields;
  const tableId = fields?.settled?.fields?.id?.id;
  if (!tableId) {
    throw new Error(`無法從 SettlementRegistry（${registryId}）解析出 Table 物件 ID`);
  }
  return tableId;
}

/** 查詢 digest 是否存在於 Table 的 dynamic field 中 */
async function isSettledOnChain(
  url: string,
  tableId: string,
  digest: Uint8Array,
): Promise<boolean> {
  // vector<u8> 的 dynamic field name 值：先試數字陣列，再退回 0x hex 字串
  const candidates: unknown[] = [
    Array.from(digest),
    "0x" + Buffer.from(digest).toString("hex"),
  ];
  let lastError: Error | null = null;
  for (const value of candidates) {
    try {
      const result = await rpc(url, "suix_getDynamicFieldObject", [
        tableId,
        { type: "vector<u8>", value },
      ]);
      if (result?.error?.code === "dynamicFieldNotFound") return false;
      if (result?.data?.objectId) return true;
      // 其他形狀視為未找到
      return false;
    } catch (e) {
      lastError = e as Error;
    }
  }
  throw lastError ?? new Error("dynamic field 查詢失敗");
}

// ===== 主流程 =====

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  const order = JSON.parse(readFileSync(resolve(args.order), "utf8"));
  const digest = computeOrderDigest(order, args.salt);
  const digestHex = "0x" + Buffer.from(digest).toString("hex");

  console.log(`order_digest：${digestHex}`);
  if (args.amount !== undefined) {
    console.log(`amount：      ${args.amount}（事件中應出現 amount_bucket = ${amountBucket(args.amount)}）`);
  }
  if (args.digestOnly) return;

  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const deploymentPath = resolve(repoRoot, `deployments/${args.network}.json`);
  const deployment = JSON.parse(readFileSync(deploymentPath, "utf8")) as {
    rpc: string;
    settlementRegistryId: string;
  };
  console.log(`網路：        ${args.network}`);
  console.log(`RPC：         ${deployment.rpc}`);

  const tableId = await fetchRegistryTableId(deployment.rpc, deployment.settlementRegistryId);
  const settled = await isSettledOnChain(deployment.rpc, tableId, digest);

  if (settled) {
    console.log("結果：        ✅ 這筆訂單「已」在鏈上結算");
    process.exit(0);
  } else {
    console.log("結果：        ❌ 這筆訂單「尚未」在鏈上結算");
    process.exit(2);
  }
}

main().catch((e: Error) => {
  console.error(`錯誤：${e.message}`);
  process.exit(1);
});
