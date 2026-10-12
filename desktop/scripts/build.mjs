import { build } from "esbuild";
import { mkdir, copyFile } from "node:fs/promises";
await mkdir("out/ui", { recursive: true });
await Promise.all([
  build({
    entryPoints: ["src/main.ts"],
    outfile: "out/main.cjs",
    bundle: true,
    platform: "node",
    format: "cjs",
    external: ["electron"],
    target: "node22",
  }),
  build({
    entryPoints: ["src/preload.ts"],
    outfile: "out/preload.cjs",
    bundle: true,
    platform: "node",
    format: "cjs",
    external: ["electron"],
    target: "node22",
  }),
  build({
    entryPoints: ["src/renderer/app.ts"],
    outfile: "out/ui/app.js",
    bundle: true,
    platform: "browser",
    format: "esm",
    target: "chrome140",
  }),
]);
for (const name of ["index.html", "style.css", "pcm-worklet.js"])
  await copyFile(`src/renderer/${name}`, `out/ui/${name}`);
await copyFile("assets/logo.svg", "out/ui/logo.svg");
