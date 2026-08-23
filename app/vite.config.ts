import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const runtimeEnv = (
  globalThis as unknown as {
    process?: { env?: Record<string, string | undefined> };
  }
).process?.env ?? {};

export default defineConfig(() => {
  const releaseMode =
    runtimeEnv.NARA_RELEASE_MODE?.trim().toLowerCase() === "activated"
      ? "activated"
      : "preview";
  const commit =
    runtimeEnv.CF_PAGES_COMMIT_SHA?.trim() ||
    runtimeEnv.GITHUB_SHA?.trim() ||
    "local";
  const branch =
    runtimeEnv.CF_PAGES_BRANCH?.trim() ||
    runtimeEnv.GITHUB_REF_NAME?.trim() ||
    "local";

  return {
    plugins: [
      react(),
      {
        name: "nara-release-evidence",
        transformIndexHtml(html: string) {
          const robots =
            releaseMode === "activated"
              ? "index, follow"
              : "noindex, nofollow, noarchive";
          return {
            html: html.replace(
              /<meta name="robots" content="[^"]*"\s*\/?>/i,
              `<meta name="robots" content="${robots}" />`,
            ),
            tags: [
              {
                tag: "meta",
                attrs: { name: "nara-build-commit", content: commit },
                injectTo: "head",
              },
              {
                tag: "meta",
                attrs: { name: "nara-build-branch", content: branch },
                injectTo: "head",
              },
              {
                tag: "meta",
                attrs: { name: "nara-release-mode", content: releaseMode },
                injectTo: "head",
              },
            ],
          };
        },
      },
    ],
    server: {
      port: 4175,
    },
  };
});
