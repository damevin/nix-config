import { PathBuilder } from "gpui-kit";

export const PALETTE = ["#d97757", "#bd8638", "#a59234", "#849e4a", "#5aa66c", "#25a98f", "#00a6b0", "#2e9fc9", "#5e95d7", "#858ad7", "#a47fca", "#bb77b1"];
const HUES = { claude: 0, codex: 9, gemini: 7, copilot: 10, cursor: 5, opencode: 2, crush: 11, goose: 3, pi: 4, omp: 11, omo: 10, dsh: 6, commandcode: 1, mimocode: 8, deveco: 7 };
export const RED = "#e5534b";

export function hueOf(id, given, near) {
  let c = given.get(id);
  if (c && !near?.has(c)) return c;
  let h = HUES[id];
  if (h == null) { h = 0; for (const ch of String(id || "")) h = (h * 31 + ch.charCodeAt(0)) >>> 0; }
  const had = new Set(given.values()), from = (k) => PALETTE[(h + k) % PALETTE.length], ks = [...PALETTE.keys()];
  c = from(ks.find((k) => !had.has(from(k)) && !near?.has(from(k))) ?? ks.find((k) => !near?.has(from(k))) ?? 0);
  given.set(id, c);
  return c;
}

export function alpha(c, a) {
  const m = /^#([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(c);
  if (!m) return c;
  const base = m[2] ? parseInt(m[2], 16) / 255 : 1;
  return `#${m[1]}${Math.round(Math.max(0, Math.min(1, a * base)) * 255).toString(16).padStart(2, "0")}`;
}

function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx, cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const X = (t) => ((ax * t + bx) * t + cx) * t, Y = (t) => ((ay * t + by) * t + cy) * t;
  return (x) => {
    let lo = 0, hi = 1, t = x;
    for (let i = 0; i < 30; i++) { t = (lo + hi) / 2; if (X(t) < x) lo = t; else hi = t; }
    return Y(t);
  };
}
const flapEase = bezier(.45, 0, .3, 1);
const liftEase = bezier(.3, 0, .2, 1);
const outEase = (k) => 1 - (1 - k) * (1 - k);

export function flatten(d) {
  const n = d.match(/[A-Za-z]|-?\d+\.?\d*/g), pts = [];
  let c = "", i = 0;
  while (i < n.length) {
    if (/[A-Za-z]/.test(n[i])) { c = n[i++]; if (c === "Z") continue; }
    if (c === "M" || c === "L") { pts.push([+n[i], +n[i + 1]]); i += 2; if (c === "M") c = "L"; }
    else if (c === "C") {
      const [x1, y1, x2, y2, x3, y3] = n.slice(i, i + 6).map(Number), [x0, y0] = pts[pts.length - 1];
      for (let s = 1; s <= 10; s++) {
        const t = s / 10, u = 1 - t;
        pts.push([u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3, u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3]);
      }
      i += 6;
    } else i++;
  }
  return pts;
}
const ellipse = (cx, cy, rx, ry) => Array.from({ length: 28 }, (_, k) => [cx + rx * Math.cos(k / 28 * 2 * Math.PI), cy + ry * Math.sin(k / 28 * 2 * Math.PI)]);

const FAR = flatten("M-14.5 -3.4C-16.5 -9.5 -14.2 -15 -8.6 -18.6C-9.4 -12.6 -9.6 -7.4 -9.2 -3.2Z");
const NEAR = flatten("M-15.6 -3.2C-17.8 -10.2 -15.2 -16.4 -8.4 -20.4C-9.3 -13.6 -9.4 -7.8 -8.8 -2.8Z");
const BAR = flatten("M-14.6 -5.6C-15.4 -10.4 -13.8 -14.4 -10.4 -17.2");
const TAIL = flatten("M-31.5 3.1L-18.6 -1.8L-17.4 1.2L-30.8 4.6Z");
const BODY = ellipse(-12.2, -1.4, 7.6, 3.9);
const BELLY = ellipse(-12.8, .4, 4.3, 1.6);
const HEAD = ellipse(-4.9, -3.7, 3.1, 3.1);
const BEAK = flatten("M-2.3 -4.8L1.4 -3.3L-2.3 -2.2Z");
const box = (...sets) => {
  const all = sets.flat();
  const xs = all.map((p) => p[0]), ys = all.map((p) => p[1]);
  return [(Math.min(...xs) + Math.max(...xs)) / 2, Math.max(...ys)];
};
const FAR_O = box(FAR), NEAR_O = box(NEAR, BAR);

const FLAP = 420;
function wingAt(ms, delay) {
  const ph = (((ms - delay) % FLAP) + FLAP) % FLAP / FLAP;
  if (ph < .55) { const e = flapEase(ph / .55); return [1 - 1.62 * e, -8 * e]; }
  const e = flapEase((ph - .55) / .45);
  return [-.62 + 1.62 * e, -8 * (1 - e)];
}
const flap = (pts, o, a, k) => {
  const t = Math.tan(k * Math.PI / 180);
  return pts.map(([x, y]) => [o[0] + (x - o[0]) + t * (y - o[1]), o[1] + a * (y - o[1])]);
};

export function newBird(kind, now) {
  return { kind, born: now, awayAt: null, flip: false, a: undefined, vx: 1, x: 0, y: 0, placed: false };
}
export const AWAY_MS = 450;

export function drawBird(b, now, c) {
  if (!b.placed) return [];
  const come = Math.min(1, (now - b.born) / 300);
  let ls = 1, lx = 0, ly = 0, op = 1;
  if (come < 1) { const e = outEase(come); ls = .85 + .15 * e; lx = -6 * (1 - e); ly = -10 * (1 - e); op = e; }
  if (b.awayAt != null) {
    const e = liftEase(Math.min(1, (now - b.awayAt) / AWAY_MS));
    ls = 1 + (.8 - 1) * e; lx = 14 * e; ly = -16 * e; op = 1 - e;
  }
  const cos = Math.cos((b.a || 0) * Math.PI / 180), sin = Math.sin((b.a || 0) * Math.PI / 180), fl = b.flip ? -1 : 1;
  const X = (p) => {
    const bx = 1.2 * (p[0] - 6.5), by = 1.2 * (p[1] + 3.2), lxp = ls * bx + lx, lyp = ls * by + ly;
    return [b.x + fl * (lxp * cos - lyp * sin), b.y + (lxp * sin + lyp * cos)];
  };
  const fill = (pts, col) => window.paint_path(PathBuilder.fill().add_polygon(pts.map(X), true).build(), alpha(col, op));
  const far = wingAt(now - b.born, -30), near = wingAt(now - b.born, 0);
  const farW = flap(FAR, FAR_O, far[0], far[1]), nearW = flap(NEAR, NEAR_O, near[0], near[1]), bar = flap(BAR, NEAR_O, near[0], near[1]).map(X);
  const barPath = PathBuilder.stroke(1.3 * 1.2 * ls).move_to(bar[0][0], bar[0][1]);
  for (let i = 1; i < bar.length; i++) barPath.line_to(bar[i][0], bar[i][1]);
  return [
    fill(farW, alpha(c.fg, .45)), fill(TAIL, c.fg), fill(BODY, c.fg), fill(BELLY, c.card), fill(HEAD, c.fg), fill(BEAK, c.fg),
    fill(nearW, c.fg), window.paint_path(barPath.build(), alpha(c.card, op)),
  ];
}

export function disk(x, y, r) { return Array.from({ length: 20 }, (_, k) => [x + r * Math.cos(k / 20 * 2 * Math.PI), y + r * Math.sin(k / 20 * 2 * Math.PI)]); }
export const heldFade = (now) => 1 - .55 * (1 - Math.cos(2 * Math.PI * (now % 1200) / 1200)) / 2;

export function makePath(points) {
  const xs = points.map((p) => p[0]), ys = points.map((p) => p[1]), cum = [0];
  for (let i = 1; i < xs.length; i++) cum.push(cum[i - 1] + Math.hypot(xs[i] - xs[i - 1], ys[i] - ys[i - 1]));
  return { xs, ys, cum, L: cum[cum.length - 1] };
}
export function wireBezier(x1, y1, x2, y2) {
  const mx = (x1 + x2) / 2, pts = [];
  for (let s = 0; s <= 60; s++) {
    const t = s / 60, u = 1 - t;
    pts.push([u * u * u * x1 + 3 * u * u * t * mx + 3 * u * t * t * mx + t * t * t * x2, u * u * u * y1 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y2]);
  }
  return makePath(pts);
}
export function viaBezier(a, b, top) {
  const k = a.x <= b.x ? 1 : -1, pts = [];
  for (let s = 0; s <= 24; s++) {
    const t = s / 24, u = 1 - t, c1x = a.x + 18 * k, c2x = b.x - 18 * k;
    pts.push([u * u * u * a.x + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * b.x, u * u * u * a.y + 3 * u * u * t * (top - 10) + 3 * u * t * t * (top - 10) + t * t * t * b.y]);
  }
  return makePath(pts);
}
export function pointAt(p, s) {
  s = Math.max(0, Math.min(p.L, s));
  let lo = 0, hi = p.cum.length - 1;
  while (hi - lo > 1) { const m = (lo + hi) >> 1; if (p.cum[m] <= s) lo = m; else hi = m; }
  const f = p.cum[hi] > p.cum[lo] ? (s - p.cum[lo]) / (p.cum[hi] - p.cum[lo]) : 0;
  return { x: p.xs[lo] + (p.xs[hi] - p.xs[lo]) * f, y: p.ys[lo] + (p.ys[hi] - p.ys[lo]) * f };
}
export function slice(p, a, b) {
  const pts = [], n = Math.max(2, Math.ceil((b - a) / 2));
  for (let i = 0; i <= n; i++) { const q = pointAt(p, a + (b - a) * i / n); pts.push(q); }
  return pts;
}
export function dashed(p, phase, on, off, width, color) {
  const period = on + off, b = PathBuilder.stroke(width);
  let any = false;
  for (let s = phase - period; s < p.L; s += period) {
    const a = Math.max(0, s), e = Math.min(p.L, s + on);
    if (e - a < .25) continue;
    const pts = slice(p, a, e);
    b.move_to(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length; i++) b.line_to(pts[i].x, pts[i].y);
    any = true;
  }
  return any ? window.paint_path(b.build(), color) : null;
}
export function solid(p, width, color) {
  const b = PathBuilder.stroke(width).move_to(p.xs[0], p.ys[0]);
  for (let i = 1; i < p.xs.length; i++) b.line_to(p.xs[i], p.ys[i]);
  return window.paint_path(b.build(), color);
}
