#!/usr/bin/env node
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Tiny reverse proxy for Chrome DevTools Protocol (CDP).
//
// Chrome rejects CDP connections where the Host header is not localhost or
// an IP address. When the NemoClaw sandbox connects through the OpenShell
// egress proxy, the Host header is "host.openshell.internal" — Chrome
// refuses it. This proxy accepts connections on a public-facing port and
// forwards them to Chrome's CDP port with the Host header rewritten to
// "localhost".
//
// Handles both HTTP (for /json/* discovery endpoints) and WebSocket
// (for the actual CDP protocol).
//
// Usage:
//   node scripts/chrome-cdp-proxy.js [--listen 9223] [--target 9222]

const http = require("http");
const net = require("net");

const LISTEN_PORT = parseInt(process.argv.find((_, i, a) => a[i - 1] === "--listen") || "9223", 10);
const TARGET_PORT = parseInt(process.argv.find((_, i, a) => a[i - 1] === "--target") || "9222", 10);
const TARGET_HOST = "127.0.0.1";

// HTTP proxy — for /json/version, /json/list, etc.
const server = http.createServer((req, res) => {
  const options = {
    hostname: TARGET_HOST,
    port: TARGET_PORT,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: "localhost" },
  };

  const proxy = http.request(options, (proxyRes) => {
    // Rewrite WebSocket URLs in discovery responses so the client
    // connects back through this proxy, not directly to Chrome.
    let body = "";
    proxyRes.on("data", (chunk) => (body += chunk));
    proxyRes.on("end", () => {
      // Replace ws://localhost:TARGET_PORT with ws://HOST:LISTEN_PORT.
      // When connecting via the in-sandbox tunnel, req.headers.host will be
      // "host.openshell.internal:9223" — the tunnel maps this to localhost:9222
      // in the sandbox, so the rewritten URLs remain valid for the client.
      const rewritten = body.replace(
        new RegExp(`ws://localhost(:${TARGET_PORT})?/`, "g"),
        `ws://${req.headers.host}/`,
      );
      // Build clean headers — drop Content-Length (we'll set our own)
      // and Connection (let Node handle it) to avoid parse errors
      // when the rewritten body differs in length from the original.
      const headers = { ...proxyRes.headers };
      delete headers["content-length"];
      delete headers["connection"];
      delete headers["transfer-encoding"];
      headers["content-length"] = String(Buffer.byteLength(rewritten));
      if (!res.headersSent) {
        res.writeHead(proxyRes.statusCode, headers);
        res.end(rewritten);
      }
    });
  });

  proxy.on("error", (err) => {
    if (!res.headersSent) {
      res.writeHead(502);
      res.end(`Proxy error: ${err.message}`);
    }
  });

  req.pipe(proxy);
});

// WebSocket upgrade — for the actual CDP protocol
server.on("upgrade", (req, socket, head) => {
  const target = net.connect(TARGET_PORT, TARGET_HOST, () => {
    // Rewrite the upgrade request with Host: localhost
    const upgradeLine = `${req.method} ${req.url} HTTP/1.1\r\n`;
    const headers = Object.entries(req.headers)
      .map(([k, v]) => (k.toLowerCase() === "host" ? `${k}: localhost` : `${k}: ${v}`))
      .join("\r\n");
    target.write(upgradeLine + headers + "\r\n\r\n");
    if (head.length > 0) target.write(head);
    target.pipe(socket);
    socket.pipe(target);
  });

  target.on("error", () => socket.destroy());
  socket.on("error", () => target.destroy());
});

server.listen(LISTEN_PORT, "0.0.0.0", () => {
  console.log(`[cdp-proxy] Listening on 0.0.0.0:${LISTEN_PORT} → Chrome CDP at ${TARGET_HOST}:${TARGET_PORT}`);
});
