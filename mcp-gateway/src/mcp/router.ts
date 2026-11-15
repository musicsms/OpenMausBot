import type { AccountCredential, ProviderType } from "../types.ts";
import type { GatewayToolDefinition, ServiceAdapter } from "../adapters/base-adapter.ts";

export class McpRouter {
  private readonly adapters: Partial<Record<ProviderType, ServiceAdapter>>;

  constructor(adapters: Partial<Record<ProviderType, ServiceAdapter>>) {
    this.adapters = adapters;
  }

  collectTools(accounts: AccountCredential[]): GatewayToolDefinition[] {
    const tools: GatewayToolDefinition[] = [];
    for (const account of accounts) {
      const adapter = this.adapters[account.provider];
      if (adapter) {
        tools.push(...adapter.getTools(account.alias));
      }
    }
    return tools;
  }

  async executeTool(
    toolName: string,
    args: Record<string, unknown>,
    accounts: AccountCredential[],
  ): Promise<{ text: string }> {
    const tools = this.collectTools(accounts);
    const target = tools.find((t) => t.name === toolName);
    if (!target) {
      throw new Error(`Tool "${toolName}" not found in Unified MCP Gateway.`);
    }

    const firstSep = toolName.indexOf("__");
    const provider = firstSep !== -1 ? toolName.slice(0, firstSep) : toolName;
    const rest = firstSep !== -1 ? toolName.slice(firstSep + 2) : "";

    const account =
      accounts.find((a) => a.provider === provider && rest.startsWith(`${a.alias}__`)) ??
      accounts.find((a) => a.provider === provider && toolName.split("__")[1] === a.alias);

    if (!account) {
      const secondSep = rest.indexOf("__");
      const alias = secondSep !== -1 ? rest.slice(0, secondSep) : rest || "unknown";
      throw new Error(`Account credentials for "${provider}:${alias}" not found in auth storage.`);
    }

    return target.execute(args, account);
  }
}
