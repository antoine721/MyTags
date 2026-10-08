// Minimal router: exact or regex paths, per-method handlers, per-route access.

import { authenticate, type Principal } from "./auth";
import { HttpError } from "./http";

/** Who may call a route: anyone, any valid token, or the admin token only. */
export type Access = "public" | "token" | "admin";

export interface RequestContext {
  request: Request;
  env: Env;
  ctx: ExecutionContext;
  url: URL;
  /** Regex capture groups of the matched path. */
  params: string[];
  /** Undefined only on public routes. */
  principal: Principal | undefined;
}

export type Handler = (context: RequestContext) => Promise<Response> | Response;

export interface Route {
  path: string | RegExp;
  access: Access;
  methods: Partial<Record<string, Handler>>;
}

export async function dispatch(
  routes: readonly Route[],
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const url = new URL(request.url);
  for (const route of routes) {
    const params = matchPath(route.path, url.pathname);
    if (params === undefined) continue;
    const principal = route.access === "public" ? undefined : await authenticate(request, env, ctx);
    if (route.access === "admin" && principal?.role !== "admin") {
      throw new HttpError(403, "forbidden", "This route requires the admin token");
    }
    const handler = route.methods[request.method];
    if (handler === undefined) {
      const allowed = Object.keys(route.methods);
      if (allowed.length === 0) break;
      const allow = allowed.join(", ");
      throw new HttpError(405, "method_not_allowed", `Use ${allow} for ${url.pathname}`, { allow });
    }
    return handler({ request, env, ctx, url, params, principal });
  }
  throw new HttpError(404, "not_found", `No route for ${url.pathname}`);
}

function matchPath(pattern: string | RegExp, pathname: string): string[] | undefined {
  if (typeof pattern === "string") return pattern === pathname ? [] : undefined;
  const match = pattern.exec(pathname);
  return match === null ? undefined : match.slice(1).map((group) => group ?? "");
}

/** The authenticated principal of a non-public route. */
export function principalOf(context: RequestContext): Principal {
  if (context.principal === undefined) throw new Error("route is public");
  return context.principal;
}
