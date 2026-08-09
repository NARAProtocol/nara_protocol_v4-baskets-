import { execFileSync } from "node:child_process";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const obsoleteRepositorySlug = ["nara_protocol_v4", "baskets", ""].join("-");
const ignoredDirectories = new Set([
  ".git",
  ".tmp",
  ".wrangler",
  "broadcast",
  "cache",
  "dist",
  "lib",
  "node_modules",
  "out",
]);

const requiredFiles = [
  "README.md",
  "SECURITY.md",
  "CONTRIBUTING.md",
  "CODE_OF_CONDUCT.md",
  "LICENSE",
  "AGENTS.md",
  ".env.example",
  ".gitattributes",
  ".editorconfig",
  ".gitmodules",
  "docs/REPOSITORY_MAINTENANCE.md",
  "docs/VALIDATION_STATUS.md",
  "docs/UI_UX_NEUTRAL_ACTION_HIERARCHY.md",
  "app/README.md",
  "app/AGENTS.md",
  "app/DESIGN.md",
  "app/.env.example",
  "app/.dev.vars.example",
  "app/package.json",
  "app/package-lock.json",
  ".github/CODEOWNERS",
  ".github/dependabot.yml",
  ".github/pull_request_template.md",
  ".github/ISSUE_TEMPLATE/bug.yml",
  ".github/ISSUE_TEMPLATE/proposal.yml",
  ".github/workflows/ci.yml",
  ".github/workflows/codeql.yml",
];

const secretPatterns = [
  {
    name: "private key assignment",
    pattern:
      /\b(?:PRIVATE_KEY|OWNER_PRIVATE_KEY|TREASURY_PRIVATE_KEY|LIQ_PRIVATE_KEY)\s*[:=]\s*["']?0x[a-fA-F0-9]{64}\b/g,
  },
  {
    name: "mnemonic or seed phrase assignment",
    pattern:
      /\b(?:MNEMONIC|SEED_PHRASE)\s*[:=]\s*["'][^"'\r\n]{20,}["']/gi,
  },
  {
    name: "credential-bearing RPC URL",
    pattern:
      /https:\/\/[^\s"'`]*(?:alchemy\.com|infura\.io|quiknode\.pro)\/(?:v2|v3|[a-fA-F0-9]{16,})\/?[^\s"'`)]+/gi,
  },
  {
    name: "GitHub token",
    pattern: /\b(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b/g,
  },
  {
    name: "provider API token",
    pattern:
      /\b(?:sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[0-9A-Za-z-]{10,})\b/g,
  },
];

const textExtensions = new Set([
  ".cjs",
  ".css",
  ".html",
  ".js",
  ".json",
  ".md",
  ".mjs",
  ".ps1",
  ".sh",
  ".sol",
  ".toml",
  ".ts",
  ".tsx",
  ".txt",
  ".yml",
  ".yaml",
]);

async function exists(filePath) {
  try {
    await stat(filePath);
    return true;
  } catch {
    return false;
  }
}

async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) continue;
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walk(absolute)));
    } else if (entry.isFile()) {
      files.push(absolute);
    }
  }
  return files;
}

function relative(absolute) {
  return path.relative(root, absolute).replaceAll("\\", "/");
}

function localMarkdownTargets(markdown) {
  const targets = [];
  const pattern = /!?\[[^\]]*]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/g;
  for (const match of markdown.matchAll(pattern)) {
    const raw = match[1].replace(/^<|>$/g, "");
    if (
      raw.startsWith("#") ||
      raw.startsWith("http://") ||
      raw.startsWith("https://") ||
      raw.startsWith("mailto:")
    ) {
      continue;
    }
    targets.push(decodeURIComponent(raw.split("#", 1)[0]));
  }
  return targets;
}

function trackedFiles() {
  return execFileSync("git", ["ls-files", "-z"], {
    cwd: root,
    encoding: "utf8",
  })
    .split("\0")
    .filter(Boolean)
    .map((file) => file.replaceAll("\\", "/"));
}

const errors = [];

for (const file of requiredFiles) {
  if (!(await exists(path.join(root, file)))) {
    errors.push(`required file missing: ${file}`);
  }
}

const forbiddenLocalFiles = [
  ".env",
  ".env.local",
  ".dev.vars",
  "app/.env",
  "app/.env.local",
  "app/.env.production",
  "app/.dev.vars",
];
for (const file of forbiddenLocalFiles) {
  if (await exists(path.join(root, file))) {
    errors.push(`private environment file present in repository tree: ${file}`);
  }
}

for (const file of trackedFiles()) {
  if (
    /(^|\/)(?:node_modules|dist|out|cache|broadcast|\.wrangler|\.tmp)(\/|$)/.test(
      file,
    )
  ) {
    errors.push(`generated or runtime path is tracked: ${file}`);
  }
  if (
    /(^|\/)(?:\.env(?:$|\.(?!example$))|\.dev\.vars$|.*\.(?:pem|key|p12|pfx|keystore)$)/i.test(
      file,
    )
  ) {
    errors.push(`credential-risk file is tracked: ${file}`);
  }
}

const files = await walk(root);
for (const absolute of files) {
  const extension = path.extname(absolute).toLowerCase();
  if (!textExtensions.has(extension)) continue;

  const content = await readFile(absolute, "utf8");
  const file = relative(absolute);

  for (const { name, pattern } of secretPatterns) {
    pattern.lastIndex = 0;
    if (pattern.test(content)) {
      errors.push(`${name} detected: ${file}`);
    }
  }

  if (content.includes(obsoleteRepositorySlug)) {
    errors.push(`obsolete repository slug detected: ${file}`);
  }

  if (
    file.startsWith("script/") &&
    (content.includes("CategoryIndexSuiteV1") ||
      content.includes("NARAIndexFeeCollectorV1"))
  ) {
    errors.push(
      `noncanonical reference contract is wired into a deployment or verification script: ${file}`,
    );
  }

  if (extension === ".json") {
    try {
      JSON.parse(content);
    } catch (error) {
      errors.push(`invalid JSON: ${file}: ${error.message}`);
    }
  }

  if (extension === ".md") {
    for (const target of localMarkdownTargets(content)) {
      if (!target) continue;
      const resolved = path.resolve(path.dirname(absolute), target);
      if (!(await exists(resolved))) {
        errors.push(`broken local Markdown link: ${file} -> ${target}`);
      }
    }
  }

  if (file.startsWith(".github/workflows/")) {
    for (const match of content.matchAll(/^\s*uses:\s*([^@\s]+)@([^\s#]+)/gm)) {
      const [, action, reference] = match;
      if (action.startsWith("docker://")) continue;
      if (!/^[a-f0-9]{40}$/i.test(reference)) {
        errors.push(`GitHub Action is not pinned to a full SHA: ${file}: ${action}@${reference}`);
      }
    }
  }
}

try {
  const status = execFileSync("git", ["submodule", "status", "--recursive"], {
    cwd: root,
    encoding: "utf8",
  });
  for (const line of status.split(/\r?\n/).filter(Boolean)) {
    if (/^[-+U]/.test(line)) {
      errors.push(`submodule is missing or not at its recorded commit: ${line.slice(0, 80)}`);
    }
  }
} catch (error) {
  errors.push(`unable to verify submodule pins: ${error.message}`);
}

if (errors.length > 0) {
  console.error("Repository verification failed:");
  for (const error of errors) console.error(`- ${error}`);
  process.exitCode = 1;
} else {
  console.log(
    `Repository verification passed (${files.length} files inspected; tracked secrets and Action pins checked).`,
  );
}
