// Browser stand-ins so kart-royale's procedural model code runs in Node.
// Canvas work (texture painting) becomes a no-op; geometry and vertex colours are untouched.
const ctxProxy = (w: number, h: number): any =>
  new Proxy({ canvas: { width: w, height: h } } as any, {
    get(t: any, k: string) {
      if (k in t) return t[k];
      if (k === 'getImageData' || k === 'createImageData') {
        return (...a: any[]) => {
          const ww = (a.length >= 4 ? a[2] : a[0]) | 0 || w;
          const hh = (a.length >= 4 ? a[3] : a[1]) | 0 || h;
          return { width: ww, height: hh, data: new Uint8ClampedArray(ww * hh * 4) };
        };
      }
      if (k === 'measureText') return () => ({ width: 10, actualBoundingBoxAscent: 8, actualBoundingBoxDescent: 2 });
      if (k === 'createLinearGradient' || k === 'createRadialGradient' || k === 'createPattern') {
        return () => ({ addColorStop() {} });
      }
      return () => undefined;
    },
    set(t: any, k: string, v: any) {
      t[k] = v;
      return true;
    },
  });

class FakeCanvas {
  width: number;
  height: number;
  style: any = {};
  constructor(w = 1, h = 1) {
    this.width = w;
    this.height = h;
  }
  getContext() {
    return ctxProxy(this.width, this.height);
  }
  toDataURL() {
    return 'data:image/png;base64,';
  }
  addEventListener() {}
}

const g = globalThis as any;
g.OffscreenCanvas = FakeCanvas;
g.HTMLCanvasElement = FakeCanvas;
g.document = {
  createElement: (t: string) => (t === 'canvas' ? new FakeCanvas() : { style: {}, appendChild() {}, setAttribute() {} }),
  createElementNS: () => new FakeCanvas(),
  body: { appendChild() {} },
};
g.window = globalThis;
g.self = globalThis;
g.ImageData = class {
  data: Uint8ClampedArray;
  width: number;
  height: number;
  constructor(d: any, w: number, h?: number) {
    this.width = w;
    this.height = h ?? w;
    this.data = d instanceof Uint8ClampedArray ? d : new Uint8ClampedArray(this.width * this.height * 4);
  }
};
g.FileReader = class {
  result: any;
  onloadend: any;
  onload: any;
  readAsArrayBuffer(b: Blob) {
    b.arrayBuffer().then((r) => {
      this.result = r;
      this.onload?.({ target: this });
      this.onloadend?.({ target: this });
    });
  }
  readAsDataURL(b: Blob) {
    b.arrayBuffer().then((r) => {
      this.result = 'data:application/octet-stream;base64,' + Buffer.from(r).toString('base64');
      this.onload?.({ target: this });
      this.onloadend?.({ target: this });
    });
  }
};
g.requestAnimationFrame = () => 0;
