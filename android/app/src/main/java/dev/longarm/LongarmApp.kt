package dev.longarm

import android.app.Application

class LongarmApp : Application() {
    override fun onCreate() {
        super.onCreate()
        MacLink.init(this)
        Remote.init(this)
    }
}
