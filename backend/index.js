const { app } = require("@azure/functions");
const { CommunicationIdentityClient } = require("@azure/communication-identity");
const { RoomsClient } = require("@azure/communication-rooms");
const { TableClient } = require("@azure/data-tables");
const {
  BlobServiceClient,
  StorageSharedKeyCredential,
  BlobSASPermissions,
  generateBlobSASQueryParameters
} = require("@azure/storage-blob");
const { WebPubSubServiceClient } = require("@azure/web-pubsub");
const crypto = require("crypto");
const bcrypt = require("bcryptjs");
const { channels, messages, locations, newId } = require("./shared/store");
const { jsonResponse } = require("./shared/response");
const acsRoomsByChannel = new Map();
const tableConn =
  process.env.AZURE_STORAGE_CONNECTION_STRING || process.env.AzureWebJobsStorage;
const channelTableName = "channels";
const tripsTableName = "clubbytrips";
const usersTableName = "clubbyusers";
const sessionsTableName = "clubbysessions";
let channelTableClient = null;
let tripsTableClient = null;
let usersTableClient = null;
let sessionsTableClient = null;
if (tableConn) {
  channelTableClient = TableClient.fromConnectionString(tableConn, channelTableName);
  tripsTableClient = TableClient.fromConnectionString(tableConn, tripsTableName);
  usersTableClient = TableClient.fromConnectionString(tableConn, usersTableName);
  sessionsTableClient = TableClient.fromConnectionString(tableConn, sessionsTableName);
}
let blobServiceClient = null;
let storageSharedKeyCredential = null;
if (tableConn) {
  blobServiceClient = BlobServiceClient.fromConnectionString(tableConn);
  const connParts = Object.fromEntries(
    tableConn
      .split(";")
      .map((part) => part.split("=", 2))
      .filter(([k, v]) => k && v)
  );
  if (connParts.AccountName && connParts.AccountKey) {
    storageSharedKeyCredential = new StorageSharedKeyCredential(
      connParts.AccountName,
      connParts.AccountKey
    );
  }
}
const mediaContainerName = "clubby-media";

function parseJson(request) {
  return request.json();
}

async function ensureChannelTable() {
  if (!channelTableClient) return;
  try {
    await channelTableClient.createTable();
  } catch (_) {
    // ignore table already exists
  }
}

async function ensureTripsTable() {
  if (!tripsTableClient) return;
  try {
    await tripsTableClient.createTable();
  } catch (_) {
    // ignore table already exists
  }
}

async function ensureUsersTable() {
  if (!usersTableClient) return;
  try {
    await usersTableClient.createTable();
  } catch (_) {
    // ignore table already exists
  }
}

async function ensureSessionsTable() {
  if (!sessionsTableClient) return;
  try {
    await sessionsTableClient.createTable();
  } catch (_) {
    // ignore table already exists
  }
}

const USERNAME_RE = /^[a-zA-Z0-9_]{3,32}$/;
const SESSION_MS = 30 * 24 * 60 * 60 * 1000;

function normalizeUsername(u) {
  return String(u || "").trim().toLowerCase();
}

async function createSessionForUser(usernameLower) {
  const token = crypto.randomBytes(32).toString("hex");
  const expiresAt = new Date(Date.now() + SESSION_MS).toISOString();
  await sessionsTableClient.upsertEntity({
    partitionKey: "session",
    rowKey: token,
    username: usernameLower,
    expiresAt
  });
  return { token, expiresAt };
}

function odataEscape(s) {
  return String(s).replace(/'/g, "''");
}

async function loadChannelsFromDb() {
  if (!channelTableClient) return channels;
  await ensureChannelTable();
  const rows = [];
  for await (const entity of channelTableClient.listEntities()) {
    rows.push({
      id: entity.rowKey,
      name: entity.name,
      isPrivate: entity.isPrivate === true || entity.isPrivate === "true",
      createdByUserId: entity.createdByUserId || null
    });
  }
  if (rows.length > 0) {
    channels.splice(0, channels.length, ...rows);
  }
  return channels;
}

async function saveChannelToDb(channel) {
  if (!channelTableClient) return;
  await ensureChannelTable();
  await channelTableClient.upsertEntity({
    partitionKey: "channel",
    rowKey: channel.id,
    name: channel.name,
    isPrivate: channel.isPrivate,
    createdByUserId: channel.createdByUserId || ""
  });
}

async function ensureMediaContainer() {
  if (!blobServiceClient) return null;
  const containerClient = blobServiceClient.getContainerClient(mediaContainerName);
  await containerClient.createIfNotExists();
  return containerClient;
}

app.http("health", {
  methods: ["GET", "OPTIONS"],
  authLevel: "anonymous",
  route: "health",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });
    return jsonResponse(200, { status: "ok", ts: new Date().toISOString() });
  }
});

app.http("channels", {
  methods: ["GET", "POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "channels",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });
    if (request.method === "GET") {
      await loadChannelsFromDb();
      return jsonResponse(200, channels);
    }

    const body = await parseJson(request);
    if (!body?.name) return jsonResponse(400, { error: "name is required" });

    const channel = {
      id: `${body.name}`.toLowerCase().replace(/\s+/g, "-") + `-${Date.now()}`,
      name: body.name,
      isPrivate: !!body.isPrivate,
      createdByUserId: body.createdByUserId || null
    };
    channels.push(channel);
    await saveChannelToDb(channel);
    return jsonResponse(201, channel);
  }
});

app.http("messages", {
  methods: ["GET", "POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "messages",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });

    if (request.method === "GET") {
      const channelId = request.query.get("channelId");
      if (!channelId) return jsonResponse(400, { error: "channelId is required" });
      const rows = messages.filter((m) => m.channelId === channelId).slice(0, 100);
      return jsonResponse(200, rows);
    }

    const body = await parseJson(request);
    if (!body?.channelId || !body?.sender || !body?.kind || !body?.encryptedPayload) {
      return jsonResponse(400, {
        error: "channelId, sender, kind, encryptedPayload are required"
      });
    }

    const item = {
      id: newId(),
      channelId: body.channelId,
      sender: body.sender,
      kind: body.kind,
      encryptedPayload: body.encryptedPayload,
      createdAt: new Date().toISOString()
    };
    messages.unshift(item);
    return jsonResponse(201, item);
  }
});

app.http("locations", {
  methods: ["GET", "POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "locations",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });
    if (request.method === "GET") {
      return jsonResponse(200, Array.from(locations.values()));
    }

    const body = await parseJson(request);
    if (!body?.userId || body?.lat == null || body?.lng == null) {
      return jsonResponse(400, { error: "userId, lat, lng are required" });
    }
    const item = {
      userId: body.userId,
      lat: body.lat,
      lng: body.lng,
      ts: new Date().toISOString()
    };
    locations.set(body.userId, item);
    return jsonResponse(200, item);
  }
});

app.http("trips", {
  methods: ["GET", "POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "trips",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });

    if (!tripsTableClient) {
      if (request.method === "GET") return jsonResponse(200, []);
      return jsonResponse(503, { error: "Trips storage not configured" });
    }
    await ensureTripsTable();

    if (request.method === "GET") {
      const userId = request.query.get("userId");
      if (!userId) return jsonResponse(400, { error: "userId is required" });
      const filter = `PartitionKey eq '${odataEscape(userId)}'`;
      const rows = [];
      for await (const e of tripsTableClient.listEntities({ queryOptions: { filter } })) {
        let points = [];
        try {
          points = JSON.parse(e.pointsJson || "[]");
        } catch (_) {
          points = [];
        }
        rows.push({
          id: e.rowKey,
          userId: e.partitionKey,
          startLat: Number(e.startLat),
          startLng: Number(e.startLng),
          endLat: Number(e.endLat),
          endLng: Number(e.endLng),
          startedAt: e.startedAt,
          endedAt: e.endedAt,
          distanceKm: Number(e.distanceKm || 0),
          points
        });
      }
      rows.sort((a, b) => String(b.endedAt).localeCompare(String(a.endedAt)));
      return jsonResponse(200, rows.slice(0, 100));
    }

    const body = await parseJson(request);
    const userId = body?.userId;
    const points = body?.points;
    if (!userId || !Array.isArray(points) || points.length < 2) {
      return jsonResponse(400, { error: "userId and points (at least 2) are required" });
    }
    const pointsJson = JSON.stringify(points);
    if (Buffer.byteLength(pointsJson, "utf8") > 60000) {
      return jsonResponse(413, { error: "points payload too large" });
    }
    const tripId = body.tripId || newId();
    const startLat = Number(body.startLat ?? points[0].lat);
    const startLng = Number(body.startLng ?? points[0].lng);
    const endLat = Number(body.endLat ?? points[points.length - 1].lat);
    const endLng = Number(body.endLng ?? points[points.length - 1].lng);
    const startedAt = body.startedAt || new Date().toISOString();
    const endedAt = body.endedAt || new Date().toISOString();
    const distanceKm = Number(body.distanceKm || 0);

    await tripsTableClient.upsertEntity({
      partitionKey: String(userId),
      rowKey: String(tripId),
      startLat,
      startLng,
      endLat,
      endLng,
      startedAt: String(startedAt),
      endedAt: String(endedAt),
      distanceKm,
      pointsJson
    });

    return jsonResponse(201, {
      id: tripId,
      userId: String(userId),
      startLat,
      startLng,
      endLat,
      endLng,
      startedAt,
      endedAt,
      distanceKm,
      points
    });
  }
});

app.http("auth-signup", {
  methods: ["POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "auth/signup",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });
    if (!usersTableClient) {
      return jsonResponse(503, { error: "User storage not configured" });
    }
    await ensureUsersTable();

    const body = await parseJson(request);
    const rawUser = body?.username;
    const password = body?.password;
    const username = normalizeUsername(rawUser);
    if (!USERNAME_RE.test(username)) {
      return jsonResponse(400, {
        error: "Username must be 3–32 characters: letters, digits, underscore only"
      });
    }
    if (typeof password !== "string" || password.length < 8) {
      return jsonResponse(400, { error: "Password must be at least 8 characters" });
    }

    try {
      await usersTableClient.getEntity("user", username);
      return jsonResponse(409, { error: "Username already taken" });
    } catch (e) {
      const sc = e?.statusCode ?? e?.status;
      if (sc !== 404) throw e;
    }

    const passwordHash = bcrypt.hashSync(password, 10);
    const createdAt = new Date().toISOString();
    await usersTableClient.upsertEntity({
      partitionKey: "user",
      rowKey: username,
      passwordHash,
      createdAt
    });

    return jsonResponse(201, { username, userId: username });
  }
});

app.http("auth-login", {
  methods: ["POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "auth/login",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });
    if (!usersTableClient || !sessionsTableClient) {
      return jsonResponse(503, { error: "Auth storage not configured" });
    }
    await ensureUsersTable();
    await ensureSessionsTable();

    const body = await parseJson(request);
    const username = normalizeUsername(body?.username);
    const password = body?.password;
    if (!username || typeof password !== "string") {
      return jsonResponse(400, { error: "username and password are required" });
    }

    let entity;
    try {
      entity = await usersTableClient.getEntity("user", username);
    } catch (e) {
      const sc = e?.statusCode ?? e?.status;
      if (sc === 404) {
        return jsonResponse(401, { error: "Invalid username or password" });
      }
      throw e;
    }

    const ok = bcrypt.compareSync(password, String(entity.passwordHash || ""));
    if (!ok) {
      return jsonResponse(401, { error: "Invalid username or password" });
    }

    const { token, expiresAt } = await createSessionForUser(username);
    return jsonResponse(200, {
      token,
      username,
      userId: username,
      expiresAt
    });
  }
});

app.http("auth-session", {
  methods: ["GET", "OPTIONS"],
  authLevel: "anonymous",
  route: "auth/session",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });
    if (!sessionsTableClient) {
      return jsonResponse(200, { valid: false });
    }
    await ensureSessionsTable();

    const token = request.query.get("token");
    if (!token) {
      return jsonResponse(400, { error: "token is required" });
    }

    try {
      const e = await sessionsTableClient.getEntity("session", token);
      const exp = new Date(e.expiresAt);
      if (Number.isNaN(exp.getTime()) || exp < new Date()) {
        await sessionsTableClient.deleteEntity("session", token).catch(() => {});
        return jsonResponse(200, { valid: false });
      }
      const username = String(e.username || "");
      return jsonResponse(200, { valid: true, username, userId: username });
    } catch (err) {
      const sc = err?.statusCode ?? err?.status;
      if (sc === 404) {
        return jsonResponse(200, { valid: false });
      }
      throw err;
    }
  }
});

app.http("negotiate", {
  methods: ["POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "negotiate",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });
    const body = await parseJson(request);
    const userId = body?.userId || "anonymous";
    const hub = process.env.WEBPUBSUB_HUB || "team-radio";
    const conn = process.env.WEBPUBSUB_CONNECTION_STRING;
    if (!conn) {
      return jsonResponse(500, { error: "WEBPUBSUB_CONNECTION_STRING not configured" });
    }

    const client = new WebPubSubServiceClient(conn, hub);
    const token = await client.getClientAccessToken({
      userId,
      roles: ["webpubsub.joinLeaveGroup", "webpubsub.sendToGroup"]
    });
    return jsonResponse(200, {
      url: token.url,
      hub
    });
  }
});

app.http("acs-token", {
  methods: ["POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "acs/token",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });

    const conn = process.env.ACS_CONNECTION_STRING;
    if (!conn) {
      return jsonResponse(500, { error: "ACS_CONNECTION_STRING not configured" });
    }

    const body = await parseJson(request);
    const displayName = body?.displayName || "guest-user";
    const channelId = body?.channelId || "general";

    const identityClient = new CommunicationIdentityClient(conn);
    const roomsClient = new RoomsClient(conn);
    const user = await identityClient.createUser();
    const tokenResponse = await identityClient.getToken(user, ["voip"]);
    let room = acsRoomsByChannel.get(channelId);
    if (!room) {
      const now = new Date();
      const validUntil = new Date(now.getTime() + 1000 * 60 * 60 * 24 * 30);
      room = await roomsClient.createRoom({
        validFrom: now,
        validUntil
      });
      acsRoomsByChannel.set(channelId, room);
    } else {
      try {
        await roomsClient.addOrUpdateParticipants(room.id, [
          {
            id: { communicationUserId: user.communicationUserId },
            role: "Attendee"
          }
        ]);
      } catch (_) {
        // Best-effort participant sync, token still allows call join.
      }
    }

    return jsonResponse(200, {
      token: tokenResponse.token,
      communicationUserId: user.communicationUserId,
      expiresOn: tokenResponse.expiresOn,
      displayName,
      channelId,
      roomId: room.id
    });
  }
});

function buildReadUrlWithSas(containerName, blobName, blockBlobClient) {
  if (!storageSharedKeyCredential) return blockBlobClient.url;
  const expiresOn = new Date(Date.now() + 1000 * 60 * 60 * 24 * 7);
  const sas = generateBlobSASQueryParameters(
    {
      containerName,
      blobName,
      permissions: BlobSASPermissions.parse("r"),
      startsOn: new Date(Date.now() - 1000 * 60 * 5),
      expiresOn
    },
    storageSharedKeyCredential
  ).toString();
  return `${blockBlobClient.url}?${sas}`;
}

app.http("media-upload", {
  methods: ["POST", "OPTIONS"],
  authLevel: "anonymous",
  route: "media/upload",
  handler: async (request) => {
    if (request.method === "OPTIONS") return jsonResponse(200, { ok: true });
    if (!blobServiceClient) {
      return jsonResponse(500, { error: "Storage connection not configured" });
    }

    const body = await parseJson(request);
    const base64Data = body?.base64Data;
    const userId = body?.userId || "anonymous";
    const fileName = body?.fileName || `upload-${Date.now()}.jpg`;
    const contentType = body?.contentType || "application/octet-stream";
    const category = body?.category || "photo";

    if (!base64Data) {
      return jsonResponse(400, { error: "base64Data is required" });
    }

    const containerClient = await ensureMediaContainer();
    const safeName = `${Date.now()}-${fileName}`.replace(/[^a-zA-Z0-9._-]/g, "_");
    const blobName = `${category}/${userId}/${safeName}`;
    const blockBlobClient = containerClient.getBlockBlobClient(blobName);
    const data = Buffer.from(base64Data, "base64");
    await blockBlobClient.uploadData(data, {
      blobHTTPHeaders: { blobContentType: contentType }
    });
    const readUrl = buildReadUrlWithSas(
      mediaContainerName,
      blobName,
      blockBlobClient
    );

    return jsonResponse(200, {
      url: readUrl,
      blobName,
      contentType
    });
  }
});
