package dev.longarm

import android.graphics.SurfaceTexture
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.input.pointer.PointerEvent
import android.util.Log
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.AnnotatedString
import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.text.style.TextOverflow
import androidx.core.content.ContextCompat
import android.graphics.Bitmap
import android.os.Build
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.TextureView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.runtime.Stable
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.abs
import kotlin.math.roundToInt
import android.content.res.Configuration
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateCentroidSize
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * Remote control: the Mac's whole screen, live and as large as the phone allows (no header, no
 * status or navigation bar; swipe from an edge to see them), with the phone's touches as its pointer.
 *
 *   tap = click · tap twice = double-click · two-finger tap = right-click there; R = right-click at the pointer
 *   long-press then drag = click-and-drag (select text, move windows); long-press alone = click
 *   one-finger drag = scroll the Mac, or move the view when zoomed in
 *   two fingers: pinch = zoom, move together = scroll the Mac
 *   three fingers: up = Mission Control, down = app windows, left / right = next Space
 *
 * Opens in landscape (⟳ switches, and the choice is remembered), whatever the phone's rotation lock.
 * Controls float over the picture: on the left stop, rotate, keyboard and hide; on the
 * right the modifier and common keys. Opening this screen asks the Mac to start remote control
 * (it has to be allowed in the Longarm menu there); leaving stops it.
 */
@Composable
internal fun RemotePane(state: MacLink.State, onExit: () -> Unit, modifier: Modifier) {
    val remote by Remote.state.collectAsStateWithLifecycle()
    val shownScreen by Remote.screen.collectAsStateWithLifecycle()
    val area = shownScreen
    val held = remember { mutableStateListOf<String>() }
    var controls by remember { mutableStateOf(true) }
    var typing by remember { mutableStateOf(false) }
    var landscape by remember { mutableStateOf(Remote.landscape) }
    val zoom = remember { ZoomState() }
    val dictation by Remote.dictation.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val askForMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) Remote.startDictation() else Remote.notice("Dictation needs the microphone")
    }
    fun toggleMic() {
        when {
            dictation.on -> Remote.stopDictation()
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED -> Remote.startDictation()
            else -> askForMic.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
    val vibrate = rememberKeyVibration()
    // Dictation lives on the keyboard: putting the keyboard away stops it.
    LaunchedEffect(typing) { if (!typing) Remote.stopDictation() }
    val activity = LocalContext.current.findActivity()
    val view = LocalView.current
    DisposableEffect(Unit) {
        Remote.setWanted(true)
        val window = activity?.window
        val bars = window?.let { WindowCompat.getInsetsController(it, view) }
        bars?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        bars?.hide(WindowInsetsCompat.Type.systemBars())
        view.keepScreenOn = true   // watching the Mac counts as using the phone
        if (landscape) activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        onDispose {
            Remote.setWanted(false)
            bars?.show(WindowInsetsCompat.Type.systemBars())
            view.keepScreenOn = false
            activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }
    fun press(key: String, vararg extra: String) {
        vibrate()
        Remote.key(key, held + extra)
        held.clear()
    }

    Box(modifier.background(Color.Black).clipToBounds()) {
        if (area != null) {
            ZoomableScreen(area, zoom, vibrate, onTapOutside = { typing = false })
        } else {
            Text(
                when {
                    state.status != MacLink.Status.Connected ->
                        "Connecting to ${state.macName}${if (state.mode == MacLink.Mode.Internet) " over the internet" else ""}…"
                    remote.error != null -> remote.error!!
                    !remote.allowed -> "Turn on Allow Remote Control in the Longarm menu on the Mac"
                    else -> "Starting…"
                },
                color = Muted, fontSize = 14.sp, textAlign = TextAlign.Center,
                modifier = Modifier.align(Alignment.Center).padding(48.dp),
            )
        }
        // The controls sit above the keyboard; empty space lets touches through to the picture.
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (controls) {
                    Rail(Modifier.align(Alignment.CenterStart)) {
                        RailButton("✕", "Stop remote control") { onExit() }
                        RailButton("⟳", "Rotate") {
                            landscape = !landscape
                            Remote.landscape = landscape
                            activity?.requestedOrientation =
                                if (landscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
                        }
                        RailButton("⌨", "Keyboard", active = typing) { typing = !typing }
                        RailButton("R", "Right-click where the pointer is") { vibrate(); Remote.rightClickHere() }
                        // Getting out of a full-screen app: Mission Control, the Spaces either side, leave full screen.
                        RailButton("▦", "Mission Control") { press("up", "control") }
                        RailButton("◀", "Space to the left") { press("left", "control") }
                        RailButton("▶", "Space to the right") { press("right", "control") }
                        RailButton("⤡", "Leave full screen") { press("f", "control", "cmd") }
                        RailButton("◌", "Hide controls") { controls = false; typing = false }
                    }
                    Rail(Modifier.align(Alignment.CenterEnd)) {
                        for ((name, label) in listOf("cmd" to "⌘", "option" to "⌥", "control" to "⌃", "shift" to "⇧")) {
                            RailButton(label, name, active = name in held) { if (name in held) held.remove(name) else held.add(name) }
                        }
                        // Zoom in the window in front: ⌘+ as the +/= key sends it, ⌘−, and back to normal.
                        RailButton("⌘+", "Zoom in") { press("=", "cmd") }
                        RailButton("⌘−", "Zoom out") { press("-", "cmd") }
                        RailButton("⌘0", "Actual size") { press("0", "cmd") }
                        RailButton("esc", "Escape") { press("escape") }
                        RailButton("⇥", "Tab") { press("tab") }
                        RailButton("⌫", "Delete") { press("delete") }
                        RailButton("↵", "Return") { press("return") }
                        RailButton("↑", "Up") { press("up") }
                        RailButton("↓", "Down") { press("down") }
                        RailButton("←", "Left") { press("left") }
                        RailButton("→", "Right") { press("right") }
                        RailButton("⌘⇥", "Switch app") { press("tab", "cmd") }
                        RailButton("⌘␣", "Spotlight") { press("space", "cmd") }
                    }
                } else {
                    RailButton("•••", "Show controls", modifier = Modifier.align(Alignment.TopStart).padding(8.dp)) { controls = true }
                }
            }
            if (typing && area != null) {
                MacKeyboard(held, area, zoom, vibrate, dictation, onMic = ::toggleMic, onHide = { typing = false },
                    Modifier.align(Alignment.CenterHorizontally))
            }
        }
    }
}

/** A column of round, see-through buttons along an edge; scrolls if the screen is short (landscape). */
@Composable
private fun Rail(modifier: Modifier, content: @Composable () -> Unit) {
    Column(
        modifier.padding(6.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) { content() }
}

@Composable
private fun RailButton(
    label: String, description: String, modifier: Modifier = Modifier, active: Boolean = false, activeColor: Color = HeldAccent, onClick: () -> Unit,
) {
    Box(
        modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(if (active) activeColor else Color.Black.copy(alpha = 0.5f))
            .border(1.dp, Color.White.copy(alpha = if (active) 0f else 0.18f), CircleShape)
            .clickable(onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = if (active) Background else Color.White, fontSize = if (label.length > 2) 11.sp else 15.sp,
            fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/** The picture's zoom, shared with the keyboard (its blurred background follows the picture). */
@Stable
private class ZoomState {
    var size by mutableStateOf(IntSize.Zero)
    var scale by mutableFloatStateOf(1f)
    var offset by mutableStateOf(Offset.Zero)
    var origin by mutableStateOf(Offset.Zero)   // the box's top-left on screen

    /** Where the picture sits in the (unzoomed) box: fitted, keeping the Mac screen's shape. */
    fun pictureRect(area: Remote.Screen): Rect {
        val width = size.width.toFloat()
        val height = size.height.toFloat()
        val ratio = area.width.toFloat() / area.height.coerceAtLeast(1)
        return if (ratio < width / height) {
            val w = height * ratio
            Rect((width - w) / 2, 0f, (width + w) / 2, height)
        } else {
            val h = width / ratio
            Rect(0f, (height - h) / 2, width, (height + h) / 2)
        }
    }

    /** The picture on screen, zoom included. */
    fun pictureOnScreen(area: Remote.Screen): Rect {
        val picture = pictureRect(area)
        return Rect(origin + picture.topLeft * scale + offset, picture.size * scale)
    }
}

@Composable
private fun ZoomableScreen(
    area: Remote.Screen, zoom: ZoomState, vibrate: () -> Unit,
    onTapOutside: () -> Unit,
) {
    var size by zoom::size
    var scale by zoom::scale
    var offset by zoom::offset
    val haptics = LocalHapticFeedback.current
    val currentArea by rememberUpdatedState(area)
    fun pictureRect() = zoom.pictureRect(currentArea)

    /** A touch on screen → 0…1 on the Mac's screen, undoing the zoom. */
    fun toMac(touch: Offset): Offset {
        val picture = pictureRect()
        val content = (touch - offset) / scale
        return Offset((content.x - picture.left) / picture.width, (content.y - picture.top) / picture.height)
    }

    fun onMac(point: Offset) = point.x in 0f..1f && point.y in 0f..1f

    /** Scrolls the Mac under [at] by a finger movement on screen: the content follows the finger. */
    fun scrollMac(at: Offset, move: Offset) {
        val picture = pictureRect()
        val delta = move / scale
        val point = toMac(at)
        Remote.scroll(point.x, point.y, delta.x / picture.width * currentArea.width, delta.y / picture.height * currentArea.height)
    }

    /** Moves the zoomed-in view by [move], keeping the picture filling the box. */
    fun pan(move: Offset) {
        offset = Offset(
            (offset.x + move.x).coerceIn(size.width * (1 - scale), 0f),
            (offset.y + move.y).coerceIn(size.height * (1 - scale), 0f),
        )
    }

    Box(
        Modifier
            .fillMaxSize()
            .onGloballyPositioned { zoom.origin = it.positionInRoot() }
            .onSizeChanged {
                if (it != size) {   // rotated: start from the whole screen again
                    size = it
                    scale = 1f
                    offset = Offset.Zero
                }
            }
            .pointerInput(Unit) {
                var lastTap = 0L
                var lastTapAt = Offset.Zero
                val slop = viewConfiguration.touchSlop
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val start = down.position
                    var last = start
                    var mode = Gesture.Pending
                    var swipeFrom = Offset.Zero   // three fingers: where they started, and where they are
                    var swipeTo = Offset.Zero
                    var twoFingerTap = false      // two fingers down from a still start: a right-click unless they move
                    var twoFingersAt = Offset.Zero
                    var twoFingersSince = 0L
                    var twoFingerSpan = 0f        // how far apart the fingers were when they came down
                    var twoFingers: Gesture? = null   // decided once they move: Zoom (pinch) or Scroll
                    while (true) {
                        val event = if (mode == Gesture.Pending) {
                            withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) { awaitPointerEvent() }
                        } else {
                            awaitPointerEvent()
                        }
                        if (event == null) {   // held still: a long press
                            mode = Gesture.LongPress
                            vibrate()
                            continue
                        }
                        val pressed = event.changes.filter { it.pressed }
                        // Three fingers, like on the Mac's trackpad: up = Mission Control, down = the app's
                        // windows, left / right = the next Space or full-screen app.
                        if (mode == Gesture.Swipe || (pressed.size >= 3 && mode in listOf(Gesture.Pending, Gesture.Scroll, Gesture.Zoom))) {
                            if (mode != Gesture.Swipe) {
                                mode = Gesture.Swipe
                                swipeFrom = event.calculateCentroid()
                                swipeTo = swipeFrom
                            }
                            if (pressed.size >= 3) swipeTo = event.calculateCentroid()
                            event.changes.forEach { it.consume() }
                            if (pressed.isNotEmpty()) continue
                            val move = swipeTo - swipeFrom
                            val enough = 60.dp.toPx()
                            when {
                                abs(move.y) > abs(move.x) && move.y < -enough -> Remote.key("up", listOf("control"))
                                abs(move.y) > abs(move.x) && move.y > enough -> Remote.key("down", listOf("control"))
                                move.x < -enough -> Remote.key("right", listOf("control"))   // fingers left: the Space to the right
                                move.x > enough -> Remote.key("left", listOf("control"))
                                else -> break   // too small to count
                            }
                            vibrate()
                            break
                        }
                        // A second finger joins: a two-finger gesture, even if the first was already scrolling or held.
                        if (mode == Gesture.Zoom || (pressed.size >= 2 && mode in listOf(Gesture.Pending, Gesture.Scroll, Gesture.Pan, Gesture.LongPress))) {
                            if (pressed.isEmpty()) {
                                // Two fingers that went down and up without moving: a right-click, like the trackpad.
                                val held = System.currentTimeMillis() - twoFingersSince
                                if (twoFingerTap && held < 1500) {
                                    val point = toMac(twoFingersAt)
                                    if (onMac(point)) {
                                        vibrate()
                                        Remote.click(point.x, point.y, right = true)
                                    }
                                } else if (twoFingers == null) {
                                    Log.i("LongarmGestures", "two-finger tap not taken: held $held ms, still=$twoFingerTap")
                                }
                                break
                            }
                            if (mode != Gesture.Zoom) {
                                // Fingers rarely land together: a first finger that was resting still counts.
                                twoFingerTap = mode == Gesture.Pending || mode == Gesture.LongPress
                                twoFingersAt = fingersCentre(event)
                                twoFingersSince = System.currentTimeMillis()
                                twoFingerSpan = fingersSpread(event)
                                twoFingers = null
                            }
                            mode = Gesture.Zoom
                            if (pressed.size >= 2) {
                                // Like the trackpad: fingers spreading or pinching zoom; moving together scroll the Mac.
                                val centroid = fingersCentre(event)
                                if (twoFingers == null) {
                                    // Spreading or pinching wins over moving: a pinch moves the middle point a little too.
                                    val spread = abs(fingersSpread(event) - twoFingerSpan)
                                    val moved = (centroid - twoFingersAt).getDistance()
                                    twoFingers = when {
                                        spread > slop * 2 -> Gesture.Zoom   // fingertips roll a little on a tap
                                        moved > slop * 2 -> Gesture.Scroll
                                        else -> null
                                    }
                                    if (twoFingers != null) {
                                        twoFingerTap = false
                                        Log.i("LongarmGestures", "two fingers: $twoFingers (spread ${spread.toInt()} px, moved ${moved.toInt()} px)")
                                    }
                                }
                                when (twoFingers) {
                                    Gesture.Zoom -> {
                                        val newScale = (scale * event.calculateZoom()).coerceIn(1f, 5f)
                                        val moved = centroid - (centroid - offset) * (newScale / scale) + event.calculatePan()
                                        scale = newScale
                                        offset = Offset(
                                            moved.x.coerceIn(size.width * (1 - scale), 0f),
                                            moved.y.coerceIn(size.height * (1 - scale), 0f),
                                        )
                                    }
                                    Gesture.Scroll -> scrollMac(centroid, event.calculatePan())
                                    else -> {}
                                }
                            }
                            event.changes.forEach { it.consume() }
                            continue
                        }
                        if (pressed.isEmpty()) {   // lifted
                            val point = toMac(start)
                            when (mode) {
                                Gesture.Pending, Gesture.LongPress -> if (mode == Gesture.LongPress) {
                                    // Held but not dragged: still just a click, so a slow tap never becomes a right-click.
                                    if (onMac(point)) Remote.click(point.x, point.y)
                                } else if (onMac(point)) {
                                    val now = System.currentTimeMillis()
                                    val twice = now - lastTap < 350 && (start - lastTapAt).getDistance() < 48.dp.toPx()
                                    Remote.click(point.x, point.y, count = if (twice) 2 else 1)
                                    lastTap = if (twice) 0L else now
                                    lastTapAt = start
                                } else {
                                    onTapOutside()   // the black around the picture: like tapping away from a phone keyboard
                                }
                                Gesture.Drag -> toMac(last).let { Remote.drag("end", it.x, it.y) }
                                else -> {}
                            }
                            break
                        }
                        val change = pressed.first()
                        val position = change.position
                        val far = (position - start).getDistance() > slop
                        // Zoomed in, one finger moves the view; otherwise it scrolls the Mac.
                        if (mode == Gesture.Pending && far) mode = if (scale > 1.01f) Gesture.Pan else Gesture.Scroll
                        if (mode == Gesture.LongPress && far) {
                            mode = Gesture.Drag
                            toMac(start).let { Remote.drag("start", it.x, it.y) }
                        }
                        when (mode) {
                            Gesture.Scroll -> scrollMac(position, position - last)
                            Gesture.Pan -> pan(position - last)
                            Gesture.Drag -> toMac(position).let { Remote.drag("move", it.x, it.y) }
                            else -> {}
                        }
                        last = position
                        change.consume()
                    }
                }
            },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    translationX = offset.x
                    translationY = offset.y
                    transformOrigin = TransformOrigin(0f, 0f)
                },
        ) {
            ScreenPicture(area, Modifier.fillMaxSize()) {}
        }
    }
}

private enum class Gesture { Pending, Scroll, Pan, LongPress, Drag, Zoom, Swipe }

/**
 * A see-through keyboard over the picture. Unlike the phone's own keyboard it doesn't push
 * anything around, and each key goes to the Mac as it's tapped. A modifier held on the right-hand
 * rail (⌘ ⌥ ⌃ ⇧) turns the next key into a shortcut, e.g. ⌘ then c = ⌘C.
 *
 * Its top strip is a handle: drag it to move the keyboard up or down. The slider there sets how
 * much the picture behind it is blurred. Both are remembered.
 */
@Composable
private fun MacKeyboard(
    held: MutableList<String>, area: Remote.Screen, zoom: ZoomState, vibrate: () -> Unit,
    dictation: Remote.Dictation, onMic: () -> Unit, onHide: () -> Unit, modifier: Modifier,
) {
    var page by remember { mutableIntStateOf(0) }   // letters, numbers, more symbols
    var shift by remember { mutableStateOf(false) }
    var lift by remember { mutableFloatStateOf(Remote.keyboardLift) }
    var blur by remember { mutableFloatStateOf(Remote.keyboardBlur) }
    var origin by remember { mutableStateOf(Offset.Zero) }
    var height by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val keyHeight = if (landscape) 34.dp else 46.dp
    val backdrop by PictureCopy.image.collectAsStateWithLifecycle()
    DisposableEffect(blur > 0) {
        PictureCopy.wanted = blur > 0
        onDispose { PictureCopy.wanted = false }
    }

    // What was just typed, shown in the handle for a moment (remote typing has no text box to look at).
    var echo by remember { mutableStateOf("") }
    LaunchedEffect(echo) {
        if (echo.isNotEmpty()) {
            delay(1500)
            echo = ""
        }
    }
    fun character(c: String) {
        vibrate()
        echo = if (held.isEmpty()) {
            (echo + if (shift) c.uppercase() else c).takeLast(28)
        } else {
            shortcut(held + if (shift) listOf("shift") else emptyList(), c)   // exactly what the Mac was sent, e.g. ⌘+
        }
        if (held.isNotEmpty()) {
            Remote.key(c, held + if (shift) listOf("shift") else emptyList())
            held.clear()
        } else {
            Remote.type(if (shift) c.uppercase() else c)
        }
        shift = false
    }
    fun named(key: String) {
        vibrate()
        echo = when (key) {
            "delete" -> echo.dropLast(1)
            "return" -> ""
            else -> echo
        }
        Remote.key(key, held.toList())
        held.clear()
    }

    val rows = when (page) {
        0 -> listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")
        1 -> listOf("1234567890", "-/:;()$&@\"", ".,?!'")
        else -> listOf("[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'")
    }
    Column(
        modifier
            .offset { IntOffset(0, -lift.dp.roundToPx()) }
            .fillMaxWidth()
            .widthIn(max = 720.dp)
            .onGloballyPositioned { origin = it.positionInRoot(); height = it.size.height }
            .clipToBounds()
            .drawBehind { drawRect(Color.Black.copy(alpha = 0.2f + 0.3f * blur)) },
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box {
            // The picture behind, blurred: a small live copy, drawn where the picture is.
            if (blur > 0) {
                backdrop?.let { image ->
                    Canvas(
                        Modifier
                            .matchParentSize()
                            .blur((blur * 24).dp, BlurredEdgeTreatment.Rectangle),
                    ) {
                        val picture = zoom.pictureOnScreen(area)
                        drawImage(
                            image,
                            dstOffset = IntOffset((picture.left - origin.x).roundToInt(), (picture.top - origin.y).roundToInt()),
                            dstSize = IntSize(picture.width.roundToInt(), picture.height.roundToInt()),
                            filterQuality = FilterQuality.Low,
                        )
                        drawRect(Color.Black.copy(alpha = 0.25f))
                    }
                }
            }
            Column(Modifier.padding(4.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Row(Modifier.fillMaxWidth().height(30.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Blur", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, modifier = Modifier.padding(start = 8.dp, end = 6.dp))
                    Slider(
                        value = blur,
                        onValueChange = { blur = it },
                        onValueChangeFinished = { Remote.keyboardBlur = blur },
                        colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = HeldAccent, inactiveTrackColor = Color.White.copy(alpha = 0.25f)),
                        modifier = Modifier.width(120.dp),
                    )
                    // The handle: drag to move the keyboard up or down.
                    Box(
                        Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .pointerInput(Unit) {
                                detectVerticalDragGestures(
                                    onDragEnd = { Remote.keyboardLift = lift },
                                ) { change, dy ->
                                    change.consume()
                                    val room = with(density) { (zoom.size.height - height).toDp().value }.coerceAtLeast(0f)
                                    lift = (lift - with(density) { dy.toDp().value }).coerceIn(0f, room)
                                }
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (echo.isEmpty()) {
                            Box(Modifier.size(width = 44.dp, height = 5.dp).background(Color.White.copy(alpha = 0.6f), RoundedCornerShape(3.dp)))
                        } else {
                            Text(echo, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1,
                                modifier = Modifier.background(Color.Black.copy(alpha = 0.45f), RoundedCornerShape(8.dp)).padding(horizontal = 10.dp, vertical = 2.dp))
                        }
                    }
                    Text("⌄", color = Color.White, fontSize = 20.sp,
                        modifier = Modifier.clickable { vibrate(); onHide() }.padding(horizontal = 16.dp))
                }
                if (dictation.on || dictation.shown.isNotEmpty()) DictationBox(dictation, onDiscard = { vibrate(); Remote.discardDictation() })
                for (row in rows.take(2)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        if (row.length < 10) Spacer(Modifier.weight(0.5f))
                        for (c in row) Key(if (shift && page == 0) c.uppercase() else c.toString(), keyHeight) { character(c.toString()) }
                        if (row.length < 10) Spacer(Modifier.weight(0.5f))
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    when (page) {
                        0 -> Key("⇧", keyHeight, weight = 1.5f, active = shift) { vibrate(); shift = !shift }
                        1 -> Key("#+=", keyHeight, weight = 1.5f) { vibrate(); page = 2 }
                        else -> Key("123", keyHeight, weight = 1.5f) { vibrate(); page = 1 }
                    }
                    for (c in rows[2]) Key(if (shift && page == 0) c.uppercase() else c.toString(), keyHeight) { character(c.toString()) }
                    RepeatingKey("⌫", keyHeight, weight = 1.5f) {
                        if (dictation.text.isNotEmpty()) { vibrate(); Remote.backspaceDictation() } else named("delete")
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Key(if (page == 0) "123" else "ABC", keyHeight, weight = 1.5f) { vibrate(); page = if (page == 0) 1 else 0 }
                    Key("🎤", keyHeight, weight = 1.2f, active = dictation.on, activeColor = DictationRed) { vibrate(); onMic() }
                    Key("space", keyHeight, weight = 4f) { if (held.isEmpty()) character(" ") else named("space") }
                    // With dictated words waiting, ↵ types them on the Mac; otherwise it's Return.
                    Key("↵", keyHeight, weight = 1.8f) {
                        if (dictation.shown.isNotEmpty()) {
                            vibrate()
                            Remote.type(Remote.takeDictation())
                        } else {
                            named("return")
                        }
                    }
                }
            }
        }
    }
}

/** A short, firm buzz for key taps; works whatever the phone's touch-feedback setting is. */
@Composable
private fun rememberKeyVibration(): () -> Unit {
    val context = LocalContext.current
    return remember {
        val vibrator = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION") context.getSystemService(Vibrator::class.java)
        }
        val effect = VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
        return@remember { vibrator?.vibrate(effect) }
    }
}

@Composable
private fun RowScope.Key(
    label: String, height: Dp, weight: Float = 1f, active: Boolean = false, activeColor: Color = HeldAccent, onTap: () -> Unit,
) {
    var lit by remember { mutableStateOf(false) }
    Box(
        Modifier
            .weight(weight)
            .height(height)
            .clip(RoundedCornerShape(7.dp))
            .background(
                when {
                    lit -> Color.White.copy(alpha = 0.55f)
                    active -> activeColor.copy(alpha = 0.85f)
                    else -> Color.Black.copy(alpha = 0.5f)
                },
            )
            .border(1.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(7.dp))
            .pointerInput(onTap) {
                detectTapGestures(
                    onPress = {
                        lit = true
                        val pressedAt = SystemClock.uptimeMillis()
                        tryAwaitRelease()
                        delay((120 - (SystemClock.uptimeMillis() - pressedAt)).coerceAtLeast(0))   // a flash you can see
                        lit = false
                    },
                    onTap = { onTap() },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = if (active) Background else Color.White, fontSize = if (label.length > 1) 13.sp else 18.sp, maxLines = 1)
    }
}

/** Fires on touch, then again and again while held (for ⌫). */
@Composable
private fun RowScope.RepeatingKey(label: String, height: Dp, weight: Float, onPress: () -> Unit) {
    val scope = rememberCoroutineScope()
    val press by rememberUpdatedState(onPress)
    Box(
        Modifier
            .weight(weight)
            .height(height)
            .clip(RoundedCornerShape(7.dp))
            .background(Color.Black.copy(alpha = 0.5f))
            .border(1.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(7.dp))
            .pointerInput(Unit) {
                detectTapGestures(onPress = {
                    press()
                    val repeat = scope.launch {
                        delay(400)
                        while (true) {
                            press()
                            delay(60)
                        }
                    }
                    tryAwaitRelease()
                    repeat.cancel()
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Color.White, fontSize = 18.sp)
    }
}

/**
 * A small copy of the live picture for the keyboard's blurred background, refreshed as frames
 * arrive (at most 20 times a second) and only while the keyboard wants it. Main thread.
 */
internal object PictureCopy {
    var view: TextureView? = null
    var wanted = false
        set(value) {
            field = value
            if (value) update(force = true)
        }
    private val _image = MutableStateFlow<ImageBitmap?>(null)
    val image: StateFlow<ImageBitmap?> = _image.asStateFlow()
    private val bitmaps = arrayOfNulls<Bitmap>(2)   // drawn from one while the other is filled
    private var next = 0
    private var lastAt = 0L

    fun update(force: Boolean = false) {
        val view = view?.takeIf { wanted && it.isAvailable && it.width > 0 && it.height > 0 } ?: return
        val now = SystemClock.uptimeMillis()
        if (!force && now - lastAt < 50) return
        lastAt = now
        val width = (view.width / 8).coerceAtLeast(1)
        val height = (view.height / 8).coerceAtLeast(1)
        val bitmap = bitmaps[next]?.takeIf { it.width == width && it.height == height }
            ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { bitmaps[next] = it }
        view.getBitmap(bitmap)
        next = 1 - next
        _image.value = bitmap.asImageBitmap()
    }
}

private val DictationRed = Color(0xFFFF6B6B)

/**
 * Dictated words, held here until ↵ types them on the Mac (so they can't land in the wrong place
 * while you talk): recognised words in white, words still being worked out in grey.
 */
@Composable
private fun DictationBox(dictation: Remote.Dictation, onDiscard: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(10.dp)).padding(start = 12.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).background(if (dictation.on) DictationRed else Muted, CircleShape))
        val words = buildAnnotatedString {
            append(dictation.text)
            if (dictation.live.isNotEmpty()) {
                if (dictation.text.isNotEmpty()) append(" ")
                withStyle(SpanStyle(color = Muted)) { append(dictation.live) }
            }
        }
        Text(
            if (words.isEmpty()) AnnotatedString(if (dictation.on) "Listening… ↵ types it on the Mac" else "") else words,
            color = if (words.isEmpty()) Muted else Color.White, fontSize = 15.sp, lineHeight = 20.sp, maxLines = 3,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).padding(start = 8.dp),
        )
        if (dictation.shown.isNotEmpty()) {
            Text("✕", color = Color.White.copy(alpha = 0.8f), fontSize = 16.sp,
                modifier = Modifier.clickable(onClickLabel = "Discard", onClick = onDiscard).padding(horizontal = 14.dp))
        }
    }
}

/** A shortcut the way the Mac writes it: ⌃⌥⇧⌘ in that order, then the key (letters as capitals). */
private fun shortcut(modifiers: Collection<String>, key: String): String =
    listOf("control" to "⌃", "option" to "⌥", "shift" to "⇧", "cmd" to "⌘")
        .filter { it.first in modifiers }.joinToString("") { it.second } + key.uppercase()

/**
 * The middle of the fingers on screen now, and how spread out they are. Compose's own
 * calculateCentroid leaves out a finger in the instant it lands, which made every two-finger tap
 * look like a pinch.
 */
private fun fingersCentre(event: PointerEvent): Offset {
    val down = event.changes.filter { it.pressed }
    if (down.isEmpty()) return Offset.Zero
    return down.fold(Offset.Zero) { sum, change -> sum + change.position } / down.size.toFloat()
}

private fun fingersSpread(event: PointerEvent): Float {
    val down = event.changes.filter { it.pressed }
    if (down.size < 2) return 0f
    val centre = fingersCentre(event)
    return down.sumOf { (it.position - centre).getDistance().toDouble() }.toFloat() / down.size
}

/**
 * The Mac's screen, live, as large as it fits: the video decoder draws on this TextureView. Until
 * the first picture of [screen] arrives it shows "Waiting for the picture…" instead.
 */
@Composable
internal fun ScreenPicture(screen: Remote.Screen?, modifier: Modifier, onBounds: (Rect) -> Unit) {
    val ready by Remote.ready.collectAsStateWithLifecycle()
    val problem by Remote.problem.collectAsStateWithLifecycle()
    var last by remember { mutableStateOf(screen) }
    if (screen != null) last = screen
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val fitted = last?.let {
            val ratio = it.width.toFloat() / it.height.coerceAtLeast(1)
            Modifier.aspectRatio(ratio, matchHeightConstraintsFirst = ratio < maxWidth / maxHeight)
        } ?: Modifier.fillMaxSize()
        AndroidView(
            factory = { context -> TextureView(context).apply { surfaceTextureListener = ScreenTexture; PictureCopy.view = this } },
            update = { it.alpha = if (screen != null && ready) 1f else 0f },   // hides an old picture too
            modifier = fitted.onGloballyPositioned { onBounds(it.boundsInRoot()) },
        )
        if (screen != null && !ready) {
            Box(fitted.border(2.dp, Accent).background(Accent.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) {
                Text(problem ?: "Waiting for the picture…", color = if (problem != null) LockedAccent else Muted,
                    fontSize = 13.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(24.dp))
            }
        }
    }
}

/** Hands the screen view's texture to the decoder, which releases it when done. */
private object ScreenTexture : TextureView.SurfaceTextureListener {
    override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) = Remote.setTexture(texture)
    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
        Remote.setTexture(null)
        return false
    }
    override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) {}
    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = PictureCopy.update()
}
