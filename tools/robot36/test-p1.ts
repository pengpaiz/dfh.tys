/*
 * P1 验收测试（Node 运行）：合成 Robot36 调制信号 → 解码 → 与源图逐像素比对。
 * 运行：node --loader ./tools/robot36/loader.mjs tools/robot36/test-p1.ts
 */
import { Decoder } from '../../entry/src/main/ets/decoder/Decoder.ts';
import { YUV2RGB } from '../../entry/src/main/ets/decoder/ColorConverter.ts';
import { modulateRobot36 } from './Modulator36.ts';
import type { TestImage } from './Modulator36.ts';

let pass = 0;
let fail = 0;
function check(name: string, cond: boolean, detail: string = ''): void {
  if (cond) {
    pass++;
    console.log(`  PASS  ${name}${detail ? '  ' + detail : ''}`);
  } else {
    fail++;
    console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`);
  }
}

const SR = 48000;
const W = 320;
const H = 240;

interface DecodeResult {
  pixels: Int32Array;
  width: number;
  height: number;
  completed: boolean;
  decodedLines: number;
  visCount: number;
}

function decode(samples: Float32Array, rate: number): DecodeResult {
  const dec = new Decoder(rate, 0);
  let completed = false;
  let visCount = 0;
  let rowsWritten = 0;
  dec.onVis = (): void => {
    visCount++;
  };
  dec.onRows = (from: number, to: number): void => {
    rowsWritten += to - from;
  };
  dec.onComplete = (): void => {
    completed = true;
  };
  const chunk = Math.round(0.02 * rate);
  for (let off = 0; off < samples.length; off += chunk) {
    const n = Math.min(chunk, samples.length - off);
    dec.push(samples.subarray(off, off + n), n);
  }
  dec.finish();
  const img = dec.imageBuffer;
  return {
    pixels: Int32Array.from(img.pixels),
    width: img.width,
    height: img.height,
    completed,
    decodedLines: rowsWritten,
    visCount
  };
}

function makeImage(kind: string): TestImage {
  const y = new Float32Array(W * H);
  const u = new Float32Array(W * H);
  const v = new Float32Array(W * H);
  for (let row = 0; row < H; row++) {
    for (let col = 0; col < W; col++) {
      const i = row * W + col;
      if (kind === 'ramp') {
        // 水平灰度渐变（studio swing 16..235）
        y[i] = 16 + (219 * col) / (W - 1);
        u[i] = 128;
        v[i] = 128;
      } else if (kind === 'color') {
        y[i] = 100;
        u[i] = 90;
        v[i] = 170;
      } else {
        // 竖条（测试跳变）
        y[i] = (Math.floor(col / 20) % 2 === 0) ? 60 : 200;
        u[i] = 110;
        v[i] = 150;
      }
    }
  }
  return { width: W, height: H, y, u, v };
}

function compare(img: TestImage, res: DecodeResult): number {
  let worst = 0;
  for (let row = 0; row < H; row++) {
    for (let col = 0; col < W; col++) {
      const even = row % 2 === 0;
      const pairV = img.v[(even ? row : row - 1) * W + col];
      const pairU = img.u[(even ? row + 1 : row) * W + col];
      const expected = YUV2RGB(img.y[row * W + col], pairU, pairV);
      const actual = res.pixels[row * W + col];
      const de = Math.abs(((expected >> 16) & 255) - ((actual >> 16) & 255));
      const dg = Math.abs(((expected >> 8) & 255) - ((actual >> 8) & 255));
      const db = Math.abs((expected & 255) - (actual & 255));
      worst = Math.max(worst, de, dg, db);
    }
  }
  return worst;
}

console.log('=== P1: Robot 36 闭环（合成调制 → 解码 → 逐像素比对） ===');

for (const kind of ['ramp', 'color', 'bars']) {
  const img = makeImage(kind);
  const audio = modulateRobot36(img, SR);
  const t0 = Date.now();
  const res = decode(audio, SR);
  const dt = (Date.now() - t0) / 1000;
  const worst = compare(img, res);
  check(`[${kind}] 命中 VIS 1 次`, res.visCount === 1, `vis=${res.visCount}`);
  check(`[${kind}] 图像尺寸 320×240`, res.width === 320 && res.height === 240, `${res.width}×${res.height}`);
  check(`[${kind}] 收到 COMPLETE`, res.completed, `decodedLines=${res.decodedLines}`);
  check(`[${kind}] 逐像素误差 ≤ 3 LSB`, worst <= 3, `maxErr=${worst}  耗时=${dt.toFixed(2)}s`);
}

console.log(`\n结果：PASS ${pass} / FAIL ${fail}`);
if (fail > 0) {
  process.exitCode = 1;
}