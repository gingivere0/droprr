// Droprr's styled QR code (design-system/droprr/qr-style.md). This is the reference implementation: the Windows and
// Apple renderers port it, so change them together. Needs vendor/qrcode.js.
(function (global) {
  "use strict";

  // design-system/droprr/qr-outline.json: in units of the outline's longest side, centered on (0, 0).
  const OUTLINE = [[-0.0844,-0.5],[-0.1287,-0.4935],[-0.1564,-0.4751],[-0.1914,-0.417],[-0.2431,-0.3524],[-0.3049,-0.2509],[-0.3077,-0.1836],[-0.2975,-0.0969],[-0.2984,-0.0489],[-0.3206,-0.0101],[-0.3418,0.0507],[-0.3482,0.1338],[-0.3768,0.2168],[-0.3796,0.2463],[-0.4304,0.3164],[-0.4479,0.3745],[-0.4377,0.4419],[-0.4091,0.4797],[-0.3704,0.4991],[-0.3298,0.5],[-0.2763,0.4926],[-0.2163,0.4622],[-0.184,0.4317],[-0.1195,0.3884],[-0.0595,0.3146],[0.0291,0.2638],[0.089,0.1836],[0.1342,0.1531],[0.1628,0.1218],[0.1896,0.1052],[0.2597,0.0839],[0.3971,0.095],[0.434,0.0839],[0.4479,0.0701],[0.446,0.0443],[0.4202,0.0157],[0.3464,-0.0295],[0.2689,-0.0637],[0.2006,-0.1218],[0.1444,-0.1218],[0.0586,-0.0996],[-0.0577,-0.1596],[-0.065,-0.1753],[-0.0623,-0.1882],[-0.03,-0.2482],[-0.0217,-0.3063],[-0.0226,-0.3782],[-0.0383,-0.4493],[-0.0613,-0.4732],[-0.0696,-0.4908]];
  const SIZE = 0.8; // the outline's longest side, as a share of the code
  const SHIFT = 0.07; // the outline sits this share of the code right of center, so its visual weight looks centered
  const GAP = 0.5;  // dark modules closer than this to the outline's edge are left out (in modules)
  const DOT = 0.95;  // dot diameter, in modules (0.8 scanned noticeably worse)
  const QUIET = 3;  // white margin, in modules

  // Rows and columns of the alignment pattern centers for a version.
  function alignment(version) {
    if (version === 1) return [];
    const count = Math.floor(version / 7) + 2;
    const step = version === 32 ? 26 : Math.floor((version * 4 + count * 2 + 1) / (count * 2 - 2)) * 2;
    const result = [6];
    for (let pos = 17 + version * 4 - 7; result.length < count; pos -= step) result.splice(1, 0, pos);
    return result;
  }

  // Function modules, which are always drawn: finders with separators and format information, timing, version
  // information, and alignment patterns.
  function functionModules(n) {
    const version = (n - 17) / 4;
    const marked = new Uint8Array(n * n);
    const mark = (r0, c0, rows, cols) => {
      for (let r = Math.max(0, r0); r < Math.min(n, r0 + rows); r++)
        for (let c = Math.max(0, c0); c < Math.min(n, c0 + cols); c++) marked[r * n + c] = 1;
    };
    mark(0, 0, 9, 9); mark(0, n - 8, 9, 8); mark(n - 8, 0, 8, 9);
    mark(6, 0, 1, n); mark(0, 6, n, 1);
    if (version >= 7) { mark(0, n - 11, 6, 3); mark(n - 11, 0, 3, 6); }
    const centers = alignment(version);
    for (const r of centers) for (const c of centers) {
      if ((r < 9 && c < 9) || (r < 9 && c > n - 10) || (r > n - 10 && c < 9)) continue;
      mark(r - 2, c - 2, 5, 5);
    }
    return marked;
  }

  function inside(x, y, poly) {
    let result = false;
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const [xi, yi] = poly[i], [xj, yj] = poly[j];
      if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) result = !result;
    }
    return result;
  }

  function edgeDistance(x, y, poly) {
    let best = Infinity;
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const [ax, ay] = poly[j], [bx, by] = poly[i];
      const dx = bx - ax, dy = by - ay;
      const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy || 1)));
      best = Math.min(best, Math.hypot(x - ax - t * dx, y - ay - t * dy));
    }
    return best;
  }

  const LIGHT = 0, OUTER = 1, INNER = 2, EYE = 3;

  // What to draw for each module of an n x n code: LIGHT, OUTER, INNER, or EYE (finder patterns).
  function classify(isDark, n) {
    const fixed = functionModules(n);
    const poly = OUTLINE.map(([x, y]) => [x * SIZE * n + n / 2 + SHIFT * n, y * SIZE * n + n / 2]);
    const kinds = new Uint8Array(n * n);
    for (let r = 0; r < n; r++) {
      for (let c = 0; c < n; c++) {
        if ((r < 7 && c < 7) || (r < 7 && c >= n - 7) || (r >= n - 7 && c < 7)) { kinds[r * n + c] = EYE; continue; }
        if (!isDark(r, c)) continue;
        const x = c + 0.5, y = r + 0.5;
        if (!fixed[r * n + c] && edgeDistance(x, y, poly) < GAP) continue;
        kinds[r * n + c] = inside(x, y, poly) ? INNER : OUTER;
      }
    }
    return kinds;
  }

  function luminance(hex) {
    const v = parseInt(hex.slice(1), 16);
    const channel = (x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4; };
    return 0.2126 * channel(v >> 16) + 0.7152 * channel((v >> 8) & 255) + 0.0722 * channel(v & 255);
  }

  // The theme's light-palette colors: outer is the accent; inner is the primary text, or the secondary text when the
  // accent is itself nearly black.
  function colors(accent = "#557A5C", textPrimary = "#15131C", secondaryText = "#4D7C0F") {
    return { outer: accent, inner: luminance(accent) < 0.05 ? secondaryText : textPrimary };
  }

  // The code as an SVG document.
  function svg(text, palette = colors()) {
    const qr = global.qrcode(0, "Q");
    qr.addData(text);
    qr.make();
    const n = qr.getModuleCount();
    const kinds = classify((r, c) => qr.isDark(r, c), n);
    const size = n + QUIET * 2;
    const dots = { [OUTER]: [], [INNER]: [] };
    for (let r = 0; r < n; r++) {
      for (let c = 0; c < n; c++) {
        const kind = kinds[r * n + c];
        if (kind === OUTER || kind === INNER) dots[kind].push(`M${c + QUIET + 0.5 - DOT / 2} ${r + QUIET + 0.5}a${DOT / 2} ${DOT / 2} 0 1 0 ${DOT} 0a${DOT / 2} ${DOT / 2} 0 1 0 -${DOT} 0`);
      }
    }
    const eyes = [[0, 0], [0, n - 7], [n - 7, 0]].map(([r, c]) => {
      const x = c + QUIET, y = r + QUIET;
      return `<rect x="${x}" y="${y}" width="7" height="7" rx="2.4" fill="${palette.outer}"/>` +
        `<rect x="${x + 1}" y="${y + 1}" width="5" height="5" rx="1.6" fill="#FFFFFF"/>` +
        `<rect x="${x + 2}" y="${y + 2}" width="3" height="3" rx="1" fill="${palette.outer}"/>`;
    }).join("");
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" shape-rendering="geometricPrecision">` +
      `<rect width="${size}" height="${size}" fill="#FFFFFF"/>` +
      `<path fill="${palette.outer}" d="${dots[OUTER].join("")}"/><path fill="${palette.inner}" d="${dots[INNER].join("")}"/>` +
      `${eyes}</svg>`;
  }

  // The code as a data: URL for an <img>.
  function dataURL(text, palette) {
    return "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg(text, palette));
  }

  global.DroprrQR = { OUTLINE, SIZE, SHIFT, GAP, alignment, functionModules, classify, colors, svg, dataURL, LIGHT, OUTER, INNER, EYE };
  if (typeof module === "object" && module.exports) module.exports = global.DroprrQR;
})(typeof self !== "undefined" ? self : globalThis);
