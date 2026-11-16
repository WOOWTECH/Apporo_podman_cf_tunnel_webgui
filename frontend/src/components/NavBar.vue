<template>
  <nav class="border-b border-gray-200 bg-white">
    <div class="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-3 px-4 py-3">
      <!-- Wordmark -->
      <!-- One line: the space between the spans keeps "Apporo CF Tunnel Web" readable as text. -->
      <div class="flex items-baseline gap-2" data-test="wordmark">
        <span class="font-display text-xl font-semibold tracking-tight text-brand">Apporo</span> <span class="text-sm font-medium text-gray-500">CF Tunnel Web</span>
      </div>

      <!-- Navigation Links -->
      <div class="order-3 flex w-full items-center gap-1 overflow-x-auto pb-1 sm:order-none sm:w-auto sm:pb-0">
        <router-link
          v-for="link in links"
          :key="link.to"
          :to="link.to"
          class="whitespace-nowrap rounded-lg px-2 py-2 text-sm font-medium transition-colors sm:px-3"
          :class="
            $route.path === link.to
              ? 'bg-brand/10 text-brand-700'
              : 'text-gray-600 hover:bg-gray-100 hover:text-ink'
          "
        >
          {{ link.label }}
        </router-link>
      </div>

      <!-- Status Dot -->
      <div class="flex items-center gap-2">
        <span
          class="h-2.5 w-2.5 rounded-full"
          :class="statusDotClass"
        />
        <span class="text-xs text-gray-500">{{ statusLabel }}</span>
      </div>
    </div>
  </nav>
</template>

<script setup lang="ts">
import { computed, onMounted, onUnmounted } from 'vue'
import { useTunnelStore } from '@/stores/tunnel'

const tunnelStore = useTunnelStore()

const links = [
  { to: '/', label: 'Dashboard' },
  { to: '/paas', label: 'Apporo Link' },
  { to: '/setup', label: 'Setup' },
  { to: '/config', label: 'Config' },
  { to: '/logs', label: 'Logs' },
]

const statusDotClass = computed(() => {
  switch (tunnelStore.tunnelStatus) {
    case 'running':
      return 'bg-green-500'
    case 'starting':
      return 'bg-amber-500'
    case 'stopped':
      return tunnelStore.health?.stopped_by_operator ? 'bg-gray-400' : 'bg-red-500'
    default:
      return 'bg-gray-400'
  }
})

const statusLabel = computed(() => tunnelStore.tunnelStatus)

onMounted(() => tunnelStore.startPolling(4000))
onUnmounted(() => tunnelStore.stopPolling())
</script>
