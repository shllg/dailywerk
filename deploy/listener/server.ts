import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHmac, timingSafeEqual } from "node:crypto";
import { closeSync, mkdtempSync, openSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const DEPLOY_SECRET = Buffer.from(resolveSecret(), "utf8");
const HOST = process.env.DEPLOY_LISTENER_HOST ?? "0.0.0.0";
const PORT = Number.parseInt(process.env.DEPLOY_LISTENER_PORT ?? "8081", 10);
const LOG_PATH = process.env.DEPLOY_LISTENER_LOG ?? "/tmp/deploy-listener.log";

interface DeployPayload {
  environment: string;
  api_image: string;
  frontend_image: string;
  build_sha: string;
  build_ref: string;
}

function log(event: string, fields: Record<string, unknown> = {}): void {
  const entry = { ts: new Date().toISOString(), event, ...fields };
  process.stdout.write(`${JSON.stringify(entry)}\n`);
}

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

function launchDeploy(payload: DeployPayload, body: Buffer): void {
  const payloadDirectory = mkdtempSync(join(tmpdir(), "dailywerk-deploy-"));
  const payloadPath = join(payloadDirectory, "payload.json");

  writeFileSync(payloadPath, body);

  // Truncate the deploy log at the start of each deploy to prevent unbounded growth.
  const logFileDescriptor = openSync(LOG_PATH, "w");

  const { environment, build_sha } = payload;

  let child: ChildProcess;

  try {
    child = spawn("/deploy/scripts/perform-deploy.sh", [payloadPath], {
      stdio: ["ignore", logFileDescriptor, logFileDescriptor],
    });
  } finally {
    closeSync(logFileDescriptor);
  }

  log("deploy_started", { environment, build_sha, pid: child.pid });

  child.on("exit", (code, signal) => {
    if (code === 0) {
      log("deploy_finished", { environment, build_sha, exit_code: 0 });
    } else {
      log("deploy_failed", { environment, build_sha, exit_code: code, signal });
    }
  });

  child.on("error", (error) => {
    log("deploy_error", { environment, build_sha, error: error.message });
  });
}

function remoteIp(request: IncomingMessage): string {
  const forwarded = request.headers["x-forwarded-for"];
  if (forwarded) {
    const first = Array.isArray(forwarded) ? forwarded[0] : forwarded.split(",")[0];
    return first.trim();
  }
  return request.socket.remoteAddress ?? "unknown";
}

async function handleRequest(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const start = Date.now();
  const path = new URL(request.url ?? "/", "http://deploy-listener.local").pathname;
  const method = request.method ?? "UNKNOWN";
  const ip = remoteIp(request);

  if (method === "GET") {
    if (path === "/up" || path === "/ready") {
      sendJson(response, 200, { status: "ok" });
      return;
    }

    log("request", { method, path, status: 404, ip, duration_ms: Date.now() - start });
    sendJson(response, 404, { error: "Not Found" });
    return;
  }

  if (method !== "POST" || path !== "/deploy") {
    log("request", { method, path, status: 404, ip, duration_ms: Date.now() - start });
    sendJson(response, 404, { error: "Not Found" });
    return;
  }

  const body = await readBody(request);
  const signature = request.headers["x-dailywerk-signature"];
  const headerValue = Array.isArray(signature) ? signature[0] : signature ?? "";

  if (!validSignature(headerValue, body)) {
    log("signature_invalid", { method, path, status: 401, ip, duration_ms: Date.now() - start });
    sendJson(response, 401, { error: "invalid signature" });
    return;
  }

  let payload: DeployPayload;

  try {
    payload = JSON.parse(body.toString("utf8"));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log("request", { method, path, status: 400, ip, error: message, duration_ms: Date.now() - start });
    sendJson(response, 400, { error: `invalid JSON payload: ${message}` });
    return;
  }

  try {
    launchDeploy(payload, body);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log("deploy_launch_error", { method, path, status: 500, ip, error: message, duration_ms: Date.now() - start });
    sendJson(response, 500, { error: message });
    return;
  }

  log("request", {
    method,
    path,
    status: 202,
    ip,
    environment: payload.environment,
    build_sha: payload.build_sha,
    duration_ms: Date.now() - start,
  });
  sendJson(response, 202, { status: "accepted" });
}

const server = createServer((request, response) => {
  void handleRequest(request, response).catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    log("unhandled_error", { error: message });
    sendJson(response, 500, { error: message });
  });
});

server.listen(PORT, HOST, () => {
  log("server_started", { host: HOST, port: PORT });
});
