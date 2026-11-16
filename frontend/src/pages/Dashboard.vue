<template>
  <div class="space-y-6">
    <h1 class="text-2xl font-bold text-ink">Dashboard</h1>

    <!-- Credential files that could not be made private -->
    <div
      v-if="health?.credentials_error"
      class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
    >
      <span class="font-medium">The credential file check failed, so the tunnel will not start:</span>
      {{ health.credentials_error }}. Replace it with a regular file (not a symlink or a hard link), then press Start.
    </div>

    <!-- Stopped from this GUI -->
    <div
      v-else-if="health?.stopped_by_operator"
      class="rounded-lg border border-gray-200 bg-gray-50 px-4 py-3 text-sm text-gray-700"
    >
      The <code>/data/.tunnel_stopped</code> marker is present: neither the healthcheck nor the start at boot
      brings the tunnel up. Press Start to remove the marker and start the tunnel.
    </div>

    <!-- First run -->
    <div
      v-else-if="unconfigured"
      class="rounded-lg border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-700"
    >
      <span class="font-medium">No tunnel is set up yet.</span>
      With an Apporo Security Access subscription, go to
      <router-link to="/paas" class="font-medium underline">Apporo Link</router-link>.
      To manage Cloudflare yourself, use
      <router-link to="/setup" class="font-medium underline">Setup</router-link>,
      or paste a tunnel token on the <router-link to="/config" class="font-medium underline">Config</router-link> page.
    </div>

    <!-- Status Cards -->
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
      <TunnelStatus
        :tunnel="health?.tunnel ?? null"
        :stopped-by-operator="health?.stopped_by_operator"
      />

      <StatusCard
        title="Mode"
        :badge="config?.mode ?? 'unknown'"
        :variant="config?.mode === 'token' ? 'green' : 'gray'"
      >
        <p class="text-sm text-gray-600">{{ modeDescription }}</p>
      </StatusCard>

      <StatusCard
        title="Token"
        :badge="tokenBadge"
        :variant="config?.tunnel_token_set ? 'green' : config?.mode === 'token' ? 'yellow' : 'gray'"
      >
        <p class="text-sm text-gray-600">
          {{ tokenDescription }}
        </p>
        <p v-if="health?.version" class="mt-1 text-xs text-gray-400">Version {{ health.version }}</p>
      </StatusCard>
    </div>

    <!-- Action Buttons -->
    <div class="flex gap-3">
      <button
        class="rounded-lg bg-green-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-green-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || tunnelStore.isRunning"
        @click="run('start')"
      >
        {{ tunnelStore.actionLoading ? 'Working...' : 'Start' }}
      </button>
      <button
        class="rounded-lg bg-red-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-red-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || !tunnelStore.isRunning"
        @click="onStop"
      >
        Stop
      </button>
      <button
        class="rounded-lg bg-amber-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-amber-700 disabled:opacity-50"
        :disabled="tunnelStore.actionLoading || !tunnelStore.isRunning"
        @click="run('restart')"
      >
        Restart
      </button>
    </div>
    <p class="text-xs text-gray-500">
      Start and Restart both launch cloudflared with the saved settings (in local mode the ingress
      configuration is regenerated and validated first).
    </p>

    <!-- Error display -->
    <div
      v-if="tunnelStore.error"
      class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700"
    >
      {{ tunnelStore.error }}
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useTunnelStore } from '@/stores/tunnel'
import { useConfigStore } from '@/stores/config'
import TunnelStatus from '@/components/TunnelStatus.vue'
import StatusCard from '@/components/StatusCard.vue'

const tunnelStore = useTunnelStore()
const configStore = useConfigStore()

const health = computed(() => tunnelStore.health)
const config = computed(() => configStore.config)

const unconfigured = computed(() => {
  const c = config.value
  if (!c || tunnelStore.isRunning) return false
  return c.mode === 'token' ? !c.tunnel_token_set : c.routes.length === 0 && !c.catch_all_service
})

const modeDescription = computed(() => {
  const mode = config.value?.mode
  if (mode === 'token') return 'Remote-managed tunnel: routes are managed in the Cloudflare dashboard or on Apporo'
  if (mode === 'local') return 'Locally managed tunnel (cert.pem): routes are managed here'
  if (configStore.error) return `Could not load the settings: ${configStore.error}`
  return 'Loading...'
})

const tokenBadge = computed(() => {
  if (config.value?.tunnel_token_managed_by_paas) return 'Apporo'
  return config.value?.tunnel_token_set ? 'configured' : 'missing'
})

const tokenDescription = computed(() => {
  if (config.value?.tunnel_token_managed_by_paas) return 'Managed automatically by Apporo'
  if (config.value?.tunnel_token_set) return config.value.tunnel_token_masked
  return config.value?.mode === 'token' ? 'Token mode, but no token is set yet' : 'Local mode does not need a token'
})

async function run(endpoint: 'start' | 'restart') {
  await tunnelStore.action(endpoint).catch(() => {})
}

async function onStop() {
  const ok = window.confirm(
    'Stop the tunnel? The healthcheck brings a configured tunnel back after about 2 minutes. Until then, SSH and every other connection through this tunnel is cut off.'
  )
  if (ok) await tunnelStore.action('stop').catch(() => {})
}

onMounted(() => {
  tunnelStore.fetchHealth()
  configStore.fetchConfig()
})
</script>
