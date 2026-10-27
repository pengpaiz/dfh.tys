/*
 * 复现：VIS 不在音频开头时是否还能识别（合成 Robot36 + 各种前缀）。
 * 运行：node --loader ./tools/robot36/loader.mjs tools/robot36/repro-previs.ts
 */
import { Decoder } from '../../entry/src/main/ets/decoder/Decoder.ts';
import { modulateRobot36 } from './Modulator36.ts';
import type { TestImage } from './Modulator36.ts';

const SR = 48000;
const W = 320;
const H = 240;

function makeImg(): TestImage {
  const y = new Float32Array(W * H);
  const u = new Float32Array(W * H);
  const v = new Float32Array(W * H);
  for (let row = 0; row < H; row++) {
    for (let col = 0; col < W; col++) {
      const i = row * W + col;
      y[i] = 16 + (219 * col) / (W - 1);
      u[i] = 128;
      v[i] = 128;
    }
  }
  return { width: W, height: H, y, u, v };
}

function decode(samples: Float32Array): { vis: number; rows: number; complete: boolean; firstVisAt: number; msgs: string[] } {
  const dec = new Decoder(SR, 0);
  let vis = 0;
  let rows = 0;
  let complete = false;
  let firstVisAt = -1;
  let pushed = 0;
  const msgs: string[] = [];
  const seen: Record<string, number> = {};
  dec.onVis = (code: number, name: string, atSec: number): void => { vis++; if (firstVisAt < 0) firstVisAt = atSec; };
  dec.onRows = (from: number, to: number): void => { rows += to - from; };
  dec.onComplete = (): void => { complete = true; };
  dec.debug = (m: string): void => { msgs.push(m); };
  const chunk = Math.round(0.02 * SR);
  for (let o = 0; o < samples.length; o += chunk) {
    const n = Math.min(chunk, samples.length - o);
    dec.push(samples.subarray(o, o + n), n);
    pushed += n;
  }
  dec.finish();
  for (const k of Object.keys(seen)) {
    if (k.indexOf('freq') >= 0 || k.indexOf('bit') >= 0 || k.indexOf('VIS') >= 0 || k.indexOf('mismatch') >= 0) {
      msgs.push(`[x${seen[k]}] ${k}`);
    }
  }
  return { vis, rows, complete, firstVisAt, msgs };
}

function silence(sec: number): Float32Array {
  return new Float32Array(Math.round(sec * SR));
}
function tone(hz: number, sec: number): Float32Array {
  const a = new Float32Array(Math.round(sec * SR));
  for (let i = 0; i < a.length; i++) a[i] = 0.5 * Math.sin(2 * Math.PI * hz * i / SR);
  return a;
}
function noise(sec: number): Float32Array {
  const a = new Float32Array(Math.round(sec * SR));
  let seed = 12345;
  for (let i = 0; i < a.length; i++) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; a[i] = (seed / 0x3fffffff - 1) * 0.3; }
  return a;
}
function concat(a: Float32Array, b: Float32Array): Float32Array {
  const out = new Float32Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

const audio = modulateRobot36(makeImg(), SR);
console.log(`标准 Robot36 音频长度=${(audio.length / SR).toFixed(2)}s`);

const cases: [string, Float32Array][] = [
  ['0s', new Float32Array(0)],
  ['5s 静音', silence(5)],
  ['6s 静音', silence(6)],
  ['6.5s 静音', silence(6.5)],
  ['6.8s 静音', silence(6.8)],
  ['7.0s 静音', silence(7.0)],
  ['7.2s 静音', silence(7.2)],
  ['8s 静音', silence(8)],
  ['6.8s 1900Hz', tone(1900, 6.8)],
  ['7.2s 1900Hz', tone(1900, 7.2)]
];

console.log('前缀'.padEnd(20) + '  vis  rows  complete  firstVisAt(s)');
for (const [name, prefix] of cases) {
  const samples = concat(prefix, audio);
  const r = decode(samples);
  console.log(`${name.padEnd(20)}  ${String(r.vis).padStart(2)}   ${String(r.rows).padStart(3)}   ${r.complete ? 'Y' : 'N'}         ${r.firstVisAt.toFixed(2)}`);
  if (r.msgs.length > 0) {
    console.log(`      debug(尾部): ${r.msgs.slice(-8).join(' | ')}`);
  }
}