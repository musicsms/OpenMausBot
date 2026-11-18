import type { AccountCredential } from "../types.ts";

export function escapeHtml(value: string): string {
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
    .connect { margin-top: 24px; padding-top: 16px; border-top: 1px solid #eee; }
    .connect label { display: block; margin-bottom: 8px; }
    .connect input { padding: 6px 8px; margin-right: 8px; }
    .status { margin-top: 12px; color: #444; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Unified MCP Gateway</h1>
    <p>Local multi-account OAuth gateway for OpenMausBot (loopback; bearer required on API)</p>
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
    <div class="connect">
      <h2>Connect Google</h2>
      <p>Starts a loopback OAuth consent flow. Requires <code>GOOGLE_CLIENT_ID</code> and <code>GOOGLE_CLIENT_SECRET</code> on the gateway process.</p>
      <label>
        Alias
        <input id="google-alias" type="text" value="default" />
      </label>
      <button id="connect-google" type="button">Connect Google</button>
      <p id="oauth-status" class="status"></p>
    </div>
  </div>
  <script>
    document.addEventListener('click', async (event) => {
      const target = event.target;
      if (!(target instanceof HTMLElement)) return;

      if (target.classList.contains('delete-btn')) {
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
        return;
      }

      if (target.id === 'connect-google') {
        const aliasInput = document.getElementById('google-alias');
        const statusEl = document.getElementById('oauth-status');
        const alias = aliasInput instanceof HTMLInputElement ? aliasInput.value.trim() || 'default' : 'default';
        if (statusEl) statusEl.textContent = 'Starting Google OAuth…';
        try {
          const res = await fetch('/api/oauth/google/start', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ alias }),
          });
          const data = await res.json().catch(() => ({}));
          if (!res.ok) {
            if (statusEl) statusEl.textContent = data.error || 'Failed to start OAuth';
            return;
          }
          if (data.authorizeUrl) {
            window.open(data.authorizeUrl, '_blank', 'noopener,noreferrer');
          }
          if (statusEl) statusEl.textContent = 'Complete consent in the opened window. Waiting…';
          const sessionId = data.sessionId;
          if (!sessionId) return;
          for (let i = 0; i < 60; i++) {
            await new Promise((r) => setTimeout(r, 1000));
            const statusRes = await fetch(\`/api/oauth/google/status/\${encodeURIComponent(sessionId)}\`);
            const statusData = await statusRes.json().catch(() => ({}));
            if (statusData.status === 'completed') {
              if (statusEl) statusEl.textContent = 'Google account connected.';
              location.reload();
              return;
            }
            if (statusData.status === 'failed') {
              if (statusEl) statusEl.textContent = statusData.error || 'OAuth failed';
              return;
            }
          }
          if (statusEl) statusEl.textContent = 'Timed out waiting for OAuth consent.';
        } catch (err) {
          if (statusEl) statusEl.textContent = err instanceof Error ? err.message : String(err);
        }
      }
    });
  </script>
</body>
</html>`;
}
