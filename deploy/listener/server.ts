import { spawn, spawnSync } from "node:child_process";
import { createHmac, timingSafeEqual } from "node:crypto";
import { closeSync, mkdtempSync, openSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const DEPLOY_SECRET = Buffer.from(resolveSecret(), "utf8");
const HOST = process.env.DEPLOY_LISTENER_HOST ?? "0.0.0.0";
const PORT = Number.parseInt(process.env.DEPLOY_LISTENER_PORT ?? "8081", 10);
const LOG_PATH = process.env.DEPLOY_LISTENER_LOG ?? "/tmp/deploy-listener.log";

function resolveSecret(): string {
  const inlineSecret = process.env.DEPLOY_WEBHOOK_SECRET?.trim();
  if (inlineSecret) {
    return inlineSecret;
  }

  const opPath = process.env.DEPLOY_WEBHOOK_SECRET_OP_PATH?.trim();
  if (!opPath) {
    throw new Error("DEPLOY_WEBHOOK_SECRET or DEPLOY_WEBHOOK_SECRET_OP_PATH is required");
  }

  const result = spawnSync("op", ["read", opPath], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || "failed to read DEPLOY_WEBHOOK_SECRET_OP_PATH");
  }

  return result.stdout.trim();
}

function readBody(request: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];

    request.on("data", (chunk) => {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    });
    request.on("end", () => {
      resolve(Buffer.concat(chunks));
    });
    request.on("error", reject);
  });
}

function sendJson(response: ServerResponse, statusCode: number, payload: object): void {
  const body = Buffer.from(JSON.stringify(payload), "utf8");

  response.writeHead(statusCode, {
    "Content-Length": body.byteLength,
    "Content-Type": "application/json",
  });
  response.end(body);
}

function validSignature(signature: string, body: Buffer): boolean {
  const expected = `sha256=${createHmac("sha256", DEPLOY_SECRET).update(body).digest("hex")}`;
  const signatureBuffer = Buffer.from(signature, "utf8");
  const expectedBuffer = Buffer.from(expected, "utf8");

  if (signatureBuffer.byteLength !== expectedBuffer.byteLength) {
    return false;
  }

  return timingSafeEqual(signatureBuffer, expectedBuffer);
}

function launchDeploy(body: Buffer): void {
  const payloadDirectory = mkdtempSync(join(tmpdir(), "dailywerk-deploy-"));
  const payloadPath = join(payloadDirectory, "payload.json");

  writeFileSync(payloadPath, body);

  const logFileDescriptor = openSync(LOG_PATH, "a");

  try {
    const child = spawn("/deploy/scripts/perform-deploy.sh", [payloadPath], {
      detached: true,
      stdio: ["ignore", logFileDescriptor, logFileDescriptor],
    });

    child.unref();
  } finally {
    closeSync(logFileDescriptor);
  }
}

async function handleRequest(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const path = new URL(request.url ?? "/", "http://deploy-listener.local").pathname;

  if (request.method === "GET") {
    if (path === "/up" || path === "/ready") {
      sendJson(response, 200, { status: "ok" });
      return;
    }

    sendJson(response, 404, { error: "Not Found" });
    return;
  }

  if (request.method !== "POST" || path !== "/deploy") {
    sendJson(response, 404, { error: "Not Found" });
    return;
  }

  const body = await readBody(request);
  const signature = request.headers["x-dailywerk-signature"];
  const headerValue = Array.isArray(signature) ? signature[0] : signature ?? "";

  if (!validSignature(headerValue, body)) {
    sendJson(response, 401, { error: "invalid signature" });
    return;
  }

  try {
    JSON.parse(body.toString("utf8"));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    sendJson(response, 400, { error: `invalid JSON payload: ${message}` });
    return;
  }

  try {
    launchDeploy(body);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    sendJson(response, 500, { error: message });
    return;
  }

  sendJson(response, 202, { status: "accepted" });
}

const server = createServer((request, response) => {
  void handleRequest(request, response).catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    sendJson(response, 500, { error: message });
  });
});

server.listen(PORT, HOST);
