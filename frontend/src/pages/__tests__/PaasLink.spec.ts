import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import PaasLink from '../PaasLink.vue'

const BOOTSTRAP = {
  authorized: false,
  portal_url: 'https://www.apporo.ai/woow#/workspaces',
  connection: null,
  release_pending: false,
}

function ok(body: unknown) {
  return { ok: true, json: async () => body }
}

function mountPage() {
  return mount(PaasLink, { global: { stubs: { RouterLink: { template: '<a><slot /></a>' } } } })
}

function link(wrapper: ReturnType<typeof mountPage>, text: string) {
  return wrapper.findAll('a').find((a) => a.text().includes(text))!
}

describe('PaasLink', () => {
  beforeEach(() => {
    document.cookie = 'apporo_csrftoken=tok123'
  })
  afterEach(() => vi.unstubAllGlobals())

  it('explains the Apporo Security Access link and opens the portal the backend returns', async () => {
    vi.stubGlobal('fetch', vi.fn(async (url: string) => {
      if (url === '/api/paas/bootstrap') return ok(BOOTSTRAP)
      throw new Error(`unexpected fetch ${url}`)
    }))
    const wrapper = mountPage()
    await flushPromises()
    expect(wrapper.text()).toContain('Link this host to Apporo Security Access')
    expect(link(wrapper, 'Subscribe on Apporo').attributes('href')).toBe('https://www.apporo.ai/woow#/workspaces')
  })

  it('falls back to the Apporo portal when the backend cannot be read', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 502, json: async () => ({ detail: 'down' }) })))
    const wrapper = mountPage()
    await flushPromises()
    expect(wrapper.get('[role="alert"]').text()).toBe('down')
    expect(link(wrapper, 'Subscribe on Apporo').attributes('href')).toBe('https://www.apporo.ai/woow#/workspaces')
  })

  it('shows the device code and the verification page the platform returns', async () => {
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      if (url === '/api/paas/bootstrap') return ok(BOOTSTRAP)
      if (url === '/api/paas/authorization' && init?.method === 'POST') {
        return ok({ user_code: 'WDJB-MJHT', verification_url: 'https://www.apporo.ai/device?user_code=WDJB-MJHT', expires_in: 900, interval: 5 })
      }
      throw new Error(`unexpected fetch ${url}`)
    })
    vi.stubGlobal('fetch', fetchMock)
    const wrapper = mountPage()
    await flushPromises()
    await wrapper.findAll('button').find((b) => b.text() === 'Get device code')!.trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('WDJB-MJHT')
    expect(link(wrapper, 'Open the device page').attributes('href')).toBe('https://www.apporo.ai/device?user_code=WDJB-MJHT')
    const [, init] = fetchMock.mock.calls.find(([url]) => url === '/api/paas/authorization')!
    expect((init!.headers as Record<string, string>)['x-csrftoken']).toBe('tok123')
    wrapper.unmount() // clears the pending authorization poll
  })
})
