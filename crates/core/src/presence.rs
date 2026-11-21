//! "Playing on <device>" between linked devices (Spotify's device bar), carried by device sync.
//!
//! Each device keeps one synced setting, `presence:<device id>`, holding what it is playing
//! (song, playing or paused, position and when that position was read). A remote control is a
//! setting too, `remote:<target device id>`, which the target runs once when it arrives. Both
//! ride the normal sync rounds (LAN every 3 s, relay every 5 s), so nothing new goes on the wire.
use serde_json::{json, Value};
use std::sync::Arc;

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
    let st = st.clone();
    crate::rt::spawn(async move {
        let mut last: Option<Value> = None;
        let mut idle_sent = false;
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
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
                        st.db.set_setting(&key, &now.to_string());
                        last = Some(now);
                        idle_sent = false;
                    }
                }
                None if !idle_sent && last.is_some() => {
                    st.db.set_setting(&key, &json!({ "name": crate::sync::device_name(), "playing": false, "at": now_ms() }).to_string());
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
    let mut out: Vec<Value> = st
        .db
        .all_settings()
        .into_iter()
        .filter_map(|(k, v)| {
            let dev = k.strip_prefix(PRESENCE)?.to_string();
            if dev == me {
                return None;
            }
            let mut p: Value = serde_json::from_str(&v).ok()?;
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
    st.db.set_setting(&format!("{REMOTE}{dev}"), &json!({ "cmd": cmd, "id": id, "from": engine.device_id(), "at": now_ms() }).to_string());
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
    // Run each command once, and only a recent one (a stale command from days ago does nothing).
    let id = v["id"].as_str().unwrap_or_default().to_string();
    if st.db.get_setting("remote_done").as_deref() == Some(id.as_str()) || now_ms() - v["at"].as_i64().unwrap_or(0) > 60_000 {
        return;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn p(id: &str, playing: bool, pos: i64, at: i64) -> Value {
        json!({ "song": { "videoId": id }, "playing": playing, "posMs": pos, "at": at })
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
