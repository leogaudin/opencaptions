/**
 * Auth types — DERIVED from the generated OpenAPI schema (api.generated.ts).
 *
 * These were declared locally when the backend had not yet regenerated the
 * schema. It has since done so, so each type below aliases its generated
 * `components["schemas"][...]` counterpart — exactly as the domain types in
 * ./index.ts do — so the TypeScript compiler catches any drift between the
 * backend auth models and the frontend.
 *
 * The exported names (`AuthUser`, `AuthSession`, `AuthStatus`) are kept as-is so
 * existing call sites need no changes.
 */
import type { components } from "./api.generated";

/** The signed-in user as returned by register / login / me. */
export type AuthUser = components["schemas"]["UserRead"];

/** Successful auth response: the user plus a CSRF token (held in memory only). */
export type AuthSession = components["schemas"]["AuthResponse"];

/**
 * Public instance state from GET /auth/status.
 * `setup_required` is true when the instance has no users yet (first run).
 */
export type AuthStatus = components["schemas"]["AuthStatus"];
