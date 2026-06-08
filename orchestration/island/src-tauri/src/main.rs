// Fiction Island — the Mac cockpit. Renders the SANITIZED /live/events feed from
// host-mcp (frontend), fires native notifications on run transitions, and exposes
// operator ops (Tailscale, OpenClaw, fiction-doctor, host-mcp restart) as commands.
//
// It MONITORS host-mcp; it does not replace it. host-mcp stays the headless Go
// trust boundary. No instruction/target text ever reaches here — the events feed
// it consumes is firewall-sanitized at the source.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use std::process::Command;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager,
};
use tauri_plugin_notification::NotificationExt;

const REPO: &str = "/Users/ethan/fiction";
const HOSTMCP_LABEL: &str = "ai.openclaw.fiction-host-mcp";

// A Finder-launched .app inherits a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
// so homebrew/local tools (tailscale) and the doctor script's own probes can't be
// found. Prepend the usual install dirs for every shell-out.
const RICH_PATH: &str = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";

#[derive(Serialize)]
struct CmdOut {
    code: i32,
    stdout: String,
    stderr: String,
}

fn run(program: &str, args: &[&str], cwd: Option<&str>) -> CmdOut {
    let mut c = Command::new(program);
    c.args(args).env("PATH", RICH_PATH);
    if let Some(d) = cwd {
        c.current_dir(d);
    }
    match c.output() {
        Ok(o) => CmdOut {
            code: o.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&o.stdout).to_string(),
            stderr: String::from_utf8_lossy(&o.stderr).to_string(),
        },
        Err(e) => CmdOut {
            code: -1,
            stdout: String::new(),
            stderr: e.to_string(),
        },
    }
}

// run, but with a hard wall-clock timeout (S24 #4-I2). The blocking run() executes
// in a helper thread; if it doesn't finish in `secs`, we return a clean "timed out"
// result so the cockpit button never sticks forever (e.g. `tailscale up` blocking on
// interactive auth). The orphaned child is left to finish on its own — the point is
// to give the UI back control, not to guarantee a kill.
fn run_timed(program: String, args: Vec<String>, cwd: Option<String>, secs: u64) -> CmdOut {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let argref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let _ = tx.send(run(&program, &argref, cwd.as_deref()));
    });
    match rx.recv_timeout(Duration::from_secs(secs)) {
        Ok(o) => o,
        Err(_) => CmdOut {
            code: -1,
            stdout: String::new(),
            stderr: format!("timed out after {secs}s (still running in the background)"),
        },
    }
}

// Resolve the tailscale binary across the common macOS install locations.
fn tailscale_bin() -> String {
    for p in [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ] {
        if std::path::Path::new(p).exists() {
            return p.to_string();
        }
    }
    "tailscale".to_string()
}

#[tauri::command]
fn tailscale_status() -> serde_json::Value {
    let out = run_timed(tailscale_bin(), vec!["ip".into(), "-4".into()], None, 8);
    let ip = out.stdout.lines().next().unwrap_or("").trim().to_string();
    serde_json::json!({ "up": !ip.is_empty(), "ip": ip, "err": out.stderr.trim() })
}

#[tauri::command]
fn tailscale_up() -> CmdOut {
    // `tailscale up` blocks on interactive auth when login is needed — cap it so the
    // button returns; the message tells the operator to finish login in a terminal.
    run_timed(tailscale_bin(), vec!["up".into()], None, 20)
}

#[tauri::command]
fn open_url(url: String) -> CmdOut {
    run("/usr/bin/open", &[&url], None)
}

#[tauri::command]
fn run_doctor() -> CmdOut {
    run_timed(format!("{REPO}/bin/fiction-doctor"), vec![], Some(REPO.into()), 60)
}

#[tauri::command]
fn hostmcp_restart() -> CmdOut {
    let uid = run("/usr/bin/id", &["-u"], None).stdout.trim().to_string();
    run_timed(
        "/bin/launchctl".into(),
        vec![
            "kickstart".into(),
            "-k".into(),
            format!("gui/{uid}/{HOSTMCP_LABEL}"),
        ],
        None,
        15,
    )
}

// notify is the SINGLE notification entry point. The frontend passes only
// sanitized fields (play, state, lane count, artifact rel path) — never an
// instruction or target — so banners are firewall-safe by construction.
#[tauri::command]
fn notify(app: AppHandle, title: String, body: String) -> Result<(), String> {
    app.notification()
        .builder()
        .title(title)
        .body(body)
        .show()
        .map_err(|e| e.to_string())
}

fn toggle_window(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        match win.is_visible() {
            Ok(true) => {
                let _ = win.hide();
            }
            _ => {
                let _ = win.show();
                let _ = win.set_focus();
            }
        }
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .invoke_handler(tauri::generate_handler![
            notify,
            tailscale_status,
            tailscale_up,
            open_url,
            run_doctor,
            hostmcp_restart
        ])
        .setup(|app| {
            // macOS shows the permission prompt on first request.
            let _ = app.notification().request_permission();

            // Island polish (S25): float over EVERY Space/app (so it sits above Chrome/
            // OpenClaw no matter which Space is focused) and park it top-right with a
            // small inset so it stays out of the way.
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.set_visible_on_all_workspaces(true);
                let _ = win.set_always_on_top(true);
                if let Ok(Some(mon)) = win.primary_monitor() {
                    let sf = mon.scale_factor();
                    let msz = mon.size().to_logical::<f64>(sf);
                    let x = (msz.width - 360.0 - 12.0).max(0.0);
                    // Pin just under the menu bar (≈24px) at top-right, so it reads as
                    // "dropped from the top". Draggable afterward if the operator wants.
                    let _ = win.set_position(tauri::LogicalPosition::new(x, 24.0));
                }

                #[cfg(target_os = "macos")]
                {
                    // Native frosted glass (real vibrancy, stronger than CSS blur) with a
                    // rounded backing — the radius also clips the window to rounded corners,
                    // killing the square-backdrop bug at the native layer. FollowsWindowActiveState
                    // dims the material when unfocused (extra distraction reduction).
                    use window_vibrancy::{
                        apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState,
                    };
                    if let Err(e) = apply_vibrancy(
                        &win,
                        NSVisualEffectMaterial::HudWindow,
                        Some(NSVisualEffectState::FollowsWindowActiveState),
                        Some(15.0),
                    ) {
                        eprintln!("[island] vibrancy failed: {e:?}");
                    }
                    if let Ok(ptr) = win.ns_window() {
                        use objc2::runtime::AnyObject;
                        let nsw = ptr as *mut AnyObject;
                        unsafe {
                            // Float over FULLSCREEN apps + every Space.
                            let cur: u64 = objc2::msg_send![nsw, collectionBehavior];
                            // canJoinAllSpaces(1) | stationary(1<<4) | fullScreenAuxiliary(1<<8)
                            let beh = cur | 1u64 | (1u64 << 4) | (1u64 << 8);
                            let _: () = objc2::msg_send![nsw, setCollectionBehavior: beh];

                            // Kill the SQUARE backdrop for good: force true transparency, no
                            // native shadow, and clip the window's CONTENT LAYER to a rounded
                            // rect — that rounds the vibrancy material AND the webview, so the
                            // corners show the desktop, not a square halo.
                            let _: () = objc2::msg_send![nsw, setOpaque: false];
                            let _: () = objc2::msg_send![nsw, setHasShadow: false];
                            let clear: *mut AnyObject =
                                objc2::msg_send![objc2::class!(NSColor), clearColor];
                            let _: () = objc2::msg_send![nsw, setBackgroundColor: clear];
                            let content: *mut AnyObject = objc2::msg_send![nsw, contentView];
                            if !content.is_null() {
                                let _: () = objc2::msg_send![content, setWantsLayer: true];
                                let layer: *mut AnyObject = objc2::msg_send![content, layer];
                                if !layer.is_null() {
                                    let _: () = objc2::msg_send![layer, setCornerRadius: 15.0f64];
                                    let _: () = objc2::msg_send![layer, setMasksToBounds: true];
                                }
                            }
                        }
                    }
                }
            }

            // Global quick-hide/show shortcut (⌘⌥I) — toggles the panel from anywhere,
            // so it never gets stuck in the way. The menu-bar tray "Show / Hide" still works.
            #[cfg(desktop)]
            {
                use tauri_plugin_global_shortcut::{
                    Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState,
                };
                let toggle_sc = Shortcut::new(Some(Modifiers::SUPER | Modifiers::ALT), Code::KeyI);
                app.handle().plugin(
                    tauri_plugin_global_shortcut::Builder::new()
                        .with_handler(move |app, shortcut, event| {
                            if shortcut == &toggle_sc && event.state() == ShortcutState::Pressed {
                                toggle_window(app);
                            }
                        })
                        .build(),
                )?;
                app.global_shortcut().register(toggle_sc)?;
            }

            let toggle = MenuItem::with_id(app, "toggle", "Show / Hide", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&toggle, &quit])?;

            let icon = app
                .default_window_icon()
                .cloned()
                .expect("bundle icon present");
            let _tray = TrayIconBuilder::new()
                .icon(icon)
                .tooltip("Aphrodite — writers' room")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running fiction-island");
}
