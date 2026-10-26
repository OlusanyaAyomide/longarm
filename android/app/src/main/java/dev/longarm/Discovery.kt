package dev.longarm

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull

/** Finds the paired Mac on the local network via Bonjour (_longarm._tcp), matched by its id. */
class Discovery(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    data class Found(val host: String, val port: Int)

    suspend fun find(macId: String, timeoutMs: Long): Found? {
        val services = Channel<NsdServiceInfo>(Channel.UNLIMITED)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) { services.trySend(info) }
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { services.close() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        try {
            return withTimeoutOrNull(timeoutMs) {
                // Resolve one at a time: older Android rejects concurrent resolves.
                for (service in services) {
                    val resolved = resolve(service) ?: continue
                    val id = resolved.attributes["id"]?.let { String(it) }
                    @Suppress("DEPRECATION")
                    val host = resolved.host?.hostAddress ?: continue
                    if (id == macId) return@withTimeoutOrNull Found(host, resolved.port)
                }
                null
            }
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
    }

    private suspend fun resolve(service: NsdServiceInfo): NsdServiceInfo? {
        val result = Channel<NsdServiceInfo?>(1)
        @Suppress("DEPRECATION")
        nsd.resolveService(service, object : NsdManager.ResolveListener {
            override fun onServiceResolved(info: NsdServiceInfo) { result.trySend(info) }
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) { result.trySend(null) }
        })
        return withTimeoutOrNull(3_000) { result.receive() }
    }

    companion object {
        const val SERVICE_TYPE = "_longarm._tcp."
    }
}
