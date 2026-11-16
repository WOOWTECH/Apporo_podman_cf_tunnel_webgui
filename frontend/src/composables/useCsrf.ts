/**
 * Read the CSRF token from the cookie set by starlette-csrf.
 * Issues a warning if the cookie is missing (e.g. first load race condition).
 *
 * The cookie is named apporo_csrftoken, not starlette-csrf's default csrftoken: browsers
 * share cookies across the ports of one host, so another tunnel GUI opened on localhost
 * keeps its own csrftoken cookie next to ours, signed with its own secret.
 */
export function getCsrfToken(): string {
  const match = document.cookie.match(/(?:^|;\s*)apporo_csrftoken=([^;]+)/)
  const token = match ? match[1] : ''
  if (!token) {
    console.warn('[useCsrf] CSRF token not found in cookies — requests may be rejected')
  }
  return token
}
