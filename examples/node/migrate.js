// Un script "one-shot" : il fait son travail puis se termine.
// Dans zpawn.yaml il a `restart: false`, donc il n'est pas relancé.
const steps = ["création des tables", "index", "données de démonstration"];
let i = 0;
const next = () => {
  if (i === steps.length) {
    console.log("\x1b[32mmigrations terminées\x1b[0m");
    return;
  }
  console.log(`[${i + 1}/${steps.length}] ${steps[i++]}...`);
  setTimeout(next, 400);
};
next();
