import { View, div } from "gpui-kit";
import { v_flex, h_flex, TextView } from "gpui-base";
import { exec, theme, readTextFile, notify, props, home } from "herdr";

const fromSlack = (s) => s
  .replace(/^\*([^*\n]+)\*\s*$/gm, "### $1")
  .replace(/(^|[^*\w])\*([^*\n]+?)\*(?![*\w])/g, "$1**$2**")
  .replace(/^(\s*)[•◦▪]\s+/gm, "$1- ")
  .replace(/<(https?:[^|>]+)\|([^>]+)>/g, "[$2]($1)")
  .replace(/(^|\s)(https?:\/\/[^\s)]+)/g, (_m, pre, url) => `${pre}[${short(url)}](${url})`);

function short(url) {
  if (/slack\.com\/archives\//.test(url)) return "thread";
  const pr = /github\.com\/[^/]+\/[^/]+\/pull\/(\d+)/.exec(url);
  if (pr) return `PR #${pr[1]}`;
  const lin = /linear\.app\/.*\/issue\/([A-Z]+-\d+)/.exec(url);
  if (lin) return lin[1];
  return url.replace(/^https?:\/\/(www\.)?/, "").split("/")[0];
}

export default class Markdown extends View {
  init(_p, cx) {
    this.file = String(props()?.file ?? "").replace(/^~/, home());
    this.text = null; this.copied = false;
    this.load(cx);
    cx.timer.every(2000, (cx) => this.load(cx));
  }

  load(cx) {
    cx.spawn(async (cx) => {
      const text = this.file ? await readTextFile(this.file).catch(() => null) : null;
      if (text !== this.text) { this.text = text; cx.notify(); }
    });
  }

  copy(cx) {
    exec("sh", ["-c", `pbcopy < "${this.file}"`]).then((r) => {
      if (r.code !== 0) { notify({ title: "Copy failed", level: "error" }); return; }
      this.copied = true; cx.notify();
      cx.timer.after(1600, (cx) => { this.copied = false; cx.notify(); });
    });
  }

  button(t, id, label, onClick, primary) {
    return div().id(id).h(24).px(10).flex().items_center().rounded(7).flex_none().text_size(11).font_semibold()
      .bg(primary ? t.solid : t.raised).text_color(primary ? t.solid_foreground : t.foreground).border_1().border_color(primary ? t.solid : t.border)
      .hover((s) => s.opacity(.9)).on_click(onClick).child(label);
  }

  render() {
    const t = theme(), name = this.file.split("/").slice(-2).join(" / ");
    return v_flex().size_full().bg(t.background)
      .child(h_flex().h(40).px(14).gap(8).items_center().border_b(1).border_color(t.border).flex_none()
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.muted).child(name || "No file"))
        .child(this.button(t, "md-edit", "Edit", () => exec("open", ["-t", this.file])))
        .child(this.button(t, "md-copy", this.copied ? "Copied ✓" : "Copy", (_e, cx) => this.copy(cx), true)))
      .child(this.text === null
        ? div().p(20).text_size(12).text_color(t.muted).child("This file is not available.")
        : div().id("md-scroll").flex_1().min_h(0).overflow_y_scrollbar().px(22).py(18)
          .child(TextView.markdown("md-body", fromSlack(this.text)).selectable(true).text_size(13.5).text_color(t.foreground)
            .on_link_click((url) => exec("open", [url]))));
  }
}
