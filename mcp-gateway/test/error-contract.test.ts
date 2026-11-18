import { describe, it, expect, vi, afterEach } from "vitest";
import { GatewayToolError } from "../src/errors.ts";
import { fetchWith429Retry, readRetryAfterSeconds } from "../src/http-retry.ts";
import { parseToolArgs, gmailSendSchema } from "../src/tool-args.ts";
import { GoogleAdapter } from "../src/adapters/google-adapter.ts";
import type { AccountCredential } from "../src/types.ts";

describe("Error contract helpers", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("parseToolArgs throws invalid_params for bad input", () => {
    expect(() => parseToolArgs(gmailSendSchema, { to: "", subject: "S", body: "B" })).toThrow(
      GatewayToolError,
    );
    try {
      parseToolArgs(gmailSendSchema, { subject: "S", body: "B" });
    } catch (err) {
      expect(err).toBeInstanceOf(GatewayToolError);
      expect((err as GatewayToolError).code).toBe("invalid_params");
    }
  });

  it("retries upstream 429 responses up to the attempt budget", async () => {
    const sleep = vi.fn().mockResolvedValue(undefined);
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(new Response("slow", { status: 429, headers: { "Retry-After": "1" } }))
      .mockResolvedValueOnce(new Response("slow", { status: 429, headers: { "Retry-After": "1" } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 200 }));

    const res = await fetchWith429Retry("https://example.test", undefined, {
      maxAttempts: 3,
      sleep,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(res.status).toBe(200);
    expect(fetchImpl).toHaveBeenCalledTimes(3);
    expect(sleep).toHaveBeenCalledTimes(2);
    expect(sleep.mock.calls[0][0]).toBe(1000);
  });

  it("surfaces rate_limited after exhausting 429 retries", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn().mockResolvedValue(
      new Response("too many", { status: 429, headers: { "Retry-After": "1" } }),
    );
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const adapter = new GoogleAdapter();
    const tool = adapter.getTools("work").find((t) => t.name === "google__work__gmail_search")!;
    const cred: AccountCredential = {
      provider: "google",
      alias: "work",
      createdAt: 1,
      updatedAt: 1,
      tokens: { accessToken: "tok" },
    };

    const pending = tool.execute({ query: "is:unread" }, cred);
    const expectation = expect(pending).rejects.toMatchObject({
      code: "rate_limited",
      details: { provider: "google", alias: "work", retryAfter: 1 },
    });
    await vi.runAllTimersAsync();
    await expectation;
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it("reads Retry-After seconds from responses", () => {
    const res = new Response("", { status: 429, headers: { "Retry-After": "7" } });
    expect(readRetryAfterSeconds(res)).toBe(7);
  });
});
