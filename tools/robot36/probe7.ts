/*
 * 行内时间轴诊断：打印前几行的 Y/色度采样头，判断窗口是否错位/错段。
 * 运行：node --loader ./tools/robot36/loader.mjs tools/robot36/probe7.ts
 */
import { Decoder } from '../../entry/src/main/ets/decoder/Decoder.ts';
import { modulateRobot36 } from './Modulator36.ts';

const SR = 48000;
const W = 320;
const H = 240;
const y = new Float32Array(W * H);
const u = new Float32Array(W * H);
const v = new Float32Array(W * H);
for (let i = 0; i < W * H; i++) {
  y[i] = 100;
  u[i] = 90;
  v[i] = 170;
}
const audio = modulateRobot36({ width: W, height: H, y, u, v }, SR);
const dec = new Decoder(SR, 0);

let printed = 0;
const origRows = dec.onRows;
dec.onRows = (f: number, t: number): void => {
  if (printed < 6) {
    printed++;
    const m = (dec as unknown as { mode: { lastLumHead: Float32Array; lastChrHead: Float32Array; lastSeparator: number; lastEvenFlag: boolean } }).mode;
    const fmt = (a: Float32Array): string => Array.from(a).map((x) => x.toFixed(2)).join(',');
    console.log(`rows ${f}..${t} even=${m.lastEvenFlag} sep=${m.lastSeparator.toFixed(2)} evenPacked=${m.lastEvenPacked.toString(16)} row0=${m.lastRow0Packed.toString(16)} row1=${m.lastRow1Packed.toString(16)}`);
    console.log(`   Y head: ${fmt(m.lastLumHead)}`);
    console.log(`   C head: ${fmt(m.lastChrHead)}`);
  }
  if (origRows !== null) {
    origRows(f, t);
  }
};

let dbg = 0;
dec.debug = (m: string): void => {
  if (dbg < 10) {
    dbg++;
    console.log('[d]', m);
  }
};
const chunk = Math.round(0.02 * SR);
for (let off = 0; off < audio.length; off += chunk) {
  const n = Math.min(chunk, audio.length - off);
  dec.push(audio.subarray(off, off + n), n);
}
dec.finish();
console.log('done');
const px = dec.imageBuffer.pixels;
console.log('imageBuffer.pixels[0]   =', (px[0] >>> 0).toString(16));
console.log('imageBuffer.pixels[160] =', (px[160] >>> 0).toString(16));
console.log('imageBuffer.pixels[32160]=', (px[32160] >>> 0).toString(16));
console.log('期望：非黑（常量图 Y=100,U=90,V=170 → 约 0xFF6B9E??）');