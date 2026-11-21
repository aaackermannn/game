import * as THREE from 'three';
// Minimal engine context: real scene, everything else a harmless stand-in.
function stub(name: string): any {
  return new Proxy(function () {} as any, {
    get(_t, k) {
      if (k === Symbol.toPrimitive) return () => 0;
      if (k === 'then') return undefined;
      return stub(name + '.' + String(k));
    },
    apply() { return stub(name + '()'); },
  });
}

export function makeCtx() {
  const scene = new THREE.Scene();
  const ctx: any = {
    scene,
    camera: new THREE.PerspectiveCamera(70, 16 / 9, 0.1, 5000),
    time: 0, dt: 1 / 60, frame: 0, width: 1600, height: 900,
    envMap: null, sun: new THREE.DirectionalLight(), sunDirection: new THREE.Vector3(-0.62, 0.245, -0.745).normalize(),
    shake() {}, bus: { on() {}, off() {}, emit() {} },
  };
  return new Proxy(ctx, {
    get(t, k) {
      if (k in t) return t[k];
      return stub('ctx.' + String(k));
    },
  });
}

