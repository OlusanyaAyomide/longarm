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
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import kotlin.math.sqrt
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
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
                var askingCode by remember { mutableStateOf(false) }
                val snackbar = remember { SnackbarHostState() }
                LaunchedEffect(Unit) { Remote.notices.collect { snackbar.showSnackbar(it) } }
                BackHandler(enabled = controlling) { controlling = false }
                // Over the internet, the link lasts as long as remote control is open: leaving it
                // disconnects, and a refused code comes back here, asking for it.
                LaunchedEffect(controlling) { if (!controlling) MacLink.disconnectInternet() }
                LaunchedEffect(state.joinError) {
                    if (state.mode == MacLink.Mode.Internet && state.joinError != null && controlling) {
                        controlling = false
                        askingCode = true
                    }
                }

                Box(Modifier.fillMaxSize().background(Background).systemBarsPadding()) {
                    when {
                        state.status == MacLink.Status.Unpaired -> PairScreen(error = pairError, onScan = ::scanQrCode)
                        controlling -> RemotePane(state, onExit = { controlling = false }, Modifier.fillMaxSize())
                        else -> HomeScreen(
                            state,
                            onControl = {
                                if (state.mode == MacLink.Mode.Internet && !MacLink.hasTicket) {
                                    askingCode = true
                                } else {
                                    if (state.mode == MacLink.Mode.Internet) MacLink.connectInternet(code = null)   // on last time's ticket
                                    controlling = true
                                }
                            },
                            onForget = {
                                MacLink.forget()
                                LinkService.stop(this@MainActivity)
                            },
                        )
                    }
                    SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp))
                    if (!controlling) VersionLabel(Modifier.align(Alignment.BottomStart))
                }
                if (askingCode) {
                    JoinCodeDialog(
                        macName = state.macName, error = state.joinError,
                        onJoin = { code ->
                            askingCode = false
                            MacLink.connectInternet(code)
                            controlling = true
                        },
                        onCancel = { askingCode = false },
                    )
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

/** Paired: how to connect (picked, never guessed), the Mac's status, and the way in to remote control. */
@Composable
private fun HomeScreen(state: MacLink.State, onControl: () -> Unit, onForget: () -> Unit) {
    val remote by Remote.state.collectAsStateWithLifecycle()
    val connected = state.status == MacLink.Status.Connected
    val internet = state.mode == MacLink.Mode.Internet
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Longarm", fontSize = 34.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        Spacer(Modifier.height(24.dp))
        ModePicker(state.mode, onSelect = MacLink::setMode)
        Spacer(Modifier.height(24.dp))
        Box(Modifier.size(10.dp).background(if (connected || (internet && state.internet != null)) Color(0xFF4ADE80) else LockedAccent, CircleShape))
        Spacer(Modifier.height(8.dp))
        Text(
            when {
                internet && state.internet == null -> "This phone doesn't know where to find ${state.macName} over the internet yet"
                internet -> "${state.macName} through ${state.internet}"
                state.status == MacLink.Status.Connected -> "Connected to ${state.macName} · ${state.via}"
                state.status == MacLink.Status.Searching -> "Looking for ${state.macName}…"
                else -> "Connecting to ${state.macName}…"
            },
            color = Body, fontSize = 16.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(32.dp))
        Button(
            onClick = onControl, enabled = if (internet) state.internet != null else connected,
            colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Background),
        ) { Text("Control your Mac", fontSize = 17.sp, fontWeight = FontWeight.SemiBold) }
        val hint = when {
            internet && state.internet == null ->
                "On the Mac: Longarm menu → Internet Server… and Internet. Then connect at home once, so this phone learns it."
            internet -> "You'll be asked for the join code you set on the Mac, again after 10 minutes away."
            connected && !remote.allowed -> "First, on the Mac: Longarm menu → Allow Remote Control"
            else -> null
        }
        if (hint != null) {
            Spacer(Modifier.height(16.dp))
            Text(hint, color = Muted, fontSize = 14.sp, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(40.dp))
        TextButton(onClick = onForget) { Text("Forget this Mac", color = Muted) }
    }
}

/** How to connect, picked by the owner: two cards, the chosen one in Longarm orange. */
@Composable
private fun ModePicker(selected: MacLink.Mode, onSelect: (MacLink.Mode) -> Unit) {
    Row(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        ModeCard(selected == MacLink.Mode.Home, "At home", "Same Wi-Fi or USB", { WifiIcon(it) }) { onSelect(MacLink.Mode.Home) }
        ModeCard(selected == MacLink.Mode.Internet, "Internet", "From anywhere", { GlobeIcon(it) }) { onSelect(MacLink.Mode.Internet) }
    }
}

@Composable
private fun RowScope.ModeCard(selected: Boolean, title: String, detail: String, icon: @Composable (Color) -> Unit, onClick: () -> Unit) {
    val shape = RoundedCornerShape(18.dp)
    Column(
        Modifier.weight(1f)
            .clip(shape)
            .background(if (selected) Accent.copy(alpha = 0.12f) else Surface)
            .border(if (selected) 1.5.dp else 1.dp, if (selected) Accent else Line, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(vertical = 18.dp, horizontal = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        icon(if (selected) Accent else Muted)
        Spacer(Modifier.height(10.dp))
        Text(title, color = if (selected) Color.White else Body, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(2.dp))
        Text(detail, color = Muted, fontSize = 12.sp, textAlign = TextAlign.Center)
    }
}

/** Three arcs over a dot. */
@Composable
private fun WifiIcon(color: Color) {
    Canvas(Modifier.size(32.dp)) {
        val stroke = Stroke(width = size.width * 0.09f, cap = StrokeCap.Round)
        val base = Offset(size.width / 2, size.height * 0.8f)
        for (fraction in listOf(0.26f, 0.5f, 0.74f)) {
            val radius = size.width * fraction
            drawArc(color, startAngle = 225f, sweepAngle = 90f, useCenter = false,
                topLeft = Offset(base.x - radius, base.y - radius), size = Size(radius * 2, radius * 2), style = stroke)
        }
        drawCircle(color, radius = size.width * 0.07f, center = base)
    }
}

/** A circle with a meridian and three parallels. */
@Composable
private fun GlobeIcon(color: Color) {
    Canvas(Modifier.size(32.dp)) {
        val width = size.width * 0.075f
        val stroke = Stroke(width = width, cap = StrokeCap.Round)
        val radius = size.width * 0.42f
        drawCircle(color, radius = radius, center = center, style = stroke)
        drawOval(color, topLeft = Offset(center.x - radius * 0.45f, center.y - radius), size = Size(radius * 0.9f, radius * 2), style = stroke)
        for (offset in listOf(-0.5f, 0f, 0.5f)) {
            val y = center.y + radius * offset
            val half = radius * sqrt(1 - offset * offset)
            drawLine(color, Offset(center.x - half, y), Offset(center.x + half, y), strokeWidth = width, cap = StrokeCap.Round)
        }
    }
}

/** Asked when there's no ticket from the Mac, or it ran out (10 minutes unused); never stored. */
@Composable
private fun JoinCodeDialog(macName: String, error: String?, onJoin: (String) -> Unit, onCancel: () -> Unit) {
    var code by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("Join code for $macName") },
        text = {
            Column {
                Text("The code you set in the Longarm menu on the Mac.", color = Muted)
                Spacer(Modifier.height(16.dp))
                OutlinedTextField(
                    value = code, onValueChange = { typed -> code = typed.filter(Char::isDigit).take(12) },
                    singleLine = true, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { if (code.length >= 6) onJoin(code) }),
                    modifier = Modifier.focusRequester(focus),
                )
                if (error != null) {
                    Spacer(Modifier.height(12.dp))
                    Text(error, color = LockedAccent, fontSize = 14.sp)
                }
            }
        },
        confirmButton = { TextButton(onClick = { onJoin(code) }, enabled = code.length >= 6) { Text("Connect") } },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

@Composable
internal fun VersionLabel(modifier: Modifier = Modifier) {
    Text(
        "v${BuildConfig.VERSION_NAME} · ${BuildConfig.BUILD_TIME}",
        color = Muted.copy(alpha = 0.5f), fontSize = 10.sp,
        modifier = modifier.padding(horizontal = 12.dp, vertical = 6.dp),
    )
}
