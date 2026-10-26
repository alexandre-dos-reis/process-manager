// Un vrai petit serveur HTTP, sans dépendance : node server.js
// PORT (défaut 3000) et NODE_ENV viennent de l'environnement / de zpawn.yaml.
const http = require("node:http");

const port = Number(process.env.PORT || 3000);
const started = Date.now();
let hits = 0;

const c = { reset: "\x1b[0m", dim: "\x1b[2m", green: "\x1b[32m", yellow: "\x1b[33m", red: "\x1b[31m", cyan: "\x1b[36m" };
const paint = (code) => (code >= 500 ? c.red : code >= 400 ? c.yellow : c.green);

function log(msg) {
  console.log(`${c.dim}${new Date().toISOString().slice(11, 19)}${c.reset} ${msg}`);
}

const routes = {
  "/": (req, res) => json(res, 200, { name: "demo-api", env: process.env.NODE_ENV, hits }),
  "/health": (req, res) => json(res, 200, { ok: true, uptime_s: Math.round((Date.now() - started) / 1000) }),
  "/api/time": (req, res) => json(res, 200, { now: new Date().toISOString() }),
  "/api/slow": (req, res) => setTimeout(() => json(res, 200, { slow: true }), 800),
  "/api/boom": (req, res) => {
    console.error(`${c.red}Error: boom (demandé par le client)\n    at routes["/api/boom"] (server.js)${c.reset}`);
    json(res, 500, { error: "boom" });
  },
};

function json(res, code, body) {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body) + "\n");
  res.statusCode = code;
}

const server = http.createServer((req, res) => {
  hits++;
  const t0 = process.hrtime.bigint();
  res.on("finish", () => {
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    log(`${c.cyan}${req.method}${c.reset} ${req.url} ${paint(res.statusCode)}${res.statusCode}${c.reset} ${c.dim}${ms.toFixed(1)}ms${c.reset}`);
  });
  const handler = routes[req.url.split("?")[0]];
  if (handler) return handler(req, res);
  json(res, 404, { error: "not found" });
});

server.listen(port, () => log(`${c.green}api prête${c.reset} sur http://localhost:${port} (${process.env.NODE_ENV || "dev"})`));

// Arrêt propre : zpawn envoie SIGTERM, on finit les requêtes en cours.
process.on("SIGTERM", () => {
  log(`${c.yellow}SIGTERM reçu, arrêt en douceur...${c.reset}`);
  server.close(() => {
    log("serveur fermé");
    process.exit(0);
  });
});
