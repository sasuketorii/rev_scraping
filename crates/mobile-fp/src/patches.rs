// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! JavaScript patch generators for browser stealth.
//!
//! Each function returns a self-contained IIFE string that, when injected
//! into a Chromium page via CDP `Page.addScriptToEvaluateOnNewDocument`,
//! masks one specific bot-detection signal.
//!
//! Ports of the upstream patches at
//! `contact_dev/contact_sender_v2/sidecar/src/captcha-pro/stealth/patches/*.ts`
//! with two notable adjustments:
//!
//! 1. JS string literals are produced via `serde_json::to_string` to avoid
//!    quoting bugs when fingerprint data contains apostrophes or unicode.
//! 2. The patches consume the [`Fingerprint`] struct from this crate so a
//!    single source of truth drives both UA / sec-ch-ua headers and the
//!    JS-level overrides.
//!
//! Patches are independently testable (unit tests assert the emitted JS
//! contains the expected literal substrings); end-to-end verification on a
//! live Chromium page is exercised by integration tests in `stealth-core`.

use crate::Fingerprint;

/// `navigator.webdriver` spoof. Returns `false` from the prototype getter
/// and removes the inherited `webdriver` data property if present.
pub fn webdriver_patch() -> &'static str {
    r#"(() => {
  try {
    const proto = Object.getPrototypeOf(navigator);
    if (proto && Object.getOwnPropertyDescriptor(proto, 'webdriver')) {
      delete proto.webdriver;
    }
    Object.defineProperty(Navigator.prototype, 'webdriver', {
      get: () => false,
      set: () => undefined,
      configurable: true,
      enumerable: true,
    });
  } catch (_e) {}
})();"#
}

/// `window.chrome.runtime` / `loadTimes` / `csi` / `app` stubs. Headless
/// Chromium ships with `window.chrome` either missing or partial; this
/// patch installs a Chrome-shaped surface without breaking grecaptcha
/// (it does not touch `window.grecaptcha`).
pub fn chrome_runtime_patch() -> &'static str {
    r#"(() => {
  try {
    const w = window;
    if (!w.chrome) {
      Object.defineProperty(w, 'chrome', { value: {}, configurable: true, writable: true, enumerable: true });
    }
    const c = w.chrome;
    if (!c.runtime) {
      c.runtime = {
        OnInstalledReason: { CHROME_UPDATE: 'chrome_update', INSTALL: 'install', SHARED_MODULE_UPDATE: 'shared_module_update', UPDATE: 'update' },
        OnRestartRequiredReason: { APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic' },
        PlatformArch: { ARM: 'arm', ARM64: 'arm64', MIPS: 'mips', MIPS64: 'mips64', X86_32: 'x86-32', X86_64: 'x86-64' },
        PlatformOs:   { ANDROID: 'android', CROS: 'cros', LINUX: 'linux', MAC: 'mac', OPENBSD: 'openbsd', WIN: 'win' },
        RequestUpdateCheckStatus: { NO_UPDATE: 'no_update', THROTTLED: 'throttled', UPDATE_AVAILABLE: 'update_available' },
        connect: () => undefined,
        sendMessage: () => undefined,
        id: undefined,
      };
    }
    if (typeof c.loadTimes !== 'function') {
      c.loadTimes = function () {
        const t = performance.timing || {};
        return {
          requestTime: (t.navigationStart || Date.now()) / 1000,
          startLoadTime: (t.navigationStart || Date.now()) / 1000,
          commitLoadTime: (t.responseStart || Date.now()) / 1000,
          finishDocumentLoadTime: (t.domContentLoadedEventEnd || Date.now()) / 1000,
          finishLoadTime: (t.loadEventEnd || Date.now()) / 1000,
          firstPaintTime: (t.responseStart || Date.now()) / 1000,
          firstPaintAfterLoadTime: 0,
          navigationType: 'Other',
          wasFetchedViaSpdy: true,
          wasNpnNegotiated: true,
          npnNegotiatedProtocol: 'h2',
          wasAlternateProtocolAvailable: false,
          connectionInfo: 'h2',
        };
      };
    }
    if (typeof c.csi !== 'function') {
      c.csi = function () {
        return { startE: Date.now(), onloadT: Date.now(), pageT: Date.now(), tran: 15 };
      };
    }
    if (!c.app) {
      c.app = {
        InstallState: { DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed' },
        RunningState: { CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running' },
        getDetails: () => null,
        getIsInstalled: () => false,
        isInstalled: false,
      };
    }
  } catch (_e) {}
})();"#
}

/// `navigator.plugins` / `navigator.mimeTypes` mock. Headless Chrome
/// ships with an empty `plugins` array; this patch installs the
/// canonical PDF-Viewer plugin set that real Chrome 130+ exposes.
pub fn plugins_patch() -> &'static str {
    r#"(() => {
  try {
    const fakeMime = (name, type, suffixes, desc) => {
      const m = Object.create(MimeType.prototype);
      Object.defineProperties(m, {
        type:        { value: type,    enumerable: true },
        suffixes:    { value: suffixes,enumerable: true },
        description: { value: desc,    enumerable: true },
        enabledPlugin: { value: null,  enumerable: true, writable: true },
      });
      return m;
    };
    const fakePlugin = (name, filename, description, mimes) => {
      const p = Object.create(Plugin.prototype);
      Object.defineProperties(p, {
        name:        { value: name,        enumerable: true },
        filename:    { value: filename,    enumerable: true },
        description: { value: description, enumerable: true },
        length:      { value: mimes.length, enumerable: true },
      });
      mimes.forEach((m, i) => {
        Object.defineProperty(p, i, { value: m, enumerable: true });
        Object.defineProperty(p, m.type, { value: m });
        m.enabledPlugin = p;
      });
      p.item = (i) => p[i];
      p.namedItem = (n) => p[n];
      return p;
    };

    const mimes = [
      fakeMime('Portable Document Format', 'application/pdf', 'pdf', 'Portable Document Format'),
      fakeMime('Portable Document Format', 'text/pdf', 'pdf', 'Portable Document Format'),
    ];
    const plugins = [
      fakePlugin('PDF Viewer',                'internal-pdf-viewer','Portable Document Format', mimes),
      fakePlugin('Chrome PDF Viewer',         'internal-pdf-viewer','Portable Document Format', mimes),
      fakePlugin('Chromium PDF Viewer',       'internal-pdf-viewer','Portable Document Format', mimes),
      fakePlugin('Microsoft Edge PDF Viewer', 'internal-pdf-viewer','Portable Document Format', mimes),
      fakePlugin('WebKit built-in PDF',       'internal-pdf-viewer','Portable Document Format', mimes),
    ];

    const pluginArray = Object.create(PluginArray.prototype);
    plugins.forEach((p, i) => {
      Object.defineProperty(pluginArray, i, { value: p, enumerable: true });
      Object.defineProperty(pluginArray, p.name, { value: p });
    });
    Object.defineProperty(pluginArray, 'length', { value: plugins.length });
    pluginArray.item = (i) => pluginArray[i] || null;
    pluginArray.namedItem = (n) => pluginArray[n] || null;
    pluginArray.refresh = () => undefined;

    const mimeArray = Object.create(MimeTypeArray.prototype);
    mimes.forEach((m, i) => {
      Object.defineProperty(mimeArray, i, { value: m, enumerable: true });
      Object.defineProperty(mimeArray, m.type, { value: m });
    });
    Object.defineProperty(mimeArray, 'length', { value: mimes.length });
    mimeArray.item = (i) => mimeArray[i] || null;
    mimeArray.namedItem = (n) => mimeArray[n] || null;

    Object.defineProperty(Navigator.prototype, 'plugins',   { get: () => pluginArray, configurable: true });
    Object.defineProperty(Navigator.prototype, 'mimeTypes', { get: () => mimeArray,   configurable: true });
  } catch (_e) {}
})();"#
}

/// WebGL `UNMASKED_VENDOR_WEBGL` / `UNMASKED_RENDERER_WEBGL` spoof.
/// Without this, headless Chrome reports SwiftShader / Mesa, an
/// instant bot signal.
pub fn webgl_patch(vendor: &str, renderer: &str) -> String {
    let vendor_json = serde_json::to_string(vendor).expect("vendor is valid utf8");
    let renderer_json = serde_json::to_string(renderer).expect("renderer is valid utf8");
    format!(
        "(() => {{
  try {{
    const VENDOR = {vendor_json};
    const RENDERER = {renderer_json};
    const UNMASKED_VENDOR = 0x9245;
    const UNMASKED_RENDERER = 0x9246;
    const wrap = (proto) => {{
      const orig = proto.getParameter;
      proto.getParameter = function (param) {{
        if (param === UNMASKED_VENDOR) return VENDOR;
        if (param === UNMASKED_RENDERER) return RENDERER;
        if (param === 0x1F00) return 'WebKit';
        if (param === 0x1F01) return 'WebKit WebGL';
        return orig.call(this, param);
      }};
    }};
    if (typeof WebGLRenderingContext !== 'undefined') wrap(WebGLRenderingContext.prototype);
    if (typeof WebGL2RenderingContext !== 'undefined') wrap(WebGL2RenderingContext.prototype);
  }} catch (_e) {{}}
}})();"
    )
}

/// `navigator.language` / `navigator.languages` spoof. `navigator.languages`
/// is a frozen copy of the slice so the page cannot mutate the value
/// across re-reads — matching real-Chrome behaviour.
pub fn languages_patch(language: &str, languages: &[String]) -> String {
    let lang_json = serde_json::to_string(language).expect("language is utf8");
    let langs_json = serde_json::to_string(languages).expect("languages is utf8");
    format!(
        "(() => {{
  try {{
    Object.defineProperty(Navigator.prototype, 'language', {{
      get: () => {lang_json},
      configurable: true,
    }});
    Object.defineProperty(Navigator.prototype, 'languages', {{
      get: () => Object.freeze({langs_json}.slice()),
      configurable: true,
    }});
  }} catch (_e) {{}}
}})();"
    )
}

/// `navigator.platform`, `hardwareConcurrency`, `deviceMemory`,
/// `maxTouchPoints` spoof. These four travel together because every
/// Chromium-based bot detection cross-checks them against the UA.
pub fn navigator_basics_patch(fp: &Fingerprint) -> String {
    let platform = serde_json::to_string(&fp.platform).expect("platform utf8");
    let hc = fp.hardware_concurrency;
    let dm = fp.device_memory;
    let touch = fp.max_touch_points;
    format!(
        "(() => {{
  try {{
    Object.defineProperty(Navigator.prototype, 'platform',            {{ get: () => {platform}, configurable: true }});
    Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', {{ get: () => {hc},        configurable: true }});
    Object.defineProperty(Navigator.prototype, 'deviceMemory',        {{ get: () => {dm},        configurable: true }});
    Object.defineProperty(Navigator.prototype, 'maxTouchPoints',      {{ get: () => {touch},     configurable: true }});
  }} catch (_e) {{}}
}})();"
    )
}

/// `navigator.connection` spoof (`effectiveType`, `downlink`, `rtt`,
/// `saveData`). Mobile fingerprints almost always need this — desktops
/// frequently report `wifi` whereas mobile reports `4g`.
pub fn connection_patch(fp: &Fingerprint) -> String {
    let eff = match fp.connection.effective_type {
        crate::EffectiveType::Slow2g => "slow-2g",
        crate::EffectiveType::TwoG => "2g",
        crate::EffectiveType::ThreeG => "3g",
        crate::EffectiveType::FourG => "4g",
        crate::EffectiveType::FiveG => "5g",
    };
    let downlink = fp.connection.downlink;
    let rtt = fp.connection.rtt;
    let save_data = fp.connection.save_data;
    format!(
        r#"(() => {{
  try {{
    const conn = {{
      effectiveType: "{eff}",
      downlink: {downlink},
      rtt: {rtt},
      saveData: {save_data},
      type: "cellular",
      onchange: null,
      addEventListener: () => undefined,
      removeEventListener: () => undefined,
      dispatchEvent: () => false,
    }};
    Object.defineProperty(Navigator.prototype, 'connection', {{ get: () => conn, configurable: true }});
  }} catch (_e) {{}}
}})();"#
    )
}

/// `screen.{{width,height,availWidth,availHeight,colorDepth,pixelDepth}}`
/// override. Without this the screen dimensions reflect the host machine,
/// not the spoofed mobile device.
pub fn screen_patch(fp: &Fingerprint) -> String {
    let w = fp.screen.width;
    let h = fp.screen.height;
    format!(
        "(() => {{
  try {{
    const screenProto = Object.getPrototypeOf(screen);
    const def = (k, v) => Object.defineProperty(screenProto, k, {{ get: () => v, configurable: true }});
    def('width',       {w});
    def('height',      {h});
    def('availWidth',  {w});
    def('availHeight', {h});
    def('colorDepth',  24);
    def('pixelDepth',  24);
  }} catch (_e) {{}}
}})();"
    )
}

/// Aggregate every fingerprint-derived patch into a single bootstrap
/// script. Order matters: `webdriver` first (so subsequent patches
/// inheriting from `Navigator.prototype` see the cleaned slate), then
/// the static patches, then the fingerprint-derived overrides.
pub fn full_bootstrap(fp: &Fingerprint) -> String {
    let mut out = String::with_capacity(8192);
    out.push_str(webdriver_patch());
    out.push('\n');
    out.push_str(chrome_runtime_patch());
    out.push('\n');
    out.push_str(plugins_patch());
    out.push('\n');
    out.push_str(&webgl_patch(&fp.webgl_vendor, &fp.webgl_renderer));
    out.push('\n');
    out.push_str(&languages_patch(&fp.language, &fp.languages));
    out.push('\n');
    out.push_str(&navigator_basics_patch(fp));
    out.push('\n');
    out.push_str(&connection_patch(fp));
    out.push('\n');
    out.push_str(&screen_patch(fp));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{iphone_15_pro, pixel_9_pro};

    #[test]
    fn webdriver_patch_returns_false() {
        let js = webdriver_patch();
        assert!(js.contains("get: () => false"));
        assert!(js.contains("Navigator.prototype"));
        // No syntax errors via balanced braces / parens (sanity check).
        assert_eq!(js.matches('{').count(), js.matches('}').count());
    }

    #[test]
    fn chrome_runtime_patch_installs_runtime_loadtimes_csi_app() {
        let js = chrome_runtime_patch();
        assert!(js.contains("c.runtime ="));
        assert!(js.contains("c.loadTimes"));
        assert!(js.contains("c.csi"));
        assert!(js.contains("c.app"));
    }

    #[test]
    fn plugins_patch_lists_five_pdf_viewers() {
        let js = plugins_patch();
        assert!(js.contains("PDF Viewer"));
        assert!(js.contains("Chrome PDF Viewer"));
        assert!(js.contains("Chromium PDF Viewer"));
        assert!(js.contains("Microsoft Edge PDF Viewer"));
        assert!(js.contains("WebKit built-in PDF"));
    }

    #[test]
    fn webgl_patch_embeds_vendor_and_renderer_safely() {
        let js = webgl_patch("Apple Inc.", "Apple GPU");
        assert!(js.contains(r#"const VENDOR = "Apple Inc.""#));
        assert!(js.contains(r#"const RENDERER = "Apple GPU""#));
        // Quote escaping path (defensive — fingerprint data could in
        // theory contain quotes / unicode).
        let with_quote = webgl_patch("Acme \"Inc\"", "GPU\\Renderer");
        assert!(
            with_quote.contains(r#"const VENDOR = "Acme \"Inc\"""#),
            "vendor with quotes must be JSON-escaped: {with_quote}"
        );
    }

    #[test]
    fn languages_patch_freezes_array() {
        let js = languages_patch("ja-JP", &["ja-JP".into(), "ja".into(), "en".into()]);
        assert!(js.contains(r#"get: () => "ja-JP""#));
        assert!(js.contains(r#"["ja-JP","ja","en"]"#));
        assert!(js.contains("Object.freeze"));
    }

    #[test]
    fn navigator_basics_patch_uses_fingerprint_values() {
        let fp = pixel_9_pro();
        let js = navigator_basics_patch(&fp);
        assert!(js.contains(r#"get: () => "Linux armv8l""#));
        assert!(js.contains("get: () => 8")); // hardwareConcurrency / deviceMemory
        assert!(js.contains("get: () => 5")); // maxTouchPoints
    }

    #[test]
    fn connection_patch_emits_4g_for_mobile() {
        let fp = iphone_15_pro();
        let js = connection_patch(&fp);
        assert!(js.contains("effectiveType: \"4g\""));
        assert!(js.contains("rtt: 50"));
        assert!(js.contains("saveData: false"));
        assert!(js.contains("downlink: 10"));
    }

    #[test]
    fn screen_patch_uses_fingerprint_dimensions() {
        let fp = iphone_15_pro();
        let js = screen_patch(&fp);
        assert!(js.contains("def('width',       393)"));
        assert!(js.contains("def('height',      852)"));
    }

    #[test]
    fn full_bootstrap_concatenates_every_patch_in_order() {
        let fp = iphone_15_pro();
        let js = full_bootstrap(&fp);
        // Order check: webdriver must precede chrome.runtime patch.
        let webdriver_idx = js.find("Navigator.prototype, 'webdriver'").unwrap();
        let runtime_idx = js.find("c.runtime =").unwrap();
        let plugins_idx = js.find("PluginArray").unwrap();
        let webgl_idx = js.find("UNMASKED_VENDOR").unwrap();
        let conn_idx = js.find("effectiveType:").unwrap();
        let screen_idx = js.find("def('width',").unwrap();
        assert!(webdriver_idx < runtime_idx);
        assert!(runtime_idx < plugins_idx);
        assert!(plugins_idx < webgl_idx);
        assert!(webgl_idx < conn_idx);
        assert!(conn_idx < screen_idx);
        // Fingerprint values are present.
        assert!(js.contains("Apple GPU"));
        assert!(js.contains("ja-JP"));
        assert!(js.contains("393"));
    }

    #[test]
    fn full_bootstrap_balanced_braces() {
        let fp = iphone_15_pro();
        let js = full_bootstrap(&fp);
        assert_eq!(
            js.matches('{').count(),
            js.matches('}').count(),
            "unbalanced braces in bootstrap"
        );
        assert_eq!(
            js.matches('(').count(),
            js.matches(')').count(),
            "unbalanced parens in bootstrap"
        );
    }
}
