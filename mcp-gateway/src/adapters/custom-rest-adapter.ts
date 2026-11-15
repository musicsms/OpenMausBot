import { readFileSync } from "node:fs";
import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential, ProviderType } from "../types.ts";

export interface CustomEndpointSpec {
  name: string;
  description: string;
  endpoint: string;
  method: "GET" | "POST" | "PUT" | "DELETE" | "PATCH";
  queryParameters?: string[];
  bodyParameters?: string[];
  headers?: Record<string, string>;
}

function cleanYamlValue(val: string): unknown {
  const v = val.trim();
  if (v.startsWith("[") && v.endsWith("]")) {
    return v
      .slice(1, -1)
      .split(",")
      .map((s) => s.trim().replace(/^['"]|['"]$/g, ""))
      .filter(Boolean);
  }
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
    return v.slice(1, -1);
  }
  if (v === "true") return true;
  if (v === "false") return false;
  return v;
}

function parseYamlOrJson(text: string): CustomEndpointSpec[] {
  const trimmed = text.trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    const parsed = JSON.parse(trimmed) as CustomEndpointSpec | CustomEndpointSpec[];
    return Array.isArray(parsed) ? parsed : [parsed];
  }

  const lines = trimmed.split("\n");
  const items: Array<Record<string, unknown>> = [];
  let current: Record<string, unknown> | null = null;
  let currentArrayKey: string | null = null;

  for (let rawLine of lines) {
    const commentIdx = rawLine.indexOf("#");
    if (commentIdx !== -1) {
      rawLine = rawLine.slice(0, commentIdx);
    }
    const line = rawLine.trim();
    if (!line) continue;

    if (line.startsWith("- ")) {
      const rest = line.slice(2).trim();
      if (rest.includes(":")) {
        current = {};
        items.push(current);
        currentArrayKey = null;
        const colonIdx = rest.indexOf(":");
        const key = rest.slice(0, colonIdx).trim();
        const val = rest.slice(colonIdx + 1).trim();
        if (val) {
          current[key] = cleanYamlValue(val);
        } else {
          currentArrayKey = key;
          current[key] = [];
        }
      } else if (current && currentArrayKey && Array.isArray(current[currentArrayKey])) {
        (current[currentArrayKey] as string[]).push(cleanYamlValue(rest) as string);
      }
    } else if (line.includes(":")) {
      const colonIdx = line.indexOf(":");
      const key = line.slice(0, colonIdx).trim();
      const val = line.slice(colonIdx + 1).trim();
      if (!current) {
        current = {};
        items.push(current);
      }
      if (val) {
        current[key] = cleanYamlValue(val);
        currentArrayKey = null;
      } else {
        currentArrayKey = key;
        current[key] = [];
      }
    } else if (current && currentArrayKey && line.startsWith("-")) {
      const val = line.replace(/^-\s*/, "");
      (current[currentArrayKey] as string[]).push(cleanYamlValue(val) as string);
    }
  }

  return items as unknown as CustomEndpointSpec[];
}

export class CustomRestAdapter implements ServiceAdapter {
  readonly provider: ProviderType | string = "custom";
  private readonly specs: CustomEndpointSpec[];

  constructor(specs: CustomEndpointSpec[] = []) {
    this.specs = specs;
  }

  static fromJson(jsonStr: string): CustomRestAdapter {
    const data = JSON.parse(jsonStr) as CustomEndpointSpec | CustomEndpointSpec[];
    const specs = Array.isArray(data) ? data : [data];
    return new CustomRestAdapter(specs);
  }

  static fromYaml(yamlStr: string): CustomRestAdapter {
    return new CustomRestAdapter(parseYamlOrJson(yamlStr));
  }

  static fromFile(filePath: string): CustomRestAdapter {
    const content = readFileSync(filePath, "utf-8");
    return new CustomRestAdapter(parseYamlOrJson(content));
  }

  getTools(alias: string): GatewayToolDefinition[] {
    return this.specs.map((spec) => ({
      name: `custom__${alias}__${spec.name}`,
      description: spec.description,
      parameters: {
        type: "object",
        properties: {
          ...spec.queryParameters?.reduce(
            (acc, q) => ({ ...acc, [q]: { type: "string" } }),
            {} as Record<string, { type: string }>,
          ),
          ...spec.bodyParameters?.reduce(
            (acc, b) => ({ ...acc, [b]: { type: "string" } }),
            {} as Record<string, { type: string }>,
          ),
        },
      },
      execute: async (args, cred: AccountCredential) => {
        const token = cred.apiKey || cred.tokens?.accessToken;
        const headers: Record<string, string> = {
          "Content-Type": "application/json",
          ...spec.headers,
        };
        if (token) {
          headers["Authorization"] = `Bearer ${token}`;
        }

        let url = spec.endpoint;
        if (spec.queryParameters?.length) {
          const params = new URLSearchParams();
          for (const q of spec.queryParameters) {
            if (args[q] !== undefined && args[q] !== null) {
              params.append(q, String(args[q]));
            }
          }
          const qs = params.toString();
          if (qs) {
            url += (url.includes("?") ? "&" : "?") + qs;
          }
        }

        let body: string | undefined = undefined;
        if (spec.method !== "GET") {
          if (spec.bodyParameters?.length) {
            const bodyObj: Record<string, unknown> = {};
            for (const b of spec.bodyParameters) {
              if (args[b] !== undefined) {
                bodyObj[b] = args[b];
              }
            }
            body = JSON.stringify(bodyObj);
          } else if (Object.keys(args).length > 0) {
            body = JSON.stringify(args);
          }
        }

        const res = await fetch(url, {
          method: spec.method,
          headers,
          body,
        });

        if (!res.ok) {
          throw new Error(`Custom API returned status ${res.status}: ${await res.text()}`);
        }
        return { text: await res.text() };
      },
    }));
  }
}
