<template>
  <div class="space-y-6 pb-12">
    <section class="overflow-hidden rounded-3xl bg-ink px-6 py-8 text-white shadow-xl sm:px-9">
      <p class="text-xs font-semibold uppercase tracking-[0.25em] text-brand-300">Apporo · Security Access</p>
      <h1 class="mt-3 text-3xl font-bold tracking-tight sm:text-4xl">Link this host to Apporo Security Access</h1>
      <p class="mt-3 max-w-2xl text-sm leading-7 text-stone-300">Sign in at www.apporo.ai with a device code, pick your workspace and Security Access service, review the routes, then connect. This page checks every route and binding condition and links this host only when they all pass.</p>
      <div class="mt-6 flex flex-wrap gap-2 text-xs font-medium">
        <span v-for="(step, index) in steps" :key="step" class="rounded-full border border-white/20 bg-white/10 px-3 py-1.5"><span class="mr-1.5 font-semibold text-brand-300">{{ index + 1 }}</span>{{ step }}</span>
      </div>
    </section>

    <div v-if="error" role="alert" class="rounded-xl border border-red-200 bg-red-50 px-5 py-4 text-sm text-red-800">{{ error }}</div>
    <div v-if="message" role="status" class="rounded-xl border border-blue-200 bg-blue-50 px-5 py-4 text-sm text-blue-800">{{ message }}</div>

    <section class="rounded-2xl border border-gray-200 bg-white p-6 shadow-sm sm:p-7">
      <div class="flex items-start gap-4">
        <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-brand-100 font-bold text-brand-700">1</span>
        <div class="min-w-0 flex-1">
          <h2 class="text-lg font-semibold text-ink">Subscribe on Apporo</h2>
          <p class="mt-1 text-sm leading-6 text-gray-600">On www.apporo.ai, choose a workspace and a plan, then create a Security Access service. Prices and payment are confirmed on Apporo; nothing is charged from this page.</p>
          <div class="mt-3 rounded-xl bg-brand-100 px-4 py-3 text-sm leading-6 text-brand-900">
            <p class="font-semibold">One public hostname needs one route. Access seats are optional.</p>
            <p class="mt-1">You can bind the tunnel without Access seats, but the hostname is then open to the whole internet. To have Cloudflare let in only the email addresses you allow, buy Access seats for the number of people and turn on protection for the route.</p>
          </div>
          <a :href="bootstrap?.portal_url || portalFallback" target="_blank" rel="noopener noreferrer" class="mt-4 inline-flex rounded-lg bg-brand px-4 py-2.5 text-sm font-semibold text-white hover:bg-brand-700">Subscribe on Apporo ↗</a>
          <p class="mt-3 text-xs text-gray-500">Already subscribed? Sign in below to choose your existing service.</p>
        </div>
      </div>
    </section>

    <section class="rounded-2xl border border-gray-200 bg-white p-6 shadow-sm sm:p-7">
      <div class="flex items-start gap-4">
        <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-brand-100 font-bold text-brand-700">2</span>
        <div class="min-w-0 flex-1">
          <h2 class="text-lg font-semibold text-ink">Authorize this host</h2>
          <p class="mt-1 text-sm leading-6 text-gray-600">Get a device code, enter it on www.apporo.ai and allow the connection. This page never asks you to paste a tunnel token.</p>
          <div v-if="bootstrap?.authorized" class="mt-4 flex flex-wrap items-center gap-3">
            <span class="inline-flex rounded-full bg-emerald-100 px-3 py-1.5 text-xs font-semibold text-emerald-800">✓ Apporo account connected</span>
            <button v-if="!bootstrap.connection && !bootstrap.release_pending" class="text-xs font-semibold text-gray-600 underline" @click="revokeAuthorization">Revoke account authorization</button>
          </div>
          <div v-else class="mt-4 space-y-4">
            <button :disabled="busy" class="rounded-lg bg-ink px-4 py-2.5 text-sm font-semibold text-white disabled:opacity-50" @click="beginAuthorization">Get device code</button>
            <div v-if="authorization" class="rounded-xl border border-blue-200 bg-blue-50 p-5">
              <p class="text-sm font-medium text-blue-900">Enter this code on the Apporo device page, then select Allow</p>
              <p class="mt-2 select-all font-mono text-2xl font-bold tracking-widest text-ink">{{ authorization.user_code }}</p>
              <a :href="authorization.verification_url" target="_blank" rel="noopener noreferrer" class="mt-3 inline-block rounded-lg bg-blue-700 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-800">Open the device page ↗</a>
              <p class="mt-3 text-xs text-blue-700">{{ authStatus === 'waiting' ? 'Waiting for you to allow the connection on Apporo. This page updates automatically.' : 'The code is valid for about 15 minutes.' }}</p>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section class="rounded-2xl border border-gray-200 bg-white p-6 shadow-sm sm:p-7" :class="!bootstrap?.authorized ? 'opacity-70' : ''">
      <div class="flex items-start gap-4">
        <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-brand-100 font-bold text-brand-700">3</span>
        <div class="min-w-0 flex-1">
          <h2 class="text-lg font-semibold text-ink">Choose a service and review each hostname's access mode</h2>
          <p class="mt-1 text-sm leading-6 text-gray-600">First add your hostnames on the Application tab of the Security Access service on Apporo. If a hostname needs Cloudflare Access, set its login method and allow list on the Access tab; otherwise leave Access off for that route. Then come back here and choose the service.</p>
          <details class="mt-3 rounded-xl bg-stone-50 px-4 py-3 text-sm text-stone-700">
            <summary class="cursor-pointer font-semibold">Which service URL should an Apporo route use? What if it returns 400 or 502?</summary>
            <p class="mt-3 leading-6">cloudflared runs on this host with host networking, so the service URL points at a service on this host, for example <code>http://localhost:8123</code> (Home Assistant) or <code>http://localhost:80</code> (Nginx Proxy Manager). Use the port the service actually listens on.</p>
            <p class="mt-2 leading-6">A 502 usually means a wrong port or a service that is not running; check it on the host, for example with <code>curl -I http://localhost:&lt;port&gt;</code>. If the service answers 400, check whether it rejects reverse proxies: Home Assistant needs <code>use_x_forwarded_for</code> turned on in its <code>http</code> settings, with <code>127.0.0.1</code> in <code>trusted_proxies</code>.</p>
            <a href="https://www.home-assistant.io/integrations/http/#reverse-proxies" target="_blank" rel="noopener noreferrer" class="mt-2 inline-block font-semibold text-brand underline">Home Assistant reverse proxy settings ↗</a>
          </details>
          <template v-if="bootstrap?.authorized">
            <button :disabled="busy" class="mt-4 rounded-lg border border-brand bg-brand-50 px-4 py-2 text-sm font-semibold text-brand-700 hover:bg-brand-100 disabled:opacity-50" @click="refreshServices">I've finished on Apporo, reload services</button>
            <div class="mt-5 grid gap-3 sm:grid-cols-2">
              <label class="text-sm font-medium text-gray-700">Workspace
                <select v-model="workspaceId" class="mt-2 block w-full rounded-lg border border-gray-300 bg-white px-3 py-2.5 text-sm" @change="onWorkspaceChange">
                  <option :value="null">Choose a workspace</option>
                  <option v-for="workspace in workspaces" :key="workspace.id" :value="workspace.id">{{ workspace.name }}</option>
                </select>
              </label>
              <label class="text-sm font-medium text-gray-700">Security Access service
                <select v-model="accessId" :disabled="!workspaceId" class="mt-2 block w-full rounded-lg border border-gray-300 bg-white px-3 py-2.5 text-sm disabled:bg-gray-100" @change="loadReview">
                  <option :value="null">Choose a service</option>
                  <option v-for="access in accesses" :key="access.id" :value="access.id">{{ access.name }} · {{ serviceLabel(access.state) }}</option>
                </select>
              </label>
            </div>
            <div v-if="workspaceId && !accesses.length" class="mt-4 rounded-lg bg-amber-50 px-4 py-3 text-sm text-amber-900">This workspace has no Security Access service yet. <a :href="workspacePortal" target="_blank" rel="noopener noreferrer" class="font-semibold underline">Create one on Apporo ↗</a></div>
            <div v-if="review" class="mt-5 rounded-xl border p-5" :class="review.ready && !review.public_routes.length ? 'border-emerald-200 bg-emerald-50' : 'border-amber-200 bg-amber-50'">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h3 class="font-semibold text-ink">{{ review.access.name }} · {{ review.ready ? (review.public_routes.length ? 'Ready to connect (includes public hostnames)' : 'Ready to connect') : 'Setup needed' }}</h3>
                <button class="text-xs font-semibold text-stone-700 underline" @click="loadReview">Check again</button>
              </div>
              <p class="mt-2 text-xs text-gray-600">Subscription: {{ review.access.subscription?.plan_name || 'Not subscribed' }} ({{ subscriptionLabel(review.access.subscription?.state) }}) · Service: {{ serviceLabel(review.access.state) }} · Binding: {{ bindingLabel(review.access.binding_state) }}</p>
              <p v-if="review.access.subscription?.ac_max_access_seats != null" class="mt-2 text-xs text-gray-600">Access seats: {{ review.access.subscription.ac_used_access_seats ?? '—' }} of {{ review.access.subscription.ac_max_access_seats }} in use. Public routes work with 0 seats; routes protected by Access need seats.</p>
              <div v-for="route in review.access.routes" :key="route.hostname" class="mt-3 rounded-lg bg-white px-4 py-3 text-sm text-gray-700">
                <span :class="route.public ? 'text-amber-700' : route.protected ? 'text-emerald-700' : route.awaiting_publication ? 'text-amber-700' : 'text-red-700'" class="font-bold">{{ route.awaiting_publication ? '…' : route.public ? '○' : route.protected ? '✓' : '!' }}</span>
                <span class="ml-2 font-medium">{{ route.hostname }}</span>
                <span class="ml-2 text-xs text-gray-500">{{ route.public ? (route.awaiting_publication ? 'Public route, waiting for Apporo to publish it' : 'Public route, Access not enabled') : route.protected ? 'Access protection confirmed' : route.awaiting_publication ? 'Access protection set up, waiting to be published' : 'Protection not finished' }}</span>
              </div>
              <ul v-if="review.issues.length" class="mt-4 list-inside list-disc space-y-1 text-sm text-amber-900"><li v-for="issue in review.issues" :key="issue">{{ issue }}</li></ul>
              <p v-if="review.public_routes.length" class="mt-4 rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-950">Not protected by Cloudflare Access: {{ review.public_routes.join(', ') }}. Once the tunnel is connected, anyone who knows the URL can reach the origin service, so make sure the service's own login is turned on.</p>
              <p v-if="review.awaiting_publication" class="mt-4 rounded-lg bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-900">Apporo has just saved the new access settings and publishes them once this host's connector is online. Until then the URL only answers 503 and never reaches your service. After you connect, use “Refresh connection status” below to see when publishing is done.</p>
              <div class="mt-4 flex flex-wrap gap-3 text-sm font-semibold">
                <a :href="review.portal_routes_url" target="_blank" rel="noopener noreferrer" class="text-brand underline">Set up routes ↗</a>
                <a :href="review.portal_access_url" target="_blank" rel="noopener noreferrer" class="text-brand underline">Access protection (optional) ↗</a>
              </div>
            </div>
          </template>
        </div>
      </div>
    </section>

    <section class="rounded-2xl border border-gray-200 bg-white p-6 shadow-sm sm:p-7">
      <div class="flex items-start gap-4">
        <span class="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-brand-100 font-bold text-brand-700">4</span>
        <div class="min-w-0 flex-1">
          <h2 class="text-lg font-semibold text-ink">Connect and enable</h2>
          <p class="mt-1 text-sm leading-6 text-gray-600">Every hostname is checked once more first. Only when that check passes does this host get the tunnel credential, bind to the service and start cloudflared in token mode.</p>
          <button :disabled="!review?.ready || busy" class="mt-4 rounded-lg bg-brand px-5 py-2.5 text-sm font-semibold text-white shadow-sm disabled:cursor-not-allowed disabled:bg-gray-300" @click="connect">{{ busy ? 'Working…' : 'Connect and enable' }}</button>
          <p v-if="bootstrap?.connection && !bootstrap.release_pending" class="mt-4 rounded-lg bg-emerald-50 px-4 py-3 text-sm text-emerald-800">✓ Linked to {{ bootstrap.connection.name }}. See the tunnel status on the Dashboard.</p>
          <div v-if="bootstrap?.release_pending" class="mt-4 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
            The local tunnel is stopped, but the remote binding is not confirmed as released yet (Apporo could not be reached). It is also retried automatically when the service restarts.
            <button class="ml-2 font-semibold underline" @click="finishDisconnect">Retry releasing the binding</button>
          </div>
          <div v-if="bootstrap?.connection" class="mt-4 flex flex-wrap items-center gap-3">
            <button class="rounded-lg border border-gray-300 bg-white px-4 py-2 text-xs font-semibold text-gray-700 hover:bg-gray-50" @click="loadStatus(false)">Refresh connection status</button>
            <button class="rounded-lg border border-blue-300 bg-blue-50 px-4 py-2 text-xs font-semibold text-blue-800 hover:bg-blue-100" @click="checkExternal">Test public URLs</button>
            <button v-if="!bootstrap.release_pending" class="text-xs font-semibold text-red-700 underline" @click="disconnect">Stop the local connection and release the binding</button>
            <button v-else class="text-xs font-semibold text-amber-800 underline" @click="finishDisconnect">Check and finish the remote release</button>
          </div>
          <div v-if="connectionStatus?.connected" class="mt-4 grid gap-3 sm:grid-cols-3">
            <div class="rounded-xl border border-gray-200 bg-gray-50 p-4 text-sm"><p class="text-xs text-gray-500">Subscription</p><p class="mt-1 font-semibold text-ink">{{ subscriptionLabel(connectionStatus.subscription?.state) }}</p></div>
            <div class="rounded-xl border border-gray-200 bg-gray-50 p-4 text-sm"><p class="text-xs text-gray-500">Hostname access</p><p class="mt-1 font-semibold" :class="!connectionStatus.service_ready ? 'text-red-700' : connectionStatus.public_routes.length || connectionStatus.awaiting_publication ? 'text-amber-700' : 'text-emerald-700'">{{ !connectionStatus.service_ready ? 'Needs fixing' : connectionStatus.public_routes.length ? publicRoutesLabel(connectionStatus.public_routes.length) : connectionStatus.awaiting_publication ? 'Waiting for Apporo to publish (URLs answer 503 for now)' : 'Access protection confirmed' }}</p></div>
            <div class="rounded-xl border border-gray-200 bg-gray-50 p-4 text-sm"><p class="text-xs text-gray-500">Tunnel</p><p class="mt-1 font-semibold text-ink">{{ tunnelLabel(connectionStatus.tunnel_status) }}</p></div>
            <p class="sm:col-span-3 text-xs text-gray-500">Checked {{ formatTime(connectionStatus.checked_at) }}. {{ connectionStatus.external.length ? 'The anonymous external check only confirms a response; it does not prove that an allowed user can sign in.' : 'Public URLs have not been tested separately yet; an online tunnel does not mean the public URLs work.' }}</p>
            <div v-for="result in connectionStatus.external" :key="result.hostname" class="rounded-xl border border-gray-200 bg-white p-4 text-sm">
              <p class="font-medium text-ink">{{ result.hostname }}</p>
              <p class="mt-1 text-xs" :class="result.status === 'login_required' ? 'text-emerald-700' : result.status === 'public_response' && connectionStatus.public_routes.includes(result.hostname) ? 'text-amber-700' : result.status === 'public_response' ? 'text-red-700' : 'text-amber-700'">{{ externalLabel(result.status, connectionStatus.public_routes.includes(result.hostname)) }}</p>
            </div>
            <ul v-if="connectionStatus.issues.length" class="sm:col-span-3 list-inside list-disc text-sm text-red-700"><li v-for="issue in connectionStatus.issues" :key="issue">{{ issue }}</li></ul>
          </div>
          <p class="mt-3 text-xs text-gray-500">A connected tunnel only means the tunnel is online. Public URLs and login protection still have to be checked one by one.</p>
        </div>
      </div>
    </section>
    <section class="rounded-2xl border border-stone-200 bg-stone-50 p-6 text-sm text-stone-700">
      <h2 class="font-semibold text-ink">Removing routes or cancelling the subscription</h2>
      <p class="mt-2 leading-6">Releasing the binding here only stops this host's tunnel and frees the device binding on Apporo. Clean up DNS, Access and the subscription on the Application tab or the service page on Apporo; this page never treats “binding released” as “public URL deleted”.</p>
      <a :href="review?.portal_routes_url || workspacePortal" target="_blank" rel="noopener noreferrer" class="mt-3 inline-block font-semibold text-brand underline">Manage routes on Apporo ↗</a>
    </section>
    <p class="text-center text-xs text-gray-500">Managing Cloudflare yourself? <router-link to="/setup" class="font-semibold text-brand underline">Go to local mode setup</router-link></p>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api } from '@/api'

interface Connection { access_id: number; workspace_id: number; name: string }
interface Bootstrap { authorized: boolean; portal_url: string; connection: Connection | null; release_pending: boolean }
interface Workspace { id: number; name: string; portal_url: string }
interface Access { id: number; name: string; state: string }
interface Review { ready: boolean; issues: string[]; public_routes: string[]; awaiting_publication: boolean; access: { id: number; name: string; state: string; binding_state: string; subscription: { state: string; plan_name: string; ac_max_access_seats?: number | null; ac_used_access_seats?: number | null } | null; routes: { hostname: string; public: boolean; protected: boolean; awaiting_publication: boolean }[] }; portal_access_url: string; portal_routes_url: string }
interface Authorization { user_code: string; verification_url: string; interval: number }
interface ConnectionStatus { connected: boolean; subscription: { state: string } | null; access_ready: boolean; service_ready: boolean; public_routes: string[]; awaiting_publication: boolean; issues: string[]; tunnel_status: string; checked_at: number; external: { hostname: string; status: string; http_status?: number }[] }

const steps = ['Subscribe', 'Sign in', 'Review routes', 'Connect']
const portalFallback = 'https://www.apporo.ai/woow#/workspaces'
const bootstrap = ref<Bootstrap | null>(null)
const authorization = ref<Authorization | null>(null)
const authStatus = ref('')
const workspaces = ref<Workspace[]>([])
const accesses = ref<Access[]>([])
const workspaceId = ref<number | null>(null)
const accessId = ref<number | null>(null)
const review = ref<Review | null>(null)
const connectionStatus = ref<ConnectionStatus | null>(null)
const busy = ref(false)
const error = ref('')
const message = ref('')
let authTimer: ReturnType<typeof setTimeout> | undefined
const workspacePortal = computed(() => workspaces.value.find((item) => item.id === workspaceId.value)?.portal_url || portalFallback)

function label(value: string | undefined, names: Record<string, string>): string {
  return value ? (names[value] || `Unrecognized (${value})`) : 'Unknown'
}

function serviceLabel(value: string): string {
  return label(value, { pending: 'Pending', provisioning: 'Setting up', active: 'Active', active_no_route: 'Active, no hostname yet', error: 'Configuration error', suspended: 'Suspended', deleting: 'Deleting' })
}

function subscriptionLabel(value?: string): string {
  return label(value, { in_progress: 'Active', draft: 'Awaiting activation', paused: 'Paused', closed: 'Ended', cancel: 'Cancelled' })
}

function bindingLabel(value: string): string {
  return label(value, { unbound: 'Not bound', claimed: 'Bound to one device', legacy: 'Legacy binding, needs checking' })
}

function tunnelLabel(value: string): string {
  return label(value, { running: 'Online', starting: 'Starting', stopped: 'Not running' })
}

function publicRoutesLabel(count: number): string {
  return `${count} public hostname${count === 1 ? '' : 's'} (no Access)`
}

// English like the rest of the UI, whatever the browser locale.
function formatTime(seconds: number): string {
  return new Date(seconds * 1000).toLocaleString('en-US', {
    year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

async function loadBootstrap() {
  bootstrap.value = await api<Bootstrap>('/api/paas/bootstrap')
  if (bootstrap.value.authorized) {
    await loadWorkspaces()
    if (bootstrap.value.connection) {
      workspaceId.value = bootstrap.value.connection.workspace_id
      await onWorkspaceChange()
      accessId.value = bootstrap.value.connection.access_id
      await loadReview()
      await loadStatus()
    }
  }
}

async function loadWorkspaces() {
  workspaces.value = (await api<{ workspaces: Workspace[] }>('/api/paas/workspaces')).workspaces
}

async function refreshServices() {
  busy.value = true
  error.value = ''
  try {
    const previousWorkspace = workspaceId.value
    const previousAccess = accessId.value
    await loadWorkspaces()
    workspaceId.value = workspaces.value.some((item) => item.id === previousWorkspace) ? previousWorkspace : null
    await onWorkspaceChange()
    if (accesses.value.some((item) => item.id === previousAccess)) {
      accessId.value = previousAccess
      await loadReview()
    }
    if (!error.value) message.value = 'Service list updated. Choose a service and check how each hostname is accessed before you connect.'
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'Could not update the service list right now'
  } finally {
    busy.value = false
  }
}

async function onWorkspaceChange() {
  review.value = null
  accessId.value = null
  accesses.value = []
  if (workspaceId.value !== null) {
    accesses.value = (await api<{ accesses: Access[] }>(`/api/paas/workspaces/${workspaceId.value}/accesses`)).accesses
  }
}

async function loadReview() {
  review.value = null
  if (accessId.value === null) return
  try {
    review.value = await api<Review>(`/api/paas/accesses/${accessId.value}/review`)
    error.value = ''
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'Could not check the service'
  }
}

async function beginAuthorization() {
  busy.value = true
  error.value = ''
  if (authTimer) clearTimeout(authTimer)
  try {
    authorization.value = await api<Authorization>('/api/paas/authorization', { method: 'POST' })
    authStatus.value = 'waiting'
    authTimer = setTimeout(pollAuthorization, authorization.value.interval * 1000)
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'Could not start the authorization'
  } finally {
    busy.value = false
  }
}

async function pollAuthorization() {
  try {
    const result = await api<{ status: string; interval?: number }>('/api/paas/authorization/status')
    authStatus.value = result.status
    if (result.status === 'authorized') {
      authorization.value = null
      await loadBootstrap()
      message.value = 'Apporo account authorized. Now choose the workspace and the Security Access service.'
      return
    }
    if (result.status === 'waiting') {
      authTimer = setTimeout(pollAuthorization, (result.interval || authorization.value?.interval || 5) * 1000)
      return
    }
    error.value = result.status === 'denied' ? 'The authorization was denied. Get a new device code.' : 'The authorization expired. Get a new device code.'
    authorization.value = null
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'Could not check the authorization status right now'
    authTimer = setTimeout(pollAuthorization, 10000)
  }
}

async function connect() {
  if (accessId.value === null || !review.value?.ready) return
  if (review.value.public_routes.length && !window.confirm(
    `These hostnames have no Cloudflare Access. Once connected, anyone on the internet can reach their origin service:\n${review.value.public_routes.join('\n')}\n\nTurn on these public routes?`
  )) return
  busy.value = true
  error.value = ''
  try {
    await api(`/api/paas/accesses/${accessId.value}/connect`, {
      method: 'POST', body: JSON.stringify({ allow_public_routes: review.value.public_routes.length > 0 }),
    })
    message.value = 'Connected. cloudflared is running in token mode.'
    await loadBootstrap()
    await loadStatus()
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'Could not connect'
    await loadReview()
  } finally {
    busy.value = false
  }
}

async function loadStatus(probe = false) {
  try {
    connectionStatus.value = await api<ConnectionStatus>(`/api/paas/connection/status${probe ? '?probe=true' : ''}`)
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'Could not read the connection status'
  }
}

async function checkExternal() {
  message.value = 'Checking the public URLs from this host…'
  await loadStatus(true)
  message.value = ''
}

function externalLabel(status: string, isPublic: boolean): string {
  const labels: Record<string, string> = {
    login_required: 'An anonymous visit gets the Cloudflare Access login',
    public_response: isPublic ? 'Public route answers directly; make sure the origin service has its own login' : 'An anonymous visit got 200 directly; check the Access protection now',
    blocked_or_protected: 'HTTP 403: blocked by Access or another rule; this check cannot tell which',
    origin_error: 'The origin service or the tunnel returned an error',
    blocked_private_address: 'The hostname resolves to a private or reserved address; check skipped',
    unreachable: 'DNS, TLS or the network connection failed',
    undetermined: 'The response could not be classified; check again on Apporo and in a browser',
  }
  return labels[status] || 'Could not be determined'
}

async function disconnect() {
  if (!window.confirm('This stops the Apporo tunnel on this host, clears the local routes and then releases the remote binding.\nIf SSH to this host goes through this tunnel, you cannot reach it remotely once it stops, and the healthcheck does not bring it back. Continue?')) return
  error.value = ''
  try {
    const result = await api<{ stopped: boolean; release_pending: boolean }>('/api/paas/disconnect', { method: 'POST' })
    message.value = result.release_pending
      ? 'The local tunnel is stopped, but the remote binding is not released yet. Select “Retry releasing the binding” in a moment.'
      : 'The local connection is stopped and the remote binding is released.'
    connectionStatus.value = null
    await loadBootstrap()
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'Could not stop the connection'
  }
}

async function finishDisconnect() {
  error.value = ''
  try {
    await api('/api/paas/disconnect/finish', { method: 'POST' })
    message.value = 'The local connection is stopped and the remote binding is released.'
    connectionStatus.value = null
    await loadBootstrap()
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'The remote release is not finished yet. Try again later or release the binding on Apporo.'
  }
}

async function revokeAuthorization() {
  error.value = ''
  try {
    await api('/api/paas/authorization/revoke', { method: 'POST' })
    workspaces.value = []
    accesses.value = []
    review.value = null
    workspaceId.value = null
    accessId.value = null
    await loadBootstrap()
    message.value = 'Apporo account authorization revoked.'
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'Could not revoke the authorization'
  }
}

onMounted(() => { loadBootstrap().catch((cause) => { error.value = cause instanceof Error ? cause.message : 'Could not read the Apporo link status' }) })
onUnmounted(() => { if (authTimer) clearTimeout(authTimer) })
</script>
