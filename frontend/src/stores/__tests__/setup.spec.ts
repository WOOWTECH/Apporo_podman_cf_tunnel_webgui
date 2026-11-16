import { setActivePinia, createPinia } from 'pinia'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { useSetupStore } from '../setup'

describe('setup store', () => {
  beforeEach(() => setActivePinia(createPinia()))
  afterEach(() => vi.unstubAllGlobals())

  it('fetchState stores hasCert/hasTunnel/tunnelUuid/mode', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          has_cert: true,
          has_tunnel: false,
          tunnel_uuid: null,
          mode: 'local',
        }),
      })
    )
    const s = useSetupStore()
    await s.fetchState()
    expect(s.hasCert).toBe(true)
    expect(s.hasTunnel).toBe(false)
    expect(s.tunnelUuid).toBe(null)
    expect(s.mode).toBe('local')
    expect(s.error).toBe(null)
  })

  it('fetchState stores the error when it fails', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        text: async () => 'Server error',
      })
    )
    const s = useSetupStore()
    await s.fetchState()
    expect(s.error).toBe('Server error')
  })

  it('createTunnel sends the CSRF header and updates tunnelUuid/hasTunnel', async () => {
    document.cookie = 'apporo_csrftoken=tok123'
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ tunnel_uuid: 'uuid-abc' }),
    })
    vi.stubGlobal('fetch', fetchMock)
    const s = useSetupStore()
    const ok = await s.createTunnel('my-tunnel')
    expect(ok).toBe(true)
    expect(s.tunnelUuid).toBe('uuid-abc')
    expect(s.hasTunnel).toBe(true)

    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('/api/setup/tunnel')
    expect(init.method).toBe('POST')
    expect(init.headers['x-csrftoken']).toBe('tok123')
    expect(JSON.parse(init.body)).toEqual({ tunnel_name: 'my-tunnel' })
  })

  it('apply sends routes + catch_all_service', async () => {
    document.cookie = 'apporo_csrftoken=tok123'
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ status: 'applied', route_count: 1 }),
    })
    vi.stubGlobal('fetch', fetchMock)
    const s = useSetupStore()
    const routes = [
      { hostname: 'app.example.com', service: 'http://localhost:8080', disableChunkedEncoding: false },
    ]
    const ok = await s.apply(routes, 'http_status:404')
    expect(ok).toBe(true)

    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('/api/setup/apply')
    expect(init.headers['x-csrftoken']).toBe('tok123')
    expect(JSON.parse(init.body)).toEqual({
      routes,
      catch_all_service: 'http_status:404',
    })
  })

  it('apply stores the 422 detail as the error and returns false', async () => {
    document.cookie = 'apporo_csrftoken=tok123'
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 422,
        json: async () => ({ detail: 'ingress validation failed: bad hostname' }),
      })
    )
    const s = useSetupStore()
    const ok = await s.apply([], '')
    expect(ok).toBe(false)
    expect(s.error).toBe('ingress validation failed: bad hostname')
  })
})
