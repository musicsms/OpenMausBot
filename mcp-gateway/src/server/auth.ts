import { timingSafeEqual } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";

export function checkBearerAuthorization(
  authorizationHeader: string | string[] | undefined,
  expectedKey: string,
): boolean {
  if (!expectedKey || typeof authorizationHeader !== "string") {
    return false;
  }

  const match = /^Bearer\s+(\S+)$/i.exec(authorizationHeader.trim());
  if (!match) {
    return false;
  }

  const provided = Buffer.from(match[1]);
  const expected = Buffer.from(expectedKey);
  if (provided.length !== expected.length) {
    return false;
  }
  return timingSafeEqual(provided, expected);
}

export function requireBearerAuth(
  req: IncomingMessage,
  res: ServerResponse,
  internalKey: string,
): boolean {
  if (checkBearerAuthorization(req.headers.authorization, internalKey)) {
    return true;
  }
  res.writeHead(401, {
    "Content-Type": "application/json",
    "WWW-Authenticate": 'Bearer realm="mcp-gateway"',
  });
  res.end(JSON.stringify({ error: "Unauthorized" }));
  return false;
}
