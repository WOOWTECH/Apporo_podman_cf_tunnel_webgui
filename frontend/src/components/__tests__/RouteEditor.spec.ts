import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import RouteEditor from '../RouteEditor.vue'
import type { Route } from '@/types'

function makeRoute(overrides: Partial<Route> = {}): Route {
  return { hostname: '', service: '', disableChunkedEncoding: false, ...overrides }
}

describe('RouteEditor', () => {
  it('clicking “Add route” emits update:routes with one more row', async () => {
    const wrapper = mount(RouteEditor, { props: { routes: [] } })
    await wrapper.get('[data-test="add-row"]').trigger('click')

    const emitted = wrapper.emitted('update:routes')
    expect(emitted).toBeTruthy()
    const payload = emitted![0][0] as Route[]
    expect(payload).toHaveLength(1)
    expect(payload[0]).toEqual({ hostname: '', service: '', disableChunkedEncoding: false })
  })

  it('clicking “Remove” emits the routes without that row', async () => {
    const routes = [
      makeRoute({ hostname: 'a.example.com', service: 'http://x' }),
      makeRoute({ hostname: 'b.example.com', service: 'http://y' }),
    ]
    const wrapper = mount(RouteEditor, { props: { routes } })
    await wrapper.findAll('[data-test="remove-row"]')[0].trigger('click')

    const payload = wrapper.emitted('update:routes')![0][0] as Route[]
    expect(payload).toHaveLength(1)
    expect(payload[0].hostname).toBe('b.example.com')
  })

  it('a valid hostname shows no error', () => {
    const routes = [makeRoute({ hostname: 'app.example.com', service: 'http://x' })]
    const wrapper = mount(RouteEditor, { props: { routes } })
    expect(wrapper.find('[data-test="hostname-error"]').exists()).toBe(false)
  })

  it('a hostname with a protocol shows an error', () => {
    const routes = [makeRoute({ hostname: 'https://app.example.com', service: 'http://x' })]
    const wrapper = mount(RouteEditor, { props: { routes } })
    const err = wrapper.find('[data-test="hostname-error"]')
    expect(err.exists()).toBe(true)
    expect(err.text()).toContain('protocol')
  })

  it('a hostname with a port shows an error', () => {
    const routes = [makeRoute({ hostname: 'app.example.com:8123', service: 'http://x' })]
    const wrapper = mount(RouteEditor, { props: { routes } })
    expect(wrapper.find('[data-test="hostname-error"]').text()).toContain('port')
  })

  it('typing a hostname emits update:routes with the new value', async () => {
    const routes = [makeRoute({ service: 'http://x' })]
    const wrapper = mount(RouteEditor, { props: { routes } })
    const input = wrapper.get('input[type="text"]')
    await input.setValue('new.example.com')

    const payload = wrapper.emitted('update:routes')![0][0] as Route[]
    expect(payload[0].hostname).toBe('new.example.com')
  })
})
