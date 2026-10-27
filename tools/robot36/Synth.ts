/*
 * 测试用合成器（仅测试代码）：生成 VIS 头音频与 WAV 文件，用于 P0 验收。
 * 不参与 app 运行。
 */

export function synthTone(out: Float32Array, startSample: number, seconds: number, freq: number, sampleRate: number, phaseRef: { p: number }): number {
  const n = Math.round(seconds * sampleRate);
  for (let i = 0; i < n; i++) {
    out[startSample + i] = 0.8 * Math.sin(phaseRef.p);
    phaseRef.p += 2 * Math.PI * freq / sampleRate;
  }
  return startSample + n;
}

/** 生成一个 VIS 头：leader 1900×300ms / break 1200×10ms / leader 1900×300ms / start 1200×30ms / 7 数据位 + 奇偶位 / stop 1200×30ms */
export function synthVis(out: Float32Array, startSample: number, visCode: number, sampleRate: number, offsetHz: number, phaseRef: { p: number }): number {
  let pos = startSample;
  pos = synthTone(out, pos, 0.3, 1900 + offsetHz, sampleRate, phaseRef);
  pos = synthTone(out, pos, 0.01, 1200 + offsetHz, sampleRate, phaseRef);
  pos = synthTone(out, pos, 0.3, 1900 + offsetHz, sampleRate, phaseRef);
  pos = synthTone(out, pos, 0.03, 1200 + offsetHz, sampleRate, phaseRef);
  // 7 个数据位（LSB 优先）+ 1 个奇偶位（数据位中有奇数个 1 时置 1 → 总数为偶数，符合参考实现校验）
  let dataOnes = 0;
  const bits: number[] = [];
  for (let i = 0; i < 7; i++) {
    const b = (visCode >> i) & 1;
    bits.push(b);
    dataOnes += b;
  }
  bits.push(dataOnes % 2 === 1 ? 1 : 0);
  for (let i = 0; i < 8; i++) {
    pos = synthTone(out, pos, 0.03, (bits[i] === 1 ? 1100 : 1300) + offsetHz, sampleRate, phaseRef);
  }
  pos = synthTone(out, pos, 0.03, 1200 + offsetHz, sampleRate, phaseRef);
  return pos;
}

export function visLengthSamples(sampleRate: number): number {
  return Math.round((0.3 + 0.01 + 0.3 + 0.03 + 8 * 0.03 + 0.03) * sampleRate);
}

/** 写 16-bit PCM 单声道 WAV */
export function writeWav16(samples: Float32Array, sampleRate: number, channels: number = 1): Uint8Array {
  const frames = Math.floor(samples.length / channels);
  const dataBytes = frames * channels * 2;
  const buf = new ArrayBuffer(44 + dataBytes);
  const dv = new DataView(buf);
  const w = (p: number, s: string): void => {
    for (let i = 0; i < 4; i++) {
      dv.setUint8(p + i, s.charCodeAt(i));
    }
  };
  w(0, 'RIFF');
  dv.setUint32(4, 36 + dataBytes, true);
  w(8, 'WAVE');
  w(12, 'fmt ');
  dv.setUint32(16, 16, true);
  dv.setUint16(20, 1, true);
  dv.setUint16(22, channels, true);
  dv.setUint32(24, sampleRate, true);
  dv.setUint32(28, sampleRate * channels * 2, true);
  dv.setUint16(32, channels * 2, true);
  dv.setUint16(34, 16, true);
  w(36, 'data');
  dv.setUint32(40, dataBytes, true);
  for (let i = 0; i < samples.length; i++) {
    let v = Math.max(-1, Math.min(1, samples[i]));
    dv.setInt16(44 + i * 2, Math.round(v * 32767), true);
  }
  return new Uint8Array(buf);
}

/** 写任意位深/编码的单声道 WAV（用于 WAV 解析测试） */
export function writeWavRaw(samples: Float32Array, sampleRate: number, channels: number, bits: number, encoding: number): Uint8Array {
  const width = bits / 8;
  const frames = Math.floor(samples.length / channels);
  const dataBytes = frames * channels * width;
  const buf = new ArrayBuffer(44 + dataBytes);
  const dv = new DataView(buf);
  const w = (p: number, s: string): void => {
    for (let i = 0; i < 4; i++) {
      dv.setUint8(p + i, s.charCodeAt(i));
    }
  };
  w(0, 'RIFF');
  dv.setUint32(4, 36 + dataBytes, true);
  w(8, 'WAVE');
  w(12, 'fmt ');
  dv.setUint32(16, 16, true);
  dv.setUint16(20, encoding, true);
  dv.setUint16(22, channels, true);
  dv.setUint32(24, sampleRate, true);
  dv.setUint32(28, sampleRate * channels * width, true);
  dv.setUint16(32, channels * width, true);
  dv.setUint16(34, bits, true);
  w(36, 'data');
  dv.setUint32(40, dataBytes, true);
  for (let i = 0; i < samples.length; i++) {
    const v = Math.max(-1, Math.min(1, samples[i]));
    const p = 44 + i * width;
    if (encoding === 3) {
      if (bits === 32) {
        dv.setFloat32(p, v, true);
      } else {
        dv.setFloat64(p, v, true);
      }
    } else if (bits === 8) {
      dv.setUint8(p, Math.round((v + 1) * 128) & 255);
    } else if (bits === 16) {
      dv.setInt16(p, Math.round(v * 32767), true);
    } else if (bits === 24) {
      const int24 = Math.round(v * 8388607);
      dv.setUint8(p, int24 & 255);
      dv.setUint8(p + 1, (int24 >> 8) & 255);
      dv.setUint8(p + 2, (int24 >> 16) & 255);
    } else {
      dv.setInt32(p, Math.round(v * 2147483647), true);
    }
  }
  return new Uint8Array(buf);
}