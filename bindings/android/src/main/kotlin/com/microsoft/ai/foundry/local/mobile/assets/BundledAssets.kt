// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.assets

import android.content.Context
import android.content.res.AssetManager
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/**
 * Extract model directories that ship inside the APK's `assets/` tree to a
 * real filesystem path that [com.microsoft.ai.foundry.local.mobile.FoundryLocal.loadModel]
 * can accept.
 *
 * Android's `AssetManager.open` returns a stream but never a real path — the
 * files are packed and (unless [android.content.pm.PackageManager.getApplicationInfo]'s
 * `dataDir` is used with the compiled asset offsets) can also be zlib-compressed
 * inside the APK, which the runtime cannot mmap. The stock way around this is
 * to copy the tree out on first launch, mark it with a manifest so subsequent
 * launches skip the copy, and add
 *
 * ```groovy
 * androidResources { noCompress += listOf("onnx", "onnx_data", "bin") }
 * ```
 *
 * to the app's `build.gradle`. Uncompressed model files can then be mmapped
 * straight out of the APK during copy without going through zlib.
 */
public object BundledAssets {

    private const val MANIFEST_FILE = ".assets-manifest"
    private const val STAGING_SUFFIX = ".staging"

    @JvmStatic
    @JvmOverloads
    public fun extractDirectory(
        context: Context,
        assetPath: String,
        target: File,
        overwrite: Boolean = false,
    ): File {
        require(assetPath.isNotBlank()) { "assetPath must not be blank" }
        val assets = context.assets

        val expectedDigest = digestOfAssets(assets, assetPath)
        val manifestFile = File(target, MANIFEST_FILE)
        if (!overwrite && target.isDirectory && manifestFile.isFile) {
            val existing = manifestFile.readText().trim()
            if (existing == expectedDigest) return target
        }

        val staging = File(target.parentFile ?: target, target.name + STAGING_SUFFIX)
        if (staging.exists()) staging.deleteRecursively()
        if (!staging.mkdirs() && !staging.isDirectory) {
            throw IllegalStateException("Failed to create staging directory: ${staging.absolutePath}")
        }

        copyTree(assets, assetPath, staging)
        File(staging, MANIFEST_FILE).writeText(expectedDigest)

        if (target.exists()) target.deleteRecursively()
        if (!staging.renameTo(target)) {
            copyDirectory(staging, target)
            staging.deleteRecursively()
        }
        return target
    }

    @JvmStatic
    public fun extractToFilesDir(context: Context, assetPath: String, name: String): File {
        val target = File(File(context.filesDir, "models"), name)
        return extractDirectory(context, assetPath, target)
    }

    private fun copyTree(assets: AssetManager, assetPath: String, dest: File) {
        val children = assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            try {
                assets.open(assetPath).use { input ->
                    dest.parentFile?.mkdirs()
                    FileOutputStream(dest).use { output -> input.copyTo(output) }
                }
                return
            } catch (_: Throwable) {
                dest.mkdirs()
                return
            }
        }
        dest.mkdirs()
        for (child in children) {
            val childAsset = if (assetPath.isEmpty()) child else "$assetPath/$child"
            copyTree(assets, childAsset, File(dest, child))
        }
    }

    private fun copyDirectory(source: File, target: File) {
        target.mkdirs()
        source.listFiles()?.forEach { child ->
            val next = File(target, child.name)
            if (child.isDirectory) copyDirectory(child, next)
            else child.copyTo(next, overwrite = true)
        }
    }

    private fun digestOfAssets(assets: AssetManager, assetPath: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digestAssetsInto(assets, assetPath, digest)
        return digest.digest().joinToString(separator = "") { "%02x".format(it) }
    }

    private fun digestAssetsInto(assets: AssetManager, assetPath: String, digest: MessageDigest) {
        digest.update(assetPath.encodeToByteArray())
        val children = assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            runCatching {
                assets.openFd(assetPath).use { fd ->
                    digest.update(fd.length.toString().encodeToByteArray())
                }
            }.onFailure {
                runCatching {
                    assets.open(assetPath).use { s ->
                        val buf = ByteArray(4096)
                        while (true) {
                            val n = s.read(buf)
                            if (n <= 0) break
                            digest.update(buf, 0, n)
                        }
                    }
                }
            }
            return
        }
        for (child in children.sorted()) {
            val next = if (assetPath.isEmpty()) child else "$assetPath/$child"
            digestAssetsInto(assets, next, digest)
        }
    }
}
