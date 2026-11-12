// osascript -l JavaScript frame.js [TERN_PID]
// Prints the Tern window that hosts the break panel as JSON: its screen rect (points, top-left
// origin), its window id, the main screen's scale and menu bar height. With a pid it prefers that
// process's window, else the largest Tern window.
ObjC.import("CoreGraphics");
ObjC.import("AppKit");

function run(argv) {
  const pid = Number(argv[0] || 0);
  const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
  let best = null;
  for (let i = 0; i < list.count; i++) {
    const w = list.objectAtIndex(i);
    if (ObjC.unwrap(w.objectForKey("kCGWindowOwnerName")) !== "Tern" || ObjC.unwrap(w.objectForKey("kCGWindowLayer")) !== 0) continue;
    const b = w.objectForKey("kCGWindowBounds");
    const f = {
      id: ObjC.unwrap(w.objectForKey("kCGWindowNumber")),
      pid: ObjC.unwrap(w.objectForKey("kCGWindowOwnerPID")),
      x: ObjC.unwrap(b.objectForKey("X")), y: ObjC.unwrap(b.objectForKey("Y")),
      w: ObjC.unwrap(b.objectForKey("Width")), h: ObjC.unwrap(b.objectForKey("Height")),
    };
    f.mine = pid !== 0 && f.pid === pid;
    if (!best || (f.mine && !best.mine) || (f.mine === best.mine && f.w * f.h > best.w * best.h)) best = f;
  }
  const screen = $.NSScreen.mainScreen, full = screen.frame, visible = screen.visibleFrame;
  if (best) {
    best.scale = screen.backingScaleFactor;
    best.top = full.size.height - (visible.origin.y + visible.size.height);
  }
  return JSON.stringify(best);
}
