// Diagnostic only (stremio-bugs#2827): inspect the WebView2 page through the DevTools protocol.
// Usage: node cdp.mjs wait | setup | hash <hash> | state | picker <file> | open <url>
const [, , cmd, arg] = process.argv;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let target;
let lastError = '';
let pages = [];
for (let i = 0; i < 300 && !target; i++) {
    try {
        const list = await (await fetch('http://127.0.0.1:9333/json/list', { signal: AbortSignal.timeout(2000) })).json();
        pages = list.map((t) => t.type + ' ' + t.url.slice(0, 60));
        target = list.find((t) => t.type === 'page' && /^https:\/\/web\.stremio\.com\//.test(t.url) && t.webSocketDebuggerUrl);
    } catch (error) { lastError = String(error && error.cause ? error.cause.code || error.cause : error); }
    if (!target) await sleep(200);
}
if (!target) { console.log('NO_TARGET last=' + lastError + ' pages=' + JSON.stringify(pages)); process.exit(1); }
if (cmd === 'wait') { console.log('target ' + target.url); process.exit(0); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res) => { ws.onopen = res; });
let id = 0;
const pending = new Map();
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async (expression) => {
    const m = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    return m.result.exceptionDetails ? 'EXCEPTION ' + JSON.stringify(m.result.exceptionDetails).slice(0, 300) : m.result.result.value;
};

if (cmd === 'setup') {
    console.log(await evaluate(`(() => {
        window.__diag = [];
        const push = (entry) => window.__diag.push(Object.assign({ at: Math.round(performance.now()) }, entry));
        ['dragenter', 'dragover', 'dragleave', 'drop'].forEach((type) => window.addEventListener(type, (e) => {
            const last = window.__diag[window.__diag.length - 1];
            if (type === 'dragover' && last && last.t === 'dragover') { last.n = (last.n || 1) + 1; return; }
            push({ t: type, prevented: e.defaultPrevented, files: e.dataTransfer ? e.dataTransfer.files.length : null, types: e.dataTransfer ? Array.from(e.dataTransfer.types) : null, target: String(e.target && e.target.className || e.target && e.target.nodeName).slice(0, 80) });
        }));
        window.chrome.webview.addEventListener('message', (ev) => push({ t: 'from-shell', data: String(typeof ev.data === 'string' ? ev.data : JSON.stringify(ev.data)).slice(0, 300) }));
        const post = window.chrome.webview.postMessage.bind(window.chrome.webview);
        window.chrome.webview.postMessage = (message) => { const text = String(typeof message === 'string' ? message : JSON.stringify(message)); if (/sub|file|drop/i.test(text)) push({ t: 'to-shell', data: text.slice(0, 300) }); return post(message); };
        return 'setup ok ' + location.href;
    })()`));
} else if (cmd === 'hash') {
    console.log(await evaluate(`(() => { location.hash = ${JSON.stringify(arg)}; return 'hash set'; })()`));
} else if (cmd === 'state') {
    console.log(await evaluate(`JSON.stringify({
        hash: location.hash.slice(0, 40),
        events: window.__diag || null,
        overlays: Array.from(document.querySelectorAll('[class*="file-drop-container"]')).map((e) => String(e.className)),
        fileInputs: Array.from(document.querySelectorAll('input[type=file]')).map((i) => i.files.length),
    })`));
} else if (cmd === 'picker') {
    // Equivalent of choosing a file in the file picker: set the file on the page's file input (fires change).
    const doc = await send('DOM.getDocument', { depth: -1 });
    const q = await send('DOM.querySelector', { nodeId: doc.result.root.nodeId, selector: 'input[type=file]' });
    if (!q.result || !q.result.nodeId) { console.log('picker: no file input'); process.exit(0); }
    const r = await send('DOM.setFileInputFiles', { nodeId: q.result.nodeId, files: [arg] });
    console.log('picker: ' + JSON.stringify(r.error || 'files set'));
} else if (cmd === 'open') {
    console.log(await evaluate(`(() => { const w = window.open(${JSON.stringify(arg)}, '_blank'); return 'window.open returned ' + (w === null ? 'null' : 'window'); })()`));
}
ws.close();
process.exit(0);
