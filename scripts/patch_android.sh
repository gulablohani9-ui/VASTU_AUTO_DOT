#!/usr/bin/env bash
set -euo pipefail

APP_DIR="android/app/src/main/kotlin/com/graphicpoint/vastu_plot_chakra_pdf"
mkdir -p "$APP_DIR"
cat > "$APP_DIR/MainActivity.kt" <<'KOTLIN'
package com.graphicpoint.vastu_plot_chakra_pdf

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.graphicpoint.vastu_plot_chakra_pdf/chakra"
        private const val PICK_TREE = 7741
        private const val PREFS = "chakra_folder_prefs"
        private const val KEY_URI = "tree_uri"
    }

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickChakraFolder" -> pickFolder(result)
                "refreshChakraFolder" -> refreshFolder(result)
                "readChakraImage" -> readImage(call.argument<String>("uri"), result)
                "getChakraFolderName" -> result.success(folderName())
                else -> result.notImplemented()
            }
        }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("BUSY", "Folder picker already open", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_TREE)
    }

    private fun refreshFolder(result: MethodChannel.Result) {
        val saved = getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_URI, null)
        if (saved.isNullOrBlank()) {
            result.error("NO_FOLDER", "No CHKRA folder selected", null)
            return
        }
        try {
            result.success(listImages(Uri.parse(saved)))
        } catch (e: Exception) {
            result.error("READ_FOLDER", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_TREE) return
        val result = pendingResult
        pendingResult = null
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(emptyList<Map<String, String>>())
            return
        }
        val uri = data.data!!
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            try {
                contentResolver.takePersistableUriPermission(uri, flags or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: SecurityException) {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(KEY_URI, uri.toString()).apply()
            result.success(listImages(uri))
        } catch (e: Exception) {
            result.error("READ_FOLDER", e.message, null)
        }
    }

    private fun folderName(): String? {
        val saved = getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_URI, null) ?: return null
        return try {
            val docId = DocumentsContract.getTreeDocumentId(Uri.parse(saved))
            val last = docId.substringAfterLast(':')
            if (last.isBlank()) "CHKRA" else last
        } catch (_: Exception) {
            "CHKRA"
        }
    }

    private fun listImages(treeUri: Uri): List<Map<String, String>> {
        val output = mutableListOf<Map<String, String>>()
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        scanChildren(treeUri, rootId, output, 0)
        return output
    }

    private fun scanChildren(treeUri: Uri, parentId: String, output: MutableList<Map<String, String>>, depth: Int) {
        if (depth > 8) return
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        )
        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                val id = cursor.getString(idIndex)
                val name = cursor.getString(nameIndex) ?: "image"
                val mime = cursor.getString(mimeIndex) ?: ""
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    scanChildren(treeUri, id, output, depth + 1)
                    continue
                }
                if (isSupportedImage(name, mime)) {
                    val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                    output.add(mapOf("name" to name, "uri" to uri.toString()))
                }
            }
        }
    }

    private fun isSupportedImage(name: String, mime: String): Boolean {
        val lower = name.lowercase(Locale.US)
        return mime.startsWith("image/") || lower.endsWith(".png") || lower.endsWith(".jpg") ||
                lower.endsWith(".jpeg") || lower.endsWith(".webp")
    }

    private fun readImage(uriString: String?, result: MethodChannel.Result) {
        if (uriString.isNullOrBlank()) {
            result.error("BAD_URI", "Missing image URI", null)
            return
        }
        try {
            val input = contentResolver.openInputStream(Uri.parse(uriString))
                ?: throw IllegalStateException("Cannot open image")
            val out = ByteArrayOutputStream()
            input.use { stream ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = stream.read(buffer)
                    if (count <= 0) break
                    out.write(buffer, 0, count)
                }
            }
            result.success(out.toByteArray())
        } catch (e: Exception) {
            result.error("READ_IMAGE", e.message, null)
        }
    }
}
KOTLIN

# Keep the generated Android project dependency-free: DocumentsContract is part of Android itself.
