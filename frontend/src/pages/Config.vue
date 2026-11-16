<template>
  <div class="space-y-6">
    <h1 class="text-2xl font-bold text-ink">Configuration</h1>

    <div v-if="configStore.loading && !configStore.config" class="text-gray-500">
      Loading...
    </div>

    <form v-else @submit.prevent="onSave(false)" class="space-y-6">
      <!-- Basic Settings -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Basic Settings</legend>
        <div class="mt-2 space-y-4">
          <!-- Mode -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Mode</label>
            <p class="mb-1 text-xs text-gray-500">
              local uses this host's certificate (cert.pem), with the routes managed below; token uses a tunnel
              token from the Cloudflare dashboard or from Apporo
            </p>
            <select
              v-model="form.mode"
              :disabled="managedByPaas"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand disabled:bg-gray-100"
            >
              <option value="local">local</option>
              <option value="token">token</option>
            </select>
          </div>

          <!-- Tunnel Token -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Tunnel Token</label>
            <template v-if="!managedByPaas">
              <p class="mb-1 text-xs text-gray-500">
                Stored in /data (mode 0600), never in settings.json. You can paste the whole
                <code>cloudflared service install …</code> command. Leave it empty to keep the current token.
              </p>
              <TokenInput
                :masked-value="configStore.config?.tunnel_token_masked ?? ''"
                placeholder="eyJhIjoiLi4uIiwidCI6Ii4uLiIsInMiOiIuLi4ifQ=="
                @update:token="tokenInput = $event"
              />
              <div class="mt-2 flex items-center gap-3">
                <span
                  class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
                  :class="configStore.config?.tunnel_token_set ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-600'"
                >
                  {{ configStore.config?.tunnel_token_set ? 'token configured' : 'no token' }}
                </span>
                <button
                  v-if="configStore.config?.tunnel_token_set"
                  type="button"
                  class="text-xs font-medium text-red-500 hover:text-red-700"
                  @click="toggleClearToken"
                >
                  {{ clearToken ? 'Keep the token when saving' : 'Remove the token when saving (switch to local mode)' }}
                </button>
              </div>
              <p v-if="clearToken" class="mt-1 text-xs text-amber-600">Saving deletes the current token.</p>
            </template>
            <p v-else class="rounded-lg bg-blue-50 px-4 py-3 text-sm leading-6 text-blue-900">
              This credential is managed automatically by Apporo. To use a manual token or local mode
              instead, first stop the connection and release the binding on the
              <router-link to="/paas" class="font-semibold underline">Apporo Link</router-link> page.
            </p>
          </div>

          <!-- Tunnel Name -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Tunnel Name</label>
            <p class="mb-1 text-xs text-gray-500">Cloudflare tunnel name (local mode)</p>
            <input
              v-model="form.tunnel_name"
              type="text"
              placeholder="my-tunnel"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand"
            />
          </div>
        </div>
      </fieldset>

      <!-- Routes -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Routes</legend>
        <p class="mt-1 mb-3 text-xs text-gray-500">
          Point public hostnames at services on this host (the container uses host networking, so enter
          http://localhost:&lt;port&gt;). Save &amp; Apply creates DNS records for new hostnames.
        </p>
        <div
          v-if="form.mode === 'token'"
          class="mb-3 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-700"
        >
          In token mode, ingress routes are managed in the Cloudflare dashboard or on Apporo. The local
          routes below only take effect in <span class="font-medium">local</span> mode.
        </div>
        <p v-else class="mb-3 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900">
          Removing a route or stopping the tunnel does not delete its Cloudflare DNS record. Check the
          hostname's CNAME in Cloudflare DNS and delete it only once nothing uses it; check the matching
          Access application too.
        </p>
        <RouteEditor :routes="form.routes" @update:routes="form.routes = $event" />
      </fieldset>

      <!-- Catch-All Service -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Catch-All Service</legend>
        <div class="mt-2 space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-700">Catch-All Service URL</label>
            <p class="mb-1 text-xs text-gray-500">
              Traffic that matches none of the hostnames above, for example Nginx Proxy Manager on this
              host: http://localhost:80
            </p>
            <input
              v-model="form.catch_all_service"
              type="text"
              placeholder="http://localhost:80"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand"
            />
          </div>
        </div>
      </fieldset>

      <!-- Advanced Settings -->
      <fieldset class="rounded-xl border border-gray-200 bg-white p-5 shadow-sm">
        <legend class="px-2 text-sm font-semibold text-gray-700">Advanced Settings</legend>
        <div class="mt-2 space-y-4">
          <!-- Post-Quantum -->
          <div class="flex items-center justify-between">
            <div>
              <span class="text-sm font-medium text-gray-700">Post-Quantum Crypto</span>
              <p class="text-xs text-gray-500">QUIC transport only; some networks cannot connect with it</p>
            </div>
            <button
              type="button"
              class="relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200"
              :class="form.post_quantum ? 'bg-brand' : 'bg-gray-200'"
              @click="form.post_quantum = !form.post_quantum"
            >
              <span
                class="pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0 transition-transform duration-200"
                :class="form.post_quantum ? 'translate-x-5' : 'translate-x-0'"
              />
            </button>
          </div>

          <!-- No TLS Verify -->
          <div class="flex items-center justify-between">
            <div>
              <span class="text-sm font-medium text-gray-700">No TLS Verify</span>
              <p class="text-xs text-gray-500">Skip origin TLS certificate verification (no-tls-verify)</p>
            </div>
            <button
              type="button"
              class="relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200"
              :class="form.no_tls_verify ? 'bg-brand' : 'bg-gray-200'"
              @click="form.no_tls_verify = !form.no_tls_verify"
            >
              <span
                class="pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0 transition-transform duration-200"
                :class="form.no_tls_verify ? 'translate-x-5' : 'translate-x-0'"
              />
            </button>
          </div>

          <!-- Log Level -->
          <div>
            <label class="block text-sm font-medium text-gray-700">cloudflared Log Level</label>
            <select
              v-model="form.log_level"
              class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand"
            >
              <option v-for="lvl in LOG_LEVELS" :key="lvl" :value="lvl">{{ lvl }}</option>
            </select>
          </div>

          <!-- Run Parameters -->
          <div>
            <label class="block text-sm font-medium text-gray-700">Run Parameters</label>
            <p class="mb-1 text-xs text-gray-500">
              One per line, as --flag=value. Allowed: --edge-bind-address, --edge-ip-version,
              --grace-period, --ha-connections, --logfile, --loglevel, --pidfile, --protocol,
              --region, --retries, --tag
            </p>
            <textarea
              v-model="runParametersText"
              rows="3"
              placeholder="--protocol=http2&#10;--region=us"
              class="mt-1 block w-full rounded-lg border px-3 py-2 font-mono text-sm shadow-sm focus:outline-none focus:ring-1"
              :class="runParametersError ? 'border-red-300 focus:border-red-500 focus:ring-red-500' : 'border-gray-300 focus:border-brand focus:ring-brand'"
            />
            <p v-if="runParametersError" class="mt-1 text-xs text-red-600">{{ runParametersError }}</p>
          </div>
        </div>
      </fieldset>

      <!-- Actions -->
      <div class="flex items-center gap-3">
        <button
          type="submit"
          class="rounded-lg border border-brand bg-white px-5 py-2 text-sm font-medium text-brand shadow-sm hover:bg-brand-50 disabled:opacity-50"
          :disabled="configStore.loading || hasErrors"
        >
          {{ configStore.loading ? 'Saving...' : 'Save' }}
        </button>
        <button
          type="button"
          class="rounded-lg bg-brand px-5 py-2 text-sm font-medium text-white shadow-sm hover:bg-brand-700 disabled:opacity-50"
          :disabled="configStore.loading || hasErrors"
          @click="onSave(true)"
        >
          Save &amp; Apply
        </button>
        <button
          type="button"
          class="rounded-lg border border-gray-300 bg-white px-5 py-2 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50"
          @click="resetForm"
        >
          Reset
        </button>
      </div>
      <p class="text-xs text-gray-500">
        Save only stores the settings. Save &amp; Apply restarts cloudflared with them (in local mode it also
        regenerates and validates the ingress and creates DNS records for new hostnames); the tunnel drops
        for a few seconds.
      </p>
      <p v-if="tokenModeWithoutToken" class="text-xs text-amber-600">
        Token mode needs a tunnel token. Paste one first.
      </p>

      <!-- Feedback -->
      <div
        v-if="configStore.saved"
        class="rounded-lg border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-700"
      >
        {{ lastSaveApplied ? 'Settings saved and applied.' : 'Settings saved (not applied yet).' }}
      </div>
      <div
        v-if="configStore.error"
        class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
      >
        {{ configStore.error }}
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { computed, reactive, ref, onMounted, watch } from 'vue'
import { useConfigStore } from '@/stores/config'
import { useTunnelStore } from '@/stores/tunnel'
import TokenInput from '@/components/TokenInput.vue'
import RouteEditor from '@/components/RouteEditor.vue'
import { hostnameError } from '@/utils/hostname'
import type { LogLevel, Route, SetupMode, TunnelConfigUpdate } from '@/types'

const LOG_LEVELS: LogLevel[] = ['debug', 'info', 'warn', 'error', 'fatal']
const RUN_PARAMETER_RE =
  /^(--edge-bind-address|--edge-ip-version|--grace-period|--ha-connections|--logfile|--loglevel|--pidfile|--protocol|--region|--retries|--tag)=.*$/

const configStore = useConfigStore()
const tunnelStore = useTunnelStore()

const tokenInput = ref<string | null>(null)
const clearToken = ref(false)
const runParametersText = ref('')
const lastSaveApplied = ref(false)

const form = reactive({
  mode: 'local' as SetupMode,
  tunnel_name: '',
  routes: [] as Route[],
  catch_all_service: '',
  post_quantum: false,
  log_level: 'info' as LogLevel,
  no_tls_verify: true,
})

const managedByPaas = computed(() => !!configStore.config?.tunnel_token_managed_by_paas)

const runParameters = computed(() =>
  runParametersText.value.split('\n').map((l) => l.trim()).filter(Boolean)
)

const runParametersError = computed(() => {
  const bad = runParameters.value.find((p) => !RUN_PARAMETER_RE.test(p))
  return bad ? `'${bad}' is not an allowed run parameter (format: --flag=value)` : null
})

const tokenModeWithoutToken = computed(() => {
  if (form.mode !== 'token' || managedByPaas.value) return false
  if (clearToken.value) return true
  return !tokenInput.value && !configStore.config?.tunnel_token_set
})

const hasErrors = computed(
  () =>
    runParametersError.value !== null ||
    tokenModeWithoutToken.value ||
    form.routes.some((r) => hostnameError(r.hostname) !== null || !r.service.trim())
)

function toggleClearToken() {
  clearToken.value = !clearToken.value
  if (clearToken.value) form.mode = 'local'
}

function resetForm() {
  const c = configStore.config
  tokenInput.value = null
  clearToken.value = false
  if (!c) return
  form.mode = c.mode
  form.tunnel_name = c.tunnel_name
  form.routes = (c.routes || []).map((r: Route) => ({ ...r }))
  form.catch_all_service = c.catch_all_service
  form.post_quantum = c.post_quantum
  form.log_level = c.log_level
  form.no_tls_verify = c.no_tls_verify
  runParametersText.value = (c.run_parameters || []).join('\n')
}

function payload(): TunnelConfigUpdate {
  const body: TunnelConfigUpdate = {
    mode: form.mode,
    tunnel_name: form.tunnel_name.trim(),
    routes: form.routes.map((r) => ({ ...r, hostname: r.hostname.trim(), service: r.service.trim() })),
    catch_all_service: form.catch_all_service.trim(),
    post_quantum: form.post_quantum,
    log_level: form.log_level,
    run_parameters: runParameters.value,
    no_tls_verify: form.no_tls_verify,
  }
  // Omitted tunnel_token keeps the stored one; '' removes it.
  if (clearToken.value) body.tunnel_token = ''
  else if (tokenInput.value) body.tunnel_token = tokenInput.value
  return body
}

async function onSave(apply: boolean) {
  lastSaveApplied.value = apply
  const ok = await configStore.updateConfig(payload(), apply)
  if (apply) tunnelStore.fetchHealth()
  if (ok) {
    clearToken.value = false
    tokenInput.value = null
  }
}

watch(() => configStore.config, resetForm, { immediate: true })

onMounted(() => {
  configStore.fetchConfig()
})
</script>
