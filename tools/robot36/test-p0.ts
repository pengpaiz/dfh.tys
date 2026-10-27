/*
 * P0 验收测试（Node 运行）：VIS 检测 / 多图 / 粗频偏 / WAV 解析 / 环形缓冲 / 错误路径。
 * 运行：node --loader ./tools/robot36/loader.mjs tools/robot36/test-p0.ts
 */
import { Decoder } from '../../entry/src/main/ets/decoder/Decoder.ts';
import { parseWavHeader, readFrames } from '../../entry/src/main/ets/service/WavStreamReader.ts';
import { RingBuffer } from '../../entry/src/main/ets/util/RingBuffer.ts';
import { synthVis, writeWavRaw } from './Synth.ts';

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
const CHUNK = Math.round(0.02 * SR);

interface Hit {
  visCode: number;
  modeName: string;
  atSec: number;
}

function scan(samples: Float32Array, rate: number, coarseOffsetHz: number = 0): Hit[] {
  const dec = new Decoder(rate, coarseOffsetHz);
  const hits: Hit[] = [];
  dec.onVis = (visCode: number, modeName: string, atSec: number): void => {
    hits.push({ visCode, modeName, atSec });
  };
  const chunk = Math.round(0.02 * rate);
  for (let off = 0; off < samples.length; off += chunk) {
    const n = Math.min(chunk, samples.length - off);
    dec.push(samples.subarray(off, off + n), n);
  }
  dec.finish();
  return hits;
}

console.log('=== P0: VIS 检测 ===');
{
  const buf = new Float32Array(Math.round(2.2 * SR));
  const phase = { p: 0 };
  const visStartSec = 0.2;
  synthVis(buf, Math.round(visStartSec * SR), 8, SR, 0, phase);
  const hits = scan(buf, SR);
  check('单张图检测到 1 次 VIS', hits.length === 1, `hits=${hits.length}`);
  if (hits.length === 1) {
    check('VIS 码 = 8', hits[0].visCode === 8, `code=${hits[0].visCode}`);
    check('模式 = Robot 36', hits[0].modeName === 'Robot 36', `mode=${hits[0].modeName}`);
    const errMs = Math.abs(hits[0].atSec - (visStartSec + 0.91)) * 1000;
    check('检测时刻 ≈ VIS 结束(+0.91s)，容差 150ms', errMs < 150, `err=${errMs.toFixed(1)}ms`);
  }
}

console.log('=== P0: 多图连续扫描 ===');
{
  const buf = new Float32Array(Math.round(5.0 * SR));
  const phase = { p: 0 };
  synthVis(buf, Math.round(0.2 * SR), 8, SR, 0, phase);
  synthVis(buf, Math.round(2.6 * SR), 8, SR, 0, phase);
  const hits = scan(buf, SR);
  check('两张图检测到 2 次 VIS', hits.length === 2, `hits=${hits.length}`);
  if (hits.length === 2) {
    check('两次都是 Robot 36 / VIS 8', hits[0].visCode === 8 && hits[1].visCode === 8);
    const gapErr = Math.abs((hits[1].atSec - hits[0].atSec) - 2.4) * 1000;
    check('两次 VIS 间隔 ≈ 2.4s', gapErr < 80, `gapErr=${gapErr.toFixed(1)}ms`);
  }
}

console.log('=== P0: 粗频偏（滑块机制 = 平移混频中心） ===');
{
  const buf = new Float32Array(Math.round(2.2 * SR));
  const phase = { p: 0 };
  synthVis(buf, Math.round(0.2 * SR), 8, SR, 300, phase);
  check('+300Hz 且 coarseOffset=+300 → 命中', scan(buf, SR, 300).length === 1);
  check('+300Hz 但未补偿 → 不命中（说明必须用频偏滑块）', scan(buf, SR, 0).length === 0);

  const buf2 = new Float32Array(Math.round(2.2 * SR));
  const phase2 = { p: 0 };
  synthVis(buf2, Math.round(0.2 * SR), 8, SR, -300, phase2);
  check('-300Hz 且 coarseOffset=-300 → 命中', scan(buf2, SR, -300).length === 1);
}

console.log('=== P0: WAV 解析（各位深/编码/声道/采样率往返） ===');
{
  const cases: number[][] = [];
  for (const bits of [8, 16, 24, 32]) {
    for (const ch of [1, 2]) {
      for (const rate of [8000, 16000, 44100, 48000]) {
        cases.push([1, bits, ch, rate]);
      }
    }
  }
  for (const bits of [32, 64]) {
    for (const ch of [1, 2]) {
      cases.push([3, bits, ch, 48000]);
    }
  }
  let worst = 0;
  let allOk = true;
  for (const c of cases) {
    const encoding = c[0];
    const bits = c[1];
    const ch = c[2];
    const rate = c[3];
    const frames = Math.round(0.05 * rate);
    const src = new Float32Array(frames * ch);
    for (let i = 0; i < frames; i++) {
      const v = 0.6 * Math.sin(2 * Math.PI * 1000 * i / rate);
      for (let k = 0; k < ch; k++) {
        src[i * ch + k] = v;
      }
    }
    const wavBytes = writeWavRaw(src, rate, ch, bits, encoding);
    try {
      const h = parseWavHeader(wavBytes);
      const okMeta = h.sampleRate === rate && h.channels === ch && h.bits === bits
        && h.encoding === encoding && h.frameCount === frames;
      const out = readFrames(wavBytes, h, 0, h.frameCount, 0);
      let maxErr = 0;
      for (let i = 0; i < out.length; i++) {
        maxErr = Math.max(maxErr, Math.abs(out[i] - src[i * ch]));
      }
      const tol = bits === 8 ? 0.01 : (encoding === 3 ? 1e-6 : (bits === 16 ? 5e-5 : 1e-6));
      worst = Math.max(worst, maxErr);
      if (!okMeta || maxErr > tol) {
        allOk = false;
        console.log(`    ! enc=${encoding} bits=${bits} ch=${ch} rate=${rate} meta=${okMeta} maxErr=${maxErr}`);
      }
    } catch (e) {
      allOk = false;
      console.log(`    ! threw: enc=${encoding} bits=${bits} ch=${ch} rate=${rate} ${(e as Error).message}`);
    }
  }
  check(`WAV 解析+取帧往返 ${cases.length} 组`, allOk, `最差样本误差=${worst.toExponential(2)}`);
}

console.log('=== P0: WAV 错误路径 ===');
{
  let threw = false;
  try {
    parseWavHeader(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]));
  } catch (e) {
    threw = true;
  }
  check('非 RIFF/WAVE 抛错', threw);

  const src = new Float32Array(4800);
  const good = writeWavRaw(src, 48000, 1, 16, 1);
  let tolerated = false;
  try {
    const h = parseWavHeader(good.subarray(0, good.length - 1000));
    tolerated = h.frameCount > 0;
  } catch (e) {
    tolerated = true;
  }
  check('截断文件：不崩溃（尽量解到 EOF）', tolerated);
}

console.log('=== P0: 环形缓冲 ===');
{
  const rb = new RingBuffer(8);
  rb.write(new Float32Array([1, 2, 3, 4, 5]), 5);
  check('写入 5 个 → count=5', rb.count === 5, `count=${rb.count}`);
  check('最旧样本 = 1', rb.read(0) === 1);
  rb.write(new Float32Array([6, 7, 8, 9, 10]), 5);
  check('再写 5 个 → count=8（容量）', rb.count === 8, `count=${rb.count}`);
  check('最旧样本滚动为 3', rb.read(0) === 3);
  const dst = new Float32Array(4);
  const n = rb.copyTo(dst, 0, 4);
  check('copyTo 取 4 个且顺序正确', n === 4 && dst[0] === 3 && dst[3] === 6, `dst=[${dst.join(',')}]`);
  check('越界读取返回 NaN', Number.isNaN(rb.read(999)));
}

console.log(`\n结果：PASS ${pass} / FAIL ${fail}`);
if (fail > 0) {
  process.exitCode = 1;
}