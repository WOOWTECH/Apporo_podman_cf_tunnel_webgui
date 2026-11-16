import { describe, it, expect, vi, afterEach } from 'vitest'
import { api } from '../api'

describe('api()', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('sends the CSRF header on state-changing requests only', async () => {
    document.cookie = 'apporo_csrftoken=tok123'
    const fetchMock = vi.fn(async () => ({ ok: true, json: async () => ({}) }))
    vi.stubGlobal('fetch', fetchMock)
    await api('/api/config')
    await api('/api/tunnel/start', { method: 'POST' })
    const calls = fetchMock.mock.calls as unknown as [string, RequestInit][]
    expect((calls[0][1].headers as Record<string, string>)['x-csrftoken']).toBeUndefined()
    expect((calls[1][1].headers as Record<string, string>)['x-csrftoken']).toBe('tok123')
  })

  it('turns a FastAPI 422 detail list into field: message', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({
      ok: false,
      status: 422,
      json: async () => ({ detail: [{ loc: ['body', 'tunnel_token'], msg: 'bad token', type: 'value_error' }] }),
    })))
    await expect(api('/api/config', { method: 'PUT' })).rejects.toThrow('tunnel_token: bad token')
  })

  it('passes a string detail through', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 409, json: async () => ({ detail: 'Release the Apporo binding first' }) })))
    await expect(api('/api/config', { method: 'PUT' })).rejects.toThrow('Release the Apporo binding first')
  })

  it("sends this app's apporo_csrftoken, never another GUI's csrftoken", async () => {
    // Cookies are per host, not per port: a second tunnel GUI opened on localhost (WOOW's
    // uses starlette-csrf's default name) keeps its own csrftoken cookie in the same jar.
    const expired = '=; expires=Thu, 01 Jan 1970 00:00:00 GMT'
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    document.cookie = 'csrftoken=other-gui-token'
    document.cookie = 'apporo_csrftoken=tok123'
    const fetchMock = vi.fn(async () => ({ ok: true, json: async () => ({}) }))
    vi.stubGlobal('fetch', fetchMock)
    await api('/api/tunnel/stop', { method: 'POST' })
    document.cookie = `apporo_csrftoken${expired}`
    await api('/api/tunnel/stop', { method: 'POST' })
    document.cookie = `csrftoken${expired}`
    warn.mockRestore()
    const calls = fetchMock.mock.calls as unknown as [string, RequestInit][]
    expect((calls[0][1].headers as Record<string, string>)['x-csrftoken']).toBe('tok123')
    // without a cookie of its own it sends no token, rather than the other GUI's
    expect((calls[1][1].headers as Record<string, string>)['x-csrftoken']).toBe('')
  })
})
