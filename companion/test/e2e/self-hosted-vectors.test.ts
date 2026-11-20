import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { describe, it } from "vitest";
import assert from "node:assert/strict";
import { isValidSelfHostedHost } from "../../src/e2e/descriptor.ts";

describe("self-hosted relay vectors", () => {
  it("matches pinned sha256 checksum", () => {
    const jsonBytes = readFileSync("companion/src/e2e/vectors/self-hosted.json");
    const expected = readFileSync("companion/src/e2e/vectors/self-hosted.sha256", "utf8").trim();
    const actual = createHash("sha256").update(jsonBytes).digest("hex");
    assert.equal(actual, expected);
  });

  it("validates self-hosted hostnames per vector", () => {
    const vectors = JSON.parse(readFileSync("companion/src/e2e/vectors/self-hosted.json", "utf8"));
    for (const item of vectors.hosts) {
      assert.equal(isValidSelfHostedHost(item.host), item.valid, `failed for host: ${item.host}`);
    }
  });
});
