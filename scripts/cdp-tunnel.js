#!/usr/bin/env node
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// TCP tunnel for CDP connections inside the OpenShell sandbox.
//
// Listens on localhost inside the sandbox and creates HTTP CONNECT tunnels
// through the egress proxy to reach the host-side CDP proxy. This is needed
// because:
//   1. Node.js WebSocket libraries don't use HTTP_PROXY env vars
//   2. The sandbox blocks direct TCP connections to external hosts
//   3. Only the egress proxy (10.200.0.1:3128) can reach the host
//
// With this tunnel, OpenClaw's browser tool connects to localhost:9222
// (which is in no_proxy), and this script tunnels the traffic through the
// egress proxy's CONNECT method to the host-side CDP proxy.
//
// Usage (inside sandbox):
//   node cdp-tunnel.js [--listen 9222] [--target host.openshell.internal:9223]

const net = require("net");
const http = require("http");

const LISTEN_PORT = parseInt(
  process.argv.find((_, i, a) => a[i - 1] === "--listen") || "9222",
  10,
);
const TARGET = process.argv.find((_, i, a) => a[i - 1] === "--target")
  || "host.openshell.internal:9223";
const PROXY_HOST = "10.200.0.1";
const PROXY_PORT = 3128;

const [targetHost, targetPort] = TARGET.split(":");

const server = net.createServer((client) => {
  // Create CONNECT tunnel through egress proxy
  const connectReq = http.request({
    hostname: PROXY_HOST,
    port: PROXY_PORT,
    method: "CONNECT",
    path: `${targetHost}:${targetPort}`,
  });

  connectReq.on("connect", (res, proxySocket, _head) => {
    if (res.statusCode !== 200) {
      console.error(`[cdp-tunnel] CONNECT rejected: ${res.statusCode}`);
      client.destroy();
      proxySocket.destroy();
      return;
    }
    // CONNECT established — pipe data bidirectionally
    client.pipe(proxySocket);
    proxySocket.pipe(client);
    proxySocket.on("error", () => client.destroy());
  });

  connectReq.on("error", (err) => {
    console.error(`[cdp-tunnel] CONNECT error: ${err.message}`);
    client.destroy();
  });

  connectReq.on("response", (res) => {
    // Non-CONNECT response (proxy rejected without upgrading)
    console.error(`[cdp-tunnel] Proxy returned ${res.statusCode} (expected CONNECT)`);
    client.destroy();
  });

  client.on("error", () => connectReq.destroy());

  connectReq.end();
});

server.listen(LISTEN_PORT, "127.0.0.1", () => {
  console.log(
    `[cdp-tunnel] 127.0.0.1:${LISTEN_PORT} → CONNECT ${TARGET} via ${PROXY_HOST}:${PROXY_PORT}`,
  );
});
