package dev.longarm

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

class MainActivity : ComponentActivity() {
    private var pendingPairing by mutableStateOf<Pairing?>(null)
    private var pairError by mutableStateOf<String?>(null)

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Always-dark UI: light status-bar icons regardless of the system theme.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        handleLink(intent)

        setContent {
            MaterialTheme(colorScheme = darkColorScheme(background = Background, surface = Surface, primary = Accent)) {
                val state by MacLink.state.collectAsStateWithLifecycle()
                var controlling by rememberSaveable { mutableStateOf(false) }
                val snackbar = remember { SnackbarHostState() }
                LaunchedEffect(Unit) { Remote.notices.collect { snackbar.showSnackbar(it) } }
                BackHandler(enabled = controlling) { controlling = false }

                Box(Modifier.fillMaxSize().background(Background).systemBarsPadding()) {
                    when {
                        state.status == MacLink.Status.Unpaired -> PairScreen(error = pairError, onScan = ::scanQrCode)
                        controlling -> RemotePane(state, onExit = { controlling = false }, Modifier.fillMaxSize())
                        else -> HomeScreen(
                            state,
                            onControl = { controlling = true },
                            onForget = {
                                MacLink.forget()
                                LinkService.stop(this@MainActivity)
                            },
                        )
                    }
                    SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp))
                    if (!controlling) VersionLabel(Modifier.align(Alignment.BottomStart))
                }
                pendingPairing?.let { pairing ->
                    AlertDialog(
                        onDismissRequest = { pendingPairing = null },
                        title = { Text("Pair with ${pairing.macName}?") },
                        text = { Text("${pairing.host}:${pairing.port}\n\nOnly pair with your own Mac. Once you allow remote control on it, this phone can see its screen and use its keyboard and mouse.") },
                        confirmButton = {
                            TextButton(onClick = {
                                MacLink.pair(pairing)
                                LinkService.start(this@MainActivity)
                                pendingPairing = null
                            }) { Text("Pair") }
                        },
                        dismissButton = { TextButton(onClick = { pendingPairing = null }) { Text("Cancel") } },
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleLink(intent)
    }

    override fun onStart() {
        super.onStart()
        if (MacLink.pairing != null) LinkService.start(this)
    }

    private fun handleLink(intent: Intent?) {
        val link = intent?.dataString ?: return
        acceptLink(link)
    }

    private fun acceptLink(link: String?) {
        val pairing = link?.let(Pairing::parse)
        if (pairing == null) {
            pairError = "That isn't a Longarm pairing code."
        } else {
            pairError = null
            pendingPairing = pairing
        }
    }

    private fun scanQrCode() {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { acceptLink(it.rawValue) }
            .addOnFailureListener { pairError = "Scanner unavailable: ${it.message}" }
    }
}

@Composable
private fun PairScreen(error: String?, onScan: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Longarm", fontSize = 34.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Spacer(Modifier.height(8.dp))
        Text("Your Mac, from your phone", color = Muted, fontSize = 16.sp)
        Spacer(Modifier.height(24.dp))
        Text(
            "On your Mac, click the Longarm icon in the menu bar → Pair a Phone…, then scan the code.",
            color = Muted, textAlign = TextAlign.Center, fontSize = 16.sp,
        )
        Spacer(Modifier.height(28.dp))
        Button(onClick = onScan) { Text("Scan QR code") }
        if (error != null) {
            Spacer(Modifier.height(16.dp))
            Text(error, color = LockedAccent, textAlign = TextAlign.Center)
        }
    }
}

/** Paired: the Mac's status, and the way in to remote control. */
@Composable
private fun HomeScreen(state: MacLink.State, onControl: () -> Unit, onForget: () -> Unit) {
    val remote by Remote.state.collectAsStateWithLifecycle()
    val connected = state.status == MacLink.Status.Connected
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Longarm", fontSize = 34.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Spacer(Modifier.height(20.dp))
        Box(Modifier.size(10.dp).background(if (connected) Color(0xFF4ADE80) else LockedAccent, CircleShape))
        Spacer(Modifier.height(8.dp))
        Text(
            when (state.status) {
                MacLink.Status.Connected -> "Connected to ${state.macName} · ${state.via}"
                MacLink.Status.Searching -> "Looking for ${state.macName}…"
                else -> "Connecting to ${state.macName}…"
            },
            color = Body, fontSize = 16.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(32.dp))
        Button(
            onClick = onControl, enabled = connected,
            colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Background),
        ) { Text("Control your Mac", fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
        if (connected && !remote.allowed) {
            Spacer(Modifier.height(16.dp))
            Text("First, on the Mac: Longarm menu → Allow Remote Control", color = Muted, fontSize = 14.sp, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(40.dp))
        TextButton(onClick = onForget) { Text("Forget this Mac", color = Muted) }
    }
}

@Composable
internal fun VersionLabel(modifier: Modifier = Modifier) {
    Text(
        "v${BuildConfig.VERSION_NAME} · ${BuildConfig.BUILD_TIME}",
        color = Muted.copy(alpha = 0.5f), fontSize = 10.sp,
        modifier = modifier.padding(horizontal = 12.dp, vertical = 6.dp),
    )
}
