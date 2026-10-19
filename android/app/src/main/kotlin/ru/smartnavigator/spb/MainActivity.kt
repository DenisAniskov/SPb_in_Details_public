package ru.smartnavigator.spb

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import ru.smartnavigator.spb.voice.AndroidSttBridge

class MainActivity : FlutterActivity() {
    private var androidSttBridge: AndroidSttBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        androidSttBridge = AndroidSttBridge(this, messenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        androidSttBridge?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        androidSttBridge?.release()
        androidSttBridge = null
        super.onDestroy()
    }
}
