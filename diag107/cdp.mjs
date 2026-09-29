// Diagnostic only (shell-ng#107): send one shell IPC request from the page. Usage: node cdp.mjs '<json args array>'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 300 && !target; i++) {
    try {
        const list = await (await fetch('http://127.0.0.1:9333/json/list', { signal: AbortSignal.timeout(2000) })).json();
        target = list.find((t) => t.type === 'page' && /^https:\/\/web\.stremio\.com\//.test(t.url) && t.webSocketDebuggerUrl);
    } catch (_) { /* not ready */ }
    if (!target) await sleep(200);
}
if (!target) { console.log('NO_TARGET'); process.exit(1); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res) => { ws.onopen = res; });
const args = process.argv[2];
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id === 1) { console.log('sent ' + args + ' -> ' + JSON.stringify(m.result && m.result.result && m.result.result.value)); ws.close(); process.exit(0); } };
ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: `(() => { window.chrome.webview.postMessage(JSON.stringify({ id: 99, type: 6, args: ${args} })); return 'ok'; })()`, returnByValue: true } }));
setTimeout(() => { console.log('timeout'); process.exit(1); }, 10000);
