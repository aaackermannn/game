// Browser stand-ins backed by a real 2D canvas (@napi-rs/canvas), so kart-royale's
// procedural textures are actually painted and can be baked into vertex colours.
import { createCanvas, ImageData as NImageData } from '@napi-rs/canvas';

const g = globalThis as any;
class OffscreenCanvasShim {
  constructor(w: number, h: number) {
    return createCanvas(Math.max(1, w | 0), Math.max(1, h | 0)) as any;
  }
}
g.OffscreenCanvas = OffscreenCanvasShim;
g.HTMLCanvasElement = Object;
g.ImageData = NImageData;
g.document = {
  createElement: (t: string) => (t === 'canvas' ? createCanvas(1, 1) : { style: {}, appendChild() {}, setAttribute() {} }),
  createElementNS: () => createCanvas(1, 1),
  body: { appendChild() {} },
};
g.window = globalThis;
g.self = globalThis;
g.requestAnimationFrame = () => 0;
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
};
