export type GatewayErrorCode =
  | "auth_required"
  | "rate_limited"
  | "invalid_params"
  | "upstream_error";

export interface GatewayErrorDetails {
  provider?: string;
  alias?: string;
  retryAfter?: number;
}

export class GatewayToolError extends Error {
  readonly code: GatewayErrorCode;
  readonly details: GatewayErrorDetails;

  constructor(message: string, code: GatewayErrorCode, details: GatewayErrorDetails = {}) {
    super(message);
    this.name = "GatewayToolError";
    this.code = code;
    this.details = details;
  }

  toPublicPayload(): Record<string, unknown> {
    return {
      code: this.code,
      message: this.message,
      ...(this.details.provider !== undefined ? { provider: this.details.provider } : {}),
      ...(this.details.alias !== undefined ? { alias: this.details.alias } : {}),
      ...(this.details.retryAfter !== undefined ? { retryAfter: this.details.retryAfter } : {}),
    };
  }
}

export function requireAccountToken(
  cred: { provider: string; alias: string; tokens?: { accessToken?: string }; apiKey?: string },
  prefer: "oauth" | "any" = "any",
): string {
  const token =
    prefer === "oauth"
      ? cred.tokens?.accessToken || cred.apiKey
      : cred.tokens?.accessToken || cred.apiKey;
  if (!token) {
    throw new GatewayToolError(
      `Token for '${cred.provider}:${cred.alias}' is missing or expired. Re-authenticate via CLI or the gateway dashboard.`,
      "auth_required",
      { provider: cred.provider, alias: cred.alias },
    );
  }
  return token;
}

function looksLikeRateLimit(body: string, retryAfter?: number): boolean {
  if (retryAfter !== undefined) return true;
  const lower = body.toLowerCase();
  return (
    lower.includes("rate limit") ||
    lower.includes("ratelimit") ||
    lower.includes("quota") ||
    lower.includes("too many requests") ||
    lower.includes("userRateLimitExceeded".toLowerCase()) ||
    lower.includes("rateLimitExceeded".toLowerCase())
  );
}

export function throwForUpstreamStatus(
  provider: string,
  alias: string,
  status: number,
  body: string,
  serviceLabel: string,
  retryAfter?: number,
): never {
  if (status === 401) {
    throw new GatewayToolError(
      `Token for '${provider}:${alias}' was rejected by ${serviceLabel} (${status}). Re-authenticate via CLI or the gateway dashboard.`,
      "auth_required",
      { provider, alias },
    );
  }
  if (status === 403 && looksLikeRateLimit(body, retryAfter)) {
    throw new GatewayToolError(
      `${serviceLabel} rate limit exceeded (${status}).`,
      "rate_limited",
      { provider, alias, retryAfter },
    );
  }
  if (status === 403) {
    throw new GatewayToolError(
      `${serviceLabel} denied access (${status}): ${body}`,
      "upstream_error",
      { provider, alias },
    );
  }
  if (status === 429) {
    throw new GatewayToolError(
      `${serviceLabel} rate limit exceeded after retries (${status}).`,
      "rate_limited",
      { provider, alias, retryAfter },
    );
  }
  throw new GatewayToolError(
    `${serviceLabel} API error (${status}): ${body}`,
    "upstream_error",
    { provider, alias },
  );
}
