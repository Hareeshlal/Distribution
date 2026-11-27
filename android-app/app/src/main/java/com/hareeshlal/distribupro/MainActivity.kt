package com.hareeshlal.distribupro

import android.app.Activity
import android.os.Bundle
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebChromeClient
import android.content.Intent
import android.net.Uri
import android.graphics.Color
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.webkit.CookieManager

class MainActivity : Activity() {
    private lateinit var webView: WebView
    private val homeUrl = "https://hareeshlal.github.io/Distribution/"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.rgb(17, 29, 53)
        window.navigationBarColor = Color.rgb(17, 29, 53)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)

        webView = WebView(this)
        webView.setBackgroundColor(Color.rgb(244, 246, 250))
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.databaseEnabled = true
        webView.settings.javaScriptCanOpenWindowsAutomatically = false
        webView.settings.setSupportMultipleWindows(false)
        webView.settings.allowFileAccess = false
        webView.settings.allowContentAccess = false
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false)

        webView.webChromeClient = WebChromeClient()
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val uri = request?.url ?: return false
                if (uri.scheme == "https" && uri.host == "hareeshlal.github.io") return false
                if (uri.scheme == "https" || uri.scheme == "mailto" || uri.scheme == "tel") {
                    startActivity(Intent(Intent.ACTION_VIEW, uri))
                    return true
                }
                return true
            }
        }
        setContentView(webView)
        if (savedInstanceState == null) webView.loadUrl(homeUrl)
        else webView.restoreState(savedInstanceState)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        webView.saveState(outState)
        super.onSaveInstanceState(outState)
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (webView.canGoBack()) webView.goBack() else super.onBackPressed()
    }

    override fun onDestroy() {
        webView.destroy()
        super.onDestroy()
    }
}
