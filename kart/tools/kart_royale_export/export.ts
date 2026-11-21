import './shim';
import * as THREE from 'three';
import { GLTFExporter } from 'three/examples/jsm/exporters/GLTFExporter.js';
import { buildKart } from '../kr-src/kart-royale-main/src/kart/KartModel';
import { kartMaterials } from '../kr-src/kart-royale-main/src/kart/Liveries';
import * as fs from 'node:fs';

const OUT = process.argv[2];
// Loop GP roster colours (same order as Game.ROSTER).
const ROSTER: [string, number][] = [
  ['Rico Blaze', 0xec2b3a], ['Momo Volt', 0x2b7ff0], ['Pip Clover', 0x4cd35a], ['Juno Fizz', 0xff5fb4],
  ['Taro Dash', 0xff8a1f], ['Nyx Bolt', 0x9a4cf0], ['Bix Turbo', 0xffd21f], ['Ollie Gear', 0x3fe0e8],
];
const ROT = new THREE.Matrix4().makeRotationY(Math.PI); // their +Z forward -> Godot -Z forward

function exportMat(src: THREE.Material, geo: THREE.BufferGeometry, role: string): THREE.MeshStandardMaterial {
  const s = src as THREE.MeshStandardMaterial;
  const m = new THREE.MeshStandardMaterial({
    name: role,
    color: s.color ? s.color.clone() : new THREE.Color(1, 1, 1),
    vertexColors: !!geo.getAttribute('color'),
    roughness: role === 'paint' ? 0.3 : 0.8,
    metalness: 0,
  });
  if (role === 'glass') m.color.set(0x1d2a3a);
  return m;
}

function bake(mesh: THREE.Mesh, rel: THREE.Matrix4, name: string, role: string): THREE.Mesh {
  const g = new THREE.BufferGeometry();
  for (const k of ['position', 'normal', 'color']) {
    const a = mesh.geometry.getAttribute(k) as THREE.BufferAttribute | undefined;
    if (a) g.setAttribute(k, a.clone());
  }
  const idx = mesh.geometry.getIndex();
  if (idx) g.setIndex(idx.clone());
  g.applyMatrix4(rel);
  // Tyre rubber is white in vertex colour (a texture darkens it in the original); bake it dark.
  const col = g.getAttribute('color') as THREE.BufferAttribute | undefined;
  if (role === 'wheel' && col) {
    for (let i = 0; i < col.count; i++) {
      if (col.getX(i) > 0.95 && col.getY(i) > 0.95 && col.getZ(i) > 0.95) col.setXYZ(i, 0.03, 0.028, 0.034);
    }
  }
  const mat = Array.isArray(mesh.material) ? mesh.material[0] : mesh.material;
  const out = new THREE.Mesh(g, exportMat(mat, g, role));
  out.name = name;
  return out;
}

function roleOf(m: THREE.Mesh, mats: Record<string, unknown>): string {
  const mat = Array.isArray(m.material) ? m.material[0] : m.material;
  for (const k in mats) if (mats[k] === mat) return k;
  const n = m.name.toLowerCase();
  if (n.includes('visor')) return 'glass';
  if (n.includes('livery') || n.includes('decal')) return 'decal';
  if (n.includes('arm')) return 'character';
  return 'misc_' + m.name;
}

async function main() {
  const mats = kartMaterials() as unknown as Record<string, unknown>;
  for (let i = 0; i < ROSTER.length; i++) {
    const [name, hex] = ROSTER[i];
    const { root, wheels } = buildKart({ name, color: new THREE.Color(hex), accelMul: 1, topSpeedMul: 1, weightMul: 1, handlingMul: 1 } as any);
    root.updateMatrixWorld(true);
    const scene = new THREE.Group();
    scene.name = 'kart';
    const body = new THREE.Group();
    body.name = 'Body';
    scene.add(body);
    const pilot = new THREE.Group();
    pilot.name = 'Pilot';
    scene.add(pilot);
    const head = new THREE.Group();
    head.name = 'Head';
    pilot.add(head);
    const skip = new Set(['shadowBlob', 'kartImpostor', 'bodyLivery']);
    const tyres = root.getObjectByName('tyres') as THREE.InstancedMesh | undefined;
    const helmet = root.getObjectByName('driverHelmet');
    const headGroup = helmet?.parent ?? null;
    if (headGroup) head.position.setFromMatrixPosition(headGroup.matrixWorld).applyMatrix4(ROT);
    const headInv = new THREE.Matrix4().makeTranslation(-head.position.x, -head.position.y, -head.position.z);
    const roles: Record<string, number> = {};
    root.traverse((o) => {
      const m = o as THREE.Mesh;
      if (!m.isMesh || skip.has(m.name) || m === tyres) return;
      const role = roleOf(m, mats);
      roles[m.name + ':' + role] = 1;
      const world = ROT.clone().multiply(m.matrixWorld);
      let inDriver = false;
      let inHead = false;
      for (let p: THREE.Object3D | null = m; p; p = p.parent) {
        if (p.name === 'driver') inDriver = true;
        if (headGroup && p === headGroup) inHead = true;
      }
      if (inHead) head.add(bake(m, headInv.clone().multiply(world), m.name, role));
      else if (inDriver) pilot.add(bake(m, world, m.name, role));
      else body.add(bake(m, world, m.name, role));
    });
    if (tyres) {
      wheels.forEach((w, k) => {
        const pos = new THREE.Vector3().setFromMatrixPosition(w.matrixWorld).applyMatrix4(ROT);
        const pivot = new THREE.Group();
        pivot.name = 'Wheel' + (pos.z < 0 ? 'F' : 'R') + (pos.x < 0 ? 'L' : 'R');
        pivot.position.copy(pos);
        const inst = new THREE.Matrix4();
        tyres.getMatrixAt(k, inst);
        const instWorld = ROT.clone().multiply(tyres.matrixWorld).multiply(inst);
        const rel = new THREE.Matrix4().makeTranslation(-pos.x, -pos.y, -pos.z).multiply(instWorld);
        pivot.add(bake(tyres, rel, pivot.name + '_tyre', 'wheel'));
        scene.add(pivot);
      });
    }
    const glb = await new GLTFExporter().parseAsync(scene, { binary: true });
    const file = `${OUT}/kart_${i}.glb`;
    fs.writeFileSync(file, Buffer.from(glb as ArrayBuffer));
    let tris = 0;
    scene.traverse((o) => {
      const m = o as THREE.Mesh;
      if (m.isMesh) tris += (m.geometry.index ? m.geometry.index.count : m.geometry.getAttribute('position').count) / 3;
    });
    console.log(file, 'tris', Math.round(tris), 'head', !!headGroup, 'body', body.children.length, 'pilot', pilot.children.length);
    if (i === 0) console.log(Object.keys(roles).join(' | '));
  }
}
main().catch((e) => {
  console.error(e);
  process.exit(1);
});
