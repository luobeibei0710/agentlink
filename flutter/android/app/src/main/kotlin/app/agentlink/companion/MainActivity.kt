package app.agentlink.companion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null

    private fun pairingLink(intent: Intent?): String? {
        val uri = intent?.data ?: return null
        return if (uri.scheme == "hapicompanion" && uri.host == "bind") uri.toString() else null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLink = pairingLink(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.agentlink.companion/links")
        channel?.setMethodCallHandler { call, result ->
            if (call.method == "initialLink") {
                result.success(pendingLink)
                pendingLink = null
            } else result.notImplemented()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pairingLink(intent)?.let { link ->
            pendingLink = link
            channel?.invokeMethod("link", link, object : MethodChannel.Result {
                override fun success(result: Any?) { if (pendingLink == link) pendingLink = null }
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            })
        }
    }
}
