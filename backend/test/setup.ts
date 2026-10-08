import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Idempotent: migrations already recorded in d1_migrations are skipped.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
