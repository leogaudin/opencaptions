/**
 * Shared client-side validation for the auth screens.
 *
 * The server remains the source of truth: these checks only catch obvious
 * mistakes early and keep the login and signup forms consistent.
 */

import { translate } from "@/lib/i18n";

/** Minimum password length enforced on account creation. */
export const MIN_PASSWORD_LENGTH = 8;

/** Returns an error message, or null when the email is acceptable. */
export function validateEmail(email: string): string | null {
  const value = email.trim();
  if (!value) return translate("Email is required.");
  // Permissive shape check, deliberately not RFC-complete.
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
    return translate("Enter a valid email address.");
  }
  return null;
}

/**
 * Returns an error message, or null when the password is acceptable.
 * `requireStrength` enforces the minimum length: used on signup, not login
 * (login must stay generic and never hint at password rules).
 */
export function validatePassword(
  password: string,
  opts: { requireStrength?: boolean } = {},
): string | null {
  if (!password) return translate("Password is required.");
  if (opts.requireStrength && password.length < MIN_PASSWORD_LENGTH) {
    return translate("Password must be at least {n} characters.", { n: MIN_PASSWORD_LENGTH });
  }
  return null;
}
