package com.nzqueenbee.mobile_pdf_editor

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channelName = "mobile_pdf_editor/file_io"
    private val pickPdfRequest = 7301
    private val savePdfRequest = 7302
    private val pickMultiplePdfsRequest = 7303
    private val pickTextRequest = 7304

    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSavePath: String? = null
    private var pendingPickMultipleResult: MethodChannel.Result? = null
    private var pendingPickTextResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickPdf" -> pickPdf(result)
                    "pickMultiplePdfs" -> pickMultiplePdfs(result)
                    "savePdf" -> savePdf(call, result)
                    "pickText" -> pickText(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickPdf(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("busy", "A PDF picker is already open.", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, pickPdfRequest)
    }

    private fun pickText(result: MethodChannel.Result) {
        if (pendingPickTextResult != null) {
            result.error("busy", "A text file picker is already open.", null)
            return
        }
        pendingPickTextResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "text/plain"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, pickTextRequest)
    }

    private fun pickMultiplePdfs(result: MethodChannel.Result) {
        if (pendingPickMultipleResult != null) {
            result.error("busy", "A PDF picker is already open.", null)
            return
        }
        pendingPickMultipleResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, pickMultiplePdfsRequest)
    }

    private fun savePdf(call: MethodCall, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("busy", "A PDF save dialog is already open.", null)
            return
        }
        val sourcePath = call.argument<String>("sourcePath")
        val fileName = sanitizeFileName(call.argument<String>("fileName") ?: "document.pdf")
        if (sourcePath.isNullOrBlank() || !File(sourcePath).exists()) {
            result.error("missing_source", "The PDF source file does not exist.", null)
            return
        }
        pendingSavePath = sourcePath
        pendingSaveResult = result
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        startActivityForResult(intent, savePdfRequest)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            pickPdfRequest -> completePick(pendingPickResult, resultCode, data?.data, "selected.pdf")
            savePdfRequest -> completeSave(resultCode, data?.data)
            pickMultiplePdfsRequest -> completePickMultiple(resultCode, data)
            pickTextRequest -> completePick(pendingPickTextResult, resultCode, data?.data, "selected.txt")
        }
        if (requestCode == pickPdfRequest) pendingPickResult = null
        if (requestCode == pickTextRequest) pendingPickTextResult = null
    }

    private fun completePick(
        pendingResult: MethodChannel.Result?,
        resultCode: Int,
        uri: Uri?,
        defaultName: String,
    ) {
        val result = pendingResult ?: return
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val displayName = queryDisplayName(uri) ?: defaultName
            val target = File(cacheDir, "picked_${System.currentTimeMillis()}_${sanitizeFileName(displayName)}")
            contentResolver.openInputStream(uri).use { input ->
                if (input == null) throw IllegalStateException("Unable to open selected file.")
                target.outputStream().use { output -> input.copyTo(output) }
            }
            result.success(mapOf("path" to target.absolutePath, "name" to displayName))
        } catch (error: Exception) {
            result.error("pick_failed", error.message, null)
        }
    }

    private fun completePickMultiple(resultCode: Int, data: Intent?) {
        val result = pendingPickMultipleResult ?: return
        pendingPickMultipleResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, String>>())
            return
        }
        val uris = mutableListOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (i in 0 until clipData.itemCount) {
                uris.add(clipData.getItemAt(i).uri)
            }
        } else {
            data.data?.let { uris.add(it) }
        }
        try {
            val picked = uris.map { uri ->
                val displayName = queryDisplayName(uri) ?: "selected.pdf"
                val target = File(
                    cacheDir,
                    "picked_${System.currentTimeMillis()}_${uris.indexOf(uri)}_${sanitizeFileName(displayName)}"
                )
                contentResolver.openInputStream(uri).use { input ->
                    if (input == null) throw IllegalStateException("Unable to open selected PDF.")
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                mapOf("path" to target.absolutePath, "name" to displayName)
            }
            result.success(picked)
        } catch (error: Exception) {
            result.error("pick_failed", error.message, null)
        }
    }

    private fun completeSave(resultCode: Int, uri: Uri?) {
        val result = pendingSaveResult ?: return
        val sourcePath = pendingSavePath
        pendingSaveResult = null
        pendingSavePath = null
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(false)
            return
        }
        try {
            if (sourcePath.isNullOrBlank()) throw IllegalStateException("Missing source PDF.")
            FileInputStream(File(sourcePath)).use { input ->
                contentResolver.openOutputStream(uri).use { output ->
                    if (output == null) throw IllegalStateException("Unable to open save destination.")
                    input.copyTo(output)
                }
            }
            result.success(true)
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        val cursor: Cursor? = contentResolver.query(uri, null, null, null, null)
        cursor.use {
            if (it == null || !it.moveToFirst()) return null
            val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index < 0) return null
            return it.getString(index)
        }
    }

    private fun sanitizeFileName(value: String): String {
        return value.replace(Regex("[^A-Za-z0-9가-힣._-]"), "_")
    }
}
