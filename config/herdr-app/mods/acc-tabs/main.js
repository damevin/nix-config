import { View, div, svg, image, PathBuilder } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, panes, run, exec, openOverlay, theme, window, shared, layout, settings } from "herdr";

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}


const K = 14 / 24;
const ring = (x, y) => Array.from({ length: 16 }, (_, i) => [(x + 2 * Math.cos(i / 16 * 2 * Math.PI)) * K, (y + 2 * Math.sin(i / 16 * 2 * Math.PI)) * K]);
function routingGlyph(color) {
  const stroke = PathBuilder.stroke(1.3);
  for (const [x, y] of [[5, 12], [12, 12], [19, 6], [19, 18]]) stroke.add_polygon(ring(x, y), true);
  const wires = PathBuilder.stroke(1.3)
    .move_to(7 * K, 12 * K).line_to(10 * K, 12 * K)
    .move_to(14 * K, 12 * K).cubic_bezier_to(17 * K, 6 * K, 16.5 * K, 12 * K, 16.5 * K, 6 * K)
    .move_to(14 * K, 12 * K).cubic_bezier_to(17 * K, 18 * K, 16.5 * K, 12 * K, 16.5 * K, 18 * K);
  return div().relative().size(14).flex_none().child(globalThis.window.paint_path(stroke.build(), color)).child(globalThis.window.paint_path(wires.build(), color));
}

function prGlyph(color) {
  const k = 14 / 24, ring = (x, y) => Array.from({ length: 16 }, (_, i) => [(x + 2 * Math.cos(i / 16 * 2 * Math.PI)) * k, (y + 2 * Math.sin(i / 16 * 2 * Math.PI)) * k]);
  const rings = PathBuilder.stroke(1.3);
  for (const [x, y] of [[6, 5], [6, 19], [18, 19]]) rings.add_polygon(ring(x, y), true);
  const lines = PathBuilder.stroke(1.3).move_to(6 * k, 7 * k).line_to(6 * k, 17 * k)
    .move_to(18 * k, 17 * k).line_to(18 * k, 11 * k).cubic_bezier_to(14 * k, 7 * k, 18 * k, 8 * k, 16 * k, 7 * k).line_to(11 * k, 7 * k);
  return div().relative().size(14).flex_none().child(globalThis.window.paint_path(rings.build(), color)).child(globalThis.window.paint_path(lines.build(), color));
}

function symGlyph(color) {
  const k = 14 / 24, bars = PathBuilder.stroke(1.6);
  for (const [x, y1, y2] of [[5, 14, 20], [10, 5, 20], [15, 9, 20], [20, 12, 20]]) bars.move_to(x * k, y1 * k).line_to(x * k, y2 * k);
  return div().relative().size(14).flex_none().child(globalThis.window.paint_path(bars.build(), color));
}

function todayGlyph(color) {
  const k = 14 / 24;
  const box = PathBuilder.stroke(1.4).move_to(4 * k, 4 * k).line_to(20 * k, 4 * k).line_to(20 * k, 20 * k).line_to(4 * k, 20 * k).line_to(4 * k, 4 * k);
  const tick = PathBuilder.stroke(1.6).move_to(8 * k, 12 * k).line_to(11 * k, 15 * k).line_to(16.5 * k, 9 * k);
  return div().relative().size(14).flex_none().child(globalThis.window.paint_path(box.build(), color)).child(globalThis.window.paint_path(tick.build(), color));
}

function reviewGlyph(color) {
  const k = 14 / 24;
  const eye = PathBuilder.stroke(1.4).move_to(2.5 * k, 12 * k).cubic_bezier_to(21.5 * k, 12 * k, 7 * k, 5 * k, 17 * k, 5 * k).cubic_bezier_to(2.5 * k, 12 * k, 17 * k, 19 * k, 7 * k, 19 * k);
  const pupil = PathBuilder.stroke(1.4);
  pupil.add_polygon(Array.from({ length: 16 }, (_, i) => [(12 + 2.6 * Math.cos(i / 8 * Math.PI)) * k, (12 + 2.6 * Math.sin(i / 8 * Math.PI)) * k]), true);
  return div().relative().size(14).flex_none().child(globalThis.window.paint_path(eye.build(), color)).child(globalThis.window.paint_path(pupil.build(), color));
}

function breakGlyph(color) {
  const k = 14 / 24;
  const box = PathBuilder.stroke(1.4).move_to(3 * k, 5 * k).line_to(21 * k, 5 * k).line_to(21 * k, 17 * k).line_to(3 * k, 17 * k).line_to(3 * k, 5 * k).move_to(8 * k, 21 * k).line_to(16 * k, 21 * k);
  const play = PathBuilder.stroke(1.3);
  play.add_polygon([[10, 8.5], [15, 11], [10, 13.5]].map(([x, y]) => [x * k, y * k]), true);
  return div().relative().size(14).flex_none().child(globalThis.window.paint_path(box.build(), color)).child(globalThis.window.paint_path(play.build(), color));
}

function autoGlyph(color) {
  const k = 14 / 24, bolt = PathBuilder.stroke(1.4);
  bolt.add_polygon([[13, 3], [5, 14], [11, 14], [10, 21], [19, 10], [13, 10]].map(([x, y]) => [x * k, y * k]), true);
  return div().relative().size(14).flex_none().child(globalThis.window.paint_path(bolt.build(), color));
}

export default class Tabs extends View {
  init(_p, cx) {
    this.sym = { on: false, running: 0 };
    const poll = (cx) => cx.spawn(async (cx) => {
      let next = { on: false, running: 0 };
      try {
        const r = await fetch("http://127.0.0.1:4000/api/v1/state");
        if (r.status === 200) { const d = JSON.parse(await r.text()); next = { on: true, running: (d.running ?? []).length }; }
      } catch {}
      if (next.on !== this.sym.on || next.running !== this.sym.running) { this.sym = next; cx.notify(); }
    });
    this.branches = JSON.parse(localStorage.getItem("branches") ?? "{}");
    const autoName = (cx) => cx.spawn(async () => {
      let changed = false;
      for (const s of spaces()) {
        if (!s.folder) continue;
        const r = await exec("git", ["-C", s.folder, "branch", "--show-current"], { on: s.machine, timeout: 3000 }).catch(() => null);
        const branch = r?.code === 0 ? r.stdout.trim() : "";
        if (!branch || /^(main|master)$/.test(branch) || this.branches[s.id] === branch) continue;
        this.branches[s.id] = branch; changed = true;
        const ticket = branch.match(/liv-\d+/i)?.[0].toUpperCase();
        const name = branch.replace(/^.*\//, "").replace(/^liv-\d+[-_]?/i, "").replace(/[-_]+/g, " ").trim() || ticket || branch;
        if (s.name !== name) run("space.rename", { id: s.id, name });
      }
      if (changed) localStorage.setItem("branches", JSON.stringify(this.branches));
    });
    poll(cx); autoName(cx);
    cx.timer.every(4000, (cx) => { poll(cx); autoName(cx); });
    this.pressed = null;
    this.panels = JSON.parse(localStorage.getItem("panels") ?? "{}");
  }

  // The side panel is remembered per space: switching shows that space's choice
  // (closed if it never had one), and opening or closing it records it.
  syncPanel(space, panel, body, enabled) {
    if (!space || !panel) return;
    const now = panel.hidden ? null : body?.active ?? null;
    if (space.id !== this.space) {
      const first = this.space === undefined;
      this.space = space.id; this.pending = null;
      if (!(first && !(space.id in this.panels))) {
        const stored = this.panels[space.id] ?? null, want = enabled.includes(stored) ? stored : null;
        if (want !== now) {
          this.pending = { want, until: Date.now() + 1000 };
          if (want) { run("layout.select", { stack: "panel-body", child: want }); run("layout.show", { id: "panel" }); }
          else run("layout.hide", { id: "panel" });
          return;
        }
      }
    }
    // Until the restore lands (or something else won), the old state isn't a choice.
    if (this.pending) {
      if (this.pending.want !== now && Date.now() < this.pending.until) return;
      this.pending = null;
    }
    if (this.panels[space.id] === now) return;
    this.panels[space.id] = now;
    localStorage.setItem("panels", JSON.stringify(this.panels));
  }

  render() {
    const t = theme();
    const space = spaces().find(p => p.active);
    const shown = space?.tabs ?? [];
    const stop = (_e, cx) => cx.stop_propagation();
    const button = (id, label, action) => div().id(id).size(26).flex_none().flex().items_center().justify_center().rounded(6).text_color(t.dim).hover(s => s.bg(t.hover).text_color(t.foreground))
      .on_mouse_down("left", stop).on_click(action).child(label);
    const item = (c, i) => {
      const pane = panes().find(p => p.tab === c.id && p.program?.agent) ?? panes().find(p => p.tab === c.id);
      const program = pane?.program;
      // Agents (omp…) set the terminal title to their session title; drop their spinner glyph, the tab has its own.
      const title = pane?.program?.agent || pane?.app ? pane.title?.replace(/^[\u2800-\u28ff\s]+/, "").trim() : "";
      // Menu-started tabs are named after the program ("ᴏᴍᴘ · resume"): still automatic.
      const auto = /^tb\d+$/.test(c.name) || (program?.name && c.name.startsWith(program.name));
      const name = auto ? (title && title.toLowerCase() !== "omp" ? title : program?.name ?? "Terminal") : c.name;
      return h_flex().id(`tab-${c.id}`).h(29).px(10).gap(7).rounded(7).items_center().flex_none().text_size(12.8)
        .border(1).border_color(c.active ? t.border : t.chrome).bg(c.active ? t.raised : t.chrome).text_color(c.active ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover))
        .on_mouse_down("left", (e, cx) => { cx.stop_propagation(); this.pressed = i; if (e.click_count === 2) run("tab.rename", { id: c.id }); })
        .on_mouse_up("left", () => {
          const from = this.pressed; this.pressed = null;
          if (from !== null && from !== i) run("tab.move", { id: shown[from].id, index: space.tabs.findIndex(x => x.id === c.id) + 1 });
          else run("tab.select", { id: c.id });
        })
        .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); openOverlay({ mod: "menu", kind: "popup", width: 200, props: { tab: "tab", target: { id: c.id, space: space.id } } }); })
        .when(Boolean(program?.icon), el => el.child(program.tint ? svg(program.icon).size(14).text_color(t.muted) : image(program.icon).size(14)))
        .child(div().max_w(170).truncate().child(c.zoomed ? `${name} Z` : name))
        .when(c.status === "working", el => el.child(svg("mods/workspace-chrome/spinner.svg").size(12).flex_none().text_color(t.working).spin(900)))
        .when(c.status === "blocked" || c.status === "done", el => el.child(div().size(6).rounded(3).bg(t[c.status])))
        .when(c.active, el => el.child(div().id(`close-${c.id}`).text_color(t.dim).on_mouse_down("left", stop).on_click((_e, cx) => { cx.stop_propagation(); run("tab.close", { id: c.id }); }).child(svg("mods/pane/close.svg").size(12))));
    };
    const root = layout(), sidebar = find(root, "sidebar"), w = window();
    // Old saved rails and a dragged-narrow sidebar can be smaller than the window buttons.
    const lightsPadding = w?.platform === "macos" && w.titlebar === "none" && !w.fullscreen && root?.traffic_lights
      ? Math.max(10, (root.traffic_lights[0] + 64) / settings().zoom - (sidebar?.hidden ? 0 : sidebar?.size?.px ?? 0))
      : 10;
    const panel = find(root, "panel"), body = find(root, "panel-body");
    const routing = find(root, "routing"), prs = find(root, "prs"), today = find(root, "today"), auto = find(root, "automation"), rev = find(root, "review"), brk = find(root, "break");
    const enabled = shared("workspace.panels") ?? ["files", "changes"];
    this.syncPanel(space, panel, body, enabled);
    const panelButton = (id, label, icon) => {
      const on = panel && !panel.hidden && body?.active === id;
      return h_flex().id(`panel-${id}`).h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(on ? t.selected : t.chrome).text_color(on ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => {
          if (on) run("layout.hide", { id: "panel" });
          else { run("layout.select", { stack: "panel-body", child: id }); run("layout.show", { id: "panel" }); }
        }).child(svg(icon).size(14)).child(label);
    };
    return h_flex().size_full().min_w(0).px(10).pl(lightsPadding).gap(3).items_center().bg(t.chrome).border_b(1).border_color(t.border)
      .on_mouse_up("left", () => { this.pressed = null; })
      .on_scroll_wheel(e => { if (Math.abs(e.delta.y) >= 1) run(e.delta.y > 0 ? "tab.prev" : "tab.next"); })
      .child(h_flex().id("tab-scroll").flex_1().min_w(0).h_full().items_center().gap(3).overflow_x_scrollbar().children(shown.map(item)))
      .child(button("tab-new", "+", () => openOverlay({ mod: "acc-new-menu", kind: "popup", width: 250, height: 543 })))
      .when(enabled.includes("files"), el => el.child(panelButton("files", "Files", "mods/files/file.svg")))
      .when(enabled.includes("changes"), el => el.child(panelButton("changes", "Changes", "mods/changes/changes.svg")))
      .child(h_flex().id("panel-routing").h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(routing && !routing.hidden ? t.selected : t.chrome).text_color(routing && !routing.hidden ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => run("layout.toggle", { id: "routing" }))
        .child(routingGlyph(routing && !routing.hidden ? t.foreground : t.muted)).child("Routing"))
      .child(h_flex().id("panel-prs").h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(prs && !prs.hidden ? t.selected : t.chrome).text_color(prs && !prs.hidden ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => run("layout.toggle", { id: "prs" }))
        .child(prGlyph(prs && !prs.hidden ? t.foreground : t.muted)).child("PRs"))
      .child(h_flex().id("panel-review").h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(rev && !rev.hidden ? t.selected : t.chrome).text_color(rev && !rev.hidden ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => run("layout.toggle", { id: "review" }))
        .child(reviewGlyph(rev && !rev.hidden ? t.foreground : t.muted)).child("Review")
        .when((shared("review.count") ?? 0) > 0, el => el.child(div().min_w(16).h(15).px(4).flex().items_center().justify_center().rounded(8).text_size(9.5).font_semibold()
          .bg(t.accent).text_color(t.accent_foreground).child(String(shared("review.count"))))))
      .child(h_flex().id("panel-today").h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(today && !today.hidden ? t.selected : t.chrome).text_color(today && !today.hidden ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => run("layout.toggle", { id: "today" }))
        .child(todayGlyph(today && !today.hidden ? t.foreground : t.muted)).child("Tasks"))
      .child(h_flex().id("panel-automation").h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(auto && !auto.hidden ? t.selected : t.chrome).text_color(auto && !auto.hidden ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => run("layout.toggle", { id: "automation" }))
        .child(autoGlyph(auto && !auto.hidden ? t.foreground : t.muted)).child("Automation")
        .when(this.sym.running > 0, el => el.child(div().size(6).rounded(3).bg(t.working).flex_none().loop("opacity", { from: .3, to: 1, period: 1100 })))
        .when(!(this.sym.running > 0) && (shared("automation.new") ?? 0) > 0, el => el.child(div().size(6).rounded(3).flex_none().bg(t.accent))))
      .child(h_flex().id("panel-break").h(26).px(8).gap(5).flex_none().items_center().rounded(6)
        .text_size(12).bg(brk && !brk.hidden ? t.selected : t.chrome).text_color(brk && !brk.hidden ? t.foreground : t.muted)
        .hover(s => s.bg(t.hover)).on_mouse_down("left", stop)
        .on_click(() => run("layout.toggle", { id: "break" }))
        .child(breakGlyph(brk && !brk.hidden ? t.foreground : t.muted)).child("Break")
        .when(shared("break.state") === "playing", el => el.child(h_flex().h(16).gap(1).items_center().flex_none()
          .child(div().relative().top(0).h(14).flex().items_center().text_size(10.5).line_height(1).text_color(t.accent).loop("top", { from: 2, to: -2, period: 1500 }).loop("opacity", { from: .4, to: 1, period: 1500 }).child("♪"))
          .child(div().relative().top(0).h(14).flex().items_center().text_size(10.5).line_height(1).text_color(t.accent).loop("top", { from: -2, to: 2, period: 1900 }).loop("opacity", { from: 1, to: .4, period: 1900 }).child("♫"))))
        .when(shared("break.state") === "paused", el => el.child(div().h(14).flex().items_center().text_size(10.5).line_height(1).text_color(t.dim).child("♪"))))
      .when(w?.buttons, el => el.child(button("minimize", w.platform === "windows" ? svg("mods/tabs/win-min.svg").size(16) : "−", () => run("window.minimize")))
        .child(button("maximize", w.platform === "windows" ? svg(`mods/tabs/${w.maximized ? "win-restore" : "win-max"}.svg`).size(16) : "□", () => run("window.maximize")))
        .child(button("close-window", w.platform === "windows" ? svg("mods/tabs/win-close.svg").size(16) : svg("mods/pane/close.svg").size(13), () => run("window.close"))));
  }
}
