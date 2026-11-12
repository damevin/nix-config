import { View, div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input, EditorState, Editor } from "gpui-base";
import { exec, theme, notify, writeTextFile, home, props, closeOverlay, panes, run } from "herdr";

// Quick capture into the Obsidian vault's inbox, opened as a pane below (or as a dialog). ⌘↩ saves, ⌘⇧↩ saves and opens it in Obsidian, Esc drops it.
const VAULT = "~/Documents/observatory";
const VAULT_NAME = "observatory";
const INBOX = "00. inbox";

const p2 = (n) => String(n).padStart(2, "0");
const stamp = (d) => `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())} ${p2(d.getHours())}h${p2(d.getMinutes())}`;
// Obsidian refuses * " \ / < > : | ? # ^ [ ] in note names.
const clean = (s) => s.replace(/[*"\\/<>:|?#^[\]]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 120);

export default class Note extends View {
  init(_p, cx) {
    this.title = InputState.new({ placeholder: "Title (empty = first line or date)" });
    this.body = EditorState.new({ language: "markdown", soft_wrap: true, line_numbers: false, folding: false });
    this.handle = cx.focus_handle();
    this.title.focus();
  }

  // As a pane it closes its own pane; as a dialog, its overlay.
  close() {
    const overlay = props()?.overlay;
    if (overlay) return closeOverlay(overlay);
    const mine = panes().filter(p => p.mod === "acc-note");
    const pane = mine.find(p => p.focused) ?? mine[mine.length - 1];
    if (pane) run("pane.close", { pane: pane.pane });
  }

  async save(open) {
    if (this.saving) return;
    const text = this.body.value().replace(/\s+$/, "") + "\n";
    if (!text.trim()) return this.close();
    this.saving = true;
    const first = text.split("\n").find((l) => l.trim())?.replace(/^#+\s*/, "") ?? "";
    const base = clean(this.title.value()) || clean(first) || stamp(new Date());
    const dir = `${VAULT.replace(/^~/, home())}/${INBOX}`;
    // null = create only: an existing note is never overwritten, it gets " 2", " 3"…
    for (let i = 1; i < 50; i++) {
      const name = i === 1 ? base : `${base} ${i}`;
      try {
        await writeTextFile(`${dir}/${name}.md`, text, null);
        this.close();
        notify({ title: "Note saved", body: `${INBOX}/${name}`, level: "success", timeout: 3000 });
        if (open) exec("open", [`obsidian://open?vault=${VAULT_NAME}&file=${encodeURIComponent(`${INBOX}/${name}`)}`]);
        return;
      } catch { /* taken: try the next suffix */ }
    }
    this.saving = false;
    notify({ title: "Note not saved", body: `Could not write to ${dir}`, level: "error" });
  }

  render() {
    const t = theme();
    const button = (id, label, hint, action) => h_flex().id(id).h(28).px(10).gap(8).rounded(6).items_center()
      .bg(t.raised).border(1).border_color(t.border).hover((s) => s.bg(t.hover)).on_click(action)
      .child(label).child(div().text_size(11).text_color(t.dim).child(hint));
    return v_flex().size_full().bg(t.popover).p(14).gap(10).text_size(13).text_color(t.foreground)
      .id("acc-note").track_focus(this.handle)
      .on_key_down((e) => {
        if (e.key === "escape") return this.close();
        if (e.key !== "enter" || !e.modifiers.platform) return;
        this.save(e.modifiers.shift);
      })
      .child(div().h(32).px(8).rounded(6).border(1).border_color(t.border).flex().items_center()
        .child(Input.new(this.title).w_full().text_size(15)))
      .child(div().flex_1().min_h(0).rounded(6).border(1).border_color(t.border).overflow_hidden()
        .child(Editor.new(this.body).size_full()))
      .child(h_flex().gap(8).items_center()
        .child(div().flex_1().text_size(11).text_color(t.dim).child(`→ ${INBOX}/`))
        .child(button("open", "Save and open", "⌘⇧↩", () => this.save(true)))
        .child(button("save", "Save", "⌘↩", () => this.save(false))));
  }
}
