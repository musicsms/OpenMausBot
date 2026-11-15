import type { AccountCredential, ProviderType } from "../types.ts";

export interface GatewayToolDefinition {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  execute: (args: Record<string, unknown>, cred: AccountCredential) => Promise<{ text: string }>;
}

export interface ServiceAdapter {
  readonly provider: ProviderType | string;
  getTools(alias: string): GatewayToolDefinition[];
}
