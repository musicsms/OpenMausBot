import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    env: {
      GATEWAY_INTERNAL_KEY: "test-gateway-internal-key",
    },
  },
});
