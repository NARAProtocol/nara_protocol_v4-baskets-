import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { resolve, relative } from "node:path";

const root = resolve(process.cwd(), process.argv[2] || "dist");

async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await walk(path)));
    if (entry.isFile()) files.push(path);
  }
  return files;
}

const digest = createHash("sha256");
const files = (await walk(root)).sort((a, b) => a.localeCompare(b));

for (const file of files) {
  const path = relative(root, file).replaceAll("\\", "/");
  const content = await readFile(file);
  digest.update(path);
  digest.update("\0");
  digest.update(createHash("sha256").update(content).digest("hex"));
  digest.update("\n");
}

console.log(digest.digest("hex"));
