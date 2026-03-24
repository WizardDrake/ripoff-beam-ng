import http from "node:http";
import { WebSocketServer } from "ws";

const PORT = Number(process.env.PORT) || 8787;
const PUBLIC_ROOM = "public";
const PRIVATE_MIN = 1;
const PRIVATE_MAX = 100;

/** @type {Map<string, Set<import('ws').WebSocket>>} */
const rooms = new Map();

function roomIdFromJoin(msg) {
  if (msg?.t !== "join") return { error: "expected_join" };
  const kind = msg.kind;
  if (kind === "public") return { roomId: PUBLIC_ROOM };
  if (kind === "private") {
    const n = Number(msg.n);
    if (!Number.isInteger(n) || n < PRIVATE_MIN || n > PRIVATE_MAX) {
      return {
        error: "invalid_private",
        detail: `n must be ${PRIVATE_MIN}-${PRIVATE_MAX}`,
      };
    }
    return { roomId: `private-${n}` };
  }
  return { error: "invalid_kind" };
}

function getOrCreateRoom(roomId) {
  if (!rooms.has(roomId)) rooms.set(roomId, new Set());
  return rooms.get(roomId);
}

function broadcast(roomId, data, except) {
  const set = rooms.get(roomId);
  if (!set) return;
  const raw = JSON.stringify(data);
  for (const client of set) {
    if (client !== except && client.readyState === 1) client.send(raw);
  }
}

function removeFromRoom(roomId, ws) {
  const set = rooms.get(roomId);
  if (!set) return;
  set.delete(ws);
  if (set.size === 0) rooms.delete(roomId);
}

let nextPlayerId = 1;

const server = http.createServer((req, res) => {
  if (req.url === "/health" || req.url === "/") {
    res.writeHead(req.url === "/health" ? 200 : 204);
    res.end(req.url === "/health" ? "ok" : "");
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server, path: "/" });

wss.on("connection", (ws) => {
  /** @type {{ id: number, roomId: string, joined: boolean } | null} */
  let meta = null;

  ws.sendSafe = (obj) => {
    if (ws.readyState === 1) ws.send(JSON.stringify(obj));
  };

  ws.on("message", (buf) => {
    let msg;
    try {
      msg = JSON.parse(buf.toString());
    } catch {
      ws.send(JSON.stringify({ t: "error", code: "bad_json" }));
      return;
    }

    if (!meta) {
      const parsed = roomIdFromJoin(msg);
      if (parsed.error) {
        ws.send(
          JSON.stringify({
            t: "error",
            code: parsed.error,
            detail: parsed.detail ?? "",
          })
        );
        ws.close();
        return;
      }

      const room = getOrCreateRoom(parsed.roomId);
      const peers = [];
      for (const other of room) {
        const oid = other._playerMeta?.id;
        if (oid != null) peers.push(oid);
      }

      meta = {
        id: nextPlayerId++,
        roomId: parsed.roomId,
        joined: true,
      };
      ws._playerMeta = meta;
      room.add(ws);

      ws.sendSafe({ t: "welcome", id: meta.id });
      ws.sendSafe({ t: "peers", ids: peers });

      for (const other of room) {
        if (other !== ws) other.sendSafe({ t: "player_joined", id: meta.id });
      }
      return;
    }

    if (msg.t === "state" && meta.roomId) {
      broadcast(
        meta.roomId,
        {
          t: "state",
          player: meta.id,
          pos: msg.pos,
          rot: msg.rot,
          vel: msg.vel,
        },
        ws
      );
    }
  });

  ws.on("close", () => {
    if (!meta?.roomId) return;
    broadcast(meta.roomId, { t: "player_left", id: meta.id });
    removeFromRoom(meta.roomId, ws);
  });
});

server.listen(PORT, () => {
  console.log(`multiplayer listening on ${PORT}`);
});
