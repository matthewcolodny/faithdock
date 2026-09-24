/* Generate the app icon PNGs from the FaithDock mark.
 *
 * WHY THIS EXISTS. The PNGs in icons/ used to be binaries with no
 * source: if one needed regenerating at a new size, the only route was
 * to render it somewhere and move the bytes across by hand, which went
 * wrong once already -- a transcribed icon arrived with its bottom half
 * transparent and still passed as a valid PNG. This script is the
 * source. Run it and the bytes are reproducible.
 *
 * NO DEPENDENCIES ON PURPOSE. It carries its own polygon rasteriser and
 * its own PNG writer, because the alternative is an image library and a
 * node_modules tree in a repo that is otherwise a couple of static
 * files. zlib is the only thing it needs and that is built into Node.
 *
 * IT IS NOT AN SVG RENDERER. It knows this one piece of artwork and
 * nothing else. The geometry below is transcribed from icons/icon.svg
 * and the two have to be kept in step by hand.
 *
 *   node tools/make-icon.js
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const NAVY = [0x1A, 0x2A, 0x49];
const GOLD = [0xC9, 0xA2, 0x27];
const VB = 172.84;               // the artwork's own coordinate space

// ---------------------------------------------------------------------
// The artwork, as polygons in viewBox coordinates.
// ---------------------------------------------------------------------
// Two fills, matching the two path elements in icon.svg.
//
// The sail is fill-rule evenodd over three subpaths: an outer triangle
// and two bars. The bars sit inside the triangle, so evenodd punches
// them out as a cross-shaped hole; the vertical bar runs on past the
// triangle's base, and that overhang is outside the triangle, so the
// same rule fills it instead. That overhang is the mast.
//
// The bars are written in the SVG with smooth-cubic commands whose
// control points are degenerate (s12.45,0,12.45,0). They are straight
// edges, so they are plain rectangles here.

const sail = {
  rule: 'evenodd',
  subpaths: [
    // The sail itself.
    [[35.68, 122.45], [89.09, 17.75], [138.20, 122.45]],
    // Upright of the cross, overrunning the base to become the mast.
    [[81.67, 60.71], [94.12, 60.71], [94.12, 135.17], [81.67, 135.17]],
    // Crossbar.
    [[60.93, 80.30], [114.86, 80.30], [114.86, 92.06], [60.93, 92.06]]
  ]
};

// Subdivide a cubic into line segments. 64 is far more than enough at
// these sizes: the curve spans about 130 units, so each segment stays
// well under a pixel even at 512.
function flattenCubic(p0, c1, c2, p3, steps) {
  steps = steps || 64;
  const pts = [];
  for (let i = 0; i <= steps; i++) {
    const t = i / steps, u = 1 - t;
    const a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    pts.push([
      a * p0[0] + b * c1[0] + c * c2[0] + d * p3[0],
      a * p0[1] + b * c1[1] + c * c2[1] + d * p3[1]
    ]);
  }
  return pts;   // closing the subpath back to p0 gives the flat waterline
}

// The hull: one cubic, then straight back along the waterline.
const hull = {
  rule: 'nonzero',
  subpaths: [
    flattenCubic([20.64, 130.74], [95.44, 162.63], [86.12, 161.99], [153.16, 130.74])
  ]
};

// ---------------------------------------------------------------------
// Rasteriser: scanline coverage, exact in x, supersampled in y.
// ---------------------------------------------------------------------
// For each output row we take SUBY evenly spaced sample lines, find
// where the edges cross each one, and fill the spans between crossings.
// Coverage in x is accumulated as a real number rather than sampled, so
// a span ending a third of the way into a pixel contributes a third.
// That is why the diagonal sail edges come out clean without needing a
// large sample count.
const SUBY = 8;

function coverage(size, shapes, scale) {
  const cov = new Float32Array(size * size);
  // Artwork space to pixel space: fit the viewBox to the canvas, then
  // scale about the centre by `scale` to leave a margin.
  const k = (size / VB) * scale;
  const off = size / 2 - (VB / 2) * k;
  const map = p => [p[0] * k + off, p[1] * k + off];

  for (const shape of shapes) {
    // Flatten every subpath into one edge list. Both fill rules treat
    // the subpaths as a single set of edges; only the test at the end
    // differs.
    const edges = [];
    for (const sub of shape.subpaths) {
      const pts = sub.map(map);
      for (let i = 0; i < pts.length; i++) {
        const a = pts[i], b = pts[(i + 1) % pts.length];
        if (a[1] !== b[1]) edges.push([a, b]);   // horizontals never cross a scanline
      }
    }

    for (let y = 0; y < size; y++) {
      for (let s = 0; s < SUBY; s++) {
        const sy = y + (s + 0.5) / SUBY;
        // Crossings on this sample line, each carrying a winding
        // direction for the nonzero rule.
        const xs = [];
        for (const e of edges) {
          const x0 = e[0][0], y0 = e[0][1], x1 = e[1][0], y1 = e[1][1];
          if ((sy >= y0 && sy < y1) || (sy >= y1 && sy < y0)) {
            xs.push([x0 + (sy - y0) / (y1 - y0) * (x1 - x0), y1 > y0 ? 1 : -1]);
          }
        }
        if (xs.length < 2) continue;
        xs.sort((p, q) => p[0] - q[0]);

        let wind = 0;
        for (let i = 0; i < xs.length - 1; i++) {
          wind += xs[i][1];
          const inside = shape.rule === 'evenodd' ? ((i % 2) === 0) : (wind !== 0);
          if (inside) addSpan(cov, size, y, xs[i][0], xs[i + 1][0], 1 / SUBY);
        }
      }
    }
  }
  return cov;
}

// Add `weight` of coverage to row `y` between x0 and x1, splitting the
// partial pixels at each end by how much of them the span really covers.
function addSpan(cov, size, y, x0, x1, weight) {
  if (x1 <= x0) return;
  x0 = Math.max(0, x0);
  x1 = Math.min(size, x1);
  if (x1 <= x0) return;
  const row = y * size;
  const last = Math.min(size - 1, Math.ceil(x1) - 1);
  for (let px = Math.floor(x0); px <= last; px++) {
    const l = Math.max(x0, px), r = Math.min(x1, px + 1);
    if (r > l) cov[row + px] += (r - l) * weight;
  }
}

// ---------------------------------------------------------------------
// PNG writer: 8-bit truecolour, no alpha.
// ---------------------------------------------------------------------
// No alpha is deliberate. iOS composites a transparent home-screen icon
// onto white, which is how the icon first ended up as a navy mark in a
// white rounded card. Everything this produces is fully opaque, so
// there is nothing for anything to composite against.

function crc32(buf) {
  let table = crc32.t, c;
  if (!table) {
    table = crc32.t = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      c = n;
      for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      table[n] = c;
    }
  }
  c = -1;
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePng(size, rgb) {
  // Filter byte 0 (none) in front of every row. The image is two flat
  // colours and the blend between them, so it compresses to almost
  // nothing regardless; choosing better filters per row would save
  // bytes nobody would notice.
  const stride = size * 3 + 1;
  const raw = Buffer.alloc(size * stride);
  for (let y = 0; y < size; y++) {
    raw[y * stride] = 0;
    rgb.copy(raw, y * stride + 1, y * size * 3, (y + 1) * size * 3);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;    // bit depth
  ihdr[9] = 2;    // colour type 2 = truecolour, no alpha
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

// ---------------------------------------------------------------------

function render(size, scale) {
  const cov = coverage(size, [sail, hull], scale);
  const rgb = Buffer.alloc(size * size * 3);
  for (let i = 0; i < size * size; i++) {
    const a = Math.min(1, cov[i]);
    for (let ch = 0; ch < 3; ch++) {
      rgb[i * 3 + ch] = Math.round(NAVY[ch] + (GOLD[ch] - NAVY[ch]) * a);
    }
  }
  return encodePng(size, rgb);
}

// 512 is the size Chrome wants for the splash screen it generates. Give
// it only a 192 and it upscales, which is what was reported as the mark
// looking pixelated on Android.
//
// The two scales are the same distinction as the two SVGs. 80% keeps a
// margin inside a square that is shown whole, matching the 192 and the
// apple-touch icon already shipping. 62% is for the maskable copy,
// which Android crops to whatever shape its launcher uses -- only the
// middle 80% of that is guaranteed to survive, so the mark is pulled in
// far enough that a circular crop cannot clip the sail.
const targets = [
  { file: 'icon-512.png',          size: 512, scale: 0.80 },
  { file: 'icon-512-maskable.png', size: 512, scale: 0.62 }
];

const dir = path.join(__dirname, '..', 'icons');
for (const t of targets) {
  const png = render(t.size, t.scale);
  fs.writeFileSync(path.join(dir, t.file), png);
  console.log(t.file + '  ' + t.size + 'x' + t.size + '  ' + png.length + ' bytes');
}
