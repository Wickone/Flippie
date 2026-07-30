#!/usr/bin/env node
import { execFileSync } from "node:child_process";

const serverInfo = {
  name: "flippie-figma",
  version: "0.1.0",
};

let inputBuffer = Buffer.alloc(0);

process.stdin.on("data", (chunk) => {
  inputBuffer = Buffer.concat([inputBuffer, chunk]);
  for (;;) {
    const parsed = readMessage(inputBuffer);
    if (!parsed) break;
    inputBuffer = inputBuffer.subarray(parsed.bytesRead);
    handleMessage(parsed.message).catch((error) => {
      if (parsed.message && Object.hasOwn(parsed.message, "id")) {
        sendError(parsed.message.id, -32603, error.message);
      }
    });
  }
});

function readMessage(buffer) {
  const headerEnd = buffer.indexOf("\r\n\r\n");
  if (headerEnd !== -1) {
    const header = buffer.subarray(0, headerEnd).toString("utf8");
    const match = header.match(/content-length:\s*(\d+)/i);
    if (!match) {
      throw new Error("MCP message is missing Content-Length.");
    }
    const length = Number(match[1]);
    const bodyStart = headerEnd + 4;
    const bodyEnd = bodyStart + length;
    if (buffer.length < bodyEnd) return null;
    return {
      bytesRead: bodyEnd,
      message: JSON.parse(buffer.subarray(bodyStart, bodyEnd).toString("utf8")),
    };
  }

  const newline = buffer.indexOf("\n");
  if (newline === -1) return null;
  const line = buffer.subarray(0, newline).toString("utf8").trim();
  if (!line) return { bytesRead: newline + 1, message: null };
  return { bytesRead: newline + 1, message: JSON.parse(line) };
}

async function handleMessage(message) {
  if (!message) return;
  const { id, method, params = {} } = message;

  if (method === "initialize") {
    sendResult(id, {
      protocolVersion: params.protocolVersion ?? "2024-11-05",
      capabilities: { tools: {} },
      serverInfo,
    });
    return;
  }

  if (method === "notifications/initialized") return;

  if (method === "tools/list") {
    sendResult(id, { tools: toolsList() });
    return;
  }

  if (method === "tools/call") {
    const result = await callTool(params.name, params.arguments ?? {});
    sendResult(id, result);
    return;
  }

  if (id !== undefined) {
    sendError(id, -32601, `Unsupported method: ${method}`);
  }
}

function toolsList() {
  return [
    {
      name: "figma_parse_url",
      description: "Extract fileKey and nodeId from a Figma URL.",
      inputSchema: {
        type: "object",
        properties: {
          url: { type: "string", description: "Figma file/design URL." },
        },
        required: ["url"],
      },
    },
    {
      name: "figma_get_file",
      description: "Read a Figma file through the Figma REST API.",
      inputSchema: {
        type: "object",
        properties: {
          fileKey: { type: "string" },
          ids: { type: "string", description: "Optional comma-separated node IDs." },
          depth: { type: "number", minimum: 1, maximum: 10 },
          geometry: { type: "boolean", default: false },
        },
        required: ["fileKey"],
      },
    },
    {
      name: "figma_get_node",
      description: "Read one node from a Figma file.",
      inputSchema: {
        type: "object",
        properties: {
          fileKey: { type: "string" },
          nodeId: { type: "string" },
          depth: { type: "number", minimum: 1, maximum: 10 },
          geometry: { type: "boolean", default: false },
        },
        required: ["fileKey", "nodeId"],
      },
    },
    {
      name: "figma_export_images",
      description: "Export Figma nodes as image URLs.",
      inputSchema: {
        type: "object",
        properties: {
          fileKey: { type: "string" },
          ids: {
            oneOf: [
              { type: "string" },
              { type: "array", items: { type: "string" } },
            ],
          },
          format: { type: "string", enum: ["jpg", "png", "svg", "pdf"], default: "png" },
          scale: { type: "number", minimum: 0.01, maximum: 4, default: 1 },
        },
        required: ["fileKey", "ids"],
      },
    },
    {
      name: "figma_get_styles",
      description: "List published styles in a Figma file.",
      inputSchema: {
        type: "object",
        properties: {
          fileKey: { type: "string" },
        },
        required: ["fileKey"],
      },
    },
    {
      name: "figma_design_summary",
      description: "Return a compact design tree summary for implementation planning.",
      inputSchema: {
        type: "object",
        properties: {
          fileKey: { type: "string" },
          nodeId: { type: "string" },
          depth: { type: "number", minimum: 1, maximum: 6, default: 3 },
        },
        required: ["fileKey"],
      },
    },
  ];
}

async function callTool(name, args) {
  switch (name) {
    case "figma_parse_url":
      return textResult(JSON.stringify(parseFigmaURL(required(args, "url")), null, 2));
    case "figma_get_file":
      return jsonResult(await figmaGet(`/files/${encodeURIComponent(required(args, "fileKey"))}`, {
        ids: args.ids,
        depth: args.depth,
        geometry: args.geometry ? "paths" : undefined,
      }));
    case "figma_get_node":
      return jsonResult(await figmaGet(`/files/${encodeURIComponent(required(args, "fileKey"))}/nodes`, {
        ids: required(args, "nodeId"),
        depth: args.depth,
        geometry: args.geometry ? "paths" : undefined,
      }));
    case "figma_export_images":
      return jsonResult(await figmaGet(`/images/${encodeURIComponent(required(args, "fileKey"))}`, {
        ids: normalizeIDs(required(args, "ids")).join(","),
        format: args.format ?? "png",
        scale: args.scale ?? 1,
      }));
    case "figma_get_styles":
      return jsonResult(await figmaGet(`/files/${encodeURIComponent(required(args, "fileKey"))}/styles`));
    case "figma_design_summary":
      return jsonResult(await designSummary(args));
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

async function designSummary(args) {
  const fileKey = required(args, "fileKey");
  const depth = args.depth ?? 3;
  const nodeId = args.nodeId;
  const data = nodeId
    ? await figmaGet(`/files/${encodeURIComponent(fileKey)}/nodes`, { ids: nodeId, depth })
    : await figmaGet(`/files/${encodeURIComponent(fileKey)}`, { depth });

  const root = nodeId
    ? data.nodes?.[nodeId]?.document
    : data.document;

  return {
    name: data.name,
    lastModified: data.lastModified,
    version: data.version,
    root: summarizeNode(root, depth),
    styles: data.styles ? Object.values(data.styles).map(summarizeStyle).slice(0, 200) : undefined,
  };
}

function summarizeNode(node, depth) {
  if (!node || depth < 0) return undefined;
  const summary = {
    id: node.id,
    name: node.name,
    type: node.type,
  };

  if (node.absoluteBoundingBox) {
    summary.frame = pick(node.absoluteBoundingBox, ["x", "y", "width", "height"]);
  }
  if (node.layoutMode) {
    summary.layout = pick(node, [
      "layoutMode",
      "primaryAxisSizingMode",
      "counterAxisSizingMode",
      "primaryAxisAlignItems",
      "counterAxisAlignItems",
      "itemSpacing",
      "paddingLeft",
      "paddingRight",
      "paddingTop",
      "paddingBottom",
    ]);
  }
  if (node.fills?.length) summary.fills = node.fills.map(summarizePaint).filter(Boolean);
  if (node.strokes?.length) summary.strokes = node.strokes.map(summarizePaint).filter(Boolean);
  if (node.cornerRadius !== undefined) summary.cornerRadius = node.cornerRadius;
  if (node.characters) summary.text = node.characters.slice(0, 500);
  if (node.style) summary.textStyle = pick(node.style, [
    "fontFamily",
    "fontPostScriptName",
    "fontSize",
    "fontWeight",
    "lineHeightPx",
    "letterSpacing",
    "textAlignHorizontal",
    "textAlignVertical",
  ]);

  if (depth > 0 && node.children?.length) {
    summary.children = node.children.slice(0, 80).map((child) => summarizeNode(child, depth - 1));
    if (node.children.length > 80) summary.truncatedChildren = node.children.length - 80;
  }
  return summary;
}

function summarizePaint(paint) {
  if (!paint || paint.visible === false) return null;
  const base = pick(paint, ["type", "opacity", "blendMode"]);
  if (paint.color) base.color = rgba(paint.color, paint.opacity);
  if (paint.gradientStops) {
    base.gradientStops = paint.gradientStops.map((stop) => ({
      position: stop.position,
      color: rgba(stop.color),
    }));
  }
  return base;
}

function summarizeStyle(style) {
  return pick(style, ["key", "name", "styleType", "description"]);
}

async function figmaGet(path, query = {}) {
  const token = figmaToken();
  const url = new URL(`https://api.figma.com/v1${path}`);
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== null && value !== "") {
      url.searchParams.set(key, String(value));
    }
  }

  const response = await fetch(url, {
    headers: { "X-Figma-Token": token },
  });

  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { raw: text };
  }

  if (!response.ok) {
    const message = body?.err || body?.message || response.statusText;
    throw new Error(`Figma API ${response.status}: ${message}`);
  }

  return body;
}

function figmaToken() {
  if (process.env.FIGMA_ACCESS_TOKEN) return process.env.FIGMA_ACCESS_TOKEN;
const keychain = process.env.HOME
    ? `${process.env.HOME}/Library/Keychains/login.keychain-db`
    : undefined;
  const account = process.env.USER;
  const attempts = [
    [
      "find-generic-password",
      "-s",
      "codex-figma-token",
      "-w",
    ],
  ];
  if (account) {
    attempts.unshift([
      "find-generic-password",
      "-s",
      "codex-figma-token",
      "-a",
      account,
      "-w",
    ]);
  }
  if (keychain) {
    attempts.unshift([
      "find-generic-password",
      "-s",
      "codex-figma-token",
      ...(account ? ["-a", account] : []),
      "-w",
      keychain,
    ]);
  }

  for (const args of attempts) {
    try {
      const token = execFileSync("/usr/bin/security", args, {
        encoding: "utf8",
      }).trim();
      if (token) return token;
    } catch {
      // Try the next lookup strategy.
    }
  }

  throw new Error(
    "Figma token is missing. Set FIGMA_ACCESS_TOKEN or add it to Keychain service codex-figma-token."
  );
}

function parseFigmaURL(urlString) {
  const url = new URL(urlString);
  const parts = url.pathname.split("/").filter(Boolean);
  const fileKey = parts[1];
  const nodeId = url.searchParams.get("node-id") ?? undefined;
  return { fileKey, nodeId, fileName: parts[2] };
}

function required(args, key) {
  if (args[key] === undefined || args[key] === null || args[key] === "") {
    throw new Error(`Missing required argument: ${key}`);
  }
  return args[key];
}

function normalizeIDs(ids) {
  return Array.isArray(ids)
    ? ids
    : String(ids).split(",").map((id) => id.trim()).filter(Boolean);
}

function pick(object, keys) {
  const result = {};
  for (const key of keys) {
    if (object?.[key] !== undefined) result[key] = object[key];
  }
  return result;
}

function rgba(color, opacity = 1) {
  return {
    r: Math.round((color.r ?? 0) * 255),
    g: Math.round((color.g ?? 0) * 255),
    b: Math.round((color.b ?? 0) * 255),
    a: color.a ?? opacity ?? 1,
  };
}

function jsonResult(value) {
  return textResult(JSON.stringify(value, null, 2));
}

function textResult(text) {
  return { content: [{ type: "text", text }] };
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function send(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}
