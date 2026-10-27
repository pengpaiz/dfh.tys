/*
 * 前端量测：合成机器人 36 音频后，直接看解调值在 Y 段/分隔段/色度段是否与期望一致。
 * 运行：node --loader ./tools/robot36/loader.mjs tools/robot36/probe5.ts
 */
import { Demodulator } from '../../entry/src/main/ets/decoder/Demodulator.ts';
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

const demod = new Demodulator(SR, 0);
const out = new Float32Array(960);
const vals: number[] = [];
// 期望（相对音频起点）：VIS 结束 = 0.2 + 0.91 = 1.11s；第一行起点 = 1.11s
const lineStart = Math.round(1.11 * SR);
const marks: number[][] = [
  [0.0045, 1200],   // 同步中部
  [0.010, 1500],    // porch
  [0.056, 100 + 0], // Y 中部（code 100 → 1814Hz）
  [0.102, 2300],    // 分隔（第一行为 even → 1500；用 0.102 测 even）
  [0.128, 170]      // 色度（even → V=170）
];
const results: number[] = [];
for (let s = 0; s < audio.length; s += 960) {
  const n = Math.min(960, audio.length - s);
  demod.processMono(audio.subarray(s, s + n), n, out);
  for (let i = 0; i < n; i++) {
    vals.push(out[i]);
  }
}
const freq = (v01: number): number => 1900 + 400 * v01;
for (const m of marks) {
  const idx = lineStart + Math.round(m[0] * SR);
  // 取该点附近 64 样本均值
  let acc = 0;
  for (let k = 0; k < 64; k++) {
    acc += vals[idx + k];
  }
  const vv = acc / 64;
  results.push(vv);
  console.log(`t=+${(m[0] * 1000).toFixed(1)}ms expect≈${m[1]}Hz  got=${freq(vv).toFixed(1)}Hz (v=${vv.toFixed(3)})`);
}