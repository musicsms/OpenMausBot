const DEFAULT_MAX_ATTEMPTS = 3;

function parseRetryAfterMs(header: string | null): number | undefined {
  if (!header) return undefined;
  const asSeconds = Number(header);
  if (Number.isFinite(asSeconds) && asSeconds >= 0) {
    return Math.min(asSeconds * 1000, 60_000);
  }
  const asDate = Date.parse(header);
  if (!Number.isNaN(asDate)) {
    return Math.max(0, Math.min(asDate - Date.now(), 60_000));
  }
  return undefined;
}

function backoffMs(attempt: number, retryAfterHeader: string | null): number {
  const fromHeader = parseRetryAfterMs(retryAfterHeader);
  if (fromHeader !== undefined) return fromHeader;
  return Math.min(1000 * 2 ** attempt, 8000);
}

export function readRetryAfterSeconds(res: { headers?: { get?: (name: string) => string | null } }): number | undefined {
  const header = res.headers?.get?.("Retry-After") ?? null;
  const ms = parseRetryAfterMs(header);
  if (ms === undefined) return undefined;
  return Math.ceil(ms / 1000);
}

export async function fetchWith429Retry(
  input: string | URL | Request,
  init?: RequestInit,
  options?: {
    maxAttempts?: number;
    sleep?: (ms: number) => Promise<void>;
    fetchImpl?: typeof fetch;
  },
): Promise<Response> {
  const maxAttempts = options?.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const sleep = options?.sleep ?? ((ms: number) => new Promise((resolve) => setTimeout(resolve, ms)));
  const fetchImpl = options?.fetchImpl ?? globalThis.fetch;

  let lastResponse: Response | undefined;
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    lastResponse = await fetchImpl(input, init);
    if (lastResponse.status !== 429 || attempt === maxAttempts - 1) {
      return lastResponse;
    }
    await sleep(backoffMs(attempt, lastResponse.headers?.get?.("Retry-After") ?? null));
  }
  return lastResponse!;
}
