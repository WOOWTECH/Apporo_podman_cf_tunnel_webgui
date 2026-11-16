/**
 * Front-end hostname pre-check, kept consistent with the backend
 * `VALID_HOSTNAME_RE` in `backend/models/schemas.py`:
 * lowercase, no protocol (`://`), no port (`:`).
 */
export const VALID_HOSTNAME_RE =
  /^(([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9])\.)*([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9])$/

/**
 * Returns a human-readable error message for an invalid hostname,
 * or `null` when the hostname is valid.
 */
export function hostnameError(raw: string): string | null {
  const value = raw.trim().toLowerCase()
  if (!value) return 'Hostname is required'
  if (raw.includes('://')) return 'Hostname must not include a protocol (such as http://)'
  if (raw.includes(':')) return 'Hostname must not include a port (such as :8123)'
  if (!VALID_HOSTNAME_RE.test(value)) {
    return 'Invalid hostname (only lowercase letters, digits, "-" and "." are allowed)'
  }
  return null
}
