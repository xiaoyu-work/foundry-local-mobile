// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method / event channel host for the FFI plugin.
 *
 * The plugin is [ffiPlugin: true], meaning the data path — chat streaming, downloads,
 * embeddings — bypasses this class entirely and goes through the shared native
 * library over dart:ffi. This class exists only to answer questions Dart cannot ask
 * the OS directly:
 *
 *   * sandbox paths (`getSandboxDirectory`),
 *   * memory-pressure notifications (ComponentCallbacks2),
 *   * metered / unmetered network transitions (ConnectivityManager),
 *   * low-power-mode transitions (PowerManager).
 *
 * The channel surface is intentionally narrow. Everything here is a Dart-side
 * boolean or string; there are no per-token payloads passing through the platform
 * channel and there are no large blobs.
 */
class FoundryLocalMobilePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ComponentCallbacks2 {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var appContext: Context? = null

    private var eventSink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var powerReceiver: android.content.BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "com.microsoft.ai.foundry.local.mobile/plugin"
        )
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(
            binding.binaryMessenger,
            "com.microsoft.ai.foundry.local.mobile/events"
        )
        eventChannel.setStreamHandler(this)

        appContext!!.registerComponentCallbacks(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        appContext?.unregisterComponentCallbacks(this)
        detachConnectivity()
        detachPowerReceiver()
        appContext = null
    }

    // ---------------------------------------------------------------------------
    // MethodChannel
    // ---------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext ?: return result.error("no_context", "Plugin detached.", null)
        when (call.method) {
            "getSandboxDirectory" -> {
                result.success(ctx.filesDir.absolutePath)
            }
            "refreshState" -> {
                emitInitialState(ctx)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------------
    // EventChannel — connectivity + power + memory
    // ---------------------------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val ctx = appContext ?: return
        attachConnectivity(ctx)
        attachPowerReceiver(ctx)
        emitInitialState(ctx)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        detachConnectivity()
        detachPowerReceiver()
    }

    private fun emit(kind: String) {
        val sink = eventSink ?: return
        sink.success(mapOf("kind" to kind))
    }

    private fun emitInitialState(ctx: Context) {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager?
            ?: return
        val active = cm.activeNetwork
        val caps = active?.let { cm.getNetworkCapabilities(it) }
        val unmetered =
            caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == true
        emit(if (unmetered) "network_unmetered" else "network_metered")
    }

    private fun attachConnectivity(ctx: Context) {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager?
            ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val unmetered =
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                emit(if (unmetered) "network_unmetered" else "network_metered")
            }

            override fun onLost(network: Network) {
                emit("network_metered")
            }
        }
        try {
            cm.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (_: SecurityException) {
            // ACCESS_NETWORK_STATE is declared in the manifest; a missing permission
            // is a host-app misconfiguration. Fall back to a one-shot poll.
            emitInitialState(ctx)
        }
    }

    private fun detachConnectivity() {
        val ctx = appContext ?: return
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager?
            ?: return
        networkCallback?.let { cm.unregisterNetworkCallback(it) }
        networkCallback = null
    }

    private fun attachPowerReceiver(ctx: Context) {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context, intent: android.content.Intent) {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager?
                    ?: return
                if (pm.isPowerSaveMode) emit("low_power")
            }
        }
        val filter = android.content.IntentFilter(
            PowerManager.ACTION_POWER_SAVE_MODE_CHANGED
        )
        ctx.registerReceiver(receiver, filter)
        powerReceiver = receiver
    }

    private fun detachPowerReceiver() {
        val ctx = appContext ?: return
        powerReceiver?.let {
            try {
                ctx.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Already unregistered.
            }
        }
        powerReceiver = null
    }

    // ---------------------------------------------------------------------------
    // ComponentCallbacks2 — memory
    // ---------------------------------------------------------------------------

    override fun onTrimMemory(level: Int) {
        when (level) {
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE,
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW,
            ComponentCallbacks2.TRIM_MEMORY_BACKGROUND ->
                emit("memory_warning")
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL,
            ComponentCallbacks2.TRIM_MEMORY_COMPLETE ->
                emit("memory_critical")
            else -> Unit
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) = Unit
    override fun onLowMemory() {
        emit("memory_critical")
    }
}
