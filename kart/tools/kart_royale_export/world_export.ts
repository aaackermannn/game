// Exports kart-royale's Sunset Bay circuit for Godot:
//   track.glb        road, kerbs, shoulders, terrain, walls, tunnel, bridge (also used for collision)
//   scenery.glb      village, harbour, crowd, trees, props (instances merged)
//   track_data.json  centreline stations (every 2 m) + start grid + boost pads
import './shim_real';
import * as THREE from 'three';
import * as fs from 'node:fs';
import { GLTFExporter } from 'three/examples/jsm/exporters/GLTFExporter.js';
import { mergeVertices } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import { Track } from '../kr-src/kart-royale-main/src/world/Track';
import { Scenery } from '../kr-src/kart-royale-main/src/world/Scenery';
import { BOOST_PADS, SEA_Y } from '../kr-src/kart-royale-main/src/world/TrackLayout';
import { makeCtx } from './world_ctx';

const OUT = process.argv[2];
// Fake blob shadows, the far-field sea and alpha-card clutter add nothing in the comic look.
const SKIP = /^(shadow|sea-surface|track-sea-fallback|kartImpostor)$/;

function meshMat(m: THREE.Mesh): any {
  return Array.isArray(m.material) ? m.material[0] : m.material;
}

// --- texture baking -------------------------------------------------------------
// Each texture is box-filtered down to 32x32 so the baked colour is the local
// average hue (comic flats), not per-pixel noise.
const TEX_N = 32;
const texCache = new Map<string, Float32Array | null>();
function texGrid(tex: THREE.Texture | null | undefined): Float32Array | null {
  if (!tex) return null;
  if (texCache.has(tex.uuid)) return texCache.get(tex.uuid)!;
  let out: Float32Array | null = null;
  try {
    const img: any = (tex as any).image;
    let data: Uint8ClampedArray | null = null, w = 0, h = 0;
    if (img && typeof img.getContext === 'function') {
      w = img.width; h = img.height;
      data = img.getContext('2d').getImageData(0, 0, w, h).data;
    } else if (img && img.data && img.width) {
      w = img.width; h = img.height; data = img.data;
    }
    if (data && w > 0 && h > 0) {
      out = new Float32Array(TEX_N * TEX_N * 3);
      const cnt = new Float32Array(TEX_N * TEX_N);
      const sx = Math.max(1, Math.floor(w / 256)), sy = Math.max(1, Math.floor(h / 256));
      for (let y = 0; y < h; y += sy) for (let x = 0; x < w; x += sx) {
        const gi = Math.min(TEX_N - 1, (y * TEX_N / h) | 0) * TEX_N + Math.min(TEX_N - 1, (x * TEX_N / w) | 0);
        const pi = (y * w + x) * 4;
        // sRGB -> linear, to match vertex colours
        out[gi * 3] += srgbToLin(data[pi] / 255); out[gi * 3 + 1] += srgbToLin(data[pi + 1] / 255); out[gi * 3 + 2] += srgbToLin(data[pi + 2] / 255);
        cnt[gi]++;
      }
      for (let i = 0; i < TEX_N * TEX_N; i++) if (cnt[i] > 0) { out[i * 3] /= cnt[i]; out[i * 3 + 1] /= cnt[i]; out[i * 3 + 2] /= cnt[i]; }
      // Data textures that are not colour (normal maps etc.) are never passed here.
    }
  } catch { out = null; }
  texCache.set(tex.uuid, out);
  return out;
}
function srgbToLin(c: number) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
function wrap(v: number, mode: number) {
  if (mode === THREE.ClampToEdgeWrapping) return Math.min(0.9999, Math.max(0, v));
  return v - Math.floor(v);
}

/** World-space copy of a mesh (instances expanded) with baked colour = vertex colour x material colour x texture x tint. */
function flatten(m: THREE.Mesh): THREE.BufferGeometry | null {
  const src = m.geometry as THREE.BufferGeometry;
  if (!src.getAttribute('position')) return null;
  const mat = meshMat(m);
  const matCol: THREE.Color = mat && mat.color ? mat.color : new THREE.Color(1, 1, 1);
  const map: THREE.Texture | null = mat && mat.map ? mat.map : null;
  const grid = texGrid(map);
  if (map) map.updateMatrix();
  const tm = map ? map.matrix.elements : null;
  let cacheKey = '';
  try { cacheKey = mat && mat.customProgramCacheKey ? String(mat.customProgramCacheKey()) : ''; } catch { cacheKey = ''; }
  const tintMasked = cacheKey.includes('tintM');

  const base = src.index ? src.toNonIndexed() : src;
  const P = base.getAttribute('position') as THREE.BufferAttribute;
  let Nrm = base.getAttribute('normal') as THREE.BufferAttribute | undefined;
  if (!Nrm) { base.computeVertexNormals(); Nrm = base.getAttribute('normal') as THREE.BufferAttribute; }
  const UV = base.getAttribute('uv') as THREE.BufferAttribute | undefined;
  const VC = base.getAttribute('color') as THREE.BufferAttribute | undefined;
  const aTint = base.getAttribute('aTint') as any;
  const aUv = base.getAttribute('aUv') as any;
  const n = P.count;

  const inst = m as THREE.InstancedMesh;
  const count = inst.isInstancedMesh ? inst.count : 1;
  const outP = new Float32Array(n * count * 3), outN = new Float32Array(n * count * 3), outC = new Float32Array(n * count * 3);
  const M = new THREE.Matrix4(), W = new THREE.Matrix4(), NM = new THREE.Matrix3();
  const v = new THREE.Vector3(), nv = new THREE.Vector3(), ic = new THREE.Color();
  for (let k = 0; k < count; k++) {
    if (inst.isInstancedMesh) { inst.getMatrixAt(k, M); W.multiplyMatrices(m.matrixWorld, M); }
    else W.copy(m.matrixWorld);
    NM.getNormalMatrix(W);
    let ir = 1, ig = 1, ib = 1;
    if (inst.isInstancedMesh && inst.instanceColor) { inst.getColorAt(k, ic); ir = ic.r; ig = ic.g; ib = ic.b; }
    const instTint = aTint && aTint.isInstancedBufferAttribute;
    const instUv = aUv && aUv.isInstancedBufferAttribute;
    for (let i = 0; i < n; i++) {
      const o = (k * n + i) * 3;
      v.fromBufferAttribute(P, i).applyMatrix4(W);
      nv.fromBufferAttribute(Nrm, i).applyMatrix3(NM).normalize();
      outP[o] = v.x; outP[o + 1] = v.y; outP[o + 2] = v.z;
      outN[o] = nv.x; outN[o + 1] = nv.y; outN[o + 2] = nv.z;
      let r = matCol.r * ir, gg = matCol.g * ig, b = matCol.b * ib;
      if (VC) { r *= VC.getX(i); gg *= VC.getY(i); b *= VC.getZ(i); }
      if (grid && UV) {
        let u = UV.getX(i), w = UV.getY(i);
        if (tm) { const uu = tm[0] * u + tm[3] * w + tm[6]; const ww = tm[1] * u + tm[4] * w + tm[7]; u = uu; w = ww; }
        if (aUv) {
          const j = instUv ? k : i;
          u = u * aUv.getX(j) + aUv.getZ(j); w = w * aUv.getY(j) + aUv.getW(j);
        }
        u = wrap(u, map!.wrapS); w = wrap(w, map!.wrapT);
        // canvas textures have flipY = true: v=0 is the bottom row
        const gx = Math.min(TEX_N - 1, (u * TEX_N) | 0);
        const gy = Math.min(TEX_N - 1, (((map!.flipY ? 1 - w : w) * TEX_N) | 0));
        const gi = (gy * TEX_N + gx) * 3;
        r *= grid[gi]; gg *= grid[gi + 1]; b *= grid[gi + 2];
      }
      if (aTint) {
        const j = instTint ? k : i;
        let tr = aTint.getX(j), tg = aTint.getY(j), tb = aTint.getZ(j);
        if (tintMasked && UV) { const mk = Math.min(1, Math.max(0, UV.getX(i))); tr = 1 + (tr - 1) * mk; tg = 1 + (tg - 1) * mk; tb = 1 + (tb - 1) * mk; }
        r *= tr; gg *= tg; b *= tb;
      }
      outC[o] = r; outC[o + 1] = gg; outC[o + 2] = b;
    }
  }
  // Degenerate source normals / tints can produce NaN, which makes the glTF invalid.
  let fixed = 0;
  for (let i = 0; i < outP.length; i += 3) {
    if (!Number.isFinite(outN[i]) || !Number.isFinite(outN[i + 1]) || !Number.isFinite(outN[i + 2])) { outN[i] = 0; outN[i + 1] = 1; outN[i + 2] = 0; fixed++; }
    for (let c = 0; c < 3; c++) if (!Number.isFinite(outC[i + c])) { outC[i + c] = 1; fixed++; }
    for (let c = 0; c < 3; c++) if (!Number.isFinite(outP[i + c])) { outP[i + c] = 0; fixed++; }
  }
  if (fixed) console.log('  sanitised', fixed, 'NaN values in', m.name);
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(outP, 3));
  g.setAttribute('normal', new THREE.BufferAttribute(outN, 3));
  g.setAttribute('color', new THREE.BufferAttribute(outC, 3));
  return g;
}

function merge(parts: THREE.BufferGeometry[]): THREE.BufferGeometry {
  if (parts.length === 1) return parts[0];
  let n = 0;
  for (const p of parts) n += p.getAttribute('position').count;
  const P = new Float32Array(n * 3), N = new Float32Array(n * 3), C = new Float32Array(n * 3);
  let o = 0;
  for (const p of parts) {
    const c = p.getAttribute('position').count;
    P.set((p.getAttribute('position') as THREE.BufferAttribute).array as Float32Array, o * 3);
    N.set((p.getAttribute('normal') as THREE.BufferAttribute).array as Float32Array, o * 3);
    C.set((p.getAttribute('color') as THREE.BufferAttribute).array as Float32Array, o * 3);
    o += c;
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(P, 3));
  g.setAttribute('normal', new THREE.BufferAttribute(N, 3));
  g.setAttribute('color', new THREE.BufferAttribute(C, 3));
  return g;
}

async function exportGroup(root: THREE.Object3D, file: string, filter: (m: THREE.Mesh) => boolean) {
  root.updateMatrixWorld(true);
  const out = new THREE.Group();
  out.name = file.replace('.glb', '');
  const byName: Record<string, THREE.BufferGeometry[]> = {};
  root.traverse((o) => {
    const m = o as THREE.Mesh;
    if (!m.isMesh || SKIP.test(m.name) || !filter(m)) return;
    const g = flatten(m);
    if (!g) return;
    const key = m.name || 'mesh';
    (byName[key] ??= []).push(g);
  });
  let tris = 0;
  for (const [name, gs] of Object.entries(byName)) {
    // Weld identical vertices (non-indexed -> indexed) to cut the file size.
    const g = mergeVertices(merge(gs), 1e-4);
    tris += (g.index ? g.index.count : g.getAttribute('position').count) / 3;
    const mesh = new THREE.Mesh(g, new THREE.MeshStandardMaterial({ name, vertexColors: true }));
    mesh.name = name;
    out.add(mesh);
  }
  const glb = await new GLTFExporter().parseAsync(out, { binary: true });
  fs.writeFileSync(`${OUT}/${file}`, Buffer.from(glb as ArrayBuffer));
  console.log(file, 'meshes', Object.keys(byName).length, 'tris', Math.round(tris), 'MB', ((glb as ArrayBuffer).byteLength / 1e6).toFixed(1));
}

const JSON_ONLY = process.argv.includes('--json-only');
async function main() {
  const ctx = makeCtx();
  const track = new Track();
  (ctx as any).track = track;
  track.init(ctx);
  const scenery = new Scenery();
  (scenery as any).init(ctx);

  // Track: everything under the circuit group.
  if (!JSON_ONLY) await exportGroup(track.group, 'track.glb', () => true);
  // Scenery: everything else in the scene.
  const rest = new THREE.Group();
  for (const c of [...ctx.scene.children]) if (c !== track.group && !(c as any).isLight) rest.add(c);
  if (!JSON_ONLY) await exportGroup(rest, 'scenery.glb', () => true);

  // Centreline every 2 m.
  const cl = track.cl;
  const step = Math.max(1, Math.round(2 / cl.ds));
  const st: number[][] = [];
  for (let i = 0; i < cl.count; i += step) {
    st.push([cl.px[i], cl.py[i], cl.pz[i], cl.tx[i], cl.ty[i], cl.tz[i], cl.nx[i], cl.ny[i], cl.nz[i],
      cl.bx[i], cl.by[i], cl.bz[i], cl.half[i], cl.bank[i], cl.curv[i], cl.race[i],
      cl.wallL[i], cl.wallR[i], cl.wallOffL[i], cl.wallOffR[i], cl.zone[i], cl.surfL[i], cl.surfR[i], cl.shoulderL[i], cl.shoulderR[i], cl.hx[i], cl.hz[i]].map((v) => Math.round(v * 1000) / 1000));
  }
  const data = {
    source: 'kart-royale Sunset Bay Circuit (MIT, ryancampbell/kart-royale)',
    fields: ['px', 'py', 'pz', 'tx', 'ty', 'tz', 'nx', 'ny', 'nz', 'bx', 'by', 'bz', 'half', 'bank', 'curv', 'race',
      'wallL', 'wallR', 'wallOffL', 'wallOffR', 'zone', 'surfL', 'surfR', 'shoulderL', 'shoulderR', 'hx', 'hz'],
    kerbWidth: 1.6, wallHeight: [0, 0.92, 4.5, 1.15],
    length: cl.length, stationSpacing: step * cl.ds, seaY: SEA_Y,
    stations: st,
    grid: track.startGrid.map((g) => ({ pos: [g.pos.x, g.pos.y, g.pos.z], yaw: g.yaw })),
    boostPads: BOOST_PADS,
  };
  fs.writeFileSync(`${OUT}/track_data.json`, JSON.stringify(data));
  console.log('track_data.json stations', st.length, 'length', cl.length.toFixed(1));
}
main().catch((e) => { console.error(e); process.exit(1); });
