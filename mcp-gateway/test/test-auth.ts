export const TEST_INTERNAL_KEY = "test-gateway-internal-key";

export function authHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return {
    Authorization: `Bearer ${TEST_INTERNAL_KEY}`,
    ...extra,
  };
}

export function sseAuthOptions(): { requestInit: { headers: Record<string, string> } } {
  return {
    requestInit: {
      headers: authHeaders(),
    },
  };
}
