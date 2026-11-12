.pragma library

function stripYamlValue(value) {
    let text = String(value || "").trim();
    if (!/^['"]/.test(text))
        text = text.replace(/\s+#.*$/, "").trim();
    if (text.length >= 2) {
        const first = text.charAt(0);
        const last = text.charAt(text.length - 1);
        if ((first === "\"" && last === "\"") || (first === "'" && last === "'"))
            text = text.slice(1, -1);
    }
    return text.trim();
}

function parseGroupOrder(text) {
    const order = [];
    const lines = String(text || "").split(/\r?\n/);
    let inGroups = false;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (/^proxy-groups\s*:/.test(line)) {
            inGroups = true;
            continue;
        }
        if (!inGroups)
            continue;
        if (/^\s*#/.test(line))
            continue;
        if (/^\S/.test(line)) {
            inGroups = false;
            continue;
        }
        let match = line.match(/^\s{1,4}- name\s*:\s*(.+)$/);
        if (match) {
            order.push(stripYamlValue(match[1]));
            continue;
        }
        match = line.match(/^\s{1,4}-\s*\{\s*name\s*:\s*(.+?)\s*,/);
        if (match)
            order.push(stripYamlValue(match[1]));
    }
    return order;
}

function parseConfig(text) {
    const result = {
        controller: "",
        secret: "",
        unixSocket: "",
        groupOrder: parseGroupOrder(text)
    };
    const lines = String(text || "").split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (/^\s*#/.test(line))
            continue;
        let match = line.match(/^external-controller\s*:\s*(.*)$/);
        if (match) {
            result.controller = stripYamlValue(match[1]);
            continue;
        }
        match = line.match(/^external-controller-unix\s*:\s*(.*)$/);
        if (match) {
            result.unixSocket = stripYamlValue(match[1]);
            continue;
        }
        match = line.match(/^secret\s*:\s*(.*)$/);
        if (match)
            result.secret = stripYamlValue(match[1]);
    }
    return result;
}

function endpointFromController(value) {
    const raw = String(value || "").trim().replace(/^https?:\/\//i, "");
    if (raw === "")
        return null;

    let host = "127.0.0.1";
    let port = 9090;
    const ipv6 = raw.match(/^\[([^\]]+)\]:(\d+)$/);
    if (ipv6) {
        host = ipv6[1];
        port = parseInt(ipv6[2], 10);
    } else if (raw.startsWith(":")) {
        port = parseInt(raw.slice(1), 10);
    } else if (/^\d+$/.test(raw)) {
        port = parseInt(raw, 10);
    } else {
        const index = raw.lastIndexOf(":");
        if (index >= 0) {
            host = raw.slice(0, index);
            port = parseInt(raw.slice(index + 1), 10);
        } else {
            host = raw;
        }
    }

    if (!host || host === "0.0.0.0" || host === "::" || host === "[::]")
        host = "127.0.0.1";
    if (!isFinite(port) || port <= 0)
        port = 9090;

    return {
        host: host,
        port: port
    };
}

function baseUrl(host, port) {
    const safeHost = host.indexOf(":") >= 0 ? "[" + host + "]" : host;
    return "http://" + safeHost + ":" + port;
}

function normalizeBase(override) {
    const raw = String(override || "").trim().replace(/\/+$/, "");
    if (raw === "")
        return "";
    return /^https?:\/\//i.test(raw) ? raw : "http://" + raw;
}

function parseResponse(stdout, exitCode) {
    const text = stdout || "";
    const index = text.lastIndexOf("\n");
    const body = index >= 0 ? text.slice(0, index) : "";
    const code = index >= 0 ? parseInt(text.slice(index + 1), 10) : 0;
    return {
        ok: exitCode === 0 && isFinite(code) && code >= 200 && code < 300,
        code: isFinite(code) ? code : 0,
        exit: exitCode,
        body: body
    };
}

function curlArgs(base, secret, unixSocket, path, method, body, maxTime) {
    const args = ["curl", "-sS", "--max-time", String(maxTime || 3), "-w", "\n%{http_code}"];
    if (secret)
        args.push("-H", "Authorization: Bearer " + secret);
    if (unixSocket)
        args.push("--unix-socket", unixSocket);
    if (method && method !== "GET")
        args.push("-X", method);
    if (body !== undefined && body !== null) {
        args.push("-H", "Content-Type: application/json");
        args.push("--data-binary", body);
    }
    args.push(base + path);
    return args;
}

function trafficArgs(base, secret, unixSocket) {
    const args = ["curl", "-sN"];
    if (secret)
        args.push("-H", "Authorization: Bearer " + secret);
    if (unixSocket)
        args.push("--unix-socket", unixSocket);
    args.push(base + "/traffic");
    return args;
}

function parseProxies(body) {
    const data = JSON.parse(body).proxies || {};
    const groups = [];
    const delays = {};
    const info = {};
    for (const name in data) {
        const proxy = data[name];
        if (!proxy)
            continue;
        const history = Array.isArray(proxy.history) ? proxy.history : [];
        const last = history.length > 0 ? history[history.length - 1] : null;
        delays[name] = last && typeof last.delay === "number" ? last.delay : -1;
        info[name] = {
            type: proxy.type || "",
            alive: proxy.alive !== false
        };
        if (Array.isArray(proxy.all) && proxy.all.length > 0) {
            groups.push({
                name: name,
                type: proxy.type || "",
                now: proxy.now || "",
                nodes: proxy.all.slice()
            });
        }
    }
    return {
        groups: groups,
        delays: delays,
        info: info
    };
}

function formatRate(bytesPerSec, gbDecimals) {
    if (!isFinite(bytesPerSec) || bytesPerSec <= 0)
        return "0 B/s";
    if (bytesPerSec < 1024)
        return bytesPerSec.toFixed(0) + " B/s";
    if (bytesPerSec < 1024 * 1024)
        return (bytesPerSec / 1024).toFixed(1) + " KB/s";
    if (bytesPerSec < 1024 * 1024 * 1024)
        return (bytesPerSec / (1024 * 1024)).toFixed(1) + " MB/s";
    return (bytesPerSec / (1024 * 1024 * 1024)).toFixed(gbDecimals ?? 2) + " GB/s";
}

function formatBytes(bytes) {
    if (!isFinite(bytes) || bytes <= 0)
        return "0 B";
    if (bytes < 1024)
        return Math.round(bytes) + " B";
    if (bytes < 1024 * 1024)
        return (bytes / 1024).toFixed(1) + " KB";
    if (bytes < 1024 * 1024 * 1024)
        return (bytes / (1024 * 1024)).toFixed(1) + " MB";
    return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB";
}
