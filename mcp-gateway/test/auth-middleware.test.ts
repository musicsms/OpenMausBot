import { describe, it, expect } from "vitest";
import { checkBearerAuthorization } from "../src/server/auth.ts";
import { toPublicAccount } from "../src/server/account-public.ts";

describe("Bearer auth helper", () => {
  it("accepts a matching Bearer token", () => {
    expect(checkBearerAuthorization("Bearer secret-key", "secret-key")).toBe(true);
    expect(checkBearerAuthorization("bearer secret-key", "secret-key")).toBe(true);
  });

  it("rejects missing, malformed, or mismatched credentials", () => {
    expect(checkBearerAuthorization(undefined, "secret-key")).toBe(false);
    expect(checkBearerAuthorization("Basic secret-key", "secret-key")).toBe(false);
    expect(checkBearerAuthorization("Bearer wrong", "secret-key")).toBe(false);
    expect(checkBearerAuthorization("Bearer secret-key", "")).toBe(false);
  });
});

describe("Public account redaction", () => {
  it("exposes metadata flags without secret material", () => {
    const publicAccount = toPublicAccount({
      provider: "github",
      alias: "dev",
      apiKey: "ghp_secret",
      tokens: {
        accessToken: "access",
        refreshToken: "refresh",
        expiresAt: 123,
        tokenType: "Bearer",
        scope: "repo",
      },
      createdAt: 1,
      updatedAt: 2,
    });

    expect(publicAccount).toEqual({
      provider: "github",
      alias: "dev",
      createdAt: 1,
      updatedAt: 2,
      hasApiKey: true,
      hasTokens: true,
      tokenExpiresAt: 123,
      tokenType: "Bearer",
      tokenScope: "repo",
    });
    expect(JSON.stringify(publicAccount)).not.toContain("ghp_secret");
    expect(JSON.stringify(publicAccount)).not.toContain("access");
    expect(JSON.stringify(publicAccount)).not.toContain("refresh");
  });
});
