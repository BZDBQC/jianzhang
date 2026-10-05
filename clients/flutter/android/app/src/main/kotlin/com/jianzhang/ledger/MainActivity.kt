package com.jianzhang.ledger

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.Closeable
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val fileWorker = Executors.newSingleThreadExecutor()
    private val startedAt = SystemClock.elapsedRealtime()
    private val activeResults = mutableSetOf<MethodChannel.Result>() // Main thread only.
    private val unclaimedImports = ConcurrentHashMap.newKeySet<File>()
    private val activeDescriptors = ConcurrentHashMap.newKeySet<Closeable>()
    private val activeSignals = ConcurrentHashMap.newKeySet<CancellationSignal>()
    @Volatile private var destroyed = false
    private var fileChannel: MethodChannel? = null
    private var performanceChannel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private var exportSource: File? = null
    private var allowedExtensions = listOf("json")
    private var fullyDrawn = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        fileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jianzhang/files").apply {
            setMethodCallHandler { call, result ->
                when {
                    destroyed -> result.error("FILE_CANCELLED", getString(R.string.file_cancelled), null)
                    call.method == "releaseFile" -> {
                        activeResults.add(result)
                        releaseImportedFile(call, result)
                    }
                    call.method != "openFile" && call.method != "saveFile" -> result.notImplemented()
                    pending != null -> result.error("FILE_BUSY", getString(R.string.file_busy), null)
                    else -> {
                        activeResults.add(result)
                        beginFileOperation(call, result)
                    }
                }
            }
        }
        performanceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jianzhang/performance").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "reportFullyDrawn") result.notImplemented()
                else {
                    if (!fullyDrawn) {
                        fullyDrawn = true
                        reportFullyDrawn()
                    }
                    result.success(mapOf("readyMs" to SystemClock.elapsedRealtime() - startedAt))
                }
            }
        }
    }

    private fun beginFileOperation(call: MethodCall, result: MethodChannel.Result) {
        try {
            val intent: Intent
            val request: Int
            if (call.method == "openFile") {
                allowedExtensions = (call.argument<List<String>>("extensions") ?: listOf("json"))
                    .map { it.lowercase().trimStart('.') }
                    .filter { it.matches(Regex("[a-z0-9]{1,10}")) }
                require(allowedExtensions.isNotEmpty()) { getString(R.string.invalid_extension) }
                intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                request = OPEN_DOCUMENT
            } else {
                val source = File(requireNotNull(call.argument<String>("sourcePath"))).canonicalFile
                val privateRoot = File(applicationInfo.dataDir).canonicalPath + File.separator
                require(source.canonicalPath.startsWith(privateRoot) && source.isFile && source.canRead()) {
                    getString(R.string.export_source_unreadable)
                }
                val name = requireNotNull(call.argument<String>("name"))
                require(name.isNotBlank() && name.length <= 180 && !name.contains('/') && !name.contains('\\')) {
                    getString(R.string.export_name_invalid)
                }
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                require(mime.contains('/') && mime.length <= 120) { getString(R.string.invalid_mime) }
                exportSource = source
                intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, name)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }
                request = SAVE_DOCUMENT
            }
            pending = result
            startActivityForResult(intent, request)
        } catch (error: Exception) {
            finish(result, code = "FILE_OPEN", message = error.message ?: getString(R.string.file_picker_error))
        }
    }

    private fun releaseImportedFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            finish(result, code = "FILE_RELEASE", message = getString(R.string.import_path_missing))
            return
        }
        submit(result) {
            try {
                val file = File(path).canonicalFile
                require(file.parentFile == cacheDir.canonicalFile &&
                    file.name.startsWith("jianzhang-import-") && file.name.endsWith(".json")) {
                    getString(R.string.import_owned_only)
                }
                if (file.exists() && !file.delete()) throw IOException(getString(R.string.import_cleanup_error))
                unclaimedImports.remove(file)
                runOnUiThread { finish(result) }
            } catch (error: Exception) {
                runOnUiThread { finish(result, code = "FILE_RELEASE", message = error.message ?: getString(R.string.import_cleanup_error)) }
            }
        }
    }

    @Deprecated("Android Activity callback required by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (destroyed || (requestCode != OPEN_DOCUMENT && requestCode != SAVE_DOCUMENT)) return
        val result = pending ?: return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finish(result, if (requestCode == SAVE_DOCUMENT) false else null)
            return
        }
        val source = exportSource
        val extensions = allowedExtensions.toList()
        submit(result) {
            var imported: File? = null
            try {
                checkCancellation()
                withCancellation { signal ->
                    if (requestCode == OPEN_DOCUMENT) {
                        val name = documentName(uri, signal)
                        if (name != null && extensions.none { name.lowercase().endsWith(".$it") }) {
                            throw IOException(getString(R.string.backup_format_unsupported))
                        }
                        val file = File.createTempFile("jianzhang-import-", ".json", cacheDir)
                        imported = file
                        unclaimedImports.add(file)
                        val descriptor = contentResolver.openFileDescriptor(uri, "r", signal) ?: throw IOException(getString(R.string.file_read_error))
                        tracked(descriptor) { input ->
                            tracked(FileOutputStream(file)) { output ->
                                copyCancellable(input.fileDescriptor, output.fd)
                            }
                            if (input.canDetectErrors()) input.checkError()
                        }
                        checkCancellation()
                        runOnUiThread {
                            if (destroyed || !activeResults.contains(result)) {
                                cleanupImportsAsync()
                            } else {
                                // Track until Dart releases it, including Activity destruction.
                                finish(result, file.absolutePath)
                            }
                        }
                    } else {
                        val file = source ?: throw IOException(getString(R.string.export_source_expired))
                        val descriptor = contentResolver.openFileDescriptor(uri, "wt", signal) ?: throw IOException(getString(R.string.file_write_error))
                        tracked(descriptor) { output ->
                            tracked(FileInputStream(file)) { input ->
                                copyCancellable(input.fd, output.fileDescriptor)
                            }
                            if (output.canDetectErrors()) output.checkError()
                        }
                        checkCancellation()
                        runOnUiThread { finish(result, true) }
                    }
                }
            } catch (error: Exception) {
                imported?.let { file -> if (!file.exists() || file.delete()) unclaimedImports.remove(file) }
                var message = error.message ?: getString(R.string.file_io_error)
                // ACTION_CREATE_DOCUMENT creates a new output; the input is never deleted.
                if (requestCode == SAVE_DOCUMENT && !removeCreatedDocument(uri)) {
                    message = getString(R.string.export_partial_error)
                }
                val finalMessage = message
                runOnUiThread { finish(result, code = "FILE_IO", message = finalMessage) }
            }
        }
    }

    private fun submit(result: MethodChannel.Result, work: () -> Unit) {
        try { fileWorker.execute { work() } }
        catch (error: RuntimeException) {
            finish(result, code = "FILE_CANCELLED", message = getString(R.string.file_cancelled))
        }
    }

    private fun checkCancellation() {
        if (destroyed || Thread.currentThread().isInterrupted) throw IOException(getString(R.string.file_cancelled))
    }

    private fun <T : Closeable, R> tracked(resource: T, action: (T) -> R): R {
        activeDescriptors.add(resource)
        try { checkCancellation(); return action(resource) }
        finally { try { resource.close() } finally { activeDescriptors.remove(resource) } }
    }

    private fun withCancellation(action: (CancellationSignal) -> Unit) {
        val signal = CancellationSignal()
        activeSignals.add(signal)
        try { checkCancellation(); action(signal) }
        finally { activeSignals.remove(signal) }
    }

    private fun waitReady(fd: FileDescriptor, events: Int) {
        val poll = StructPollfd().apply { this.fd = fd; this.events = events.toShort() }
        while (true) {
            checkCancellation()
            try {
                if (Os.poll(arrayOf(poll), 100) > 0) return
            } catch (error: ErrnoException) {
                if (error.errno != OsConstants.EINTR) throw error
            }
        }
    }

    private fun nonBlocking(fd: FileDescriptor) {
        val flags = Os.fcntlInt(fd, OsConstants.F_GETFL, 0)
        Os.fcntlInt(fd, OsConstants.F_SETFL, flags or OsConstants.O_NONBLOCK)
    }

    private fun copyCancellable(input: FileDescriptor, output: FileDescriptor) {
        // Poll bounded, nonblocking descriptors so a stalled provider pipe cannot
        // retain a destroyed Activity indefinitely inside a blocking read/write.
        nonBlocking(input)
        nonBlocking(output)
        val buffer = ByteArray(65536)
        while (true) {
            waitReady(input, OsConstants.POLLIN)
            val count = try { Os.read(input, buffer, 0, buffer.size) }
                catch (error: ErrnoException) {
                    if (error.errno == OsConstants.EAGAIN || error.errno == OsConstants.EINTR) continue
                    throw error
                }
            if (count == 0) break
            var written = 0
            while (written < count) {
                waitReady(output, OsConstants.POLLOUT)
                try { written += Os.write(output, buffer, written, count - written) }
                catch (error: ErrnoException) {
                    if (error.errno != OsConstants.EAGAIN && error.errno != OsConstants.EINTR) throw error
                }
            }
        }
        checkCancellation()
    }

    private fun removeCreatedDocument(uri: Uri): Boolean = try {
        DocumentsContract.isDocumentUri(this, uri) && DocumentsContract.deleteDocument(contentResolver, uri)
    } catch (error: Exception) { false }

    private fun documentName(uri: Uri, signal: CancellationSignal): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null, signal)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        }
        return null
    }

    private fun finish(result: MethodChannel.Result, value: Any? = null, code: String? = null, message: String? = null) {
        if (destroyed || !activeResults.remove(result)) return
        if (pending === result) { pending = null; exportSource = null }
        if (code == null) result.success(value) else result.error(code, message, null)
    }

    private fun cleanupImportsAsync() {
        val files = unclaimedImports.toList()
        Thread {
            if (destroyed) {
                activeDescriptors.toList().forEach { resource ->
                    try { resource.close() } catch (error: Exception) { android.util.Log.w("Jianzhang", "Unable to close cancelled file operation", error) }
                }
                activeSignals.toList().forEach { it.cancel() }
            }
            files.forEach { file -> if (!file.exists() || file.delete()) unclaimedImports.remove(file) }
        }.apply { isDaemon = true; start() }
    }

    override fun onDestroy() {
        destroyed = true
        fileChannel?.setMethodCallHandler(null)
        performanceChannel?.setMethodCallHandler(null)
        activeResults.toList().forEach {
            try { it.error("FILE_CANCELLED", getString(R.string.file_cancelled), null) }
            catch (error: Exception) { android.util.Log.w("Jianzhang", "Cancelled channel is already detached", error) }
        }
        activeResults.clear()
        pending = null
        exportSource = null
        fileWorker.shutdownNow()
        cleanupImportsAsync()
        super.onDestroy()
    }

    companion object {
        private const val OPEN_DOCUMENT = 7311
        private const val SAVE_DOCUMENT = 7312
    }
}
