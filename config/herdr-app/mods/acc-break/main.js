import { View, div, PathBuilder } from "gpui-kit";
import { v_flex, h_flex, InputState, Input, SliderState, Slider, SliderTrack, SliderIndicator, SliderThumb } from "gpui-base";
import { exec, theme, layout, notify, readTextFile, home, agents, run, setShared, settings } from "herdr";
import { Game } from "./game.js";

const DIR = "~/.local/state/acc-break";
const RADIO = [{ name: "Lofi Girl", sub: "live radio to focus", url: "https://www.youtube.com/@LofiGirl/live" }];
const ENTER = { duration: 260, easing: "ease-out" };
const TABS = [["listen", "Listen"], ["play", "Play"]];
const SEG = 72;
const FORMAT = { audio: "bestaudio/best", video: "bestvideo[height<=?720]+bestaudio/best" };
// mpv per-file options; %n% quotes a value so its own `=`, `[` and `/` stay literal.
const fileOpts = (audio, start) => [audio ? "vid=no,force-window=no" : "vid=auto,force-window=immediate",
  `ytdl-format=%${(audio ? FORMAT.audio : FORMAT.video).length}%${audio ? FORMAT.audio : FORMAT.video}`, start ? `start=${Math.floor(start)}` : null].filter(Boolean).join(",");
const SOURCES = { twitch: ["Twitch", "#9146ff"], youtube: ["YouTube", "#ff3b30"], stream: ["Stream", null] };
const source = (url) => (/twitch\.tv/.test(url ?? "") ? "twitch" : /youtu/.test(url ?? "") ? "youtube" : "stream");
const who = (a) => (a.tab_name && !/^\d+$/.test(a.tab_name) ? a.tab_name : a.space_name) || "An agent";
const clock = (s) => { s = Math.max(0, Math.floor(s ?? 0)); const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = String(s % 60).padStart(2, "0"); return h ? `${h}:${String(m).padStart(2, "0")}:${x}` : `${m}:${x}`; };
function icon(kind, size, color) {
  const k = size / 24, p = (pts) => pts.map(([x, y]) => [x * k, y * k]), paths = [];
  if (kind === "play") { const f = PathBuilder.fill(); f.add_polygon(p([[8, 5], [19, 12], [8, 19]]), true); paths.push(f); }
  if (kind === "pause") { for (const x of [7, 14]) { const f = PathBuilder.fill(); f.add_polygon(p([[x, 5], [x + 3.5, 5], [x + 3.5, 19], [x, 19]]), true); paths.push(f); } }
  if (kind === "stop") { const f = PathBuilder.fill(); f.add_polygon(p([[7, 7], [17, 7], [17, 17], [7, 17]]), true); paths.push(f); }
  if (kind === "back" || kind === "fwd") {
    const d = kind === "back" ? -1 : 1, c = (x) => 12 + d * (x - 12), f = PathBuilder.fill(), g = PathBuilder.fill();
    f.add_polygon(p([[c(5), 6], [c(12), 12], [c(5), 18]]), true); g.add_polygon(p([[c(12), 6], [c(19), 12], [c(12), 18]]), true); paths.push(f, g);
  }
  if (kind === "speaker" || kind === "muted") {
    const f = PathBuilder.fill(); f.add_polygon(p([[4, 9], [8, 9], [13, 5], [13, 19], [8, 15], [4, 15]]), true); paths.push(f);
    const w = PathBuilder.stroke(1.6);
    if (kind === "speaker") w.move_to(16 * k, 9 * k).cubic_bezier_to(16 * k, 15 * k, 18.5 * k, 10.5 * k, 18.5 * k, 13.5 * k);
    else w.move_to(16 * k, 9 * k).line_to(21 * k, 15 * k).move_to(21 * k, 9 * k).line_to(16 * k, 15 * k);
    paths.push(w);
  }
  return paths.reduce((el, path) => el.child(globalThis.window.paint_path(path.build(), color)), div().relative().size(size).flex_none());
}
const INSET = 10, HEADER = 44, ABOVE = 42 + 8 + 1, RIGHT = 8 + 1;
const FRAME = `ObjC.import("CoreGraphics"); ObjC.import("AppKit");
const l = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
let best = null;
for (let i = 0; i < l.count; i++) {
  const w = l.objectAtIndex(i);
  if (!/herdr/i.test(ObjC.unwrap(w.objectForKey("kCGWindowOwnerName"))) || ObjC.unwrap(w.objectForKey("kCGWindowLayer")) !== 0) continue;
  const b = w.objectForKey("kCGWindowBounds"), f = { x: ObjC.unwrap(b.objectForKey("X")), y: ObjC.unwrap(b.objectForKey("Y")), w: ObjC.unwrap(b.objectForKey("Width")), h: ObjC.unwrap(b.objectForKey("Height")) };
  if (!best || f.w * f.h > best.w * best.h) best = f;
}
const sc = $.NSScreen.mainScreen, fr = sc.frame, vf = sc.visibleFrame;
if (best) { best.scale = sc.backingScaleFactor; best.top = fr.size.height - (vf.origin.y + vf.size.height); }
JSON.stringify(best);`;
const find = (n, id) => (n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean) ?? null);
const host = (url) => String(url).replace(/^https?:\/\/(www\.)?/, "").split(/[/?#]/)[0];
const q = (s) => `'${String(s).replace(/'/g, "'\\''")}'`;
const tool = (bin, args) => `if command -v mpv >/dev/null && command -v yt-dlp >/dev/null; then ${bin} ${args}; else nix shell nixpkgs#mpv nixpkgs#yt-dlp -c ${bin} ${args}; fi`;
const IPC = `import socket, json, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(1.5)
try:
    s.connect(sys.argv[1])
except OSError:
    print("null"); sys.exit()
cmds = json.loads(sys.argv[2]); out = {}; buf = b""
for i, c in enumerate(cmds):
    s.sendall((json.dumps({"command": c, "request_id": i + 1}) + "\\n").encode())
try:
    while len(out) < len(cmds):
        chunk = s.recv(65536)
        if not chunk: break
        buf += chunk
        *lines, buf = buf.split(b"\\n")
        for l in lines:
            m = json.loads(l)
            if "request_id" in m and m["request_id"]: out[m["request_id"]] = m.get("data")
except OSError:
    pass
print(json.dumps([out.get(i + 1) for i in range(len(cmds))]))`;


export default class Break extends View {
  init(_p, cx) {
    this.dir = DIR.replace(/^~/, home()); this.sock = `${this.dir}/mpv.sock`; this.file = `${this.dir}/state.json`;
    this.data = { favorites: [], queue: [], tab: "listen", auto: { pause: true, resume: true } };
    this.live = {}; this.player = null; this.reason = null; this.loading = null; this.autoPaused = false; this.autoAt = 0; this.working = 0;
    this.width = 400; this.seen = new Map(); this.pending = []; this.last = null; this.next = 0; this.liveNext = 0;
    this.vol = SliderState.new({ min: 0, max: 100, step: 1, value: 60 });
    this.vol.on("change", (v) => { this.volDrag = Date.now(); this.ipc([["set_property", "volume", Number(v)]]); });
    this.seek = this.rebuildSeek(1);
    this.chan = InputState.new({ placeholder: "Add a Twitch channel" });
    this.chan.on("submit", (_e, cx) => this.addChannel(cx));
    this.link = InputState.new({ placeholder: "Paste a YouTube or Twitch link" });
    this.link.on("submit", (_e, cx) => this.addLink(cx));
    this.game = new Game(`${this.dir}/game.json`, cx);
    cx.spawn(async (cx) => {
      await exec("mkdir", ["-p", this.dir]);
      try {
        const d = JSON.parse(await readTextFile(this.file) ?? "{}");
        this.data = { ...this.data, ...d, auto: { ...this.data.auto, ...d.auto } };
      } catch {}
      for (const it of this.data.queue) if (!it.title || it.title === it.url) this.fetchMeta(it, cx);
      cx.notify(); this.settle(cx);
    });
    cx.timer.every(1000, (cx) => this.tick(cx));
  }

  async close() { await this.game.save(); }

  visible() { const n = find(layout(), "break"); return Boolean(n) && !n.hidden; }

  settle(cx) {
    cx.timer.after(50, (cx) => {
      if (!this.pending.length) return;
      this.pending.forEach((k, i) => this.seen.set(k, Math.min(i * 35, 280)));
      this.pending = []; cx.notify();
    });
  }
  appear(key, el) {
    const d = this.seen.get(key);
    if (d === undefined && !this.pending.includes(key)) this.pending.push(key);
    return el.relative().opacity(d === undefined ? 0 : 1).top(d === undefined ? 8 : 0)
      .transition("opacity", { ...ENTER, delay: d ?? 0 }).transition("top", { ...ENTER, delay: d ?? 0 });
  }

  tick(cx) {
    const t = Date.now(), vis = this.visible(), gaming = vis && this.data.tab === "play";
    this.watchAgents(cx);
    this.game.tick(t, this.working, gaming);
    if (gaming) cx.notify();
    if (vis && this.pending.length) this.settle(cx);
    this.syncDock(vis);
    if (vis && !this.shown) { this.next = 0; this.liveNext = 0; }
    this.shown = vis;
    if (t >= this.next && (vis || this.player)) { this.next = t + (vis ? 1500 : 4000); this.poll(cx); }
    if (vis && this.data.tab === "listen" && t >= this.liveNext && this.data.favorites.length) { this.liveNext = t + 180000; this.checkLive(cx); }
  }

  // The mpv window sits over the pane while a video shows on the Listen tab, and hides otherwise.
  syncDock(vis = this.visible()) {
    const video = Boolean(this.player) && !this.player.audio, want = vis && video && this.data.tab === "listen";
    if (!video) { this.docked = undefined; return; }
    if (want !== this.docked) { this.docked = want; this.dock(want); }
  }

  // Pauses when an agent needs you or finishes; resumes, if it paused itself, once an agent works again and none is waiting.
  watchAgents(cx) {
    const list = agents() ?? [], now = {}, waiting = list.some((a) => a.status === "blocked");
    this.working = list.filter((a) => a.status === "working").length;
    for (const a of list) {
      now[a.address] = a.status;
      if (!this.last || this.last[a.address] === a.status) continue;
      const p = this.player, auto = this.data.auto;
      if (auto.pause && (a.status === "blocked" || a.status === "done") && p && !p.paused) {
        this.setPaused(true); this.autoPaused = true; this.autoAt = Date.now();
        this.reason = { terminal: a.address, text: `${who(a)} ${a.status === "blocked" ? "needs you" : "is done"}` };
        notify({ title: `Paused: ${this.reason.text}`, body: auto.resume ? "It plays again when an agent gets back to work." : "Your music is waiting for you.", level: "info", timeout: 4000 });
        cx.notify();
      } else if (a.status === "blocked" && this.autoPaused) {
        this.reason = { terminal: a.address, text: `${who(a)} needs you` }; cx.notify();
      } else if (auto.resume && a.status === "working" && this.autoPaused && p?.paused && !waiting) {
        this.setPaused(false); this.autoPaused = false; this.reason = null;
        notify({ title: "Music back on", body: `${who(a)} is working again.`, level: "info", timeout: 2500 });
        cx.notify();
      }
    }
    this.last = now;
  }

  setPaused(v) { this.ipc([["set_property", "pause", v]]); if (this.player) this.player = { ...this.player, paused: v }; }

  async ipc(cmds) {
    const r = await exec("python3", ["-c", IPC, this.sock, JSON.stringify(cmds)], { timeout: 4000 }).catch(() => null);
    try { return JSON.parse(r?.stdout ?? "null"); } catch { return null; }
  }

  poll(cx) {
    cx.spawn(async (cx) => {
      const r = await this.ipc([["get_property", "media-title"], ["get_property", "pause"], ["get_property", "volume"], ["get_property", "path"], ["get_property", "vid"], ["get_property", "time-pos"],
        ["get_property", "duration"], ["get_property", "mute"], ["get_property", "playlist-count"], ["get_property", "playlist-pos"]]);
      const next = r && r.some((x) => x !== null) ? { title: String(r[0] ?? r[3] ?? "Loading…").replace(/\s\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/, "").replace(/\s*\(live\)\s*$/i, ""), paused: Boolean(r[1]), volume: Math.round(r[2] ?? 60), path: r[3], audio: r[4] === false || r[4] === "no",
        pos: r[5] ?? 0, duration: r[6] && r[6] > 0 && !/twitch\.tv|\/live\b/.test(r[3] ?? "") ? r[6] : null, mute: Boolean(r[7]), count: r[8] ?? 1, index: r[9] ?? 0 } : null;
      if (next) {
        if (Date.now() - (this.volDrag ?? 0) > 1500) this.vol.set_value(next.volume);
        if (next.duration && !this.seekDrag) { if (this.seekMax !== Math.round(next.duration)) { this.seekMax = Math.round(next.duration); this.seek = this.rebuildSeek(this.seekMax); } this.seek.set_value(Math.min(this.seekMax, Math.round(next.pos))); }
        // Played again from elsewhere (media keys, the mpv window): no longer ours to resume.
        if (!next.paused && this.autoPaused && Date.now() - this.autoAt > 3000) { this.autoPaused = false; this.reason = null; }
      }
      if (!next) { this.reason = null; this.autoPaused = false; }
      if (next && this.loading) this.loading = null;
      setShared("break.state", next ? (next.paused ? "paused" : "playing") : null);
      if (JSON.stringify(next) !== JSON.stringify(this.player)) { this.player = next; this.syncDock(); cx.notify(); }
    });
  }

  play(url, audio, label, cx) {
    this.loading = label; this.loadingAudio = audio; this.reason = null; this.autoPaused = false; cx.notify();
    cx.spawn(async (cx) => {
      const r = await this.ipc([["loadfile", url, "replace", -1, fileOpts(audio)], ["set_property", "pause", false], ...(audio ? [] : [["set_property", "geometry", await this.geometry()]])]);
      if (!r || r[0] === null && !this.player) {
        const args = [`--input-ipc-server=${q(this.sock)}`, "--ontop", "--no-border", "--title=Break", "--auto-window-resize=no", "--keepaspect-window=yes", `--geometry=${await this.geometry()}`,
          "--force-window=immediate", "--keep-open=no", "--volume=60", `--ytdl-format=${q(audio ? FORMAT.audio : FORMAT.video)}`, ...(audio ? ["--no-video", "--force-window=no"] : []), q(url)].join(" ");
        const cmd = `rm -f ${q(this.sock)}; ${tool("mpv", args)}`;
        await exec("python3", ["-c", "import subprocess, sys; log = open(sys.argv[2], 'w'); subprocess.Popen(['sh', '-lc', sys.argv[1]], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)", cmd, `${this.dir}/mpv.log`]);
      }
      this.next = Date.now() + 1500; cx.notify();
      cx.timer.after(25000, (cx) => { if (this.loading === label) { this.loading = null; cx.notify(); } });
    });
  }

  // Video → audio keeps the stream (and its playlist) and drops the picture. Audio → video turns the
  // picture back on when the stream has one, else reloads the track with video at the same spot.
  switchMode(cx) {
    const p = this.player; if (!p) return;
    cx.spawn(async (cx) => {
      if (!p.audio) {
        this.docked = false; await this.dock(false);
        await this.ipc([["set_property", "vid", "no"], ["set_property", "force-window", "no"]]);
      } else {
        const tracks = (await this.ipc([["get_property", "track-list"]]))?.[0] ?? [], g = await this.geometry();
        if (tracks.some((x) => x.type === "video" && !x.albumart)) await this.ipc([["set_property", "force-window", "immediate"], ["set_property", "geometry", g], ["set_property", "vid", "auto"]]);
        else await this.ipc([["loadfile", p.path, "replace", -1, fileOpts(false, p.duration ? p.pos : 0)], ["set_property", "geometry", g]]);
      }
      this.next = 0; this.poll(cx);
    });
  }

  async dock(show) {
    const list = await exec("aerospace", ["list-windows", "--all", "--format", "%{window-id}|%{app-name}|%{window-title}|%{workspace}"], { timeout: 4000 }).catch(() => null);
    if (!list || list.code !== 0) return;
    const rows = list.stdout.split("\n").map((l) => l.split("|"));
    const win = rows.find((r) => /mpv/i.test(r[1] ?? "") && r[2] === "Break"), herdr = rows.find((r) => /herdr/i.test(r[1] ?? ""));
    if (!win) return;
    const target = show ? herdr?.[3] : "break-hidden";
    if (!target || win[3] === target) return;
    await exec("aerospace", ["move-node-to-workspace", "--window-id", win[0], target], { timeout: 4000 }).catch(() => null);
    if (show) { const g = await this.geometry(); this.ipc([["set_property", "geometry", g]]); }
  }

  videoSize() { const w = Math.max(240, this.width - 2 * INSET); return { w, h: Math.round(w * 9 / 16) }; }

  async frame() {
    const r = await exec("osascript", ["-l", "JavaScript", "-e", FRAME], { timeout: 5000 }).catch(() => null);
    try { return JSON.parse(r?.stdout?.trim() || "null"); } catch { return null; }
  }

  async geometry() {
    const z = Number(settings().zoom ?? 1) || 1, v = this.videoSize(), f = await this.frame();
    if (!f) return `${Math.round(v.w * z * 2)}x${Math.round(v.h * z * 2)}-40-40`;
    const s = f.scale || 2, w = v.w * z, h = v.h * z;
    const x = f.x + f.w - (RIGHT + INSET) * z - w, y = f.y + (ABOVE + HEADER + INSET) * z - (f.top || 0);
    return `${Math.round(w * s)}x${Math.round(h * s)}+${Math.round(x * s)}+${Math.round(y * s)}`;
  }

  resized(width) {
    const zoom = Number(settings().zoom ?? 1) || 1, w = width / zoom;
    if (Math.abs(w - this.width) < 8) return;
    this.width = w;
    if (this.player && !this.player.audio) this.geometry().then((g) => this.ipc([["set_property", "geometry", g]]));
  }

  rebuildSeek(max) {
    const st = SliderState.new({ min: 0, max: Math.max(1, max), step: 1, value: 0 });
    st.on("change", () => { this.seekDrag = Date.now(); });
    st.on("release", (v, cx) => { this.seekDrag = 0; this.control([["seek", Number(v), "absolute"]], cx); });
    return st;
  }

  control(cmds, cx) { cx.spawn(async (cx) => { await this.ipc(cmds); this.next = 0; this.poll(cx); }); }
  togglePause(cx) { this.reason = null; this.autoPaused = false; this.control([["cycle", "pause"]], cx); }
  stop(cx) { this.control([["quit"]], cx); this.player = null; this.reason = null; this.autoPaused = false; cx.notify(); }

  switchTab(k, cx) {
    if (this.data.tab === k) return;
    this.data.tab = k; this.save(); this.syncDock(); cx.notify();
    if (k === "listen") { this.liveNext = 0; this.settle(cx); }
  }
  flip(key, cx) { this.data.auto[key] = !this.data.auto[key]; if (key === "resume" && !this.data.auto.resume) this.autoPaused = false; this.save(); cx.notify(); }

  save() { exec("python3", ["-c", "import sys; open(sys.argv[1], 'w').write(sys.argv[2])", this.file, JSON.stringify(this.data, null, 2)]); }

  addChannel(cx) {
    const name = this.chan.value().trim().replace(/^https?:\/\/(www\.)?twitch\.tv\//, "").replace(/\/.*$/, "").toLowerCase();
    if (!name || this.data.favorites.includes(name)) return;
    this.chan.set_value("");
    this.data.favorites.push(name); this.save(); this.liveNext = 0; cx.notify(); this.settle(cx);
  }

  addLink(cx) {
    const url = this.link.value().trim();
    if (!/^https?:\/\//.test(url)) { notify({ title: "That is not a link", level: "info", timeout: 2000 }); return; }
    this.link.set_value("");
    const item = { url, title: null, added: new Date().toISOString() };
    this.data.queue.push(item); this.save(); cx.notify(); this.settle(cx);
    this.fetchMeta(item, cx);
  }

  // --no-playlist: a link from a YouTube mix (list=RD…) would otherwise list the whole mix and time out.
  fetchMeta(item, cx) {
    item.failed = false;
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", tool("yt-dlp", `--skip-download --no-warnings --no-playlist --playlist-items 1 --print '%(title)s|%(uploader)s|%(duration_string)s' ${q(item.url)}`)], { timeout: 90000 }).catch(() => null);
      const [title, by, dur] = ((r?.stdout ?? "").split("\n").find((l) => l.includes("|")) ?? "").split("|");
      item.title = title && title !== "NA" ? title : null; item.by = by && by !== "NA" ? by : null; item.duration = dur && dur !== "NA" ? dur : null;
      item.failed = !item.title;
      this.save(); cx.notify();
    });
  }

  remove(list, i, cx) { this.data[list].splice(i, 1); this.save(); cx.notify(); }

  checkLive(cx) {
    for (const name of this.data.favorites) {
      cx.spawn(async (cx) => {
        const r = await exec("sh", ["-c", tool("yt-dlp", `--skip-download --no-warnings --print '%(is_live)s|%(title)s' ${q(`https://www.twitch.tv/${name}`)}`)], { timeout: 60000 }).catch(() => null);
        const line = (r?.stdout ?? "").trim().split("\n").pop() ?? "", [live, ...title] = line.split("|");
        this.live[name] = live === "True" ? { on: true, title: title.join("|").replace(/\s\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/, "") } : { on: false };
        cx.notify();
      });
    }
  }

  // ---- pieces

  section(t, text, right) {
    return h_flex().px(14).pt(18).pb(7).items_center()
      .child(div().flex_1().text_size(10).font_semibold().text_color(t.dim).child(text.toUpperCase()))
      .when(Boolean(right), (el) => el.child(div().text_size(10).text_color(t.dim).child(right ?? "")));
  }
  button(t, id, label, onClick) {
    return div().id(id).h(30).px(12).flex().items_center().justify_center().rounded(8).flex_none().text_size(12).font_semibold()
      .bg(t.raised).text_color(t.foreground).border_1().border_color(t.border).cursor_pointer()
      .hover((s) => s.border_color(t.input)).on_click(onClick).child(label);
  }
  ghost(t, id, label, onClick) {
    return div().id(id).h(24).px(8).flex().items_center().rounded(7).flex_none().text_size(11).font_semibold().text_color(t.muted).cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click(onClick).child(label);
  }
  field(t, id, state, onAdd) {
    return h_flex().mx(10).mt(2).gap(6).items_center()
      .child(div().id(`${id}-box`).flex_1().min_w(0).h(30).px(10).flex().items_center().rounded(8).border_1().border_color(t.border).bg(t.surface).cursor_text()
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation()).child(Input.new(state).h_full().text_size(12).text_color(t.foreground)))
      .child(this.button(t, `${id}-add`, "Add", onAdd));
  }
  // A small round action inside a row; it never also triggers the row.
  act(t, id, child, onClick) {
    return div().id(id).size(26).rounded(13).flex().items_center().justify_center().flex_none().cursor_pointer()
      .text_size(12).text_color(t.muted).hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click((e, cx) => { cx.stop_propagation(); onClick(e, cx); }).child(child);
  }
  slider(t, state, key, w, color) {
    const s = Slider.new(state);
    return (w ? s.w(w).flex_none() : s.flex_1().min_w(0)).child(SliderTrack.new(state).flex().items_center().h(18).w_full().cursor_pointer()
      .child(SliderIndicator.new(state).relative().w_full().h(3).rounded(2).bg(t.raised)
        .range_style((fill) => fill.rounded(2).bg(color))
        .child(SliderThumb.new(state).id(`th-${key}`).size(10).rounded(5).ml(-5).mt(-3.5).bg(t.foreground).hover((s) => s.size(12).ml(-6).mt(-4.5)))));
  }
  pp(t, id, paused, size) {
    const g = Math.round(size * 0.46), off = (size - g) / 2;
    return div().id(id).relative().size(size).rounded(size / 2).flex_none().bg(t.solid).cursor_pointer()
      .hover((s) => s.opacity(0.9)).on_click((_e, cx) => this.togglePause(cx))
      .child(div().absolute().left(off + 1).top(off).opacity(paused ? 1 : 0).transition("opacity", { duration: 150, easing: "ease-out" }).child(icon("play", g, t.solid_foreground)))
      .child(div().absolute().left(off).top(off).opacity(paused ? 0 : 1).transition("opacity", { duration: 150, easing: "ease-out" }).child(icon("pause", g, t.solid_foreground)));
  }
  toggle(t, id, label, sub, on, onFlip) {
    return h_flex().id(id).mx(10).mb(6).px(12).py(10).gap(12).items_center().rounded(10).bg(t.surface).border_1().border_color(t.border).cursor_pointer()
      .hover((s) => s.border_color(t.input)).on_click((_e, cx) => onFlip(cx))
      .child(v_flex().flex_1().min_w(0).gap(2)
        .child(div().text_size(12.5).font_semibold().text_color(t.foreground).child(label))
        .child(div().text_size(11).line_height(1.4).whitespace_normal().text_color(t.muted).child(sub)))
      .child(div().relative().w(30).h(18).rounded(9).flex_none().bg(on ? t.accent : t.raised).border_1().border_color(on ? t.accent : t.border)
        .child(div().id(`${id}-knob`).absolute().top(2).left(on ? 14 : 2).size(12).rounded(6).bg(on ? t.accent_foreground : t.muted)
          .spring("left", { response: 260, damping: 0.8 })));
  }
  segmented(t) {
    const idx = TABS.findIndex(([k]) => k === this.data.tab), playing = Boolean(this.player && !this.player.paused);
    return div().id("seg").relative().w(SEG * TABS.length + 6).h(28).p(3).rounded(9).bg(t.surface).border_1().border_color(t.border)
      .child(div().id("seg-ind").absolute().top(2).left(2 + idx * SEG).w(SEG).h(22).rounded(7).bg(t.raised).border_1().border_color(t.input)
        .spring("left", { response: 300, damping: 0.78 }))
      .child(h_flex().relative().size_full().children(TABS.map(([k, l]) => h_flex().id(`seg-${k}`).w(SEG).h_full().gap(5).items_center().justify_center()
        .text_size(12).font_semibold().text_color(this.data.tab === k ? t.foreground : t.muted).cursor_pointer()
        .hover((s) => s.text_color(t.foreground)).on_click((_e, cx) => this.switchTab(k, cx)).child(l)
        .when(k === "listen" && this.data.tab !== k && playing, (el) => el.child(div().size(5).rounded(3).bg(t.accent)
          .loop("opacity", { from: 0.35, to: 1, period: 1200 }))))));
  }
  // One line per thing you can play: a click on the row plays it the default way; the buttons pick.
  row(t, key, { lead, title, sub, active, dim, onRow, listen, watch, remove }) {
    return this.appear(key, h_flex().id(key).mx(10).mb(6).pl(10).pr(6).py(7).gap(10).items_center().rounded(10).bg(active ? t.selected : t.surface)
      .border_1().border_color(active ? t.input : t.border)
      .when(Boolean(onRow), (el) => el.cursor_pointer().hover((s) => s.border_color(t.input)).on_click((_e, cx) => onRow(cx)))
      .child(lead)
      .child(v_flex().flex_1().min_w(0).gap(2)
        .child(div().truncate().text_size(12.5).font_semibold().text_color(dim ? t.muted : t.foreground).child(title))
        .child(div().truncate().text_size(11).text_color(t.muted).child(sub)))
      .child(h_flex().gap(2).items_center().flex_none()
        .when(Boolean(listen), (el) => el.child(this.act(t, `${key}-listen`, "♪", (_e, cx) => listen(cx))))
        .when(Boolean(watch), (el) => el.child(this.act(t, `${key}-watch`, icon("play", 11, t.muted), (_e, cx) => watch(cx))))
        .when(Boolean(remove), (el) => el.child(this.act(t, `${key}-rm`, "×", (_e, cx) => remove(cx))))));
  }
  lead(t, text, color, round) {
    return div().size(30).rounded(round ? 15 : 8).flex().items_center().justify_center().flex_none().bg(t.raised)
      .border_1().border_color(color ?? t.border).text_size(12).font_semibold().text_color(color ?? t.muted).child(text);
  }

  // ---- player

  nowPlaying(t) {
    const p = this.player, auto = this.data.auto;
    if (!p && !this.loading) return this.appear("np-empty", v_flex().mx(10).mt(10).p(14).gap(5).rounded(12).bg(t.surface).border_1().border_color(t.border)
      .child(div().text_size(13).font_semibold().text_color(t.foreground).child("Nothing playing"))
      .child(div().text_size(11.5).line_height(1.45).whitespace_normal().text_color(t.muted)
        .child("Press ♪ on a link to just hear it, ▶ to watch. Music pauses when an agent needs you and comes back when they get to work.")));
    const [name, color] = SOURCES[source(p?.path)], live = p && !p.duration, paused = p?.paused;
    const meta = p ? [name, p.audio ? "audio only" : "video", live ? "live" : null, p.count > 1 ? `${p.index + 1} of ${p.count}` : null].filter(Boolean).join(" · ") : this.loadingAudio ? "audio only" : "video";
    return this.appear("np", v_flex().mx(10).mt(10).rounded(12).bg(t.surface).border_1().border_color(this.reason ? t.blocked : t.border)
      .child(h_flex().pl(12).pr(6).pt(10).gap(10).items_center()
        .child(div().size(8).rounded(4).flex_none().bg(live ? "#ff4d4f" : color ?? t.muted).when(Boolean(live && !paused), (d) => d.loop("opacity", { from: 0.35, to: 1, period: 1400 })))
        .child(v_flex().flex_1().min_w(0).gap(2)
          .child(div().truncate().text_size(12.5).font_semibold().text_color(p && !paused ? t.foreground : t.muted).child(p?.title ?? `Opening ${this.loading ?? ""}…`))
          .child(div().truncate().text_size(10.5).text_color(t.dim).child(meta)))
        .when(Boolean(p), (el) => el.child(this.act(t, "np-stop", icon("stop", 10, t.dim), (_e, cx) => this.stop(cx)))))
      .when(Boolean(p?.duration), (el) => el.child(h_flex().px(12).pt(8).gap(8).items_center()
        .child(div().w(38).text_size(10).text_color(t.dim).child(clock(p.pos)))
        .child(this.slider(t, this.seek, "seek", null, t.accent))
        .child(div().w(38).flex().justify_end().text_size(10).text_color(t.dim).child(clock(p.duration)))))
      .when(Boolean(p), (el) => el.child(h_flex().px(8).pt(6).pb(10).gap(4).items_center()
        .when(p.count > 1, (e) => e.child(this.act(t, "np-prev", icon("back", 12, t.muted), (_e, cx) => this.control([["playlist-prev"]], cx))))
        .child(div().ml(p.count > 1 ? 0 : 4).child(this.pp(t, "np-pp", paused, 34)))
        .when(p.count > 1, (e) => e.child(this.act(t, "np-next", icon("fwd", 12, t.muted), (_e, cx) => this.control([["playlist-next"]], cx))))
        .child(div().id("np-mode").ml(6).h(24).px(9).flex().items_center().rounded(12).flex_none().cursor_pointer()
          .bg(t.raised).border_1().border_color(t.border).text_size(11).font_semibold().text_color(t.muted)
          .hover((s) => s.border_color(t.input).text_color(t.foreground)).on_click((_e, cx) => this.switchMode(cx))
          .child(p.audio ? "▶ Show video" : "♪ Audio only"))
        .child(div().flex_1())
        .child(this.act(t, "np-mute", icon(p.mute ? "muted" : "speaker", 13, p.mute ? t.dim : t.muted), (_e, cx) => this.control([["cycle", "mute"]], cx)))
        .child(div().pr(6).when(p.mute, (d) => d.opacity(0.35)).transition("opacity", 160).child(this.slider(t, this.vol, "vol", 64, t.muted)))))
      .when(Boolean(this.reason), (el) => el.child(h_flex().gap(8).items_center().px(12).py(8).border_t(1).border_color(t.border)
        .child(div().size(6).rounded(3).flex_none().bg(t.blocked))
        .child(v_flex().flex_1().min_w(0).gap(1)
          .child(div().truncate().text_size(11.5).text_color(t.foreground).child(`Paused: ${this.reason.text}`))
          .when(auto.resume && this.autoPaused, (e) => e.child(div().truncate().text_size(10.5).text_color(t.dim).child("Plays again when an agent gets back to work"))))
        .child(this.ghost(t, "go-agent", "Go to agent", () => run("agent.focus", { terminal: this.reason.terminal }))))));
  }

  miniPlayer(t) {
    const p = this.player;
    return h_flex().mx(10).mt(10).h(42).pl(14).pr(5).gap(8).items_center().rounded(21).bg(t.surface).border_1().border_color(this.reason ? t.blocked : t.border)
      .child(div().text_size(12).text_color(p.paused ? t.dim : t.accent).child("♪"))
      .child(div().flex_1().min_w(0).truncate().text_size(12).font_semibold().text_color(p.paused ? t.muted : t.foreground)
        .child(this.reason ? `Paused: ${this.reason.text}` : p.title))
      .when(p.count > 1, (el) => el.child(this.act(t, "mini-next", icon("fwd", 11, t.muted), (_e, cx) => this.control([["playlist-next"]], cx))))
      .child(this.pp(t, "mini-pp", p.paused, 30));
  }

  listenView(t) {
    const fav = this.data.favorites, live = fav.filter((n) => this.live[n]?.on), off = fav.filter((n) => !this.live[n]?.on), path = this.player?.path, auto = this.data.auto;
    return [
      this.section(t, "Links", this.data.queue.length ? `${this.data.queue.length}` : null),
      ...this.data.queue.map((it, i) => {
        const src = source(it.url), [name, color] = SOURCES[src], label = it.title ?? host(it.url);
        return this.row(t, `q-${it.added}`, {
          lead: this.lead(t, src === "youtube" ? "▶" : src === "twitch" ? "T" : "•", color),
          title: it.title ?? (it.failed ? host(it.url) : "Fetching title…"),
          sub: [it.by, it.duration, it.failed ? "title not found" : null].filter(Boolean).join(" · ") || name,
          active: path === it.url,
          onRow: (cx) => this.play(it.url, true, label, cx),
          listen: (cx) => this.play(it.url, true, label, cx),
          watch: (cx) => this.play(it.url, false, label, cx),
          remove: (cx) => this.remove("queue", i, cx),
        });
      }),
      this.field(t, "link", this.link, (_e, cx) => this.addLink(cx)),
      this.section(t, "Twitch", live.length ? `${live.length} live` : null),
      ...[...live, ...off].map((name) => {
        const l = this.live[name], url = `https://www.twitch.tv/${name}`;
        return this.row(t, `fav-${name}`, {
          lead: this.lead(t, name.slice(0, 1).toUpperCase(), l?.on ? t.ansi1 : null, true),
          title: l?.on ? `${name} · live` : name,
          sub: l?.on ? l.title : l ? "offline" : "checking…",
          dim: !l?.on, active: path === url,
          onRow: l?.on ? (cx) => this.play(url, false, name, cx) : null,
          listen: l?.on ? (cx) => this.play(url, true, name, cx) : null,
          watch: l?.on ? (cx) => this.play(url, false, name, cx) : null,
          remove: (cx) => { this.data.favorites = fav.filter((x) => x !== name); this.save(); cx.notify(); },
        });
      }),
      this.field(t, "chan", this.chan, (_e, cx) => this.addChannel(cx)),
      this.section(t, "Radio"),
      ...RADIO.map((r, i) => this.row(t, `radio-${i}`, {
        lead: this.lead(t, "♪", null, true), title: r.name, sub: r.sub, active: path === r.url,
        onRow: (cx) => this.play(r.url, true, r.name, cx),
        listen: (cx) => this.play(r.url, true, r.name, cx),
        watch: (cx) => this.play(r.url, false, r.name, cx),
      })),
      this.section(t, "Agents"),
      this.toggle(t, "auto-pause", "Pause when an agent needs you", "Also when one finishes while you listen.", auto.pause, (cx) => this.flip("pause", cx)),
      this.toggle(t, "auto-resume", "Play again when agents get to work", "Only after a pause it made itself, and while no agent is waiting on you.", auto.resume, (cx) => this.flip("resume", cx)),
    ];
  }

  render() {
    const t = theme(), tab = this.data.tab, video = Boolean(this.player && !this.player.audio || this.loading && !this.loadingAudio);
    return v_flex().id("br-root").size_full().bg(t.chrome).on_size_change((sz) => this.resized(sz.width))
      .child(h_flex().h(HEADER).px(14).gap(8).items_center().border_b(1).border_color(t.border).flex_none()
        .child(div().text_size(13).font_semibold().text_color(t.foreground).child("Break"))
        .child(div().flex_1())
        .child(this.segmented(t)))
      .when(tab === "listen" && video, (el) => el.child(div().flex_none().w_full().h(this.videoSize().h + 2 * INSET).px(INSET).py(INSET)
        .child(div().size_full().rounded(8).bg("#000000").border_1().border_color(t.border).flex().items_center().justify_center()
          .child(div().text_size(11).text_color(t.dim).child(this.player ? "" : "Opening the stream…")))))
      .child(v_flex().id(`br-scroll-${tab}`).flex_1().min_h(0).overflow_y_scrollbar().pb(16)
        .when(tab === "listen", (el) => el.child(this.nowPlaying(t)).children(this.listenView(t)))
        .when(tab === "play", (el) => el.when(Boolean(this.player), (e) => e.child(this.miniPlayer(t))).child(this.game.view(t, this.width))));
  }
}
