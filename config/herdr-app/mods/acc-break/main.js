import { View, div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { exec, theme, layout, notify, readTextFile, home, agents, run, setShared } from "herdr";

const DIR = "~/.local/state/acc-break";
const RADIO = [{ name: "Lofi Girl", sub: "live radio to focus", url: "https://www.youtube.com/@LofiGirl/live" }];
const ENTER = { duration: 260, easing: "ease-out" };
const find = (n, id) => (n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean) ?? null);
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
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
    this.data = { favorites: [], queue: [] }; this.live = {}; this.player = null; this.reason = null; this.loading = null;
    this.seen = new Map(); this.pending = []; this.last = {}; this.next = 0; this.liveNext = 0;
    this.chan = InputState.new({ placeholder: "Add a Twitch channel" });
    this.chan.on("submit", (_e, cx) => this.addChannel(cx));
    this.link = InputState.new({ placeholder: "Paste a YouTube or Twitch link" });
    this.link.on("submit", (_e, cx) => this.addLink(cx));
    cx.spawn(async (cx) => {
      await exec("mkdir", ["-p", this.dir]);
      try { this.data = { favorites: [], queue: [], ...JSON.parse(await readTextFile(this.file) ?? "{}") }; } catch {}
      cx.notify(); this.settle(cx);
    });
    cx.timer.every(1000, (cx) => this.tick(cx));
  }

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
    const t = Date.now(), vis = this.visible();
    this.watchAgents(cx);
    if (vis && this.pending.length) this.settle(cx);
    if (vis && !this.shown) { this.next = 0; this.liveNext = 0; }
    this.shown = vis;
    if (t >= this.next && (vis || this.player)) { this.next = t + (vis ? 1500 : 4000); this.poll(cx); }
    if (vis && t >= this.liveNext && this.data.favorites.length) { this.liveNext = t + 180000; this.checkLive(cx); }
  }

  watchAgents(cx) {
    const now = {};
    for (const a of agents() ?? []) {
      now[a.address] = a.status;
      const was = this.last[a.address];
      if (was && was !== a.status && (a.status === "blocked" || a.status === "done") && this.player && !this.player.paused) {
        this.ipc([["set_property", "pause", true]]);
        this.player = { ...this.player, paused: true };
        this.reason = { terminal: a.address, text: `${a.tab_name || a.space_name || "An agent"} ${a.status === "blocked" ? "needs you" : "is done"}` };
        notify({ title: `Paused: ${this.reason.text}`, body: "Your video is waiting for you.", level: "info", timeout: 4000 });
        cx.notify();
      }
    }
    this.last = now;
  }

  async ipc(cmds) {
    const r = await exec("python3", ["-c", IPC, this.sock, JSON.stringify(cmds)], { timeout: 4000 }).catch(() => null);
    try { return JSON.parse(r?.stdout ?? "null"); } catch { return null; }
  }

  poll(cx) {
    cx.spawn(async (cx) => {
      const r = await this.ipc([["get_property", "media-title"], ["get_property", "pause"], ["get_property", "volume"], ["get_property", "path"], ["get_property", "vid"]]);
      const next = r && r.some((x) => x !== null) ? { title: r[0] ?? r[3] ?? "Loading…", paused: Boolean(r[1]), volume: Math.round(r[2] ?? 60), path: r[3], audio: r[4] === false || r[4] === "no" } : null;
      if (!next) this.reason = null;
      if (next && this.loading) this.loading = null;
      setShared("break.state", next ? (next.paused ? "paused" : "playing") : null);
      if (JSON.stringify(next) !== JSON.stringify(this.player)) { this.player = next; cx.notify(); }
    });
  }

  play(url, audio, label, cx) {
    this.loading = label; this.reason = null; cx.notify();
    cx.spawn(async (cx) => {
      const opt = audio ? "vid=no" : "vid=auto";
      const r = await this.ipc([["loadfile", url, "replace", -1, opt], ["set_property", "pause", false]]);
      if (!r || r[0] === null && !this.player) {
        const args = [`--input-ipc-server=${q(this.sock)}`, "--ontop", "--no-border", "--title=Break", "--geometry=560x315-24+64", "--autofit=560x315",
          "--force-window=immediate", "--keep-open=no", "--volume=60", `--ytdl-format=${q("bestvideo[height<=?720]+bestaudio/best")}`, ...(audio ? ["--no-video", "--force-window=no"] : []), q(url)].join(" ");
        const cmd = `rm -f ${q(this.sock)}; ${tool("mpv", args)}`;
        await exec("python3", ["-c", "import subprocess, sys; log = open(sys.argv[2], 'w'); subprocess.Popen(['sh', '-lc', sys.argv[1]], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)", cmd, `${this.dir}/mpv.log`]);
      }
      this.next = Date.now() + 1500; cx.notify();
      cx.timer.after(25000, (cx) => { if (this.loading === label) { this.loading = null; cx.notify(); } });
    });
  }

  control(cmds, cx) { cx.spawn(async (cx) => { await this.ipc(cmds); this.next = 0; this.poll(cx); }); }
  togglePause(cx) { this.reason = null; this.control([["cycle", "pause"]], cx); }
  stop(cx) { this.control([["quit"]], cx); this.player = null; this.reason = null; cx.notify(); }

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
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", tool("yt-dlp", `--skip-download --no-warnings --print '%(title)s|%(uploader)s|%(duration_string)s' ${q(url)}`)], { timeout: 90000 }).catch(() => null);
      const [title, by, dur] = (r?.stdout ?? "").trim().split("\n").pop().split("|");
      item.title = title || url; item.by = by && by !== "NA" ? by : null; item.duration = dur && dur !== "NA" ? dur : null;
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

  button(t, id, label, onClick, tone) {
    const solid = tone === "primary";
    return div().id(id).h(28).min_w(28).px(10).flex().items_center().justify_center().rounded(8).flex_none().text_size(12).font_semibold()
      .bg(solid ? t.solid : t.raised).text_color(solid ? t.solid_foreground : t.foreground).border_1().border_color(solid ? t.solid : t.border)
      .hover((s) => s.opacity(.9)).on_click(onClick).child(label);
  }
  ghost(t, id, label, onClick) {
    return div().id(id).h(24).px(8).flex().items_center().rounded(7).flex_none().text_size(11).font_semibold().text_color(t.muted)
      .hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click(onClick).child(label);
  }
  section(t, text) { return div().px(14).pt(16).pb(6).text_size(10).font_semibold().text_color(t.dim).child(text.toUpperCase()); }
  field(t, id, state, onAdd) {
    return h_flex().mx(10).gap(6).items_center()
      .child(div().id(`${id}-box`).flex_1().min_w(0).h(30).px(10).flex().items_center().rounded(8).border_1().border_color(t.border).bg(t.surface).cursor_text()
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation()).child(Input.new(state).h_full().text_size(12).text_color(t.foreground)))
      .child(this.button(t, `${id}-add`, "Add", onAdd));
  }
  avatar(t, name, on) {
    return div().size(28).rounded(14).flex().items_center().justify_center().flex_none().text_size(12).font_semibold()
      .bg(on ? t.selected : t.raised).text_color(on ? t.foreground : t.muted).border_1().border_color(on ? t.ansi2 : t.border).child(name.slice(0, 1).toUpperCase());
  }

  nowPlaying(t) {
    const p = this.player;
    if (!p && !this.loading) return this.appear("np-empty", v_flex().mx(10).mt(10).p(16).gap(4).rounded(12).bg(t.surface).border_1().border_color(t.border)
      .child(div().text_size(13).font_semibold().text_color(t.foreground).child("Nothing playing"))
      .child(div().text_size(11.5).line_height(1.45).whitespace_normal().text_color(t.muted).child("Pick a live stream, a link or the radio. It plays in a small window on top, and pauses itself when an agent needs you.")));
    const vol = p?.volume ?? 60, W = 120;
    return this.appear("np", v_flex().mx(10).mt(10).p(14).gap(12).rounded(12).bg(t.surface).border_1().border_color(this.reason ? t.blocked : t.input)
      .child(h_flex().gap(10).items_center()
        .child(div().size(8).rounded(4).flex_none().bg(!p ? t.ansi3 : p.paused ? t.muted : t.ansi2).when(!p || !p.paused, (el) => el.loop("opacity", { from: .35, to: 1, period: 1200 })))
        .child(v_flex().flex_1().min_w(0).gap(2)
          .child(div().text_size(13).font_semibold().line_height(1.35).whitespace_normal().text_color(t.foreground).child(clip(p?.title ?? this.loading ?? "", 110)))
          .child(div().text_size(11).text_color(t.muted).child(!p ? "Loading…" : `${p.paused ? "Paused" : "Playing"}${p.audio ? " · audio only" : ""}`))))
      .when(Boolean(this.reason), (el) => el.child(h_flex().gap(8).items_center().p(8).rounded(8).bg(t.raised)
        .child(div().flex_1().min_w(0).truncate().text_size(11.5).text_color(t.foreground).child(`Paused: ${this.reason.text}`))
        .child(this.ghost(t, "go-agent", "Go to agent", () => run("agent.focus", { terminal: this.reason.terminal })))))
      .when(Boolean(p), (el) => el.child(h_flex().gap(6).items_center()
        .child(this.button(t, "pp", p.paused ? "▶" : "❚❚", (_e, cx) => this.togglePause(cx), "primary"))
        .child(this.button(t, "vd", "−", (_e, cx) => this.control([["add", "volume", -10]], cx)))
        .child(div().w(W).h(4).rounded(2).bg(t.raised).overflow_hidden().child(div().h(4).w(Math.round(W * Math.min(100, vol) / 100)).rounded(2).bg(t.accent).transition("width", { duration: 180, easing: "ease-out" })))
        .child(this.button(t, "vu", "+", (_e, cx) => this.control([["add", "volume", 10]], cx)))
        .child(div().flex_1())
        .child(this.ghost(t, "stop", "Stop", (_e, cx) => this.stop(cx))))));
  }

  render() {
    const t = theme(), fav = this.data.favorites, live = fav.filter((n) => this.live[n]?.on), off = fav.filter((n) => !this.live[n]?.on);
    const favRow = (name) => {
      const l = this.live[name];
      return this.appear(`fav-${name}`, h_flex().id(`fav-${name}`).mx(10).mb(6).px(10).py(8).gap(10).items_center().rounded(10).bg(t.surface).border_1().border_color(t.border)
        .when(Boolean(l?.on), (el) => el.cursor_pointer().hover((s) => s.border_color(t.ansi2)).on_click((_e, cx) => this.play(`https://www.twitch.tv/${name}`, false, name, cx)))
        .child(this.avatar(t, name, l?.on))
        .child(v_flex().flex_1().min_w(0).gap(2)
          .child(h_flex().gap(6).items_center()
            .child(div().text_size(12.5).font_semibold().text_color(l?.on ? t.foreground : t.muted).child(name))
            .when(Boolean(l?.on), (el) => el.child(h_flex().gap(4).items_center().child(div().size(6).rounded(3).bg(t.ansi1).loop("opacity", { from: .4, to: 1, period: 1400 }))
              .child(div().text_size(10).font_semibold().text_color(t.ansi1).child("LIVE")))))
          .child(div().truncate().text_size(11).text_color(t.muted).child(l?.on ? l.title : l ? "offline" : "checking…")))
        .child(this.ghost(t, `rm-${name}`, "×", (_e, cx) => { cx.stop_propagation(); this.data.favorites = fav.filter((x) => x !== name); this.save(); cx.notify(); })));
    };
    return v_flex().size_full().bg(t.chrome)
      .child(h_flex().h(44).px(14).gap(8).items_center().border_b(1).border_color(t.border).flex_none()
        .child(div().text_size(13).font_semibold().text_color(t.foreground).child("Break"))
        .child(div().flex_1())
        .child(div().text_size(10.5).text_color(t.dim).child("pauses when an agent needs you")))
      .child(v_flex().id("br-scroll").flex_1().min_h(0).overflow_y_scrollbar().pb(14)
        .child(this.nowPlaying(t))
        .child(this.section(t, live.length ? `Live now · ${live.length}` : "Live"))
        .children([...live, ...off].map(favRow))
        .child(this.field(t, "chan", this.chan, (_e, cx) => this.addChannel(cx)))
        .child(this.section(t, "Queue"))
        .children(this.data.queue.map((it, i) => this.appear(`q-${it.added}`, h_flex().id(`q-${i}`).mx(10).mb(6).px(10).py(8).gap(10).items_center().rounded(10).bg(t.surface).border_1().border_color(t.border)
          .cursor_pointer().hover((s) => s.border_color(t.input)).on_click((_e, cx) => this.play(it.url, false, it.title ?? it.url, cx))
          .child(div().size(28).rounded(7).flex().items_center().justify_center().flex_none().bg(t.raised).text_size(11).text_color(t.muted).child("▶"))
          .child(v_flex().flex_1().min_w(0).gap(2)
            .child(div().truncate().text_size(12.5).font_semibold().text_color(t.foreground).child(it.title ?? "Fetching title…"))
            .child(div().truncate().text_size(11).text_color(t.muted).child([it.by, it.duration].filter(Boolean).join(" · ") || it.url)))
          .child(this.ghost(t, `qrm-${i}`, "×", (_e, cx) => { cx.stop_propagation(); this.remove("queue", i, cx); })))))
        .child(this.field(t, "link", this.link, (_e, cx) => this.addLink(cx)))
        .child(this.section(t, "Radio"))
        .children(RADIO.map((r, i) => this.appear(`radio-${i}`, h_flex().id(`radio-${i}`).mx(10).mb(6).px(10).py(8).gap(10).items_center().rounded(10).bg(t.surface).border_1().border_color(t.border)
          .cursor_pointer().hover((s) => s.border_color(t.input)).on_click((_e, cx) => this.play(r.url, true, r.name, cx))
          .child(div().size(28).rounded(14).flex().items_center().justify_center().flex_none().bg(t.raised).text_size(12).text_color(t.muted).child("♪"))
          .child(v_flex().flex_1().min_w(0).gap(2)
            .child(div().text_size(12.5).font_semibold().text_color(t.foreground).child(r.name))
            .child(div().text_size(11).text_color(t.muted).child(r.sub)))))));
  }
}
