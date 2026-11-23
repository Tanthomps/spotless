//! "Playing on <device>" between linked devices (Spotify's device bar), carried by device sync.
//!
//! Each device keeps one synced setting, `presence:<device id>`, holding what it is playing
//! (song, playing or paused, position and when that position was read). A remote control is a
//! setting too, `remote:<target device id>`, which the target runs once when it arrives. Both
//! ride the normal sync rounds (LAN every 3 s, relay every 5 s).
//!
//! On top of that, while the app is open, the same state and commands go over a live socket to the
//! share relay (`live`), so a play, pause or skip shows on the other device in well under a second.
//! The channel and its key come from the sync group's key, so only linked devices can read it. The
//! synced settings stay as the fallback (an iPhone in the background has no socket).
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::host::HostExt;
use crate::state::AppState;

pub const PRESENCE: &str = "presence:";
pub const REMOTE: &str = "remote:";
/// A paused device that hasn't said anything for this long isn't shown.
const FRESH_MS: i64 = 15 * 60 * 1000;
/// A playing device re-announces itself this often, so one that quit or lost its connection
/// drops off after `PLAYING_GONE_MS` instead of showing "Playing on …" for 15 minutes.
const HEARTBEAT_MS: i64 = 60 * 1000;
const PLAYING_GONE_MS: i64 = 150 * 1000;

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// What this device would publish right now, or None while nothing is loaded.
async fn snapshot(st: &Arc<AppState>) -> Option<Value> {
    let (_, source, item) = st.queue_source().await;
    let item = item?;
    if st.player.is_idle() {
        return None;
    }
    Some(json!({
        "name": crate::sync::device_name(),
        "platform": crate::sync::platform(),
        "song": { "videoId": item.video_id, "title": item.title, "artists": item.artists, "thumbnail": item.thumbnail },
        "source": source,
        "playing": !st.player.is_paused(),
        "posMs": (st.player.clock().unwrap_or(0.0) * 1000.0) as i64,
        "at": now_ms(),
    }))
}

/// True when `next` says something `prev` didn't: another song, play/pause flipped, or the
/// position moved more than 3 s from where `prev` predicts (a seek). Plain progress isn't news.
fn changed(prev: &Value, next: &Value) -> bool {
    if prev["song"]["videoId"] != next["song"]["videoId"] || prev["playing"] != next["playing"] {
        return true;
    }
    let elapsed = if prev["playing"].as_bool() == Some(true) { next["at"].as_i64().unwrap_or(0) - prev["at"].as_i64().unwrap_or(0) } else { 0 };
    let predicted = prev["posMs"].as_i64().unwrap_or(0) + elapsed;
    (next["posMs"].as_i64().unwrap_or(0) - predicted).abs() > 3000
}

/// Publishes this device's state when it changes (checked every 2 s; only while linked).
pub fn start(st: &Arc<AppState>) {
    live::start(st);
    let st = st.clone();
    crate::rt::spawn(async move {
        let mut last: Option<Value> = None;
        let mut idle_sent = false;
        loop {
            // Twice a second while the socket is up (it's what makes a pause show at once), else 2 s.
            let tick = if live::up() { 500 } else { 2000 };
            tokio::time::sleep(std::time::Duration::from_millis(tick)).await;
            let Some(engine) = crate::sync::engine() else { continue };
            if engine.group().is_none() {
                continue;
            }
            let key = format!("{PRESENCE}{}", engine.device_id());
            match snapshot(&st).await {
                Some(now) => {
                    let beat = now["playing"].as_bool() == Some(true)
                        && last.as_ref().is_some_and(|p| now["at"].as_i64().unwrap_or(0) - p["at"].as_i64().unwrap_or(0) > HEARTBEAT_MS);
                    if beat || last.as_ref().is_none_or(|p| changed(p, &now)) {
                        live::publish(&engine.device_id(), &now);
                        st.db.set_setting(&key, &now.to_string());
                        last = Some(now);
                        idle_sent = false;
                    }
                }
                None if !idle_sent && last.is_some() => {
                    let idle = json!({ "name": crate::sync::device_name(), "playing": false, "at": now_ms() });
                    live::publish(&engine.device_id(), &idle);
                    st.db.set_setting(&key, &idle.to_string());
                    last = None;
                    idle_sent = true;
                }
                None => {}
            }
        }
    });
}

/// The other linked devices with something loaded recently, freshest first.
pub fn list(st: &AppState) -> Value {
    let me = crate::sync::engine().map(|e| e.device_id()).unwrap_or_default();
    let now = now_ms();
    // Synced settings and what the socket brought, the fresher of the two per device.
    let mut by_dev: HashMap<String, Value> = st
        .db
        .all_settings()
        .into_iter()
        .filter_map(|(k, v)| Some((k.strip_prefix(PRESENCE)?.to_string(), serde_json::from_str::<Value>(&v).ok()?)))
        .collect();
    for (dev, v) in live::seen() {
        if by_dev.get(&dev).is_none_or(|old| old["at"].as_i64() < v["at"].as_i64()) {
            by_dev.insert(dev, v);
        }
    }
    let mut out: Vec<Value> = by_dev
        .into_iter()
        .filter_map(|(dev, mut p)| {
            if dev == me {
                return None;
            }
            let age = now - p["at"].as_i64().unwrap_or(0);
            if p["song"].is_null() || !shown(p["playing"].as_bool() == Some(true), age) {
                return None;
            }
            p["dev"] = json!(dev);
            Some(p)
        })
        .collect();
    out.sort_by_key(|p| -p["at"].as_i64().unwrap_or(0));
    json!(out)
}

/// Whether a device that last spoke `age_ms` ago still shows: a playing one goes quiet fast (it
/// heartbeats every minute), a paused one lingers so it can be resumed from here.
fn shown(playing: bool, age_ms: i64) -> bool {
    age_ms <= if playing { PLAYING_GONE_MS } else { FRESH_MS }
}

/// Ask `dev` to `cmd` ("play" | "pause" | "next" | "prev"). Arrives with the next sync round.
pub fn send(st: &AppState, dev: &str, cmd: &str) -> Result<(), String> {
    if !matches!(cmd, "play" | "pause" | "next" | "prev") {
        return Err(format!("unknown command {cmd}"));
    }
    let engine = crate::sync::engine().ok_or("sync is off")?;
    let id = format!("{:x}", rand::random::<u64>());
    let v = json!({ "cmd": cmd, "id": id, "from": engine.device_id(), "at": now_ms() });
    live::send(json!({ "t": "cmd", "to": dev, "c": v }));
    st.db.set_setting(&format!("{REMOTE}{dev}"), &v.to_string());
    engine.kick();
    Ok(())
}

/// Called when synced settings land: tell the UI about presence, run a command meant for us.
pub async fn applied(st: &Arc<AppState>, keys: &[String]) {
    if keys.iter().any(|k| k.starts_with(PRESENCE)) {
        let _ = st.host.emit("presence-changed", list(st));
    }
    let Some(engine) = crate::sync::engine() else { return };
    let mine = format!("{REMOTE}{}", engine.device_id());
    if !keys.contains(&mine) {
        return;
    }
    let Some(v) = st.db.get_setting(&mine).and_then(|v| serde_json::from_str::<Value>(&v).ok()) else { return };
    run(st, &v).await;
}

/// Run a remote command once (it can come by socket and again by sync), and only a recent one.
async fn run(st: &Arc<AppState>, v: &Value) {
    // Every id seen in the freshness window, not just the last: a replayed box (by sync or the
    // relay) within that minute is refused too.
    static DONE: Mutex<Option<HashMap<String, i64>>> = Mutex::new(None);
    let id = v["id"].as_str().unwrap_or_default().to_string();
    let now = now_ms();
    if id.is_empty() || (now - v["at"].as_i64().unwrap_or(0)).abs() > 60_000 {
        return;
    }
    {
        let mut done = DONE.lock().unwrap();
        let done = done.get_or_insert_with(HashMap::new);
        done.retain(|_, t| now - *t <= 120_000);
        if done.contains_key(&id) || st.db.get_setting("remote_done").as_deref() == Some(id.as_str()) {
            return;
        }
        done.insert(id.clone(), now);
    }
    st.db.set_setting("remote_done", &id);
    match v["cmd"].as_str() {
        Some("play") if st.player.is_paused() || st.player.is_idle() => st.resume_or_toggle().await,
        Some("pause") if !st.player.is_paused() => {
            let _ = st.player.pause();
        }
        Some("next") => st.next_in_queue().await,
        Some("prev") => st.prev_in_queue().await,
        _ => {}
    }
}

/// The live socket: one share-relay channel per sync group. Every message is sealed with a key
/// derived from the group key and sent as a relay "snapshot", so the relay keeps only the latest
/// one; a device that connects says `hello` and the others answer with their state.
mod live {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use sha2::{Digest, Sha256};
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::sync::mpsc;
    use tokio_tungstenite::tungstenite::Message;

    const RELAY: &str = "wss://spotless-share.tanthompsig.workers.dev";

    static UP: AtomicBool = AtomicBool::new(false);
    static OUT: Mutex<Option<mpsc::UnboundedSender<Value>>> = Mutex::new(None);
    static SEEN: Mutex<Option<HashMap<String, Value>>> = Mutex::new(None);

    pub fn up() -> bool {
        UP.load(Ordering::Relaxed)
    }

    pub fn seen() -> Vec<(String, Value)> {
        SEEN.lock().unwrap().as_ref().map(|m| m.iter().map(|(k, v)| (k.clone(), v.clone())).collect()).unwrap_or_default()
    }

    pub fn send(msg: Value) {
        if let Some(tx) = OUT.lock().unwrap().as_ref() {
            let _ = tx.send(msg);
        }
    }

    pub fn publish(dev: &str, state: &Value) {
        send(json!({ "t": "p", "dev": dev, "s": state }));
    }

    /// (channel id, box key, access token) for a group key.
    pub(super) fn channel(group_key: &[u8]) -> (String, [u8; 32], String) {
        let id = crate::sync::crypto::hex(&crate::sync::crypto::derive(group_key, "spotless presence channel")[..16]);
        let key = crate::sync::crypto::derive(group_key, "spotless presence box");
        let mut h = Sha256::new();
        h.update(key);
        h.update(b"relay");
        (id, key, crate::sync::crypto::hex(&h.finalize()))
    }

    pub fn start(st: &Arc<AppState>) {
        let st = st.clone();
        crate::rt::spawn(async move {
            let mut fails = 0u64;
            loop {
                let group = crate::sync::engine().and_then(|e| e.group().map(|g| (e.device_id(), g.key)));
                let Some((me, gkey)) = group else {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    continue;
                };
                match session(&st, &me, &gkey).await {
                    Ok(()) => fails = 0,
                    Err(e) => {
                        fails += 1;
                        tracing::debug!(error = %e, "presence socket");
                    }
                }
                UP.store(false, Ordering::Relaxed);
                *OUT.lock().unwrap() = None;
                *SEEN.lock().unwrap() = None;
                tokio::time::sleep(std::time::Duration::from_secs((2 * fails).clamp(1, 30))).await;
            }
        });
    }

    fn same_group(gkey: &[u8]) -> bool {
        crate::sync::engine().and_then(|e| e.group()).is_some_and(|g| g.key == gkey)
    }

    async fn session(st: &Arc<AppState>, me: &str, gkey: &[u8]) -> Result<(), String> {
        let (id, key, token) = channel(gkey);
        let boxkey = crate::sync::crypto::BoxKey::raw(key);
        let url = format!("{RELAY}/c/{id}/ws?token={token}");
        let (ws, _) = tokio_tungstenite::connect_async(&url).await.map_err(|e| e.to_string())?;
        // The relay wants a short lowercase sender id; the real device id rides inside the box.
        let wire = crate::sync::crypto::hex(&crate::sync::crypto::derive(me.as_bytes(), "spotless presence sender")[..8]);
        let (mut sink, mut stream) = ws.split();
        let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
        *OUT.lock().unwrap() = Some(tx.clone());
        UP.store(true, Ordering::Relaxed);
        let _ = tx.send(json!({ "t": "hello" }));
        let mut ping = tokio::time::interval(std::time::Duration::from_secs(5));
        let mut keepalive = 0u32;
        loop {
            tokio::select! {
                out = rx.recv() => {
                    let Some(m) = out else { return Ok(()) };
                    let frame = json!({ "from": wire, "box": boxkey.seal(&id, m.to_string().as_bytes()), "snap": true });
                    sink.send(Message::text(frame.to_string())).await.map_err(|e| e.to_string())?;
                }
                _ = ping.tick() => {
                    if !same_group(gkey) {
                        return Ok(()); // unlinked or re-paired: drop this channel now
                    }
                    keepalive += 1;
                    if keepalive % 4 == 0 {
                        sink.send(Message::text(r#"{"type":"ping"}"#)).await.map_err(|e| e.to_string())?;
                    }
                }
                frame = stream.next() => {
                    let Some(frame) = frame else { return Ok(()) };
                    let Message::Text(t) = frame.map_err(|e| e.to_string())? else { continue };
                    let Ok(o) = serde_json::from_str::<Value>(t.as_str()) else { continue };
                    if o["type"] != "msg" || o["from"].as_str() == Some(wire.as_str()) {
                        continue;
                    }
                    let Some(plain) = o["box"].as_str().and_then(|b| boxkey.open(&id, b)) else { continue };
                    let Ok(m) = serde_json::from_slice::<Value>(&plain) else { continue };
                    if !same_group(gkey) {
                        return Ok(());
                    }
                    handle(st, me, &m, &tx).await;
                }
            }
        }
    }

    async fn handle(st: &Arc<AppState>, me: &str, m: &Value, tx: &mpsc::UnboundedSender<Value>) {
        match m["t"].as_str() {
            Some("hello") => {
                if let Some(now) = snapshot(st).await {
                    let _ = tx.send(json!({ "t": "p", "dev": me, "s": now }));
                }
            }
            Some("p") => {
                let (Some(dev), s) = (m["dev"].as_str(), &m["s"]) else { return };
                if dev == me || !s.is_object() {
                    return;
                }
                SEEN.lock().unwrap().get_or_insert_with(HashMap::new).insert(dev.to_string(), s.clone());
                let _ = st.host.emit("presence-changed", list(st));
            }
            Some("cmd") if m["to"].as_str() == Some(me) => run(st, &m["c"]).await,
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(id: &str, playing: bool, pos: i64, at: i64) -> Value {
        json!({ "song": { "videoId": id }, "playing": playing, "posMs": pos, "at": at })
    }

    /// Live: two sockets on the real relay, one seals a message, the other opens it.
    #[tokio::test]
    #[ignore]
    async fn live_relay_round_trip() {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::Message;
        let gkey: [u8; 32] = rand::random();
        let (id, key, token) = live::channel(&gkey);
        let bk = crate::sync::crypto::BoxKey::raw(key);
        let url = format!("wss://spotless-share.tanthompsig.workers.dev/c/{id}/ws?token={token}");
        let to = std::time::Duration::from_secs(10);
        let (mut a, _) = tokio::time::timeout(to, tokio_tungstenite::connect_async(&url)).await.expect("connect A timed out").unwrap();
        println!("A connected");
        let (mut b, _) = tokio::time::timeout(to, tokio_tungstenite::connect_async(&url)).await.expect("connect B timed out").unwrap();
        println!("B connected");
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let t0 = std::time::Instant::now();
        let frame = json!({ "from": "test-device-a", "box": bk.seal(&id, br#"{"t":"hello"}"#), "snap": true });
        a.send(Message::text(frame.to_string())).await.unwrap();
        loop {
            let f = tokio::time::timeout(to, b.next()).await.expect("B got nothing").unwrap().unwrap();
            println!("B frame: {f:?}");
            let Message::Text(t) = f else { continue };
            let o: Value = serde_json::from_str(t.as_str()).unwrap();
            if o["type"] != "msg" { continue }
            let plain = bk.open(&id, o["box"].as_str().unwrap()).unwrap();
            assert_eq!(plain, br#"{"t":"hello"}"#);
            println!("delivered in {:?}", t0.elapsed());
            break;
        }
    }

    #[test]
    fn the_live_channel_is_the_same_for_every_device_in_a_group_and_only_theirs() {
        let (id, key, token) = live::channel(b"group key one");
        assert_eq!(live::channel(b"group key one"), (id.clone(), key, token.clone()));
        assert_eq!(id.len(), 32);
        assert_eq!(token.len(), 64);
        assert_ne!(live::channel(b"group key two").0, id);
    }

    #[test]
    fn a_silent_playing_device_drops_off_fast_a_paused_one_lingers() {
        assert!(shown(true, 60_000));
        assert!(!shown(true, 200_000), "quit while playing: gone in 2.5 min");
        assert!(shown(false, 10 * 60_000), "paused: still there to resume");
        assert!(!shown(false, 20 * 60_000));
    }

    #[test]
    fn progress_is_not_news_but_a_seek_or_a_new_song_is() {
        let a = p("x", true, 10_000, 0);
        assert!(!changed(&a, &p("x", true, 12_000, 2_000)), "plain progress");
        assert!(changed(&a, &p("x", true, 60_000, 2_000)), "seek");
        assert!(changed(&a, &p("x", false, 12_000, 2_000)), "paused");
        assert!(changed(&a, &p("y", true, 0, 2_000)), "next song");
        let paused = p("x", false, 10_000, 0);
        assert!(!changed(&paused, &p("x", false, 10_000, 60_000)), "paused stays put");
    }
}
