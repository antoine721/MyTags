// Worker bindings (see wrangler.jsonc). Declared on Cloudflare.Env so that
// `env` from "cloudflare:workers" is typed too.
declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    BUCKET: R2Bucket;
    ADMIN_TOKEN: string;
  }
}

interface Env extends Cloudflare.Env {}
