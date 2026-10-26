// Un worker de file d'attente simulé : node worker.js
// QUEUE donne le nom de la file ; une tâche sur 7 échoue pour avoir des warnings.
const queue = process.env.QUEUE || "default";
const c = { reset: "\x1b[0m", dim: "\x1b[2m", green: "\x1b[32m", yellow: "\x1b[1;33m", cyan: "\x1b[36m", red: "\x1b[31m" };

let n = 0;
console.log(`${c.cyan}worker${c.reset} à l'écoute de la file « ${queue} »`);

const timer = setInterval(() => {
  n++;
  const id = `job-${String(n).padStart(4, "0")}`;
  if (n % 7 === 0) {
    console.log(`${c.yellow}WARN${c.reset} ${id} a échoué, nouvel essai plus tard`);
  } else {
    console.log(`${c.green}OK${c.reset}   ${id} traité ${c.dim}(${queue})${c.reset}`);
  }
}, 1500);

process.on("SIGTERM", () => {
  clearInterval(timer);
  console.log(`${c.dim}worker: ${n} tâches traitées, bye${c.reset}`);
  process.exit(0);
});
