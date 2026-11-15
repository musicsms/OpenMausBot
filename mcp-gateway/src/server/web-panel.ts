import type { AccountCredential } from "../types.ts";

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export function renderDashboardHtml(accounts: AccountCredential[]): string {
  const accountRows = accounts
    .map(
      (a) => `
      <tr>
        <td style="padding: 8px; border: 1px solid #ccc;"><strong>${escapeHtml(a.provider)}</strong></td>
        <td style="padding: 8px; border: 1px solid #ccc;"><code>${escapeHtml(a.alias)}</code></td>
        <td style="padding: 8px; border: 1px solid #ccc;">${a.tokens ? "OAuth2" : "API Key / PAT"}</td>
        <td style="padding: 8px; border: 1px solid #ccc;">${Number.isFinite(a.updatedAt) ? new Date(a.updatedAt).toLocaleString() : "N/A"}</td>
        <td style="padding: 8px; border: 1px solid #ccc;">
          <button data-provider="${escapeHtml(a.provider)}" data-alias="${escapeHtml(a.alias)}" class="delete-btn">Delete</button>
        </td>
      </tr>`,
    )
    .join("");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Unified MCP Gateway Dashboard</title>
  <style>
    body { font-family: system-ui, -apple-system, sans-serif; margin: 40px; background: #fafafa; }
    .card { background: white; padding: 24px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); max-width: 800px; margin: 0 auto; }
    table { width: 100%; border-collapse: collapse; margin-top: 16px; }
    th { text-align: left; padding: 8px; border: 1px solid #ccc; background: #f0f0f0; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Unified MCP Gateway</h1>
    <p>Direct Multi-Account Integrations for OpenMausBot (Port 8318)</p>
    <h2>Connected Accounts</h2>
    <table>
      <thead>
        <tr>
          <th>Provider</th><th>Alias</th><th>Type</th><th>Last Updated</th><th>Actions</th>
        </tr>
      </thead>
      <tbody>
        ${accountRows || '<tr><td colspan="5" style="text-align:center; padding:16px;">No accounts connected yet.</td></tr>'}
      </tbody>
    </table>
  </div>
  <script>
    document.addEventListener('click', async (event) => {
      const target = event.target;
      if (!(target instanceof HTMLElement) || !target.classList.contains('delete-btn')) {
        return;
      }
      const provider = target.dataset.provider;
      const alias = target.dataset.alias;
      if (!provider || !alias) return;
      if (!confirm(\`Delete account \${provider}:\${alias}?\`)) return;
      try {
        const res = await fetch(\`/api/accounts/\${encodeURIComponent(provider)}/\${encodeURIComponent(alias)}\`, {
          method: 'DELETE',
        });
        if (!res.ok) {
          const err = await res.json().catch(() => ({ error: 'Delete failed' }));
          alert(\`Failed to delete account: \${err.error || res.statusText}\`);
          return;
        }
        location.reload();
      } catch (err) {
        alert(\`Failed to delete account: \${err instanceof Error ? err.message : String(err)}\`);
      }
    });
  </script>
</body>
</html>`;
}
