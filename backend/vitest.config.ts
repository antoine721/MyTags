import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export const TEST_ADMIN_TOKEN = "test-admin-token-0123456789abcdef";

export default defineConfig(async () => {
  // Read in Node.js, applied inside the Workers runtime by test/setup.ts.
  const migrations = await readD1Migrations("migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: { ADMIN_TOKEN: TEST_ADMIN_TOKEN, TEST_MIGRATIONS: migrations },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/setup.ts"],
    },
  };
});
